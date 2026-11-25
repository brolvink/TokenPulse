import Foundation
import Testing
@testable import TokenPulseCore

struct ProviderRegressionTests {
    @Test("Claude preserves the original quota timestamp and skips requests during cooldown")
    func claudeCachedRateLimit() async {
        let stub = QuotaAPIStub([
            .init(200, body: #"{"five_hour":{"utilization":30}}"#),
            .init(429)
        ])
        let provider = ClaudeProvider(session: stub.session)

        let live = await provider.fetchUsageSnapshot(token: stub.token, planName: "Max", local: nil)
        let cached = await provider.fetchUsageSnapshot(token: stub.token, planName: "Max", local: nil)
        let local = LocalTokenSummary(recent5hTokens: 50)
        let cooldown = await provider.fetchUsageSnapshot(token: stub.token, planName: "Max", local: local)

        #expect(!live.isCached)
        #expect(cached.isCached && cooldown.isCached)
        #expect(cached.fetchedAt == live.fetchedAt && cooldown.fetchedAt == live.fetchedAt)
        #expect(cooldown.windows == live.windows)
        #expect(cooldown.localTokens == local)
        #expect(stub.requestCount == 2)
    }

    @Test("Claude honors server cooldown with and without cached quota")
    func claudeRateLimitWithoutCache() async {
        let delayed = QuotaAPIStub([.init(429, headers: ["Retry-After": "60"])])
        let provider = ClaudeProvider(session: delayed.session)
        let first = await provider.fetchUsageSnapshot(token: delayed.token, planName: nil, local: nil)
        let second = await provider.fetchUsageSnapshot(token: delayed.token, planName: nil, local: nil)
        #expect(first.status == .unavailable("Claude quota is temporarily rate limited."))
        #expect(second.status == first.status)
        #expect(second.windows.isEmpty)
        #expect(delayed.requestCount == 1)

        let immediate = QuotaAPIStub([
            .init(429, headers: ["Retry-After": "0"]),
            .init(200, body: #"{"five_hour":{"utilization":20}}"#)
        ])
        let retryable = ClaudeProvider(session: immediate.session)
        _ = await retryable.fetchUsageSnapshot(token: immediate.token, planName: nil, local: nil)
        let retried = await retryable.fetchUsageSnapshot(token: immediate.token, planName: nil, local: nil)
        #expect(retried.status == .live)
        #expect(!retried.isCached)
        #expect(immediate.requestCount == 2)
    }

    @Test("Antigravity tries Cloud Code when CLI quota is stale")
    func antigravitySourcePriority() async {
        let stub = QuotaAPIStub([
            .init(200, body: #"{"currentTier":{"name":"Google AI Pro"}}"#),
            .init(200, body: #"{"buckets":[{"modelId":"gemini","remainingFraction":0.8}]}"#),
            .init(503),
            .init(503)
        ])
        let provider = AntigravityProvider(session: stub.session)
        let windows = [
            QuotaWindow(id: "gemini-weekly", label: "Gemini Weekly", usedPercent: 70, windowDurationSeconds: 7 * 86_400),
            QuotaWindow(id: "gemini-short", label: "Gemini Session", usedPercent: 30, windowDurationSeconds: 5 * 3_600)
        ]
        let fresh = ProviderSnapshot(provider: .antigravity, windows: windows, status: .live, sourceDetail: "Antigravity CLI")
        let stale = ProviderSnapshot(
            provider: .antigravity, windows: windows, status: .live, sourceDetail: "Antigravity CLI",
            fetchedAt: Date().addingTimeInterval(-900), isCached: true
        )

        let current = await provider.fetchSnapshot(cli: fresh, localTokens: nil) { stub.token }
        #expect(current == fresh)
        #expect(stub.requestCount == 0)

        let cloud = await provider.fetchSnapshot(cli: stale, localTokens: nil) { stub.token }
        #expect(cloud.planName == "Google AI Pro")
        #expect(cloud.primaryWindow?.remainingPercent == 80)
        #expect(!cloud.isCached)
        #expect(cloud.windows.count == 2)
        #expect(cloud.shortWindow?.cachedAt == nil)
        #expect(cloud.weeklyWindow?.remainingPercent == 30)
        #expect(cloud.weeklyWindow?.cachedAt == stale.fetchedAt)

        let fallback = await provider.fetchSnapshot(cli: stale, localTokens: nil) { stub.token }
        #expect(fallback == stale)
        #expect(stub.requestCount == 4)
    }

    @Test("Antigravity quota groups take the reset from their limiting bucket")
    func antigravityUsesMatchingReset() throws {
        let payload = """
        {"quotaGroups":[
          {"id":"gemini","buckets":[
            {"remainingFraction":0.7,"resetTime":"2026-11-25T14:00:00Z"},
            {"remainingFraction":0.2,"resetTime":"2026-11-25T15:00:00Z"},
            {"remainingFraction":0.2,"resetTime":"2026-11-25T16:00:00Z"}
          ]},
          {"id":"claude","buckets":[
            {"remainingFraction":-1,"resetTime":"2026-11-25T13:00:00Z"},
            {"remainingFraction":0.5,"resetTime":"2026-11-25T14:00:00Z"},
            {"remainingFraction":0.1}
          ]}
        ]}
        """
        let response = try AntigravityProvider.decodeQuotaResponse(from: Data(payload.utf8))
        let windows = AntigravityProvider.windows(from: response)

        #expect(windows.count == 2)
        #expect(windows[0].usedPercent == 80)
        #expect(windows[0].resetsAt == Formatters.parseISO8601("2026-11-25T15:00:00Z"))
        #expect(windows[1].usedPercent == 90)
        #expect(windows[1].resetsAt == nil)
    }
}

private final class QuotaAPIStub: @unchecked Sendable {
    struct Response {
        let status: Int
        let body: Data
        let headers: [String: String]

        init(_ status: Int, body: String = "", headers: [String: String] = [:]) {
            self.status = status
            self.body = Data(body.utf8)
            self.headers = headers
        }
    }

    let token = UUID().uuidString
    let session: URLSession
    private let lock = NSLock()
    private let responses: [Response]
    private var count = 0

    var requestCount: Int { lock.withLock { count } }

    init(_ responses: [Response]) {
        self.responses = responses
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuotaURLProtocol.self]
        session = URLSession(configuration: config)
        QuotaURLProtocol.register(token: token, respond: { [weak self] in self?.nextResponse() })
    }

    deinit {
        QuotaURLProtocol.unregister(token: token)
        session.invalidateAndCancel()
    }

    private func nextResponse() -> Response? {
        lock.withLock {
            defer { count += 1 }
            return responses.indices.contains(count) ? responses[count] : nil
        }
    }
}

private final class QuotaURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var responses: [String: () -> QuotaAPIStub.Response?] = [:]

    static func register(token: String, respond: @escaping () -> QuotaAPIStub.Response?) {
        lock.withLock { responses["Bearer \(token)"] = respond }
    }

    static func unregister(token: String) {
        lock.withLock { responses["Bearer \(token)"] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let auth = request.value(forHTTPHeaderField: "Authorization"),
              let respond = Self.lock.withLock({ Self.responses[auth] }),
              let stub = respond(),
              let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
