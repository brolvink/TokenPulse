import Foundation

public struct CodexWhamUsageResponse: Decodable, Sendable {
    public struct Window: Decodable, Sendable {
        public let usedPercent: Double
        public let limitWindowSeconds: Double?
        public let resetAfterSeconds: Double?
        public let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }

    public struct RateLimit: Decodable, Sendable {
        public let allowed: Bool?
        public let limitReached: Bool?
        public let primaryWindow: Window?
        public let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case allowed
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    public struct AdditionalRateLimit: Decodable, Sendable {
        public let id: String?
        public let title: String?
        public let primaryWindow: Window?
        public let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    public let planType: String?
    public let rateLimit: RateLimit?
    public let additionalRateLimits: [AdditionalRateLimit]?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }
}

private struct CodexAuthFile: Decodable {
    struct Tokens: Decodable {
        let accessToken: String?
        let accountId: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountId = "account_id"
        }
    }

    let tokens: Tokens?
    let accessToken: String?
    let accountId: String?

    enum CodingKeys: String, CodingKey {
        case tokens
        case accessToken = "access_token"
        case accountId = "account_id"
    }
}

public final class CodexProvider: QuotaProvider, @unchecked Sendable {
    public let kind: AIProviderKind = .codex
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchSnapshot(preferences: AppPreferences) async -> ProviderSnapshot {
        let rolloutData = scanLocalRollouts()

        if let auth = loadAuth() {
            if let live = try? await fetchLiveUsage(token: auth.accessToken, accountId: auth.accountId) {
                let windows = Self.windows(from: live)
                if !windows.isEmpty {
                    return ProviderSnapshot(
                        provider: .codex,
                        planName: live.planType?.capitalized ?? "ChatGPT Plan",
                        windows: windows,
                        localTokens: rolloutData.tokens,
                        status: .live,
                        sourceDetail: "ChatGPT WHAM Usage API"
                    )
                }
            }
        }

        let now = Date()
        let currentWindows = rolloutData.windows.filter { ($0.resetsAt ?? .distantPast) > now }
        if !currentWindows.isEmpty {
            return ProviderSnapshot(
                provider: .codex,
                planName: rolloutData.planType?.capitalized ?? "Codex Session",
                windows: currentWindows,
                localTokens: rolloutData.tokens,
                status: .localOnly,
                sourceDetail: "~/.codex/sessions JSONL snapshot"
            )
        }


        return ProviderSnapshot(
            provider: .codex,
            planName: nil,
            windows: [],
            localTokens: rolloutData.tokens,
            status: .unavailable("Sign in via `codex` (~/.codex/auth.json) or enable Demo Mode."),
            sourceDetail: "No Codex auth or session logs found"
        )
    }

    public static func decodeWhamUsage(from data: Data) throws -> CodexWhamUsageResponse {
        try JSONDecoder().decode(CodexWhamUsageResponse.self, from: data)
    }

    public static func windows(from response: CodexWhamUsageResponse) -> [QuotaWindow] {
        var result: [QuotaWindow] = []
        if let primary = response.rateLimit?.primaryWindow {
            result.append(makeWindow(id: "codex-primary", window: primary, isPrimary: true))
        }
        if let secondary = response.rateLimit?.secondaryWindow {
            result.append(makeWindow(id: "codex-secondary", window: secondary, isPrimary: response.rateLimit?.primaryWindow == nil))
        }
        if let extra = response.additionalRateLimits {
            for item in extra {
                if let pw = item.primaryWindow {
                    let title = item.title ?? item.id ?? "Model Limit"
                    result.append(makeWindow(
                        id: "codex-\(item.id ?? title)",
                        overrideLabel: title,
                        window: pw,
                        isPrimary: false
                    ))
                }
            }
        }
        return result
    }

    private static func makeWindow(
        id: String,
        overrideLabel: String? = nil,
        window: CodexWhamUsageResponse.Window,
        isPrimary: Bool
    ) -> QuotaWindow {
        let duration = window.limitWindowSeconds ?? 18_000
        let label = overrideLabel ?? labelForWindowSeconds(duration)
        let resetsAt: Date?
        if let epoch = window.resetAt {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let after = window.resetAfterSeconds {
            resetsAt = Date().addingTimeInterval(after)
        } else {
            resetsAt = nil
        }

        return QuotaWindow(
            id: id,
            label: label,
            usedPercent: window.usedPercent,
            resetsAt: resetsAt,
            windowDurationSeconds: duration,
            isPrimary: isPrimary
        )
    }

    private static func labelForWindowSeconds(_ seconds: Double) -> String {
        if seconds >= 6 * 86_400 {
            return "7d Weekly"
        } else if seconds >= 80_000 {
            return "24h Daily"
        } else {
            let hours = max(1, Int((seconds / 3_600).rounded()))
            return "\(hours)h Session"
        }
    }

    public static func parseRolloutRateLimits(fromJSONLine line: String) -> (planType: String?, windows: [QuotaWindow])? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any] else {
            return nil
        }

        let planType = rateLimits["plan_type"] as? String
        var windows: [QuotaWindow] = []

        if let primary = rateLimits["primary"] as? [String: Any],
           let used = primary["used_percent"] as? Double {
            let mins = (primary["window_minutes"] as? Double) ?? 300
            let resetEpoch = primary["resets_at"] as? Double
            windows.append(QuotaWindow(
                id: "codex-rollout-primary",
                label: labelForWindowSeconds(mins * 60),
                usedPercent: used,
                resetsAt: resetEpoch.map { Date(timeIntervalSince1970: $0) },
                windowDurationSeconds: mins * 60,
                isPrimary: true
            ))
        }

        if let secondary = rateLimits["secondary"] as? [String: Any],
           let used = secondary["used_percent"] as? Double {
            let mins = (secondary["window_minutes"] as? Double) ?? 10_080
            let resetEpoch = secondary["resets_at"] as? Double
            windows.append(QuotaWindow(
                id: "codex-rollout-secondary",
                label: labelForWindowSeconds(mins * 60),
                usedPercent: used,
                resetsAt: resetEpoch.map { Date(timeIntervalSince1970: $0) },
                windowDurationSeconds: mins * 60,
                isPrimary: windows.isEmpty
            ))
        }

        return windows.isEmpty ? nil : (planType, windows)
    }

    private func loadAuth() -> (accessToken: String, accountId: String?)? {
        let url = LocalFileScanner.homeDirectory
            .appendingPathComponent(".codex")
            .appendingPathComponent("auth.json")
        guard let data = LocalFileScanner.readDataIfPresent(at: url),
              let decoded = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else {
            return nil
        }
        if let token = decoded.tokens?.accessToken, !token.isEmpty {
            return (token, decoded.tokens?.accountId)
        }
        if let token = decoded.accessToken, !token.isEmpty {
            return (token, decoded.accountId)
        }
        return nil
    }

    private func fetchLiveUsage(token: String, accountId: String?) async throws -> CodexWhamUsageResponse {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try Self.decodeWhamUsage(from: data)
    }

    private func scanLocalRollouts() -> (planType: String?, windows: [QuotaWindow], tokens: LocalTokenSummary?) {
        let sessionsDir = LocalFileScanner.homeDirectory
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
        let files = LocalFileScanner.recentFiles(in: sessionsDir, matchingSuffix: ".jsonl", maxAgeDays: 7, limit: 120)
        guard !files.isEmpty else { return (nil, [], nil) }

        let now = Date()
        let cutoff7d = now.addingTimeInterval(-7 * 86_400)
        let cutoff5h = now.addingTimeInterval(-5 * 3_600)
        var latestQuotaTimestamp: Date?
        var latestPlan: String?
        var latestWindows: [QuotaWindow] = []
        var latestActivity: Date?
        var totalTokens7d = 0
        var totalTokens5h = 0

        for file in files {
            guard let data = LocalFileScanner.readDataIfPresent(at: file),
                  let text = String(data: data, encoding: .utf8) else { continue }

            let lines = text.split(separator: "\n")
            var sessionMaxTokens = 0

            for lineSub in lines {
                let line = String(lineSub)
                guard line.contains("rate_limits") || line.contains("total_token_usage"),
                      let root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let timestamp = Formatters.parseISO8601(root["timestamp"] as? String) else { continue }

                if timestamp >= (latestQuotaTimestamp ?? .distantPast),
                   let parsed = Self.parseRolloutRateLimits(fromJSONLine: line) {
                    latestQuotaTimestamp = timestamp
                    latestPlan = parsed.planType
                    latestWindows = parsed.windows
                }

                guard let payload = root["payload"] as? [String: Any],
                      let info = payload["info"] as? [String: Any],
                      let totalUsage = info["total_token_usage"] as? [String: Any],
                      let total = totalUsage["total_tokens"] as? Int else { continue }
                latestActivity = max(latestActivity ?? .distantPast, timestamp)
                let increment = max(0, total - sessionMaxTokens)
                sessionMaxTokens = max(sessionMaxTokens, total)
                let eventUsage = info["last_token_usage"] as? [String: Any]
                let tokens = max(0, min(increment, eventUsage?["total_tokens"] as? Int ?? increment))
                if timestamp >= cutoff7d { totalTokens7d += tokens }
                if timestamp >= cutoff5h { totalTokens5h += tokens }
            }

        }

        let summary = LocalTokenSummary(
            recent5hTokens: totalTokens5h,
            recent7dTokens: totalTokens7d,
            sessionCount: files.count,
            lastActivityAt: latestActivity
        )
        return (latestPlan, latestWindows, summary)
    }
}
