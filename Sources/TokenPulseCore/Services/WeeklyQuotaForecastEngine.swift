import Foundation

public struct WeeklyQuotaForecast: Equatable, Sendable {
    public let provider: AIProviderKind
    public let windowID: String
    public let projectedUnusedPercent: Int
    public let observedAt: Date
    public let expiresAt: Date
    public let resetsAt: Date

    public func isCurrent(at now: Date = Date()) -> Bool {
        observedAt <= now && now < expiresAt && now < resetsAt
    }
}

@MainActor
public final class WeeklyQuotaForecastEngine {
    private struct Observation: Codable, Equatable {
        let fetchedAt: Date
        let usedPercent: Double

        var bucket: Double {
            floor(fetchedAt.timeIntervalSinceReferenceDate / (6 * 3_600))
        }
    }

    private struct Cycle: Codable, Equatable {
        let resetsAt: Date
        let planName: String?
        var observations: [Observation]

        func matches(reset: Date, planName: String?) -> Bool {
            // Relative reset timestamps can drift between requests by a few seconds.
            self.planName == planName && abs(resetsAt.timeIntervalSince(reset)) <= 120
        }

        mutating func append(_ observation: Observation) {
            if let previous = observations.last {
                guard observation.fetchedAt > previous.fetchedAt else { return }
                if observation.usedPercent < previous.usedPercent {
                    // A same-cycle correction makes the preceding consumption trend unusable.
                    observations.removeAll()
                } else if observation.bucket == previous.bucket {
                    observations.removeLast()
                }
            }
            observations.append(observation)
        }
    }

    private static let week: TimeInterval = 7 * 86_400
    private static let freshness: TimeInterval = 15 * 60
    private static let maximumWindowsPerProvider = 8

    private let defaults: UserDefaults
    private let historyKey = "TokenPulse.WeeklyQuotaForecast.v1"
    private var history: [AIProviderKind: [String: Cycle]] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: historyKey),
           let saved = try? JSONDecoder().decode([AIProviderKind: [String: Cycle]].self, from: data) {
            history = saved
        }
    }

    public func record(snapshots: [ProviderSnapshot], now: Date = Date()) {
        var updated: [AIProviderKind: [String: Cycle]] = [:]
        for (provider, cycles) in history {
            let active = cycles.filter { $0.value.resetsAt.addingTimeInterval(120) > now }
            if !active.isEmpty { updated[provider] = active }
        }

        for snapshot in snapshots where isFresh(snapshot, at: now) {
            var cycles = updated[snapshot.provider, default: [:]]
            for window in snapshot.windows {
                guard let reset = validReset(for: window, snapshot: snapshot, now: now) else { continue }
                let observation = Observation(fetchedAt: snapshot.fetchedAt, usedPercent: window.usedPercent)
                var cycle = cycles[window.id] ?? Cycle(resetsAt: reset, planName: snapshot.planName, observations: [])
                if let last = cycle.observations.last, last.fetchedAt >= observation.fetchedAt { continue }
                if !cycle.matches(reset: reset, planName: snapshot.planName) {
                    cycle = Cycle(resetsAt: reset, planName: snapshot.planName, observations: [])
                }
                cycle.append(observation)
                cycles[window.id] = cycle
            }
            for oldest in cycles.sorted(by: {
                let left = $0.value.observations.last?.fetchedAt ?? .distantPast
                let right = $1.value.observations.last?.fetchedAt ?? .distantPast
                return left == right ? $0.key < $1.key : left < right
            }).dropLast(Self.maximumWindowsPerProvider) {
                cycles.removeValue(forKey: oldest.key)
            }
            if !cycles.isEmpty { updated[snapshot.provider] = cycles }
        }

        guard updated != history else { return }
        history = updated
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
    }

    public func forecasts(
        for snapshots: [ProviderSnapshot], now: Date = Date()
    ) -> [AIProviderKind: WeeklyQuotaForecast] {
        var result: [AIProviderKind: WeeklyQuotaForecast] = [:]
        for snapshot in snapshots where isFresh(snapshot, at: now) {
            guard let window = snapshot.weeklyWindow,
                  let reset = validReset(for: window, snapshot: snapshot, now: now),
                  let cycle = history[snapshot.provider]?[window.id],
                  cycle.matches(reset: reset, planName: snapshot.planName),
                  let latest = cycle.observations.last,
                  latest.fetchedAt == snapshot.fetchedAt, latest.usedPercent == window.usedPercent,
                  let unused = projectedUnused(in: cycle, latest: latest, reset: reset) else { continue }

            result[snapshot.provider] = WeeklyQuotaForecast(
                provider: snapshot.provider,
                windowID: window.id,
                projectedUnusedPercent: unused,
                observedAt: snapshot.fetchedAt,
                expiresAt: min(reset, snapshot.fetchedAt.addingTimeInterval(Self.freshness)),
                resetsAt: reset
            )
        }
        return result
    }

    private func isFresh(_ snapshot: ProviderSnapshot, at now: Date) -> Bool {
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        return snapshot.status == .live && !snapshot.isCached && age >= 0 && age < Self.freshness
    }

    private func validReset(for window: QuotaWindow, snapshot: ProviderSnapshot, now: Date) -> Date? {
        guard window.windowDurationSeconds == Self.week, !window.isEstimated, window.cachedAt == nil,
              snapshot.provider != .claude || window.id == "claude-7d",
              window.usedPercent.isFinite,
              let reset = window.resetsAt, now < reset,
              reset.timeIntervalSince(snapshot.fetchedAt) <= Self.week else { return nil }
        return reset
    }

    private func projectedUnused(in cycle: Cycle, latest: Observation, reset: Date) -> Int? {
        var earliest = latest
        var sampleCount = 1
        for observation in cycle.observations.dropLast().reversed() {
            guard earliest.fetchedAt.timeIntervalSince(observation.fetchedAt) <= 36 * 3_600 else { break }
            earliest = observation
            sampleCount += 1
        }

        let observedSpan = latest.fetchedAt.timeIntervalSince(earliest.fetchedAt)
        let timeUntilReset = reset.timeIntervalSince(latest.fetchedAt)
        // Require repeated observations over a full day and limit extrapolation to twice the observed span.
        guard sampleCount >= 3, observedSpan >= 24 * 3_600, timeUntilReset <= 2 * observedSpan + 120 else { return nil }

        let projectedSpend = (latest.usedPercent - earliest.usedPercent) * timeUntilReset / observedSpan
        let unused = max(0, 100 - latest.usedPercent - projectedSpend)
        return Int((unused / 5).rounded()) * 5
    }
}
