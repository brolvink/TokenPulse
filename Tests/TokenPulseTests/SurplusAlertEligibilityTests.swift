import Foundation
import Testing
@testable import TokenPulseCore

struct SurplusAlertEligibilityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let engine = SurplusAlertEngine()
    private let preferences = AppPreferences(enableLowQuotaAlerts: true)

    @Test(arguments: AIProviderKind.allCases, [12.0, 48.0])
    func exhaustedShortWindowBlocksWeeklySurplus(provider: AIProviderKind, weeklyResetInHours: Double) {
        let ids = overlappingWindowIDs(for: provider)
        let short = window(ids.short, remaining: 0, resetInHours: 1, durationInHours: 5)
        let weekly = window(ids.weekly, remaining: 90, resetInHours: weeklyResetInHours, durationInHours: 168)
        let blocked = snapshot(provider, windows: [short, weekly])
        let alternative = snapshot(alternativeProvider(to: provider), windows: [
            window("alternative", remaining: 70, resetInHours: 8, durationInHours: 168)
        ])

        let alerts = evaluate([blocked, alternative])
        #expect(alerts.contains { $0.provider == provider && $0.kind == .lowQuota })
        #expect(!alerts.contains { $0.provider == provider && $0.isSpendingOpportunity })
        #expect(alerts.contains { $0.provider == alternative.provider && $0.kind == .crossProviderShift })
        #expect(engine.bestProviderToUseNow(from: [blocked, alternative], now: now)?.provider == alternative.provider)
    }

    @Test(arguments: AIProviderKind.allCases)
    func exhaustedWeeklyWindowBlocksShortSurplus(provider: AIProviderKind) {
        let ids = overlappingWindowIDs(for: provider)
        let short = window(ids.short, remaining: 90, resetInHours: 1, durationInHours: 5)
        let weekly = window(ids.weekly, remaining: 0, resetInHours: 48, durationInHours: 168)
        let blocked = snapshot(provider, windows: [short, weekly])

        #expect(!evaluate([blocked]).contains { $0.isSpendingOpportunity })
        #expect(engine.bestProviderToUseNow(from: [blocked], now: now) == nil)
    }

    @Test
    func exhaustedModelPoolLeavesOtherPoolsUsable() {
        let claude = snapshot(.claude, windows: [
            window("claude-7d", remaining: 90, resetInHours: 12, durationInHours: 168),
            window("claude-7d-opus", remaining: 0, resetInHours: 8, durationInHours: 168),
            window("claude-7d-sonnet", remaining: 80, resetInHours: 4, durationInHours: 168)
        ])
        let codex = snapshot(.codex, windows: [
            window("codex-secondary", remaining: 92, resetInHours: 12, durationInHours: 168),
            window("codex-codex-spark", remaining: 0, resetInHours: 1, durationInHours: 5)
        ])
        let antigravity = snapshot(.antigravity, windows: [
            window("agy-cli-gemini-weekly", remaining: 96, resetInHours: 1, durationInHours: 168),
            window("agy-cli-gemini-5h", remaining: 0, resetInHours: 1, durationInHours: 5),
            window("agy-cli-3p-weekly", remaining: 97, resetInHours: 12, durationInHours: 168)
        ])

        for snapshot in [claude, codex, antigravity] {
            #expect(engine.bestProviderToUseNow(from: [snapshot], now: now)?.provider == snapshot.provider)
        }
        let eligible = evaluate([claude, codex, antigravity]).filter(\.isSpendingOpportunity)
        #expect(Set(eligible.map(\.windowLabel)) == [
            "claude-7d", "claude-7d-sonnet", "codex-secondary", "agy-cli-3p-weekly"
        ])
    }

    @Test
    func expiredAndEstimatedLimitsCannotBlockOrCreateSurplus() {
        let weekly = window("claude-7d", remaining: 95, resetInHours: 12, durationInHours: 168)
        let expired = window("claude-5h", remaining: 0, resetInHours: 0, durationInHours: 5)
        let estimated = QuotaWindow(id: "claude-7d-sonnet", label: "Estimated Sonnet", usedPercent: 0,
                                    resetsAt: now.addingTimeInterval(3_600), isEstimated: true)
        let claude = snapshot(.claude, windows: [weekly, expired, estimated])

        let eligible = evaluate([claude]).filter(\.isSpendingOpportunity)
        #expect(eligible.map(\.windowLabel) == [weekly.label])
        #expect(engine.bestProviderToUseNow(from: [claude], now: now)?.provider == .claude)
    }

    @Test
    func exhaustedSharedQuotaBlocksModelSpecificSurplus() {
        let shared = window("claude-5h", remaining: 0, resetInHours: 1, durationInHours: 5)
        let opus = window("claude-7d-opus", remaining: 95, resetInHours: 12, durationInHours: 168)
        let claude = snapshot(.claude, windows: [shared, opus])

        #expect(!evaluate([claude]).contains { $0.isSpendingOpportunity })
        #expect(engine.bestProviderToUseNow(from: [claude], now: now) == nil)
    }

    @Test
    func cachedWindowsCannotBlockOrCreateSurplus() {
        let weekly = window("agy-cli-gemini-weekly", remaining: 95, resetInHours: 12, durationInHours: 168)
        var short = window("agy-cli-gemini-5h", remaining: 0, resetInHours: 1, durationInHours: 5)
        var partner = window("agy-cli-3p-weekly", remaining: 98, resetInHours: 4, durationInHours: 168)
        short.cachedAt = now.addingTimeInterval(-3_600)
        partner.cachedAt = short.cachedAt
        let antigravity = snapshot(.antigravity, windows: [weekly, short, partner])

        let eligible = evaluate([antigravity]).filter(\.isSpendingOpportunity)
        #expect(eligible.map(\.windowLabel) == [weekly.label])
        #expect(antigravity.effectiveSpendingLimit(at: now) == weekly)
    }

    private func overlappingWindowIDs(for provider: AIProviderKind) -> (short: String, weekly: String) {
        switch provider {
        case .claude: ("claude-5h", "claude-7d")
        case .codex: ("codex-rollout-primary", "codex-rollout-secondary")
        case .antigravity: ("agy-cli-gemini-5h", "agy-cli-gemini-weekly")
        }
    }

    private func alternativeProvider(to provider: AIProviderKind) -> AIProviderKind {
        provider == .claude ? .codex : .claude
    }

    private func window(_ id: String, remaining: Double, resetInHours: Double,
                        durationInHours: Double) -> QuotaWindow {
        QuotaWindow(id: id, label: id, usedPercent: 100 - remaining,
                    resetsAt: now.addingTimeInterval(resetInHours * 3_600),
                    windowDurationSeconds: durationInHours * 3_600)
    }

    private func snapshot(_ provider: AIProviderKind, windows: [QuotaWindow]) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, windows: windows, status: .live, sourceDetail: "Test")
    }

    private func evaluate(_ snapshots: [ProviderSnapshot]) -> [SurplusAlert] {
        engine.evaluateAlerts(snapshots: snapshots, preferences: preferences, now: now, respectCooldown: false)
    }
}
