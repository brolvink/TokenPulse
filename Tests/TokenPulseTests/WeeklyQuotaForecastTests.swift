import Foundation
import Testing
@testable import TokenPulseCore

@MainActor
@Suite("Weekly quota forecast")
struct WeeklyQuotaForecastTests {
    private static let hour: TimeInterval = 3_600
    private static let week = 7 * 24 * hour
    private let reset = Date(timeIntervalSinceReferenceDate: 840_000_000)

    @Test("Forecast survives restart and projects each provider's own trend")
    func projectsPersistedHistory() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = WeeklyQuotaForecastEngine(defaults: defaults)

        for (hours, used) in [(72.0, 10.0), (60, 15), (48, 20)] {
            record(snapshot(hoursBeforeReset: hours, used: used), with: engine)
            record(snapshot(hoursBeforeReset: hours, used: 32, provider: .codex), with: engine)
        }

        let reopened = WeeklyQuotaForecastEngine(defaults: defaults)
        let claude = snapshot(hoursBeforeReset: 48, used: 20)
        let codex = snapshot(hoursBeforeReset: 48, used: 32, provider: .codex)
        let forecasts = reopened.forecasts(for: [claude, codex], now: claude.fetchedAt)
        #expect(forecasts[.claude]?.projectedUnusedPercent == 60)
        #expect(forecasts[.codex]?.projectedUnusedPercent == 70)
        #expect(forecasts[.claude]?.windowID == "claude-7d")
        #expect(forecasts[.claude]?.resetsAt == reset)
    }

    @Test("A forecast needs representative samples and a bounded lookahead")
    func representativeHistory() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = WeeklyQuotaForecastEngine(defaults: defaults)

        for hours in [144.0, 132, 120, 119, 118] {
            let early = snapshot(hoursBeforeReset: hours, used: 20)
            record(early, with: engine)
            #expect(engine.forecasts(for: [early], now: early.fetchedAt).isEmpty)
        }

        let afterLongGap = snapshot(hoursBeforeReset: 40, used: 20)
        record(afterLongGap, with: engine)
        #expect(engine.forecasts(for: [afterLongGap], now: afterLongGap.fetchedAt).isEmpty)

        let second = snapshot(hoursBeforeReset: 16, used: 20)
        record(second, with: engine)
        #expect(engine.forecasts(for: [second], now: second.fetchedAt).isEmpty)

        let third = snapshot(hoursBeforeReset: 4, used: 20)
        record(third, with: engine)
        #expect(engine.forecasts(for: [third], now: third.fetchedAt)[.claude]?.projectedUnusedPercent == 80)
    }

    @Test("Cached, estimated, demo, local, stale and model-only observations are excluded")
    func ignoresUntrustworthyData() throws {
        let invalid: [(ProviderSnapshot, TimeInterval)] = [
            (snapshot(hoursBeforeReset: 60, used: 25, cached: true), 0.0),
            (snapshot(hoursBeforeReset: 60, used: 25, cachedWindow: true), 0),
            (snapshot(hoursBeforeReset: 60, used: 25, estimated: true), 0),
            (snapshot(hoursBeforeReset: 60, used: 25, status: .demo), 0),
            (snapshot(hoursBeforeReset: 60, used: 25, status: .localOnly), 0),
            (snapshot(hoursBeforeReset: 60, used: 25, windowID: "claude-7d-sonnet"), 0),
            (snapshot(hoursBeforeReset: 60, used: 25, windowDuration: 5 * Self.hour), 0),
            (snapshot(hoursBeforeReset: 60, used: 25), 16 * 60),
            (snapshot(hoursBeforeReset: 60, used: 25), -60),
        ]
        for (sample, delay) in invalid {
            let (defaults, suite) = try isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let engine = WeeklyQuotaForecastEngine(defaults: defaults)
            record(snapshot(hoursBeforeReset: 72, used: 25), with: engine)
            engine.record(snapshots: [sample], now: sample.fetchedAt.addingTimeInterval(delay))
            let fresh = snapshot(hoursBeforeReset: 48, used: 25)
            record(fresh, with: engine)
            #expect(engine.forecasts(for: [fresh], now: fresh.fetchedAt).isEmpty)
        }
    }

    @Test("Reset drift preserves samples, while a new reset or a decrease starts over")
    func isolatesEachCycle() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = WeeklyQuotaForecastEngine(defaults: defaults)
        record(snapshot(hoursBeforeReset: 72, used: 30), with: engine)
        record(snapshot(hoursBeforeReset: 60, used: 40), with: engine)
        let shifted = snapshot(hoursBeforeReset: 48, used: 50, resetShift: 30)
        record(shifted, with: engine)
        #expect(engine.forecasts(for: [shifted], now: shifted.fetchedAt)[.claude]?.projectedUnusedPercent == 10)

        let corrected = snapshot(hoursBeforeReset: 47, used: 45)
        record(corrected, with: engine)
        #expect(engine.forecasts(for: [corrected], now: corrected.fetchedAt).isEmpty)

        record(snapshot(hoursBeforeReset: 35, used: 45), with: engine)
        let recovered = snapshot(hoursBeforeReset: 23, used: 45)
        record(recovered, with: engine)
        #expect(engine.forecasts(for: [recovered], now: recovered.fetchedAt)[.claude]?.projectedUnusedPercent == 55)

        let nextCycle = snapshot(hoursBeforeReset: 0, used: 50, resetShift: Self.week)
        record(nextCycle, with: engine)
        #expect(engine.forecasts(for: [nextCycle], now: nextCycle.fetchedAt).isEmpty)
    }

    @Test("Forecast expires when the live reading goes stale or the window resets")
    func forecastExpires() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = WeeklyQuotaForecastEngine(defaults: defaults)
        record(snapshot(hoursBeforeReset: 25, used: 50), with: engine)
        record(snapshot(hoursBeforeReset: 13, used: 70), with: engine)
        let last = snapshot(hoursBeforeReset: 1, used: 90)
        record(last, with: engine)
        let forecast = try #require(engine.forecasts(for: [last], now: last.fetchedAt)[.claude])
        #expect(forecast.isCurrent(at: last.fetchedAt))
        let cached = snapshot(hoursBeforeReset: 1, used: 90, cachedWindow: true)
        #expect(engine.forecasts(for: [cached], now: last.fetchedAt).isEmpty)
        #expect(!forecast.isCurrent(at: last.fetchedAt.addingTimeInterval(15 * 60)))
        #expect(engine.forecasts(for: [last], now: last.fetchedAt.addingTimeInterval(15 * 60)).isEmpty)

        let nearReset = snapshot(hoursBeforeReset: 5.0 / 60, used: 100)
        record(nearReset, with: engine)
        let depleted = try #require(engine.forecasts(for: [nearReset], now: nearReset.fetchedAt)[.claude])
        #expect(depleted.projectedUnusedPercent == 0)
        #expect(!depleted.isCurrent(at: reset))
        #expect(engine.forecasts(for: [nearReset], now: reset).isEmpty)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "TokenPulse.ForecastTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func record(_ snapshot: ProviderSnapshot, with engine: WeeklyQuotaForecastEngine) {
        engine.record(snapshots: [snapshot], now: snapshot.fetchedAt)
    }

    private func snapshot(
        hoursBeforeReset: Double,
        used: Double,
        provider: AIProviderKind = .claude,
        resetShift: TimeInterval = 0,
        cached: Bool = false,
        cachedWindow: Bool = false,
        estimated: Bool = false,
        status: ProviderConnectionStatus = .live,
        windowID: String? = nil,
        windowDuration: TimeInterval = WeeklyQuotaForecastTests.week
    ) -> ProviderSnapshot {
        let fetchedAt = reset.addingTimeInterval(-hoursBeforeReset * Self.hour)
        var window = QuotaWindow(
            id: windowID ?? "\(provider.rawValue)-7d",
            label: "Weekly",
            usedPercent: used,
            resetsAt: reset.addingTimeInterval(resetShift),
            windowDurationSeconds: windowDuration,
            isEstimated: estimated
        )
        if cachedWindow { window.cachedAt = fetchedAt }
        return ProviderSnapshot(
            provider: provider,
            windows: [window],
            status: status,
            sourceDetail: "Test",
            fetchedAt: fetchedAt,
            isCached: cached
        )
    }
}
