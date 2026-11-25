import Foundation
import Testing
@testable import TokenPulseCore

struct ClaudeKeychainTests {
    @Test("security -w output is read as text or hex")
    func decodesSecurityOutput() {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat-x","subscriptionType":"max","expiresAt":1800000000000}}"#
        let plain = ClaudeProvider.decodeSecurityOutput(Data((json + "\n").utf8))
        let hex = json.utf8.map { String(format: "%02x", $0) }.joined()
        let fromHex = ClaudeProvider.decodeSecurityOutput(Data(hex.utf8))

        #expect(plain == Data(json.utf8))
        #expect(fromHex == Data(json.utf8))
        #expect(ClaudeProvider.decodeSecurityOutput(Data("\n".utf8)) == nil)
    }

    @Test("Credentials keep the token expiry so the keychain is read only when needed")
    func parsesExpiry() {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat-x","subscriptionType":"max","expiresAt":1800000000000}}"#
        let parsed = ClaudeProvider.parseCredentialsData(Data(json.utf8))

        #expect(parsed?.token == "sk-ant-oat-x")
        #expect(parsed?.planType == "Max")
        #expect(parsed?.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
    }
}
