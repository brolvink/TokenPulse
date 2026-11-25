import Foundation

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
        let expiresAt: Double?
    }
    let claudeAiOauth: OAuth?
}

public protocol QuotaProvider: Sendable {
    var kind: AIProviderKind { get }
    func fetchSnapshot(preferences: AppPreferences) async -> ProviderSnapshot
}

public actor ClaudeProvider: QuotaProvider {
    public let kind: AIProviderKind = .claude
    private let session: URLSession
    private var rateLimitedUntil: Date?
    private var cachedSnapshot: ProviderSnapshot?
    private var inFlight: Task<ProviderSnapshot, Never>?
    private var cachedCredentials: ClaudeCredentials?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchSnapshot(preferences: AppPreferences) async -> ProviderSnapshot {
        await fetchSnapshot(allowKeychainPrompt: false)
    }

    func fetchSnapshot(allowKeychainPrompt: Bool) async -> ProviderSnapshot {
        let localSummary = scanLocalClaudeLogs()
        guard let credentials = loadOAuthToken(allowKeychainPrompt: allowKeychainPrompt) else {
            return ProviderSnapshot(
                provider: .claude,
                windows: [],
                localTokens: localSummary,
                status: .unavailable("No Claude Code sign-in found. Log in with Claude Code, then choose Connect Claude."),
                sourceDetail: "No Claude OAuth credentials found"
            )
        }
        let snapshot = await fetchUsageSnapshot(token: credentials.token, planName: credentials.planType, local: localSummary)
        guard snapshot.sourceDetail == Self.unauthorizedDetail else { return snapshot }
        // Claude Code refreshed its token since we cached it. Re-read once and retry.
        cachedCredentials = nil
        guard let fresh = loadOAuthToken(allowKeychainPrompt: allowKeychainPrompt),
              fresh.token != credentials.token else { return snapshot }
        return await fetchUsageSnapshot(token: fresh.token, planName: fresh.planType, local: localSummary)
    }

    private static let unauthorizedDetail = "Anthropic OAuth token rejected"

    func fetchUsageSnapshot(token: String, planName: String?, local: LocalTokenSummary?) async -> ProviderSnapshot {
        if let inFlight {
            return await inFlight.value
        }
        if let rateLimitedUntil, Date() < rateLimitedUntil {
            return rateLimitedSnapshot(local: local)
        }
        let request = Task { await requestUsageSnapshot(token: token, planName: planName, local: local) }
        inFlight = request
        defer { inFlight = nil }
        return await request.value
    }

    private func requestUsageSnapshot(token: String, planName: String?, local: LocalTokenSummary?) async -> ProviderSnapshot {
        do {
            let usage = try await fetchLiveUsage(token: token)
            let snapshot = ProviderSnapshot(
                provider: .claude,
                planName: planName ?? "Claude Plan",
                windows: Self.windows(from: usage),
                localTokens: local,
                status: .live,
                sourceDetail: "Anthropic OAuth Usage API"
            )
            if !snapshot.windows.isEmpty { cachedSnapshot = snapshot }
            rateLimitedUntil = nil
            return snapshot
        } catch ClaudeError.unauthorized {
            return ProviderSnapshot(
                provider: .claude,
                windows: [],
                localTokens: local,
                status: .unavailable("Claude sign-in expired. Run Claude Code once to refresh it."),
                sourceDetail: Self.unauthorizedDetail
            )
        } catch ClaudeError.rateLimited(let retryAfter) {
            rateLimitedUntil = Self.retryDate(after: retryAfter, now: Date())
            return rateLimitedSnapshot(local: local)
        } catch {
            return ProviderSnapshot(
                provider: .claude,
                windows: [],
                localTokens: local,
                status: .unavailable("Claude quota is temporarily unavailable. Try refreshing again."),
                sourceDetail: "Anthropic OAuth Usage API request failed"
            )
        }
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

    private func rateLimitedSnapshot(local: LocalTokenSummary?) -> ProviderSnapshot {
        let detail = "Anthropic Usage API rate limited"
        let now = Date()
        if let cachedSnapshot {
            let windows = cachedSnapshot.windows.filter { ($0.resetsAt ?? .distantFuture) > now }
            if !windows.isEmpty {
                return ProviderSnapshot(
                    provider: .claude,
                    planName: cachedSnapshot.planName,
                    windows: windows,
                    localTokens: local,
                    status: .live,
                    sourceDetail: detail,
                    fetchedAt: cachedSnapshot.fetchedAt,
                    isCached: true
                )
            }
        }
        return ProviderSnapshot(
            provider: .claude,
            windows: [],
            localTokens: local,
            status: .unavailable("Claude quota is temporarily rate limited."),
            sourceDetail: detail
        )
    }

    private static func retryDate(after header: String?, now: Date) -> Date {
        if let header = header?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let seconds = Int(header), seconds >= 0 {
                return now.addingTimeInterval(TimeInterval(seconds))
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: header) { return max(now, date) }
        }
        return now.addingTimeInterval(600)
    }

    private enum ClaudeError: Error {
        case rateLimited(String?)
        case unauthorized
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
        if http.statusCode == 401 {
            throw ClaudeError.unauthorized
        }
        if http.statusCode == 429 {
            throw ClaudeError.rateLimited(http.value(forHTTPHeaderField: "Retry-After"))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeError.badResponse
        }
        return try Self.decodeUsageResponse(from: data)
    }

    struct ClaudeCredentials: Equatable {
        let token: String
        let planType: String?
        let expiresAt: Date?
    }

    private func loadOAuthToken(allowKeychainPrompt: Bool) -> ClaudeCredentials? {
        // Connect Claude is an explicit re-check, so it skips the cache.
        if allowKeychainPrompt { cachedCredentials = nil }
        // Reuse the token until it expires, so the keychain is read rarely.
        if let cached = cachedCredentials,
           (cached.expiresAt ?? .distantFuture) > Date().addingTimeInterval(60) {
            return cached
        }
        cachedCredentials = nil
        if let credsData = Self.readKeychainCredentials(),
           let parsed = Self.parseCredentialsData(credsData) {
            cachedCredentials = parsed
            return parsed
        }
        let fileURL = LocalFileScanner.homeDirectory
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
        if let fileData = LocalFileScanner.readDataIfPresent(at: fileURL),
           let parsed = Self.parseCredentialsData(fileData) {
            cachedCredentials = parsed
            return parsed
        }
        return nil
    }

    static func parseCredentialsData(_ data: Data) -> ClaudeCredentials? {
        if let decoded = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data),
           let token = decoded.claudeAiOauth?.accessToken, !token.isEmpty {
            let expiresAt = decoded.claudeAiOauth?.expiresAt.map { Date(timeIntervalSince1970: $0 / 1_000) }
            return ClaudeCredentials(
                token: token,
                planType: decoded.claudeAiOauth?.subscriptionType?.capitalized,
                expiresAt: expiresAt
            )
        }
        if let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           raw.hasPrefix("sk-ant-") {
            return ClaudeCredentials(token: raw, planType: nil, expiresAt: nil)
        }
        return nil
    }

    /// Claude Code writes "Claude Code-credentials" with /usr/bin/security, so that tool is
    /// the only app its keychain ACL trusts. Reading through it never shows a password prompt.
    /// Reading with SecItemCopyMatching from TokenPulse itself prompts, and "Always Allow"
    /// does not last: every rebuild of the ad-hoc signed app gets a new code hash.
    private static func readKeychainCredentials() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // A locked login keychain makes `security` wait for an unlock dialog. Don't stall refreshes.
        let watchdog = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        defer { watchdog.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return decodeSecurityOutput(data)
    }

    /// `security -w` prints the secret as text, or as hex when it is not plain text.
    static func decodeSecurityOutput(_ data: Data) -> Data? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.first == "{" || text.hasPrefix("sk-ant-") {
            return Data(text.utf8)
        }
        let isHex = text.count.isMultiple(of: 2) && text.allSatisfy(\.isHexDigit)
        guard isHex else { return Data(text.utf8) }
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
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
