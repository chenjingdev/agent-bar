import Foundation
import Security
import Testing
@testable import agent_bar

struct BackgroundCredentialAccessTests {
    @Test func legacyKeychainUISuppressionIsScopedAndRestoredEvenOnFailure() throws {
        enum FixtureError: Error { case expected }
        try BackgroundKeychain.withInteraction(true) {
            #expect(throws: FixtureError.self) {
                try BackgroundKeychain.withInteraction(false) {
                    var allowed = DarwinBoolean(true)
                    #expect(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess)
                    #expect(!allowed.boolValue)
                    throw FixtureError.expected
                }
            }
            var restored = DarwinBoolean(false)
            #expect(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess)
            #expect(restored.boolValue)
        }
    }
    @Test func pollingAndAvailabilityQueriesForbidAuthorizationDialogs() {
        for secret in [false, true] {
            let query = BackgroundKeychain.query(service: "fixture-only", account: "fixture-user", secret: secret)
            #expect(query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
            #expect(query[kSecReturnData as String] as? Bool == (secret ? true : nil))
            #expect(query[kSecReturnAttributes as String] as? Bool == (secret ? nil : true))
        }
    }

    @Test func currentAccountUsesFileWhenKeychainNeedsApproval() async throws {
        let home = try fixtureHome(); defer { try? FileManager.default.removeItem(at: home) }
        try credential("fixture-original").write(to: home.appendingPathComponent(".claude/.credentials.json"))
        let calls = CredentialCalls()
        // The external current-login reader also remains noninteractive.
        let provider = ClaudeUsageProvider(homeDirectory: home,
            keychainReader: { _, _ in calls.keychain(); throw BackgroundKeychain.ReadError.authorizationRequired },
            transport: { request in
                calls.http()
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-original")
                return success(request)
            })
        for _ in 0..<3 {
            let result = await provider.load()
            #expect(!result.isStale)
            #expect(result.weekly?.utilization == 0.42)
        }
        #expect(calls.counts == [6, 3]) // Initial read plus race check; no third secret read.
    }

    @Test func unavailableOrExpiredCredentialStopsAfterOneDeniedRead() async throws {
        for expired in [false, true] {
            let home = try fixtureHome(); defer { try? FileManager.default.removeItem(at: home) }
            if expired { try credential("fixture-expired", expired: true).write(to: home.appendingPathComponent(".claude/.credentials.json")) }
            let calls = CredentialCalls()
            let provider = ClaudeUsageProvider(homeDirectory: home,
                keychainReader: { _, _ in calls.keychain(); throw BackgroundKeychain.ReadError.authorizationRequired },
                transport: { request in calls.http(); return success(request) })
            let result = await provider.load()
            #expect(result.isStale && result.note?.contains("Reconnect this account") == true)
            #expect(result.requiresLogin)
            #expect(calls.counts == [1, 0])
        }
    }

    @Test func fileFallbackStillRejectsAccountChangeDuringHTTPRequest() async throws {
        let home = try fixtureHome(); defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent(".claude/.credentials.json")
        try credential("fixture-before").write(to: path)
        let replacement = credential("fixture-after")
        let provider = ClaudeUsageProvider(homeDirectory: home,
            keychainReader: { _, _ in throw BackgroundKeychain.ReadError.authorizationRequired },
            transport: { request in try replacement.write(to: path); return success(request) })
        let result = await provider.load()
        #expect(result.isStale && result.weekly?.utilization == nil)
        #expect(result.note?.contains("account changed during the request") == true)
    }

    @Test func managedIdentityIsCheckedLocallyBeforeUsingCredential() async throws {
        let home = try fixtureHome(); defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".claude")
        try credential("fixture").write(to: directory.appendingPathComponent(".credentials.json"))
        try Data("{\"oauthAccount\":{\"emailAddress\":\"other@example.invalid\",\"organizationUuid\":\"org-other\"}}".utf8)
            .write(to: directory.appendingPathComponent(".claude.json"))
        let calls = CredentialCalls()
        let provider = ClaudeUsageProvider(directory: directory,
            expectedIdentity: AccountIdentity(email: "selected@example.invalid", organizationID: "org-selected"),
            keychainReader: { _, _ in calls.keychain(); return nil },
            transport: { request in calls.http(); return success(request) })
        let result = await provider.load()
        #expect(result.isStale && result.note?.contains("linked Claude account has changed") == true)
        #expect(calls.counts == [0, 0])
    }
}

private func fixtureHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-quiet-credentials-\(UUID())")
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    return home
}
private func credential(_ token: String, expired: Bool = false) -> Data {
    let expiry = expired ? 1 : Int((Date().timeIntervalSince1970 + 3600) * 1000)
    return Data("{\"claudeAiOauth\":{\"accessToken\":\"\(token)\",\"expiresAt\":\(expiry),\"subscriptionType\":\"max\"}}".utf8)
}
private func success(_ request: URLRequest) -> (Data, URLResponse) {
    (Data("{\"five_hour\":{\"utilization\":18},\"seven_day\":{\"utilization\":42}}".utf8),
     HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}
private final class CredentialCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = [0, 0]
    var counts: [Int] { lock.lock(); defer { lock.unlock() }; return value }
    func keychain() { lock.lock(); defer { lock.unlock() }; value[0] += 1 }
    func http() { lock.lock(); defer { lock.unlock() }; value[1] += 1 }
}
