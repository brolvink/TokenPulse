import Foundation
import Testing
@testable import TokenPulseCore

@Suite("TokenPulse Core Tests")
struct TokenPulseTests {
    @Test("Claude usage JSON decodes 5h and 7d windows")
    func claudeUsageDecoding() throws {
        let json = """
        {
          "five_hour": {
            "utilization": 33.0,
            "resets_at": "2026-11-25T21:00:00Z"
          },
          "seven_day": {
            "utilization": 13.0,
            "resets_at": "2026-11-29T00:59:59Z"
          },
          "seven_day_sonnet": {
            "utilization": 4.0,
            "resets_at": "2026-11-29T00:59:59Z"
          }
        }
        """
        let decoded = try ClaudeProvider.decodeUsageResponse(from: Data(json.utf8))
        let windows = ClaudeProvider.windows(from: decoded)

        #expect(windows.count == 3)
        #expect(windows[0].label == "5h Session")
        #expect(abs(windows[0].remainingPercent - 67.0) < 0.01)
        #expect(windows[0].isPrimary)
        #expect(windows[1].label == "7d Weekly")
        #expect(abs(windows[1].remainingPercent - 87.0) < 0.01)
    }

    @Test("Codex WHAM usage and JSONL rollout rate limits decode cleanly")
    func codexWhamUsageAndRolloutDecoding() throws {
        let whamJson = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 18,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 43200
            },
            "secondary_window": {
              "used_percent": 55,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 7200
            }
          }
        }
        """
        let wham = try CodexProvider.decodeWhamUsage(from: Data(whamJson.utf8))
        let windows = CodexProvider.windows(from: wham)
        #expect(windows.count == 2)
        #expect(windows[0].label == "7d Weekly")
        #expect(abs(windows[0].remainingPercent - 82.0) < 0.01)
        #expect(windows[1].label == "5h Session")
        #expect(abs(windows[1].remainingPercent - 45.0) < 0.01)

        let rolloutLine = """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"plus","primary":{"used_percent":81.0,"window_minutes":300,"resets_at":1795640000},"secondary":{"used_percent":24.0,"window_minutes":10080,"resets_at":1796072000}}}}
        """
        let parsed = CodexProvider.parseRolloutRateLimits(fromJSONLine: rolloutLine)
        #expect(parsed != nil)
        #expect(parsed?.planType == "plus")
        #expect(parsed?.windows.count == 2)
        #expect(abs((parsed?.windows[0].remainingPercent ?? 0) - 19.0) < 0.01)
        #expect(abs((parsed?.windows[1].remainingPercent ?? 0) - 76.0) < 0.01)
    }

    @Test("Antigravity quota buckets decode cleanly")
    func antigravityQuotaDecoding() throws {
        let json = """
        {
          "project": "gen-lang-client-123",
          "quotaGroups": [
            {
              "id": "gemini-models",
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "modelId": "gemini-pro",
                  "remainingFraction": 0.85,
                  "resetTime": "2026-11-25T22:30:00Z"
                },
                {
                  "modelId": "gemini-flash",
                  "remainingFraction": 0.95,
                  "resetTime": "2026-11-25T22:30:00Z"
                }
              ]
            }
          ]
        }
        """
        let decoded = try AntigravityProvider.decodeQuotaResponse(from: Data(json.utf8))
        let windows = AntigravityProvider.windows(from: decoded)
        #expect(windows.count == 1)
        #expect(windows[0].label == "Gemini Models")
        #expect(abs(windows[0].remainingPercent - 85.0) < 0.01)
    }

    @Test("Antigravity status-line feed distinguishes weekly, short-term, and expired limits")
    func antigravityStatusLineQuota() throws {
        let json = """
        {"quota":{
          "gemini-weekly":{"remaining_fraction":0.8,"reset_in_seconds":3600},
          "gemini-5h":{"remaining_fraction":0,"reset_in_seconds":600},
          "other-weekly":{"remaining_fraction":0.1,"reset_in_seconds":10},
          "disabled-weekly":{"remaining_fraction":0.1,"disabled":true}
        }}
        """
        let capturedAt = Date()
        let windows = try AntigravityQuotaFeed.windows(
            from: Data(json.utf8), capturedAt: capturedAt, now: capturedAt.addingTimeInterval(60)
        )
        let snapshot = ProviderSnapshot(provider: .antigravity, windows: windows, status: .live, sourceDetail: "Test")
        #expect(windows.count == 2)
        #expect(snapshot.weeklyWindow?.remainingPercent == 80)
        #expect(snapshot.shortWindow?.remainingPercent == 0)
        #expect(snapshot.shortLimitBlocksWeekly)
        #expect(snapshot.menuBarWindow == snapshot.weeklyWindow)
    }

    @Test("Surplus alert engine triggers before reset, detects imbalance, and respects cooldown")
    func surplusAlertEngineTriggersBeforeResetAndRespectsCooldown() {
        let now = Date()
        let claude = ProviderSnapshot(
            provider: .claude,
            planName: "Max",
            windows: [
                QuotaWindow(
                    id: "claude-7d",
                    label: "7d Weekly",
                    usedPercent: 18,
                    resetsAt: now.addingTimeInterval(12 * 3_600),
                    windowDurationSeconds: 7 * 86_400,
                    isPrimary: true
                )
            ],
            status: .live,
            sourceDetail: "Test",
            fetchedAt: now
        )
        let codex = ProviderSnapshot(
            provider: .codex,
            planName: "Plus",
            windows: [
                QuotaWindow(
                    id: "codex-5h",
                    label: "5h Session",
                    usedPercent: 85,
                    resetsAt: now.addingTimeInterval(3 * 3_600),
                    windowDurationSeconds: 5 * 3_600,
                    isPrimary: true
                )
            ],
            status: .live,
            sourceDetail: "Test",
            fetchedAt: now
        )

        let engine = SurplusAlertEngine()
        let prefs = AppPreferences(
            surplusThresholdPercent: 60,
            surplusLeadHours: 24,
            enableSurplusAlerts: true,
            enableImbalanceAlerts: true,
            alertCooldownHours: 4
        )

        let alerts = engine.evaluateAlerts(snapshots: [claude, codex], preferences: prefs, now: now, respectCooldown: true)
        #expect(alerts.contains(where: { $0.provider == .claude && $0.kind == .surplusBeforeReset }))
        #expect(alerts.contains(where: { $0.provider == .claude && $0.kind == .crossProviderShift }))

        let limitedEngine = SurplusAlertEngine()
        let firstDelivery = limitedEngine.evaluateAlerts(
            snapshots: [claude, codex], preferences: prefs, now: now, deliveryLimit: 1
        )
        let nextDelivery = limitedEngine.evaluateAlerts(
            snapshots: [claude, codex], preferences: prefs, now: now, deliveryLimit: 1
        )
        #expect(firstDelivery.first?.kind == .surplusBeforeReset)
        #expect(nextDelivery.first?.kind == .crossProviderShift)

        limitedEngine.snoozeAll(hours: 4, now: now)
        #expect(limitedEngine.evaluateAlerts(
            snapshots: [claude, codex], preferences: prefs, now: now, respectCooldown: false
        ).isEmpty)

        // Second immediate call should be suppressed by cooldown
        let secondCall = engine.evaluateAlerts(snapshots: [claude, codex], preferences: prefs, now: now.addingTimeInterval(60), respectCooldown: true)
        #expect(secondCall.isEmpty)

        // Best recommendation should pick Claude
        let best = engine.bestProviderToUseNow(from: [claude, codex], now: now)
        #expect(best?.provider == .claude)
    }
    @Test("Spending opportunities prefer the closest reset and then unused capacity")
    func spendingOpportunityOrdering() {
        let now = Date()
        func snapshot(_ provider: AIProviderKind, hoursToReset: Double, used: Double) -> ProviderSnapshot {
            ProviderSnapshot(
                provider: provider,
                windows: [QuotaWindow(id: provider.rawValue, label: "Weekly", usedPercent: used,
                                      resetsAt: now.addingTimeInterval(hoursToReset * 3_600),
                                      windowDurationSeconds: 7 * 86_400)],
                status: .live, sourceDetail: "Test"
            )
        }

        let engine = SurplusAlertEngine()
        let preferences = AppPreferences()
        let claude = snapshot(.claude, hoursToReset: 40, used: 15)
        let codex = snapshot(.codex, hoursToReset: 45, used: 5)
        let antigravity = snapshot(.antigravity, hoursToReset: 4, used: 30)
        let imminent = engine.evaluateAlerts(snapshots: [claude, codex, antigravity], preferences: preferences,
                                             now: now, respectCooldown: false)
        #expect(imminent.first(where: \.isSpendingOpportunity)?.provider == .antigravity)

        let underused = engine.evaluateAlerts(snapshots: [claude, codex], preferences: preferences,
                                              now: now, respectCooldown: false)
        #expect(underused.first(where: \.isSpendingOpportunity)?.provider == .codex)

        let anotherReset = snapshot(.claude, hoursToReset: 8, used: 5)
        let competing = engine.evaluateAlerts(snapshots: [anotherReset, antigravity], preferences: preferences,
                                              now: now, respectCooldown: false)
        #expect(competing.first(where: \.isSpendingOpportunity)?.provider == .antigravity)
    }

}

private struct SnapshotProvider: QuotaProvider {
    let kind: AIProviderKind = .codex
    let snapshot: ProviderSnapshot

    func fetchSnapshot(preferences: AppPreferences) async -> ProviderSnapshot { snapshot }
}

@Test("Quota cache survives a new view model and a failed refresh")
@MainActor
func persistedQuotaCache() async throws {
    let suite = "TokenPulseTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let now = Date()
    let live = ProviderSnapshot(
        provider: .codex,
        windows: [
            QuotaWindow(id: "short", label: "Short", usedPercent: 26, resetsAt: now.addingTimeInterval(3600),
                        windowDurationSeconds: 18_000),
            QuotaWindow(id: "weekly", label: "Weekly", usedPercent: 32, resetsAt: now.addingTimeInterval(86_400),
                        windowDurationSeconds: 604_800),
            QuotaWindow(id: "expired", label: "Expired", usedPercent: 3, resetsAt: now.addingTimeInterval(-60))
        ],
        status: .live, sourceDetail: "Test", fetchedAt: now
    )
    let first = UsageMonitorViewModel(providers: [SnapshotProvider(snapshot: live)], defaults: defaults)
    await first.refreshAll(triggerNotifications: false)

    let failed = ProviderSnapshot(provider: .codex, windows: [], status: .unavailable("Offline"), sourceDetail: "Test")
    let relaunched = UsageMonitorViewModel(providers: [SnapshotProvider(snapshot: failed)], defaults: defaults)
    let restored = try #require(relaunched.snapshots.first)
    #expect(restored.isCached)
    #expect(restored.fetchedAt == now)
    #expect(restored.shortWindow?.remainingPercent == 74)
    #expect(restored.weeklyWindow?.remainingPercent == 68)
    #expect(restored.windows.count == 2)
    await relaunched.refreshAll(triggerNotifications: false)
    #expect(relaunched.snapshots == [restored])
}
