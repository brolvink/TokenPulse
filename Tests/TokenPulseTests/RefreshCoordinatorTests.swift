import Foundation
import Testing
@testable import TokenPulseCore

private actor PausingClaude: InteractiveClaudeProvider {
    nonisolated let kind = AIProviderKind.claude
    private var firstRequest: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var requests: [Bool] = []

    func fetchSnapshot(preferences: AppPreferences) async -> ProviderSnapshot {
        await fetchSnapshot(allowKeychainPrompt: false)
    }

    func fetchSnapshot(allowKeychainPrompt: Bool) async -> ProviderSnapshot {
        requests.append(allowKeychainPrompt)
        if requests.count == 1 {
            await withCheckedContinuation {
                firstRequest = $0
                started?.resume()
                started = nil
            }
        }
        return ProviderSnapshot(provider: kind, windows: [], status: .localOnly, sourceDetail: "Fixture")
    }

    func waitUntilStarted() async {
        if firstRequest == nil { await withCheckedContinuation { started = $0 } }
    }

    func release() {
        firstRequest?.resume()
        firstRequest = nil
    }
}

@Test @MainActor
func connectingDuringRefreshKeepsInteractiveRequest() async throws {
    let suite = "RefreshQueueTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = PausingClaude()
    let monitor = UsageMonitorViewModel(providers: [provider], defaults: defaults)
    let refresh = Task { await monitor.refreshAll(triggerNotifications: false) }
    await provider.waitUntilStarted()
    await monitor.refreshAll(triggerNotifications: false, connectClaude: true)
    await monitor.refreshAll(triggerNotifications: false)
    await provider.release()
    await refresh.value
    #expect(await provider.requests == [false, true])
}

private struct FixedAntigravity: QuotaProvider {
    let kind = AIProviderKind.antigravity
    var snapshot: ProviderSnapshot
    func fetchSnapshot(preferences: AppPreferences) async -> ProviderSnapshot { snapshot }
}

@Test @MainActor
func newShortReadingKeepsWeeklyReadingWithOriginalDate() async throws {
    let suite = "MixedCacheTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let now = Date()
    let captured = now.addingTimeInterval(-3600)
    let weekly = QuotaWindow(id: "agy-cli-gemini-weekly", label: "Gemini Weekly", usedPercent: 25,
                             resetsAt: now.addingTimeInterval(86400), windowDurationSeconds: 604800)
    let first = ProviderSnapshot(provider: .antigravity, windows: [weekly], status: .live,
                                 sourceDetail: "CLI", fetchedAt: captured)
    await UsageMonitorViewModel(providers: [FixedAntigravity(snapshot: first)], defaults: defaults)
        .refreshAll(triggerNotifications: false)
    let short = QuotaWindow(id: "agy-gemini", label: "Gemini", usedPercent: 10,
                            resetsAt: now.addingTimeInterval(3600), windowDurationSeconds: 18000)
    let fresh = ProviderSnapshot(provider: .antigravity, windows: [short], status: .live,
                                 sourceDetail: "API", fetchedAt: now)
    let monitor = UsageMonitorViewModel(providers: [FixedAntigravity(snapshot: fresh)], defaults: defaults)
    await monitor.refreshAll(triggerNotifications: false)
    let result = try #require(monitor.snapshots.first)
    #expect(result.weeklyWindow?.cachedAt == captured)
    #expect(result.weeklyWindow?.remainingPercent == 75)
    #expect(result.shortWindow == short)
    #expect(!result.isCached)
}

@Test @MainActor
func forecastFooterSurvivesRelaunchAndSkipsBlockedProvider() async throws {
    let suite = "ForecastFooterTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let now = Date().addingTimeInterval(-1)
    let reset = now.addingTimeInterval(24 * 3600)
    func sample(hoursAgo: Double, used: Double, blocked: Bool = false) -> ProviderSnapshot {
        let windows = [
            QuotaWindow(id: "agy-cli-gemini-weekly", label: "Gemini Weekly", usedPercent: used,
                        resetsAt: reset, windowDurationSeconds: 604800),
            QuotaWindow(id: "agy-cli-gemini-5h", label: "Gemini Session", usedPercent: blocked ? 100 : 0,
                        resetsAt: now.addingTimeInterval(3600), windowDurationSeconds: 18000)
        ]
        return ProviderSnapshot(provider: .antigravity, windows: windows, status: .live,
                                sourceDetail: "Fixture CLI", fetchedAt: now.addingTimeInterval(-hoursAgo * 3600))
    }
    let history = WeeklyQuotaForecastEngine(defaults: defaults)
    for (hoursAgo, used) in [(48.0, 15.0), (24, 25), (12, 30)] {
        let snapshot = sample(hoursAgo: hoursAgo, used: used)
        history.record(snapshots: [snapshot], now: snapshot.fetchedAt)
    }
    let fresh = sample(hoursAgo: 0, used: 35)
    let monitor = UsageMonitorViewModel(providers: [FixedAntigravity(snapshot: fresh)], defaults: defaults)
    await monitor.refreshAll(triggerNotifications: false)
    #expect(monitor.topWeeklyForecast(at: now)?.projectedUnusedPercent == 55)
    #expect(monitor.topWeeklyForecast(at: reset) == nil)

    let blocked = sample(hoursAgo: 0, used: 35, blocked: true)
    let other = UsageMonitorViewModel(providers: [FixedAntigravity(snapshot: blocked)], defaults: defaults)
    await other.refreshAll(triggerNotifications: false)
    #expect(other.topWeeklyForecast(at: now) == nil)
}
