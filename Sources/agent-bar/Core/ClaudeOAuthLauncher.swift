import Foundation

/// Captures the URL passed to the CLI's BROWSER opener instead of allowing it to
/// launch the user's shared browser. The CLI remains responsible for PKCE/tokens.
enum ClaudeOAuthLauncher {
    static func environment(directory: URL) throws -> [String: String] {
        let helper = directory.appendingPathComponent("agentbar-browser-opener")
        let script = "#!/bin/sh\numask 077\n/usr/bin/printf '%s' \"$1\" > \"$AGENTBAR_OAUTH_URL_FILE\"\n"
        try Data(script.utf8).write(to: helper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        var env = ProviderCLI.environment(provider: .claude, directory: directory)
        env["BROWSER"] = helper.path
        env["AGENTBAR_OAUTH_URL_FILE"] = directory.appendingPathComponent("agentbar-oauth-url").path
        return env
    }
    static func validate(_ data: Data) throws -> URL {
        guard data.count <= 65_536, let raw = String(data: data, encoding: .utf8),
              let url = URL(string: raw), url.scheme == "https",
              ((url.host == "claude.ai" && url.path == "/oauth/authorize") ||
               (url.host == "claude.com" && url.path == "/cai/oauth/authorize")),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let redirect = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let callback = URL(string: redirect), callback.scheme == "http",
              ["localhost", "127.0.0.1", "[::1]"].contains(callback.host ?? ""),
              callback.port != nil else {
            throw AccountError.message("Claude CLI에서 유효한 로컬 콜백 로그인 주소를 받지 못했습니다. 기존 브라우저로 전환하지 않았습니다.")
        }
        return url
    }
    static func login(directory: URL, control: OperationControl, openURL: @Sendable (URL) -> Void) throws -> AccountIdentity {
        let urlFile = directory.appendingPathComponent("agentbar-oauth-url")
        try? FileManager.default.removeItem(at: urlFile)
        let env = try environment(directory: directory)
        let session = try ProcessSession(executable: ProviderCLI.executable(.claude), arguments: ["auth", "login", "--claudeai"],
                                         environment: env, directory: directory)
        defer { session.stop(); try? FileManager.default.removeItem(at: urlFile) }
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: urlFile.path) {
            if control.cancelled { throw AccountError.cancelled }
            if Date() >= deadline { throw AccountError.message("Claude 로그인 주소를 받지 못했습니다. 기존 브라우저로 전환하지 않았습니다.") }
            if session.exitStatus != -1 { throw AccountError.message("Claude 로그인 준비에 실패했습니다.") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // The opener creates the file before its write finishes. Wait for a valid
        // complete URL while preserving the same bounded deadline.
        var authorizationURL: URL?
        while authorizationURL == nil && Date() < deadline {
            if control.cancelled { throw AccountError.cancelled }
            authorizationURL = (try? Data(contentsOf: urlFile)).flatMap { try? validate($0) }
            if authorizationURL == nil { Thread.sleep(forTimeInterval: 0.05) }
        }
        guard let authorizationURL else { throw AccountError.message("Claude 로그인 주소 형식이 지원되지 않습니다.") }
        try FileManager.default.removeItem(at: urlFile)
        openURL(authorizationURL)
        _ = try session.collect(until: Date().addingTimeInterval(300), control: control)
        guard !control.cancelled else { throw AccountError.cancelled }
        guard session.exitStatus == 0 else { throw AccountError.message("Claude 로그인이 완료되지 않았습니다.") }
        return try ProviderCLI.claudeStatus(directory: directory, control: control)
    }
}
