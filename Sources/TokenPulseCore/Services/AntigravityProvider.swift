import Foundation

public struct AntigravityQuotaResponse: Decodable, Sendable {
    public struct Bucket: Decodable, Sendable {
        public let modelId: String?
        public let remainingFraction: Double?
        public let resetTime: String?

        fileprivate var validRemaining: Double? {
            guard let remainingFraction, (0...1).contains(remainingFraction) else { return nil }
            return remainingFraction
        }
    }

    public struct QuotaGroup: Decodable, Sendable {
        public let id: String?
        public let displayName: String?
        public let buckets: [Bucket]?
    }

    public let project: String?
    public let quotaGroups: [QuotaGroup]?
    public let buckets: [Bucket]?
}

private struct GoogleOAuthCreds: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiryDate: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiryDate = "expiry_date"
    }
}

private struct LoadCodeAssistResponse: Decodable {
    struct Tier: Decodable {
        let id: String?
        let name: String?
    }
    let cloudaicompanionProject: String?
    let currentTier: Tier?
}

public final class AntigravityProvider: QuotaProvider, @unchecked Sendable {
    public let kind: AIProviderKind = .antigravity
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchSnapshot(preferences: AppPreferences) async -> ProviderSnapshot {
        let localSummary = scanLocalAntigravityLogs()
        return await fetchSnapshot(cli: Self.cliSnapshot(localTokens: localSummary), localTokens: localSummary) {
            loadOAuthToken()?.accessToken
        }
    }

    func fetchSnapshot(
        cli: ProviderSnapshot?,
        localTokens: LocalTokenSummary?,
        loadToken: () -> String?
    ) async -> ProviderSnapshot {
        if let cli, !cli.isCached {
            return cli
        }

        let token = loadToken()
        if let token, !token.isEmpty {
            if let live = try? await fetchCloudCodeQuota(token: token) {
                var windows = Self.windows(from: live.response)
                if !windows.isEmpty {
                    let now = Date()
                    if let cli, !windows.contains(where: { $0.windowDurationSeconds == 7 * 86_400 }) {
                        let weekly = cli.windows.filter {
                            $0.windowDurationSeconds == 7 * 86_400 && ($0.resetsAt ?? .distantFuture) > now
                        }
                        windows += weekly.map { reading in
                            var cached = reading
                            cached.cachedAt = reading.cachedAt ?? cli.fetchedAt
                            return cached
                        }
                    }
                    return ProviderSnapshot(
                        provider: .antigravity,
                        planName: live.tierName ?? "Google AI Plan",
                        windows: windows,
                        localTokens: localTokens,
                        status: .live,
                        sourceDetail: "Cloud Code Assist Quota API"
                    )
                }
            }
        }
        if let cli { return cli }

        return ProviderSnapshot(
            provider: .antigravity,
            planName: nil,
            windows: [],
            localTokens: localTokens,
            status: .unavailable("Open Antigravity CLI and run /usage to see your live limits."),
            sourceDetail: token == nil ? "CLI quota connection unavailable" : "Google quota request unavailable"
        )
    }

    static func cliSnapshot(localTokens: LocalTokenSummary?, now: Date = Date()) -> ProviderSnapshot? {
        guard let feed = AntigravityQuotaFeed.read(now: now) else { return nil }
        return ProviderSnapshot(provider: .antigravity, windows: feed.windows, localTokens: localTokens,
                                status: .live, sourceDetail: "Antigravity CLI", fetchedAt: feed.date,
                                isCached: now.timeIntervalSince(feed.date) > 15 * 60)
    }

    public static func decodeQuotaResponse(from data: Data) throws -> AntigravityQuotaResponse {
        try JSONDecoder().decode(AntigravityQuotaResponse.self, from: data)
    }

    public static func windows(from response: AntigravityQuotaResponse) -> [QuotaWindow] {
        var result: [QuotaWindow] = []
        if let groups = response.quotaGroups {
            for (gIdx, group) in groups.enumerated() {
                let buckets = group.buckets ?? []
                guard let minRemaining = buckets.compactMap(\.validRemaining).min() else { continue }
                let earliestReset = buckets
                    .filter { $0.validRemaining == minRemaining }
                    .compactMap { Formatters.parseISO8601($0.resetTime) }
                    .min()
                let label = group.displayName ?? group.id ?? "Quota Group \(gIdx + 1)"
                result.append(QuotaWindow(
                    id: "agy-\(group.id ?? "\(gIdx)")",
                    label: label,
                    usedPercent: (1.0 - minRemaining) * 100.0,
                    resetsAt: earliestReset,
                    windowDurationSeconds: 5 * 3_600,
                    isPrimary: result.isEmpty
                ))
            }
        } else if let flatBuckets = response.buckets {
            for (idx, bucket) in flatBuckets.enumerated() {
                guard let remaining = bucket.validRemaining else { continue }
                let label = bucket.modelId ?? "Model \(idx + 1)"
                result.append(QuotaWindow(
                    id: "agy-bucket-\(idx)-\(label)",
                    label: label,
                    usedPercent: (1.0 - remaining) * 100.0,
                    resetsAt: Formatters.parseISO8601(bucket.resetTime),
                    windowDurationSeconds: 5 * 3_600,
                    isPrimary: result.isEmpty
                ))
            }
        }
        return result
    }

    private func loadOAuthToken() -> GoogleOAuthCreds? {
        let geminiDir = LocalFileScanner.homeDirectory.appendingPathComponent(".gemini")
        let candidates = [
            geminiDir.appendingPathComponent("oauth_creds.json"),
            geminiDir.appendingPathComponent("antigravity-cli").appendingPathComponent("oauth_creds.json")
        ]
        for url in candidates {
            if let data = LocalFileScanner.readDataIfPresent(at: url),
               let decoded = try? JSONDecoder().decode(GoogleOAuthCreds.self, from: data),
               let token = decoded.accessToken, !token.isEmpty {
                return decoded
            }
        }
        return nil
    }

    private func fetchCloudCodeQuota(token: String) async throws -> (tierName: String?, response: AntigravityQuotaResponse) {
        var projectId: String?
        var tierName: String?

        if let loadURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist") {
            var loadReq = URLRequest(url: loadURL)
            loadReq.httpMethod = "POST"
            loadReq.timeoutInterval = 10
            loadReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            loadReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            loadReq.httpBody = Data("{\"metadata\":{\"ideType\":\"ANTIGRAVITY\"}}".utf8)
            if let (data, resp) = try? await session.data(for: loadReq),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let loaded = try? JSONDecoder().decode(LoadCodeAssistResponse.self, from: data) {
                projectId = loaded.cloudaicompanionProject
                tierName = loaded.currentTier?.name ?? loaded.currentTier?.id
            }
        }

        guard let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
            throw URLError(.badURL)
        }
        var quotaReq = URLRequest(url: quotaURL)
        quotaReq.httpMethod = "POST"
        quotaReq.timeoutInterval = 12
        quotaReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        quotaReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let projectId {
            quotaReq.httpBody = Data("{\"project\":\"\(projectId)\"}".utf8)
        } else {
            quotaReq.httpBody = Data("{}".utf8)
        }

        let (data, response) = try await session.data(for: quotaReq)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try Self.decodeQuotaResponse(from: data)
        return (tierName, decoded)
    }

    private func scanLocalAntigravityLogs() -> LocalTokenSummary? {
        let brainDir = LocalFileScanner.homeDirectory
            .appendingPathComponent(".gemini")
            .appendingPathComponent("antigravity-cli")
            .appendingPathComponent("brain")
        let files = LocalFileScanner.recentFiles(in: brainDir, matchingSuffix: "transcript.jsonl", maxAgeDays: 7, limit: 150)
        guard !files.isEmpty else { return nil }

        let now = Date()
        let cutoff5h = now.addingTimeInterval(-5 * 3_600)
        var tokens7d = 0
        var tokens5h = 0
        var latestActivity: Date?

        for file in files {
            let fileMod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let fileMod, latestActivity == nil || fileMod > latestActivity! {
                latestActivity = fileMod
            }

            guard let data = LocalFileScanner.readDataIfPresent(at: file),
                  let text = String(data: data, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n") {
                guard line.contains("tokens") || line.contains("usage"),
                      let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }
                let ts = Formatters.parseISO8601(obj["timestamp"] as? String) ?? fileMod
                if let ts, latestActivity == nil || ts > latestActivity! {
                    latestActivity = ts
                }

                let usage = (obj["usage"] as? [String: Any])
                    ?? (obj["usageMetadata"] as? [String: Any])
                    ?? obj
                let total = (usage["total_tokens"] as? Int)
                    ?? (usage["totalTokenCount"] as? Int)
                    ?? (((usage["input_tokens"] as? Int) ?? (usage["promptTokenCount"] as? Int) ?? 0)
                        + ((usage["output_tokens"] as? Int) ?? (usage["candidatesTokenCount"] as? Int) ?? 0))

                guard total > 0 else { continue }
                tokens7d += total
                if let ts, ts >= cutoff5h {
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
