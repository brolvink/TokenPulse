import Foundation
import LocalAuthentication
import Security

public struct ClaudeUsageResponse: Decodable, Sendable {
    public struct Window: Decodable, Sendable {
        public let utilization: Double
        public let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    public struct ExtraUsage: Decodable, Sendable {
        public let isEnabled: Bool?
        public let monthlyLimit: Double?
        public let usedCredits: Double?
        public let utilization: Double?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case utilization
        }
    }

    public let fiveHour: Window?
    public let sevenDay: Window?
    public let sevenDayOpus: Window?
    public let sevenDaySonnet: Window?
    public let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }
}

private struct ClaudeCredentialsFile: Decodable {
    struct OAuth: Decodable {
        let accessToken: String?
        let subscriptionType: String?
    }
    let claudeAiOauth: OAuth?
}

public protocol QuotaProvider: Sendable {
    var kind: AIProviderKind { get }
    func fetchSnapshot(preferences: AppPreferences) async -> ProviderSnapshot
}

public final class ClaudeProvider: QuotaProvider, @unchecked Sendable {
    public let kind: AIProviderKind = .claude
    private let session: URLSession
    private var rateLimitedUntil: Date?
    private var cachedResponse: ClaudeUsageResponse?
    private var cachedPlanName: String?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchSnapshot(preferences: AppPreferences) async -> ProviderSnapshot {
        await fetchSnapshot(allowKeychainPrompt: false)
    }

    func fetchSnapshot(allowKeychainPrompt: Bool) async -> ProviderSnapshot {
        let localSummary = scanLocalClaudeLogs()

        if let credentials = loadOAuthToken(allowKeychainPrompt: allowKeychainPrompt) {
            if let backoff = rateLimitedUntil, Date() < backoff, let cached = cachedResponse {
                return buildLiveSnapshot(
                    from: cached,
                    planName: cachedPlanName ?? credentials.planType,
                    local: localSummary,
                    detail: "Cached (Anthropic 429 cooldown)"
                )
            }

            do {
                let usage = try await fetchLiveUsage(token: credentials.token)
                cachedResponse = usage
                cachedPlanName = credentials.planType
                rateLimitedUntil = nil
                return buildLiveSnapshot(
                    from: usage,
                    planName: credentials.planType ?? "Claude Plan",
                    local: localSummary,
                    detail: "Anthropic OAuth Usage API"
                )
            } catch ClaudeError.rateLimited {
                rateLimitedUntil = Date().addingTimeInterval(600)
                if let cached = cachedResponse {
                    return buildLiveSnapshot(
                        from: cached,
                        planName: cachedPlanName ?? credentials.planType,
                        local: localSummary,
                        detail: "Cached (rate limited)"
                    )
                }
            } catch {
                // Fall through to local fallback below.
            }
        }


        return ProviderSnapshot(
            provider: .claude,
            planName: nil,
            windows: [],
            localTokens: localSummary,
            status: .unavailable("Use Connect Claude in the TokenPulse menu to grant Keychain access."),
            sourceDetail: "No Claude OAuth credentials found"
        )
    }

    public static func decodeUsageResponse(from data: Data) throws -> ClaudeUsageResponse {
        try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
    }

    public static func windows(from response: ClaudeUsageResponse) -> [QuotaWindow] {
        var result: [QuotaWindow] = []
        if let five = response.fiveHour {
            result.append(QuotaWindow(
                id: "claude-5h",
                label: "5h Session",
                usedPercent: five.utilization,
                resetsAt: Formatters.parseISO8601(five.resetsAt),
                windowDurationSeconds: 5 * 3_600,
                isPrimary: true
            ))
        }
        if let seven = response.sevenDay {
            result.append(QuotaWindow(
                id: "claude-7d",
                label: "7d Weekly",
                usedPercent: seven.utilization,
                resetsAt: Formatters.parseISO8601(seven.resetsAt),
                windowDurationSeconds: 7 * 86_400,
                isPrimary: response.fiveHour == nil
            ))
        }
        if let sonnet = response.sevenDaySonnet {
            result.append(QuotaWindow(
                id: "claude-7d-sonnet",
                label: "7d Sonnet",
                usedPercent: sonnet.utilization,
                resetsAt: Formatters.parseISO8601(sonnet.resetsAt),
                windowDurationSeconds: 7 * 86_400,
                isPrimary: false
            ))
        }
        if let opus = response.sevenDayOpus {
            result.append(QuotaWindow(
                id: "claude-7d-opus",
                label: "7d Opus",
                usedPercent: opus.utilization,
                resetsAt: Formatters.parseISO8601(opus.resetsAt),
                windowDurationSeconds: 7 * 86_400,
                isPrimary: false
            ))
        }
        return result
    }

    private func buildLiveSnapshot(
        from response: ClaudeUsageResponse,
        planName: String?,
        local: LocalTokenSummary?,
        detail: String
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .claude,
            planName: planName,
            windows: Self.windows(from: response),
            localTokens: local,
            status: .live,
            sourceDetail: detail
        )
    }

    private enum ClaudeError: Error {
        case rateLimited
        case badResponse
    }

    private func fetchLiveUsage(token: String) async throws -> ClaudeUsageResponse {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ClaudeError.badResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.badResponse
        }
        if http.statusCode == 429 {
            throw ClaudeError.rateLimited
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeError.badResponse
        }
        return try Self.decodeUsageResponse(from: data)
    }

    private func loadOAuthToken(allowKeychainPrompt: Bool) -> (token: String, planType: String?)? {
        if let credsData = readKeychainCredentials(allowPrompt: allowKeychainPrompt),
           let parsed = parseCredentialsData(credsData) {
            return parsed
        }
        let fileURL = LocalFileScanner.homeDirectory
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
        if let fileData = LocalFileScanner.readDataIfPresent(at: fileURL),
           let parsed = parseCredentialsData(fileData) {
            return parsed
        }
        return nil
    }

    private func parseCredentialsData(_ data: Data) -> (token: String, planType: String?)? {
        if let decoded = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data),
           let token = decoded.claudeAiOauth?.accessToken, !token.isEmpty {
            return (token, decoded.claudeAiOauth?.subscriptionType?.capitalized)
        }
        if let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           raw.hasPrefix("sk-ant-") {
            return (raw, nil)
        }
        return nil
    }

    private func readKeychainCredentials(allowPrompt: Bool) -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = !allowPrompt
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    private func scanLocalClaudeLogs() -> LocalTokenSummary? {
        let projectsDir = LocalFileScanner.homeDirectory
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
        let files = LocalFileScanner.recentFiles(in: projectsDir, matchingSuffix: ".jsonl", maxAgeDays: 7, limit: 150)
        guard !files.isEmpty else { return nil }

        let now = Date()
        let cutoff5h = now.addingTimeInterval(-5 * 3_600)
        var tokens5h = 0
        var tokens7d = 0
        var latestActivity: Date?

        for file in files {
            guard let data = LocalFileScanner.readDataIfPresent(at: file),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard line.contains("\"usage\""),
                      let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }
                let timestamp = Formatters.parseISO8601(obj["timestamp"] as? String)
                if let ts = timestamp, latestActivity == nil || ts > latestActivity! {
                    latestActivity = ts
                }
                let message = obj["message"] as? [String: Any]
                let usage = (message?["usage"] as? [String: Any]) ?? (obj["usage"] as? [String: Any])
                guard let usage else { continue }

                let input = (usage["input_tokens"] as? Int) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? 0
                let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                let total = input + output + cacheCreate + cacheRead

                tokens7d += total
                if let ts = timestamp, ts >= cutoff5h {
                    tokens5h += total
                }
            }
        }

        return LocalTokenSummary(
            recent5hTokens: tokens5h,
            recent7dTokens: tokens7d,
            sessionCount: files.count,
            lastActivityAt: latestActivity
        )
    }
}
