import Combine
import Foundation
import SwiftUI

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

    private let defaults: UserDefaults
    private let providers: [any QuotaProvider]
    private let alertEngine: SurplusAlertEngine
    private var refreshTimer: Timer?
    private var refreshRequested = false
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
    }

    public func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    public func refreshAll(triggerNotifications: Bool = true, connectClaude: Bool = false) async {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshRequested {
                refreshRequested = false
                Task { await refreshAll(triggerNotifications: false) }
            }
        }

        let currentPrefs = preferences
        if currentPrefs.demoMode {
            snapshots = Self.makeDemoSnapshots()
        } else {
            let results = await withTaskGroup(of: ProviderSnapshot.self) { group in
                for provider in providers {
                    group.addTask {
                        if connectClaude, let claude = provider as? ClaudeProvider {
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
            let order = AIProviderKind.allCases
            let previousCache = lastLiveSnapshots
            snapshots = results.map(retainLastLiveSnapshot).sorted {
                (order.firstIndex(of: $0.provider) ?? 0) < (order.firstIndex(of: $1.provider) ?? 0)
            }
            if lastLiveSnapshots != previousCache,
               let data = try? JSONEncoder().encode(lastLiveSnapshots) {
                defaults.set(data, forKey: quotaCacheKey)
            }
        }

        lastRefreshedAt = Date()
        reevaluateAlerts(triggerNotifications: triggerNotifications)
    }

    private func retainLastLiveSnapshot(_ snapshot: ProviderSnapshot) -> ProviderSnapshot {
        if snapshot.status == .live && !snapshot.windows.isEmpty {
            if let previous = lastLiveSnapshots[snapshot.provider], previous.fetchedAt > snapshot.fetchedAt {
                return cachedCopy(of: previous, at: Date()) ?? snapshot
            }
            lastLiveSnapshots[snapshot.provider] = snapshot
            return snapshot
        }
        guard !snapshot.isCached, let previous = lastLiveSnapshots[snapshot.provider] else { return snapshot }
        return cachedCopy(of: previous, at: snapshot.fetchedAt, localTokens: snapshot.localTokens) ?? snapshot
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
