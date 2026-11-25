import Foundation

public final class SurplusAlertEngine: @unchecked Sendable {
    private var lastAlertDates: [String: Date] = [:]
    private var snoozedUntil: Date?

    public init() {}

    public func snoozeAll(hours: Double, now: Date = Date()) {
        snoozedUntil = now.addingTimeInterval(hours * 3_600)
    }

    public func clearSnooze() {
        snoozedUntil = nil
    }

    public var isSnoozed: Bool {
        if let snoozedUntil {
            return Date() < snoozedUntil
        }
        return false
    }

    /// Evaluates current snapshots and returns actionable surplus/imbalance/low alerts,
    /// filtering out alerts still within cooldown or snooze.
    public func evaluateAlerts(
        snapshots: [ProviderSnapshot],
        preferences: AppPreferences,
        now: Date = Date(),
        respectCooldown: Bool = true,
        deliveryLimit: Int? = nil
    ) -> [SurplusAlert] {
        if let snoozedUntil, now < snoozedUntil {
            return []
        }

        var candidates: [SurplusAlert] = []
        let healthy = snapshots.filter { $0.status.isHealthy && !$0.isCached && !$0.windows.isEmpty }

        if preferences.enableSurplusAlerts {
            for snap in healthy {
                for window in snap.spendingWindows(at: now) {
                    guard let reset = window.resetsAt, reset > now else { continue }
                    guard window.remainingPercent >= preferences.surplusThresholdPercent else { continue }
                    let leadSeconds = effectiveLeadSeconds(for: window, defaultHours: preferences.surplusLeadHours)
                    if let remainingTime = window.timeUntilReset(from: now),
                       remainingTime > 0,
                       remainingTime <= leadSeconds {
                        let countdown = Formatters.formatCountdown(until: window.resetsAt, from: now)
                        candidates.append(SurplusAlert(
                            id: "surplus-\(snap.provider.rawValue)-\(window.id)",
                            provider: snap.provider,
                            kind: .surplusBeforeReset,
                            title: "\(snap.provider.displayName): \(Int(window.remainingPercent.rounded()))% tokens still to spend",
                            body: "\(window.label) has \(Int(window.remainingPercent.rounded()))% left (\(countdown.lowercased())). Put it to work before it resets!",
                            remainingPercent: window.remainingPercent,
                            windowLabel: window.label,
                            priority: 100,
                            resetsAt: reset
                        ))
                    } else if let elapsed = window.elapsedFraction(from: now),
                              elapsed >= 0.55,
                              window.remainingPercent >= max(80.0, preferences.surplusThresholdPercent) {
                        candidates.append(SurplusAlert(
                            id: "unused-\(snap.provider.rawValue)-\(window.id)",
                            provider: snap.provider,
                            kind: .unusedSubscription,
                            title: "\(snap.provider.displayName) is mostly unused (\(Int(window.remainingPercent.rounded()))% left)",
                            body: "More than half of your \(window.label) window has passed and you still have \(Int(window.remainingPercent.rounded()))% left to spend.",
                            remainingPercent: window.remainingPercent,
                            windowLabel: window.label,
                            priority: 80,
                            resetsAt: reset
                        ))
                    }
                }
            }
        }

        if preferences.enableImbalanceAlerts, healthy.count >= 2 {
            let ranked = healthy.compactMap { snap -> (ProviderSnapshot, QuotaWindow)? in
                guard let w = snap.effectiveSpendingLimit(at: now) else { return nil }
                return (snap, w)
            }
            if let lowest = ranked.min(by: { $0.1.remainingPercent < $1.1.remainingPercent }),
               let highest = ranked.max(by: { $0.1.remainingPercent < $1.1.remainingPercent }),
               lowest.0.provider != highest.0.provider,
               lowest.1.remainingPercent <= 25,
               highest.1.remainingPercent > 0,
               highest.1.remainingPercent >= preferences.surplusThresholdPercent {
                candidates.append(SurplusAlert(
                    id: "shift-\(lowest.0.provider.rawValue)-to-\(highest.0.provider.rawValue)",
                    provider: highest.0.provider,
                    kind: .crossProviderShift,
                    title: "Shift tasks to \(highest.0.provider.displayName) (\(Int(highest.1.remainingPercent.rounded()))% left)",
                    body: "\(lowest.0.provider.displayName) is down to \(Int(lowest.1.remainingPercent.rounded()))%, while \(highest.0.provider.displayName) still has \(Int(highest.1.remainingPercent.rounded()))% available.",
                    remainingPercent: highest.1.remainingPercent,
                    windowLabel: highest.1.label,
                    priority: 90
                ))
            }
        }

        if preferences.enableLowQuotaAlerts {
            for snap in healthy {
                if let w = snap.currentQuotaWindows(at: now).min(by: { $0.remainingPercent < $1.remainingPercent }), w.remainingPercent <= preferences.lowQuotaThresholdPercent {
                    candidates.append(SurplusAlert(
                        id: "low-\(snap.provider.rawValue)-\(w.id)",
                        provider: snap.provider,
                        kind: .lowQuota,
                        title: "\(snap.provider.displayName) running low (\(Int(w.remainingPercent.rounded()))% left)",
                        body: "\(w.label) is almost depleted (\(Formatters.formatCountdown(until: w.resetsAt, from: now).lowercased())).",
                        remainingPercent: w.remainingPercent,
                        windowLabel: w.label,
                        priority: 60
                    ))
                }
            }
        }

        let sorted = candidates.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.kind == .surplusBeforeReset, lhs.resetsAt != rhs.resetsAt {
                return (lhs.resetsAt ?? .distantFuture) < (rhs.resetsAt ?? .distantFuture)
            }
            return lhs.remainingPercent > rhs.remainingPercent
        }
        guard respectCooldown else { return sorted }

        let cooldownSeconds = max(0.25, preferences.alertCooldownHours) * 3_600
        var toDeliver: [SurplusAlert] = []
        for alert in sorted {
            if let deliveryLimit, toDeliver.count >= deliveryLimit { break }
            if let last = lastAlertDates[alert.id], now.timeIntervalSince(last) < cooldownSeconds {
                continue
            }
            lastAlertDates[alert.id] = now
            toDeliver.append(alert)
        }
        return toDeliver
    }

    /// Picks the single best subscription to spend tokens on right now.
    public func bestProviderToUseNow(from snapshots: [ProviderSnapshot], now: Date = Date()) -> (provider: AIProviderKind, reason: String)? {
        let candidates: [(AIProviderKind, QuotaWindow, Double)] = snapshots.compactMap { snap in
            guard let window = snap.effectiveSpendingLimit(at: now),
                  window.remainingPercent > 0 else { return nil }
            // Score combines remaining capacity and urgency of approaching reset
            var urgencyBonus = 0.0
            if let t = window.timeUntilReset(from: now), t > 0 {
                let hours = t / 3_600
                if hours < 24 {
                    urgencyBonus = (24.0 - hours) * 1.2
                }
            }
            return (snap.provider, window, window.remainingPercent + urgencyBonus)
        }

        guard let best = candidates.max(by: { $0.2 < $1.2 }) else {
            return nil
        }

        let pct = Int(best.1.remainingPercent.rounded())
        let countdown = Formatters.formatCountdown(until: best.1.resetsAt, from: now).lowercased()
        if best.1.resetsAt != nil {
            return (best.0, "\(best.0.displayName) has \(pct)% left on \(best.1.label) (\(countdown)).")
        }
        return (best.0, "\(best.0.displayName) has \(pct)% remaining capacity.")
    }

    private func effectiveLeadSeconds(for window: QuotaWindow, defaultHours: Double) -> TimeInterval {
        if let duration = window.windowDurationSeconds, duration <= 6 * 3_600 {
            // For 5h rolling sessions, alert within the last 2 hours (or 40% of window)
            return min(defaultHours * 3_600, max(1_800, duration * 0.4))
        }
        return defaultHours * 3_600
    }
}

extension ProviderSnapshot {
    fileprivate func currentQuotaWindows(at now: Date) -> [QuotaWindow] {
        guard status.isHealthy, !isCached else { return [] }
        return windows.filter {
            !$0.isEstimated && $0.cachedAt == nil && ($0.resetsAt ?? .distantFuture) > now
        }
    }

    func spendingWindows(at now: Date) -> [QuotaWindow] {
        let eligibleIDs = Set(spendingPaths(at: now)
            .filter { $0.allSatisfy { $0.remainingPercent > 0 } }
            .flatMap { $0.map(\.id) })
        return currentQuotaWindows(at: now).filter { eligibleIDs.contains($0.id) }
    }

    func effectiveSpendingLimit(at now: Date) -> QuotaWindow? {
        spendingPaths(at: now)
            .compactMap { $0.min { $0.remainingPercent < $1.remainingPercent } }
            .max { $0.remainingPercent < $1.remainingPercent }
    }

    /// Each model pool has its own constraints and also consumes any provider-wide quota.
    private func spendingPaths(at now: Date) -> [[QuotaWindow]] {
        var shared: [QuotaWindow] = []
        var pools: [String: [QuotaWindow]] = [:]
        for window in currentQuotaWindows(at: now) {
            if let pool = quotaPool(for: window) {
                pools[pool, default: []].append(window)
            } else {
                shared.append(window)
            }
        }

        // Claude and Codex use separate windows for additional model limits, alongside
        // their standard quota. The shared quota remains usable by the standard pool.
        var paths = shared.isEmpty ? [] : [shared]
        paths += pools.keys.sorted().compactMap { pool in pools[pool].map { shared + $0 } }
        return paths
    }

    private func quotaPool(for window: QuotaWindow) -> String? {
        switch provider {
        case .claude:
            return window.id.hasPrefix("claude-7d-") ? window.id : nil
        case .codex:
            switch window.id {
            case "codex-primary", "codex-secondary", "codex-rollout-primary", "codex-rollout-secondary",
                 "codex-5h", "codex-7d":
                return nil
            default:
                return window.id.hasPrefix("codex-") ? window.id : nil
            }
        case .antigravity:
            guard window.id.hasPrefix("agy-cli-") else { return window.id }
            // The CLI identifies a pool by the bucket ID with its time window removed.
            let timeWindows: Set<Substring> = ["weekly", "5h", "session"]
            return window.id.lowercased().dropFirst("agy-cli-".count).split(separator: "-")
                .filter { !timeWindows.contains($0) }
                .joined(separator: "-")
        }
    }
}
