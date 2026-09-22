import Foundation

/// Only AgentBar-managed credential files are renewed. Concurrent readers share
/// one exchange because the provider may rotate a refresh token on every use.
actor ClaudeCredentialRefresher {
    static let shared = ClaudeCredentialRefresher()
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private var inFlight: [URL: Task<Void, Error>] = [:]

    func refresh(data: Data, directory: URL, transport: @escaping Transport) async throws {
        let file = directory.standardizedFileURL.appendingPathComponent(".credentials.json")
        if let task = inFlight[file] { return try await task.value }
        let task = Task { try await Self.exchange(data: data, file: file, transport: transport) }
        inFlight[file] = task
        defer { inFlight[file] = nil }
        try await task.value
    }

    private static func exchange(data: Data, file: URL, transport: Transport) async throws {
        // A newer credential may have arrived while this request was queued.
        guard try Data(contentsOf: file) == data else { return }
        guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = document["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else {
            throw AccountError.loginRequired
        }
        // Official Claude Code OAuth endpoint/client (CLI 2.1.278). Preserve the
        // granted scope instead of requesting additional permissions.
        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refreshToken,
                                   "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"]
        if let scopes = oauth["scopes"] as? [String], !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (responseData, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse else {
            throw AccountError.message("Could not refresh Claude sign-in. Please try again.")
        }
        switch response.statusCode {
        case 200: break
        case 400, 401, 403: throw AccountError.loginRequired
        case 429: throw AccountError.rateLimited(60)
        default: throw AccountError.message("Claude sign-in refresh is temporarily unavailable. Please try again.")
        }
        guard let result = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let accessToken = result["access_token"] as? String, !accessToken.isEmpty,
              let lifetime = result["expires_in"] as? Double, lifetime.isFinite, lifetime > 0,
              lifetime < 365 * 24 * 60 * 60 else {
            throw AccountError.message("Claude returned an invalid sign-in refresh response.")
        }
        oauth["accessToken"] = accessToken
        oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + lifetime) * 1000)
        if let replacement = result["refresh_token"] as? String, !replacement.isEmpty { oauth["refreshToken"] = replacement }
        if let scope = result["scope"] as? String { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
        document["claudeAiOauth"] = oauth
        // Never recreate a deleted account or overwrite a changed credential.
        guard try Data(contentsOf: file) == data else {
            throw AccountError.message("The Claude account changed during sign-in refresh. Refresh again.")
        }
        // Persist a rotated token even if the UI cancelled during the exchange;
        // dropping it would force an unnecessary browser login next time.
        try JSONSerialization.data(withJSONObject: document).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
