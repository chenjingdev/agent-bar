import Foundation
import Testing
@testable import agent_bar

struct ClaudeCredentialRefreshTests {
    @Test func expiredManagedAccountRefreshesAndPersistsRotatedToken() async throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".credentials.json")
        try fixtureCredential.write(to: file)
        let calls = RefreshCalls()
        let provider = ClaudeUsageProvider(directory: directory,
            keychainReader: { _, _ in Issue.record("Managed credential must not read shared Keychain"); return nil },
            transport: { request in
                await calls.record(request.httpMethod ?? "GET")
                if request.httpMethod == "POST" {
                    #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
                    let bodyData = try #require(request.httpBody)
                    let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: String])
                    #expect(body["refresh_token"] == "fixture-refresh")
                    #expect(body["grant_type"] == "refresh_token")
                    #expect(body["scope"] == "user:profile user:inference")
                    return reply(request, body: refreshed)
                }
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-new")
                return reply(request, body: usage)
            })
        let result = await provider.load()
        #expect(!result.requiresLogin && !result.isStale && result.weekly?.utilization == 0.42)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let oauth = try #require(saved["claudeAiOauth"] as? [String: Any])
        #expect(oauth["refreshToken"] as? String == "fixture-rotated")
        #expect(oauth["subscriptionType"] as? String == "max")
        #expect(saved["unrelatedField"] as? String == "preserved")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        _ = await provider.load()
        #expect(await calls.methods == ["POST", "GET", "GET"])
    }

    @Test func revokedRefreshRequiresLoginButTemporaryFailureDoesNot() async throws {
        for code in [400, 401, 403, 429, 500] {
            let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent(".credentials.json")
            try fixtureCredential.write(to: file)
            let provider = ClaudeUsageProvider(directory: directory, transport: { request in
                #expect(request.httpMethod == "POST")
                return reply(request, status: code, body: "secret-provider-error")
            })
            let result = await provider.load()
            #expect(result.isStale)
            #expect(result.requiresLogin == [400, 401, 403].contains(code))
            #expect(result.note?.contains("secret-provider-error") == false)
            #expect(try Data(contentsOf: file) == fixtureCredential)
        }
    }

    @Test func concurrentRefreshExchangesTokenOnlyOnce() async throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try fixtureCredential.write(to: directory.appendingPathComponent(".credentials.json"))
        let refresher = ClaudeCredentialRefresher(), calls = RefreshCalls()
        let transport: ClaudeCredentialRefresher.Transport = { request in
            await calls.record("POST")
            try await Task.sleep(for: .milliseconds(50))
            return reply(request, body: refreshed)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { try await refresher.refresh(data: fixtureCredential, directory: directory, transport: transport) }
            }
            try await group.waitForAll()
        }
        #expect(await calls.methods == ["POST"])
    }

    @Test func changedOrDeletedAccountIsNeverOverwritten() async throws {
        for delete in [false, true] {
            let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent(".credentials.json")
            try fixtureCredential.write(to: file)
            let provider = ClaudeUsageProvider(directory: directory, transport: { request in
                if delete { try FileManager.default.removeItem(at: directory) }
                else { try Data("replacement".utf8).write(to: file) }
                return reply(request, body: refreshed)
            })
            let result = await provider.load()
            #expect(result.isStale)
            if delete { #expect(!FileManager.default.fileExists(atPath: directory.path)) }
            else { #expect(try Data(contentsOf: file) == Data("replacement".utf8)) }
        }
    }

    @Test func cancellationAfterExchangeStillSavesRotatedToken() async throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".credentials.json")
        try fixtureCredential.write(to: file)
        let control = OperationControl()
        let provider = ClaudeUsageProvider(directory: directory, control: control, transport: { request in
            #expect(request.httpMethod == "POST")
            control.cancel()
            return reply(request, body: refreshed)
        })
        let result = await provider.load()
        #expect(result.isStale)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("fixture-rotated"))
    }

    @Test func expiredKeychainCredentialIsMirroredBeforeRefresh() async throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ClaudeUsageProvider(directory: directory,
            keychainReader: { service, _ in
                #expect(service == AccountFiles.claudeService(directory))
                return fixtureCredential
            }, transport: { request in reply(request, body: request.httpMethod == "POST" ? refreshed : usage) })
        let result = await provider.load()
        #expect(!result.requiresLogin && !result.isStale)
    }
}

private actor RefreshCalls {
    var methods: [String] = []
    func record(_ method: String) { methods.append(method) }
}
private let fixtureCredential = Data(#"{"unrelatedField":"preserved","claudeAiOauth":{"accessToken":"fixture-expired","refreshToken":"fixture-refresh","expiresAt":1,"scopes":["user:profile","user:inference"],"subscriptionType":"max"}}"#.utf8)
private let refreshed = #"{"access_token":"fixture-new","refresh_token":"fixture-rotated","expires_in":3600,"scope":"user:profile user:inference"}"#
private let usage = #"{"five_hour":{"utilization":18},"seven_day":{"utilization":42}}"#
private func reply(_ request: URLRequest, status: Int = 200, body: String) -> (Data, URLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}
private func fixtureDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-refresh-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory
}
