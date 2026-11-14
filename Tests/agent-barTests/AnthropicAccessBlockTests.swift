import Foundation
import Testing
@testable import agent_bar

// The refusal third-party Claude clients met in 2026, and a plain expiry.
private let blockBody = #"{"type":"error","error":{"type":"permission_error","message":"This credential is only authorized for use with Claude Code and cannot be used for other API requests."}}"#
private let expiredBody = #"{"type":"error","error":{"type":"authentication_error","message":"OAuth token has expired."}}"#

struct AnthropicAccessBlockTests {
    @Test func onlyTheClaudeCodeOnlyRefusalCountsAsABlock() {
        #expect(AnthropicAccessBlock.matches(status: 403, body: Data(blockBody.utf8)))
        #expect(!AnthropicAccessBlock.matches(status: 401, body: Data(expiredBody.utf8)))
        #expect(!AnthropicAccessBlock.matches(status: 500, body: Data(blockBody.utf8)))
        #expect(!AnthropicAccessBlock.matches(status: 403, body: Data()))
    }

    @Test func aBlockedUsageReadSaysSoInsteadOfAskingToReconnect() async throws {
        let directory = try credentialDirectory(expiresAt: 4_102_444_800_000); defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ClaudeUsageProvider(directory: directory, transport: { request in
            #expect(request.httpMethod == "GET")
            return reply(request, status: 403, body: blockBody)
        })
        let result = await provider.load()
        #expect(result.isStale && !result.requiresLogin)
        #expect(result.note == AnthropicAccessBlock.message)
    }

    @Test func aBlockedTokenRefreshSaysSoAndKeepsTheCredential() async throws {
        let directory = try credentialDirectory(expiresAt: 1); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".credentials.json")
        let before = try Data(contentsOf: file)
        let provider = ClaudeUsageProvider(directory: directory, transport: { request in
            #expect(request.httpMethod == "POST")
            return reply(request, status: 403, body: blockBody)
        })
        let result = await provider.load()
        #expect(result.isStale && !result.requiresLogin)
        #expect(result.note == AnthropicAccessBlock.message)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func theUsageReadNamesTheInstalledClaudeCode() async throws {
        let directory = try credentialDirectory(expiresAt: 4_102_444_800_000); defer { try? FileManager.default.removeItem(at: directory) }
        let agents = SentAgents()
        let provider = ClaudeUsageProvider(directory: directory, transport: { request in
            agents.append(request.value(forHTTPHeaderField: "User-Agent"))
            return reply(request, status: 200, body: #"{"five_hour":{"utilization":10,"resets_at":null}}"#)
        }, couponUserAgent: { "claude-cli/2.1.330 (external, cli)" })
        #expect(ClaudeCouponClient.userAgent(installed: ClaudeCodeVersion(major: 2, minor: 1, patch: 340)) == "claude-cli/2.1.340 (external, cli)")
        // An older or unreadable Claude Code sends the oldest version the reset program accepts.
        #expect(ClaudeCouponClient.userAgent(installed: ClaudeCodeVersion(major: 2, minor: 1, patch: 200)) == "claude-cli/2.1.295 (external, cli)")
        #expect(ClaudeCouponClient.userAgent(installed: nil) == "claude-cli/2.1.295 (external, cli)")
        _ = await provider.load()
        #expect(agents.all == ["claude-cli/2.1.330 (external, cli)"])
    }

    @Test func anExpiredSignInStillAsksToReconnect() async throws {
        let directory = try credentialDirectory(expiresAt: 4_102_444_800_000); defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ClaudeUsageProvider(directory: directory, transport: { request in
            reply(request, status: 401, body: expiredBody)
        })
        #expect(await provider.load().requiresLogin)
    }

    @MainActor
    @Test func theClaudeConsentIsAskedOnceAndRemembered() {
        let suite = "AnthropicAccessBlockTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!AppSettings(defaults: defaults).claudeAccessNoticeAccepted)
        AppSettings(defaults: defaults).claudeAccessNoticeAccepted = true
        #expect(AppSettings(defaults: defaults).claudeAccessNoticeAccepted)
    }
}

private func credentialDirectory(expiresAt: Int) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-block-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let credential = #"{"claudeAiOauth":{"accessToken":"fixture","refreshToken":"fixture-refresh","expiresAt":\#(expiresAt),"scopes":["user:profile","user:inference"],"subscriptionType":"max"}}"#
    try Data(credential.utf8).write(to: directory.appendingPathComponent(".credentials.json"))
    return directory
}

private final class SentAgents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?] = []
    var all: [String?] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ value: String?) { lock.lock(); values.append(value); lock.unlock() }
}

private func reply(_ request: URLRequest, status: Int, body: String) -> (Data, URLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}
