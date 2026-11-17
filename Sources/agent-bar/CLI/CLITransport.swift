import AppKit
import Foundation

// One line of JSON each way. The command sends {"args": [...]}; the app answers with any number of
// {"progress": "..."} lines and one {"exit": N, "stdout": "...", "stderr": "..."} line.

enum UnixSocket {
    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8.prefix(buffer.count - 1))
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func write(_ fd: Int32, _ object: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    // Reads JSON lines until the other side closes, handing each to `line`.
    static func readLines(_ fd: Int32, _ line: ([String: Any]) -> Bool) {
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { return }
            pending.append(contentsOf: chunk[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let data = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !line(object) { return }
            }
        }
    }
}

// The app side: listens on the socket and runs each command on the main actor.
final class CLIServer: @unchecked Sendable {
    static let shared = CLIServer()
    private var listener: Int32 = -1

    func start(root: URL) {
        guard listener < 0 else { return }
        let path = CLI.socketPath(root: root)
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Another AgentBar with the same data folder already answers: leave it its socket.
        if let other = UnixSocket.connect(path) { close(other); return }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = UnixSocket.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); return }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); return }
        listener = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "AgentBar command socket"
        thread.start()
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { Self.serve(client) }
        }
    }

    private static func serve(_ fd: Int32) {
        var request: [String: Any]?
        UnixSocket.readLines(fd) { request = $0; return false }
        guard let args = request?["args"] as? [String] else { close(fd); return }
        Task { @MainActor in
            let connection = CLIConnection(fd: fd)
            let (code, out, err) = await CLIRunner.execute(args, connection: connection)
            _ = UnixSocket.write(fd, ["exit": Int(code), "stdout": out, "stderr": err])
            close(fd)
        }
    }
}

@MainActor
final class CLIConnection {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }
    func progress(_ text: String) { _ = UnixSocket.write(fd, ["progress": text]) }
    // A peer that went away reads as end-of-file at once.
    var isOpen: Bool {
        var byte: UInt8 = 0
        let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return count != 0
    }
}

// Runs a parsed command inside the app and formats its answer.
@MainActor
enum CLIRunner {
    static func execute(_ args: [String], connection: CLIConnection?) async -> (Int32, String, String) {
        let json = args.contains("--json")
        do {
            switch try CLI.parse(args) {
            case .help(let spec, let words): return (0, CLI.help(spec, words) + "\n", "")
            case .invocation(var invocation):
                if let connection {
                    invocation.emit = { connection.progress($0) }
                    invocation.isOpen = { connection.isOpen }
                }
                let result: CLIResult
                if let run = invocation.spec.run { result = try await run(invocation) }
                else if let local = invocation.spec.local { result = try local(invocation) }
                else { throw CLIError("`agentbar \(invocation.spec.name)` has nothing to run.") }
                return (0, (json ? CLI.jsonString(result.json) : result.text) + "\n", "")
            }
        } catch let error as CLIError {
            return (error.code, "", json ? CLI.jsonString(["error": error.message, "exit": Int(error.code)]) + "\n" : "agentbar: \(error.message)\n")
        } catch {
            return (1, "", json ? CLI.jsonString(["error": error.localizedDescription]) + "\n" : "agentbar: \(error.localizedDescription)\n")
        }
    }
}

// The command side.
enum CLIClient {
    static func main(_ arguments: [String]) -> Int32 {
        let words = Array(arguments.dropFirst())
        let json = words.contains("--json")
        func fail(_ error: CLIError) -> Int32 {
            if json { print(CLI.jsonString(["error": error.message, "exit": Int(error.code)])) }
            else { FileHandle.standardError.write(Data("agentbar: \(error.message)\n".utf8)) }
            return error.code
        }
        let parsed: CLI.Parsed
        do { parsed = try CLI.parse(words) } catch let error as CLIError { return fail(error) } catch { return fail(CLIError("\(error)")) }
        switch parsed {
        case .help(let spec, let words):
            print(CLI.help(spec, words)); return 0
        case .invocation(let invocation):
            if let local = invocation.spec.local {
                do {
                    let result = try local(invocation)
                    print(json ? CLI.jsonString(result.json) : result.text); return 0
                } catch let error as CLIError { return fail(error) } catch { return fail(CLIError(error.localizedDescription)) }
            }
        }
        let path = CLI.socketPath(root: CLI.dataRoot())
        var fd = UnixSocket.connect(path)
        if fd == nil {
            if let error = launchApp() { return fail(error) }
            let deadline = Date().addingTimeInterval(20)
            while fd == nil && Date() < deadline {
                usleep(200_000)
                fd = UnixSocket.connect(path)
            }
        }
        guard let fd else {
            return fail(CLIError("AgentBar did not answer at \(path). Open AgentBar (version with the command) and try again.", code: 3))
        }
        defer { close(fd) }
        guard UnixSocket.write(fd, ["args": words]) else { return fail(CLIError("Could not send the command to AgentBar.", code: 3)) }
        var code: Int32?
        UnixSocket.readLines(fd) { line in
            if let progress = line["progress"] as? String {
                FileHandle.standardError.write(Data((progress + "\n").utf8))
                return true
            }
            if let out = line["stdout"] as? String, !out.isEmpty { FileHandle.standardOutput.write(Data(out.utf8)) }
            if let err = line["stderr"] as? String, !err.isEmpty { FileHandle.standardError.write(Data(err.utf8)) }
            code = Int32(line["exit"] as? Int ?? 1)
            return false
        }
        return code ?? fail(CLIError("AgentBar closed the connection without an answer.", code: 3))
    }

    // The executable this command runs from, with links resolved.
    static var executableURL: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    }

    // The .app this executable belongs to, if any.
    static var appBundleURL: URL? {
        let bundle = executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return bundle.pathExtension == "app" ? bundle : nil
    }

    // Starts AgentBar in the background with the same data folder and defaults, so a test run talks to a test app.
    private static func launchApp() -> CLIError? {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["AGENTBAR_DATA_DIR", "AGENTBAR_DEFAULTS_SUITE"]
        let process = Process()
        if let bundle = appBundleURL {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-g"] + keys.flatMap { key in environment[key].map { ["--env", "\(key)=\($0)"] } ?? [] } + [bundle.path]
        } else {
            // A development build outside a bundle runs as a detached child.
            process.executableURL = executableURL
            process.arguments = []
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        FileHandle.standardError.write(Data("agentbar: starting AgentBar…\n".utf8))
        do { try process.run() } catch { return CLIError("Could not start AgentBar: \(error.localizedDescription)", code: 3) }
        if appBundleURL != nil { process.waitUntilExit() }
        return nil
    }
}
