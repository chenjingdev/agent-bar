import CryptoKit
import Foundation

// The `agentbar` command: everything a person does in the menu bar and in Settings, as terminal commands an AI can run.
// The app's own executable is the command. Started with arguments it does not open the app: it sends the command to the
// running AgentBar over a private socket (starting AgentBar in the background when it is not running) and prints the
// app's answer. A few commands (help, version, install-cli, paths) run in the command itself.

struct CLIOption: Sendable {
    let name: String
    // nil for a flag; otherwise the name of the value, as `--name VALUE`.
    let value: String?
    let help: String
    init(_ name: String, _ value: String? = nil, _ help: String) { self.name = name; self.value = value; self.help = help }
}

struct CLIError: Error {
    var message: String
    // 1: the command failed. 2: the command line is wrong. 3: AgentBar could not be reached.
    var code: Int32 = 1
    init(_ message: String, code: Int32 = 1) { self.message = message; self.code = code }
}

// What a command produced: lines for a person, and the same facts as JSON for `--json`.
struct CLIResult {
    var text: String
    var json: Any
    init(_ text: String, json: Any? = nil) { self.text = text; self.json = json ?? ["message": text] }
}

struct CLIInvocation {
    let spec: CLISpec
    var positionals: [String]
    var values: [String: String]
    var flags: Set<String>
    var json: Bool { flags.contains("json") }
    // Writes a progress line to the command's standard error while a long command runs.
    var emit: @MainActor (String) -> Void = { _ in }
    // False once the command was interrupted (Ctrl-C) and nobody waits for the answer any more.
    var isOpen: @MainActor () -> Bool = { true }

    func value(_ name: String) -> String? { values[name] }
    func flag(_ name: String) -> Bool { flags.contains(name) }
    func positional(_ index: Int) -> String? { positionals.indices.contains(index) ? positionals[index] : nil }
}

struct CLISpec: Sendable {
    let path: [String]
    // Positional arguments as they read in help: `<required>` and `[optional]`.
    let arguments: [String]
    let summary: String
    var details: String? = nil
    var options: [CLIOption] = []
    // Runs in the command process, without AgentBar.
    var local: (@Sendable (CLIInvocation) throws -> CLIResult)? = nil
    // Runs inside AgentBar.
    var run: (@MainActor @Sendable (CLIInvocation) async throws -> CLIResult)? = nil

    var name: String { path.joined(separator: " ") }
    var usage: String {
        let flags: [String] = options.map { option in option.value.map { "[--\(option.name) \($0)]" } ?? "[--\(option.name)]" }
        return (["agentbar"] + path + arguments + flags).joined(separator: " ")
    }
    var requiredCount: Int { arguments.filter { $0.hasPrefix("<") }.count }
    var allowsMore: Bool { arguments.last?.hasSuffix("...]") == true || arguments.last?.hasSuffix("...>") == true }
}

enum CLI {
    static let globalOptions = [CLIOption("json", nil, "Print the result as JSON (errors too: {\"error\": …})."),
                                CLIOption("help", nil, "Show this command's help.")]

    // Whether the executable was started as the command rather than as the app. macOS passes the app `-psn_…` and
    // `-NS…` arguments of its own; the command always starts with a word.
    static func isCommand(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        let first = arguments[1]
        return !first.hasPrefix("-") || ["--help", "-h", "--version", "--json"].contains(first)
    }

    enum Parsed {
        case help(CLISpec?, [String])
        case invocation(CLIInvocation)
    }

    static func parse(_ words: [String]) throws -> Parsed {
        var words = words
        if words.first == "help" { words.removeFirst(); words.append("--help") }
        if words.first == "--version" { words[0] = "version" }
        let wantsHelp = words.contains("--help") || words.contains("-h")
        let plain = words.filter { !$0.hasPrefix("-") }
        // The longest command path the words start with.
        let spec = CLICommands.all.filter { $0.path.count <= plain.count && Array(words.prefix($0.path.count)) == $0.path }
            .max { $0.path.count < $1.path.count }
        guard let spec else {
            if wantsHelp || words.isEmpty { return .help(nil, plain) }
            throw CLIError("Unknown command: \(plain.prefix(2).joined(separator: " ")). Run `agentbar --help` for the commands.", code: 2)
        }
        if wantsHelp { return .help(spec, plain) }
        var invocation = CLIInvocation(spec: spec, positionals: [], values: [:], flags: [])
        var rest = Array(words.dropFirst(spec.path.count))
        let options = spec.options + globalOptions
        while !rest.isEmpty {
            let word = rest.removeFirst()
            guard word.hasPrefix("--"), word.count > 2 else { invocation.positionals.append(word); continue }
            var name = String(word.dropFirst(2))
            var inline: String?
            if let eq = name.firstIndex(of: "=") { inline = String(name[name.index(after: eq)...]); name = String(name[..<eq]) }
            guard let option = options.first(where: { $0.name == name }) else {
                throw CLIError("Unknown option --\(name) for `agentbar \(spec.name)`.\nUsage: \(spec.usage)", code: 2)
            }
            if option.value == nil { invocation.flags.insert(name); continue }
            guard let value = inline ?? (rest.isEmpty ? nil : rest.removeFirst()) else {
                throw CLIError("--\(name) needs a value (\(option.value!)).\nUsage: \(spec.usage)", code: 2)
            }
            invocation.values[name] = value
        }
        if invocation.positionals.count < spec.requiredCount {
            throw CLIError("Missing \(spec.arguments[invocation.positionals.count]).\nUsage: \(spec.usage)", code: 2)
        }
        if !spec.allowsMore && invocation.positionals.count > spec.arguments.count {
            throw CLIError("Unexpected argument: \(invocation.positionals[spec.arguments.count]).\nUsage: \(spec.usage)", code: 2)
        }
        return .invocation(invocation)
    }

    static func help(_ spec: CLISpec?, _ words: [String]) -> String {
        if let spec {
            var lines = ["Usage: \(spec.usage)", "", spec.summary]
            if let details = spec.details { lines += ["", details] }
            let options = spec.options + globalOptions
            lines += ["", "Options:"] + options.map { option in
                let left = "--\(option.name)" + (option.value.map { " \($0)" } ?? "")
                return "  " + left.padding(toLength: max(22, left.count + 2), withPad: " ", startingAt: 0) + option.help
            }
            let children = CLICommands.all.filter { $0.path.count > spec.path.count && Array($0.path.prefix(spec.path.count)) == spec.path }
            if !children.isEmpty { lines += ["", "Subcommands:"] + table(children) }
            return lines.joined(separator: "\n")
        }
        let prefix = words.isEmpty ? [] : words
        let matching = CLICommands.all.filter { prefix.isEmpty || Array($0.path.prefix(prefix.count)) == prefix }
        return ([
            "agentbar — control AgentBar (Codex and Claude subscription limits in the menu bar) from the terminal.",
            "",
            "Usage: agentbar <command> [arguments] [--json]",
            "",
            "Commands:",
        ] + table(matching.isEmpty ? CLICommands.all : matching) + [
            "",
            "<account> is an account's number from `agentbar accounts`, its email, the start of its id, or `claude`/`codex`",
            "when only one account of that provider exists. <group> is a group's number from `agentbar groups`, its name or",
            "the start of its id. <slot> is a usage line's slot in its group, 1 to 3 (more in Text Only groups).",
            "",
            "Commands are carried out by the running AgentBar app, which is started in the background when it is not",
            "running. Every command takes --json. Exit status: 0 done, 1 failed, 2 wrong command line, 3 AgentBar not reachable.",
            "Run `agentbar <command> --help` for a command's options.",
        ]).joined(separator: "\n")
    }

    private static func table(_ specs: [CLISpec]) -> [String] {
        let lefts = specs.map { ([$0.name] + $0.arguments).joined(separator: " ") }
        let width = min(44, (lefts.map(\.count).max() ?? 0) + 2)
        return zip(specs, lefts).map { spec, left in
            "  " + (left.count < width ? left.padding(toLength: width, withPad: " ", startingAt: 0) : left + "  ") + spec.summary
        }
    }

    // The JSON a command prints with --json. Keys are sorted so the output is stable.
    static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            if let text = value as? String { return "\"\(text)\"" }
            return "null"
        }
        return text
    }

    // AgentBar's data folder, as the app chooses it.
    static func dataRoot(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        environment["AGENTBAR_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? AccountFiles().root
    }

    // The socket the running app listens on. A socket path must stay under 104 bytes, so a long data folder (a test's)
    // uses a short name in /tmp derived from it.
    static func socketPath(root: URL) -> String {
        let path = root.appendingPathComponent("control.sock").path
        if path.utf8.count < 100 { return path }
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return "/tmp/agentbar-\(getuid())-\(digest).sock"
    }
}
