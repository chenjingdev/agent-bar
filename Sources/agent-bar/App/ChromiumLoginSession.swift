import AppKit
import AuthenticationServices

/// A separate browser process and profile isolate even other open incognito
/// windows. Only this owned process group and temporary directory are cleaned up.
@MainActor
final class ChromiumLoginSession: BrowserAuthenticationSession {
    var prefersEphemeralWebBrowserSession = true
    weak var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
    private let url: URL
    private let executable: URL
    private let completion: BrowserLoginLauncher.Completion
    let profileDirectory: URL
    private var process: ProcessSession?
    private var monitor: Task<Void, Never>?

    static func installedBrowser(for url: URL) -> URL? {
        let supported = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "org.chromium.Chromium"]
        let workspace = NSWorkspace.shared
        var apps: [URL] = []
        if let preferred = workspace.urlForApplication(toOpen: url),
           let id = Bundle(url: preferred)?.bundleIdentifier, supported.contains(id) { apps.append(preferred) }
        apps += supported.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        return apps.compactMap { Bundle(url: $0)?.executableURL }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    init(url: URL, executable: URL, temporaryRoot: URL = FileManager.default.temporaryDirectory,
         completion: @escaping BrowserLoginLauncher.Completion) {
        self.url = url
        self.executable = executable
        self.completion = completion
        profileDirectory = temporaryRoot.appendingPathComponent("AgentBar-sign-in-\(UUID())", isDirectory: true)
    }

    var arguments: [String] {
        ["--user-data-dir=\(profileDirectory.path)", "--incognito", "--no-first-run", "--no-default-browser-check",
         "--disable-background-mode", "--new-window", url.absoluteString]
    }

    func start() -> Bool {
        guard process == nil else { return false }
        do {
            try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let process = try ProcessSession(executable: executable, arguments: arguments,
                environment: ProviderCLI.processEnvironment(), directory: profileDirectory)
            self.process = process
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled, let self else { return }
                    if process.exitStatus != -1 {
                        self.cancel()
                        self.completion(nil, ASWebAuthenticationSessionError(.canceledLogin))
                        return
                    }
                }
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: profileDirectory)
            return false
        }
    }

    func cancel() {
        monitor?.cancel(); monitor = nil
        let previous = process
        process = nil
        let directory = profileDirectory
        // Stopping a browser can take a moment; keep Accounts responsive.
        Task.detached(priority: .utility) {
            previous?.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
