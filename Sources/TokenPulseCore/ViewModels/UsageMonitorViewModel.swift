import Combine
import Foundation
import SwiftUI

protocol InteractiveClaudeProvider: QuotaProvider {
    func fetchSnapshot(allowKeychainPrompt: Bool) async -> ProviderSnapshot
}

extension ClaudeProvider: InteractiveClaudeProvider {}

@MainActor
public final class UsageMonitorViewModel: ObservableObject {
    @Published public private(set) var snapshots: [ProviderSnapshot] = []
    @Published public private(set) var activeAlerts: [SurplusAlert] = []
    @Published public private(set) var bestRecommendation: (provider: AIProviderKind, reason: String)?
    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var lastRefreshedAt: Date?

    @Published public var preferences: AppPreferences {
        didSet {
            savePreferences()
            if oldValue.refreshIntervalMinutes != preferences.refreshIntervalMinutes {
                restartTimer()
            }
            if oldValue.demoMode != preferences.demoMode {
                Task { await refreshAll(triggerNotifications: false) }
            } else {
                reevaluateAlerts(triggerNotifications: false)
            }
        }
    }

    private let forecastEngine: WeeklyQuotaForecastEngine
    @Published private(set) var weeklyForecasts: [AIProviderKind: WeeklyQuotaForecast] = [:]

    private let defaults: UserDefaults
    private let providers: [any QuotaProvider]
    private let alertEngine: SurplusAlertEngine
    private var refreshTimer: Timer?
    private var antigravityFeedWatcher: (any DispatchSourceFileSystemObject)?
    private var pendingRefresh: (notify: Bool, connect: Bool)?
    private var lastLiveSnapshots: [AIProviderKind: ProviderSnapshot] = [:]
    private let quotaCacheKey = "TokenPulse.QuotaCache.v1"
    private let prefsKey = "TokenPulse.Preferences.v1"

    public init(
        providers: [any QuotaProvider] = [
            ClaudeProvider(),
            CodexProvider(),
            AntigravityProvider()
        ],
        alertEngine: SurplusAlertEngine = SurplusAlertEngine(),
        defaults: UserDefaults = .standard
    ) {
        self.forecastEngine = WeeklyQuotaForecastEngine(defaults: defaults)
        self.defaults = defaults
        self.providers = providers
        self.alertEngine = alertEngine
        if let data = defaults.data(forKey: prefsKey),
           let decoded = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            self.preferences = decoded
        } else {
            self.preferences = AppPreferences()
        }
        if let data = defaults.data(forKey: quotaCacheKey),
           let saved = try? JSONDecoder().decode([AIProviderKind: ProviderSnapshot].self, from: data) {
            lastLiveSnapshots = saved
        }
        snapshots = preferences.demoMode ? Self.makeDemoSnapshots() : cachedSnapshots()
    }

    private func cachedSnapshots() -> [ProviderSnapshot] {
        let now = Date()
        return AIProviderKind.allCases.compactMap { provider in
            lastLiveSnapshots[provider].flatMap { cachedCopy(of: $0, at: now) }
        }
    }

    public func startMonitoring() {
        Task { _ = await NotificationManager.shared.requestAuthorization() }
        Task { await refreshAll(triggerNotifications: true) }
        restartTimer()
        if antigravityFeedWatcher == nil, providers.contains(where: { $0 is AntigravityProvider }) {
            antigravityFeedWatcher = AntigravityQuotaFeed.watch { [weak self] in
                self?.applyAntigravityFeed()
            }
            applyAntigravityFeed()
        }
    }

    public func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        antigravityFeedWatcher?.cancel()
        antigravityFeedWatcher = nil
    }

    public func refreshAll(triggerNotifications: Bool = true, connectClaude: Bool = false) async {
        guard !isRefreshing else {
            pendingRefresh = (triggerNotifications || pendingRefresh?.notify == true,
                              connectClaude || pendingRefresh?.connect == true)
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        var request: (notify: Bool, connect: Bool)? = (triggerNotifications, connectClaude)
        while let next = request {
            await performRefresh(triggerNotifications: next.notify, connectClaude: next.connect)
            request = pendingRefresh
            pendingRefresh = nil
        }
    }

    private func performRefresh(triggerNotifications: Bool, connectClaude: Bool) async {
        let currentPrefs = preferences
        if currentPrefs.demoMode {
            snapshots = Self.makeDemoSnapshots()
        } else {
            let results = await withTaskGroup(of: ProviderSnapshot.self) { group in
                for provider in providers {
                    group.addTask {
                        if connectClaude, let claude = provider as? any InteractiveClaudeProvider {
                            return await claude.fetchSnapshot(allowKeychainPrompt: true)
                        }
                        return await provider.fetchSnapshot(preferences: currentPrefs)
                    }
                }
                var collected: [ProviderSnapshot] = []
                for await snap in group {
                    collected.append(snap)
                }
                return collected
            }
            guard currentPrefs.demoMode == preferences.demoMode else { return }
            let previousCache = lastLiveSnapshots
            snapshots = ordered(results.map { retainLastLiveSnapshot($0) })
            if lastLiveSnapshots != previousCache { saveQuotaCache() }
        }

        lastRefreshedAt = Date()
        reevaluateAlerts(triggerNotifications: triggerNotifications)
    }

    private func applyAntigravityFeed() {
        guard !preferences.demoMode else { return }
        let previous = snapshots.first { $0.provider == .antigravity }
        guard let snapshot = AntigravityProvider.cliSnapshot(localTokens: previous?.localTokens),
              (previous?.fetchedAt ?? .distantPast) < snapshot.fetchedAt else { return }
        snapshots = ordered(snapshots.filter { $0.provider != .antigravity } + [retainLastLiveSnapshot(snapshot)])
        saveQuotaCache()
        reevaluateAlerts(triggerNotifications: false)
    }

    private func ordered(_ snapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        AIProviderKind.allCases.compactMap { provider in snapshots.first { $0.provider == provider } }
    }

    private func saveQuotaCache() {
        if let data = try? JSONEncoder().encode(lastLiveSnapshots) {
            defaults.set(data, forKey: quotaCacheKey)
        }
    }

    private func retainLastLiveSnapshot(_ snapshot: ProviderSnapshot) -> ProviderSnapshot {
        let previous = lastLiveSnapshots[snapshot.provider]
        let now = Date()
        if let previous, previous.fetchedAt > snapshot.fetchedAt,
           let retained = cachedCopy(of: previous, at: now) {
            // An in-flight refresh can finish after a newer CLI watcher update.
            if let displayed = snapshots.first(where: { $0.provider == snapshot.provider }),
               displayed.fetchedAt == previous.fetchedAt, !displayed.isCached,
               now.timeIntervalSince(displayed.fetchedAt) < 900 {
                return displayed
            }
            return retained
        }
        if snapshot.status == .live && !snapshot.windows.isEmpty {
            var windows = snapshot.windows.filter { ($0.resetsAt ?? .distantFuture) > now }
            if snapshot.provider == .antigravity, let previous {
                // Different sources can report different periods. Keep the original
                // observation time on a missing period until that window resets.
                for (current, older) in [(snapshot.weeklyWindow, previous.weeklyWindow),
                                         (snapshot.shortWindow, previous.shortWindow)] {
                    if current == nil, var window = older, let reset = window.resetsAt, reset > now {
                        window.cachedAt = window.cachedAt ?? previous.fetchedAt
                        windows.append(window)
                    }
                }
            }
            if !windows.isEmpty {
                let merged = ProviderSnapshot(provider: snapshot.provider, planName: snapshot.planName,
                                              windows: windows, localTokens: snapshot.localTokens,
                                              status: snapshot.status, sourceDetail: snapshot.sourceDetail,
                                              fetchedAt: snapshot.fetchedAt, isCached: snapshot.isCached)
                lastLiveSnapshots[snapshot.provider] = merged
                return merged
            }
        }
        return previous.flatMap { cachedCopy(of: $0, at: now, localTokens: snapshot.localTokens) } ?? snapshot
    }

    private func cachedCopy(
        of previous: ProviderSnapshot, at date: Date, localTokens: LocalTokenSummary? = nil
    ) -> ProviderSnapshot? {
        let windows = previous.windows.filter { ($0.resetsAt ?? .distantFuture) > date }
        guard !windows.isEmpty else { return nil }
        return ProviderSnapshot(provider: previous.provider, planName: previous.planName,
                                windows: windows, localTokens: localTokens ?? previous.localTokens,
                                status: previous.status, sourceDetail: previous.sourceDetail,
                                fetchedAt: previous.fetchedAt, isCached: true)
    }

    func topWeeklyForecast(at date: Date) -> WeeklyQuotaForecast? {
        weeklyForecasts.values.filter { forecast in
            forecast.projectedUnusedPercent >= 10 && forecast.isCurrent(at: date) &&
                snapshots.first(where: { $0.provider == forecast.provider })?
                .spendingWindows(at: date).contains(where: { $0.id == forecast.windowID }) == true
        }.sorted {
            if $0.projectedUnusedPercent != $1.projectedUnusedPercent {
                return $0.projectedUnusedPercent > $1.projectedUnusedPercent
            }
            if $0.resetsAt != $1.resetsAt { return $0.resetsAt < $1.resetsAt }
            return $0.provider.rawValue < $1.provider.rawValue
        }.first
    }

    public func snoozeAlerts(hours: Double = 4) {
        alertEngine.snoozeAll(hours: hours)
        activeAlerts = []
    }

    public func clearSnoozeAndRecheck() {
        alertEngine.clearSnooze()
        reevaluateAlerts(triggerNotifications: true)
    }

    public var isSnoozed: Bool {
        alertEngine.isSnoozed
    }

    public func sendTestNotification() {
        Task {
            await NotificationManager.shared.sendTestNotification()
        }
    }

    private func reevaluateAlerts(triggerNotifications: Bool) {
        if preferences.demoMode {
            weeklyForecasts = [:]
        } else {
            forecastEngine.record(snapshots: snapshots)
            weeklyForecasts = forecastEngine.forecasts(for: snapshots)
        }
        bestRecommendation = alertEngine.bestProviderToUseNow(from: snapshots)
        activeAlerts = alertEngine.evaluateAlerts(
            snapshots: snapshots,
            preferences: preferences,
            respectCooldown: false
        )

        if triggerNotifications && !preferences.demoMode {
            let deliverable = alertEngine.evaluateAlerts(
                snapshots: snapshots,
                preferences: preferences,
                respectCooldown: true,
                deliveryLimit: 1
            )
            if let topAlert = deliverable.first {
                Task {
                    await NotificationManager.shared.sendAlert(topAlert)
                }
            }
        }
    }

    private func restartTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(1, preferences.refreshIntervalMinutes) * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAll(triggerNotifications: true)
            }
        }
    }

    private func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: prefsKey)
        }
    }

    public static func makeDemoSnapshots(now: Date = Date()) -> [ProviderSnapshot] {
        [
            ProviderSnapshot(
                provider: .claude,
                planName: "Max 5x",
                windows: [
                    QuotaWindow(
                        id: "claude-5h",
                        label: "5h Session",
                        usedPercent: 22,
                        resetsAt: now.addingTimeInterval(2.5 * 3_600),
                        windowDurationSeconds: 5 * 3_600,
                        isPrimary: true
                    ),
                    QuotaWindow(
                        id: "claude-7d",
                        label: "7d Weekly",
                        usedPercent: 18,
                        resetsAt: now.addingTimeInterval(14 * 3_600),
                        windowDurationSeconds: 7 * 86_400,
                        isPrimary: false
                    )
                ],
                localTokens: LocalTokenSummary(
                    recent5hTokens: 280_000,
                    recent7dTokens: 1_940_000,
                    sessionCount: 9,
                    lastActivityAt: now.addingTimeInterval(-1_200)
                ),
                status: .demo,
                sourceDetail: "Demo sample data",
                fetchedAt: now
            ),
            ProviderSnapshot(
                provider: .codex,
                planName: "Plus",
                windows: [
                    QuotaWindow(
                        id: "codex-5h",
                        label: "5h Session",
                        usedPercent: 81,
                        resetsAt: now.addingTimeInterval(1.4 * 3_600),
                        windowDurationSeconds: 5 * 3_600,
                        isPrimary: true
                    ),
                    QuotaWindow(
                        id: "codex-7d",
                        label: "7d Weekly",
                        usedPercent: 64,
                        resetsAt: now.addingTimeInterval(3.2 * 86_400),
                        windowDurationSeconds: 7 * 86_400,
                        isPrimary: false
                    )
                ],
                localTokens: LocalTokenSummary(
                    recent5hTokens: 640_000,
                    recent7dTokens: 3_420_000,
                    sessionCount: 14,
                    lastActivityAt: now.addingTimeInterval(-300)
                ),
                status: .demo,
                sourceDetail: "Demo sample data",
                fetchedAt: now
            ),
            ProviderSnapshot(
                provider: .antigravity,
                planName: "Google AI Pro",
                windows: [
                    QuotaWindow(
                        id: "agy-gemini",
                        label: "Gemini Pool",
                        usedPercent: 34,
                        resetsAt: now.addingTimeInterval(3.8 * 3_600),
                        windowDurationSeconds: 5 * 3_600,
                        isPrimary: true
                    ),
                    QuotaWindow(
                        id: "agy-3p",
                        label: "Partner Models",
                        usedPercent: 12,
                        resetsAt: now.addingTimeInterval(18 * 3_600),
                        windowDurationSeconds: 7 * 86_400,
                        isPrimary: false
                    )
                ],
                localTokens: LocalTokenSummary(
                    recent5hTokens: 195_000,
                    recent7dTokens: 1_210_000,
                    sessionCount: 7,
                    lastActivityAt: now.addingTimeInterval(-900)
                ),
                status: .demo,
                sourceDetail: "Demo sample data",
                fetchedAt: now
            )
        ]
    }
}
