import SwiftUI

// What a Claude account's row in a group's account list shows about using that account in Claude Code: a control on
// its first line and a few lines under it. Plain values, so every state can be drawn without a store;
// `UsageStore.claudeCodePanel(for:)` makes it from the store's state. Adapted from the original AgentBar.
struct ClaudeCodePanel: Equatable {
    enum Control: Equatable {
        // Nothing: the feature is off, Claude Code is not installed, or the account is not a Claude account.
        case hidden
        // "In use": the login Claude Code uses now is this account's.
        case inClaudeCode
        // "Use". `help` says what it does, or why it cannot be pressed.
        case use(enabled: Bool, help: String)
        // "Set Up in Settings…": this account has no sign-in saved for Claude Code yet. The button opens Settings ›
        // Accounts, where the account signs in once; the panel never opens a browser.
        case setUp(help: String)
    }

    enum Line: Equatable {
        // A switch is running.
        case progress(String)
        // Claude Code holds a login AgentBar does not have; switching would remove it.
        case confirmation(email: String?)
        // How the last switch ended.
        case result(succeeded: Bool, message: String)
        // Why the button is blocked.
        case notice(String)
    }

    var control: Control
    var lines: [Line]

    static let hidden = ClaudeCodePanel(control: .hidden, lines: [])

    static func confirmationText(email: String?) -> String {
        if let email {
            return String(localized: "Claude Code is signed in as \(email), which isn't in \(AppInfo.name). Switching removes that login from Claude Code.")
        }
        return String(localized: "Claude Code is signed in to an account that isn't in \(AppInfo.name). Switching removes that login from Claude Code.")
    }
}

// What the app calls using an account in Claude Code, in one place so a group's account list and Settings › Accounts
// say the same. The Use button's help comes with its control from `UsageStore.claudeCodePanel(for:)`, since it also
// says why the button is blocked.
enum ClaudeCodeWords {
    // The button that switches Claude Code to the account.
    static var use: String { String(localized: "Use") }
    // The state of the account Claude Code uses now.
    static var inUse: String { String(localized: "In use") }
    static var inUseHelp: String { String(localized: "Claude Code is signed in to this account.") }
}

// The lines under an account's row: progress, the question, the last result, or why the button is blocked.
struct ClaudeCodeLinesView: View {
    let lines: [ClaudeCodePanel.Line]
    // "Switch" on the question.
    var confirm: () -> Void = {}
    // "Cancel" on the question.
    var decline: () -> Void = {}
    var openLog: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line) }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ line: ClaudeCodePanel.Line) -> some View {
        switch line {
        case .progress(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
        case .confirmation(let email):
            VStack(alignment: .leading, spacing: 6) {
                Text(ClaudeCodePanel.confirmationText(email: email))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Cancel", action: decline)
                    Button("Switch", action: confirm)
                }
                .buttonStyle(PanelBorderedButtonStyle())
            }
        case .result(let succeeded, let message):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(succeeded ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .foregroundStyle(succeeded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !succeeded, let openLog {
                    Spacer(minLength: 4)
                    Button("Open Log", action: openLog)
                        .buttonStyle(PanelButtonStyle(kind: .text))
                        .help("Opens the Claude Code switch log, which records each step of every switch.")
                }
            }
        case .notice(let message):
            Text(message)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// What a Claude account's row in Settings › Accounts says about using the account in Claude Code: whether its sign-in
// for Claude Code is done, and the button that does it once in the browser. `UsageStore.claudeCodeSetup(for:)` makes it.
struct ClaudeCodeSetup: Equatable {
    enum Status: Equatable {
        // Nothing is shown: the feature is off, Claude Code is not installed, or the account is not a Claude account.
        case hidden
        // The login Claude Code uses now is this account's; there is nothing to prepare.
        case inClaudeCode
        // The account's own folder holds a login to hand over, so switching to it needs no browser.
        case ready
        // No sign-in is saved yet. "Set Up…" does it in the browser; `blocked` is why it cannot be pressed now.
        case notSetUp(blocked: String?)
        // This account's sign-in is running. The wait for the browser can be cancelled.
        case signingIn(message: String, cancellable: Bool)
    }

    var status: Status
    // Why the last sign-in did not work. Shown with "Open Log" while the account is not set up.
    var failure: String? = nil

    static let hidden = ClaudeCodeSetup(status: .hidden)
}

struct ClaudeCodeSetupView: View {
    let setup: ClaudeCodeSetup
    var setUp: () -> Void = {}
    var cancel: () -> Void = {}
    var openLog: (() -> Void)? = nil

    var body: some View {
        if setup.status != .hidden {
            VStack(alignment: .leading, spacing: 4) {
                status
                if let failure = setup.failure, case .notSetUp = setup.status {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(failure)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let openLog {
                            Spacer(minLength: 8)
                            Button("Open Log", action: openLog)
                                .help("Opens the Claude Code switch log, which records each step of every sign-in and switch.")
                        }
                    }
                }
            }
            // A size up from the status line above it, so it does not read as part of "Updated …".
            .font(.callout)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch setup.status {
        case .hidden:
            EmptyView()
        case .inClaudeCode:
            Label(ClaudeCodeWords.inUse, systemImage: "checkmark.circle.fill")
                .fontWeight(.semibold)
                .foregroundStyle(.green)
                .help(ClaudeCodeWords.inUseHelp)
        case .ready:
            Label {
                Text("Ready for Claude Code")
            } icon: {
                Image(systemName: "checkmark.circle").foregroundStyle(Color.accentColor)
            }
            .help("Switching Claude Code to this account needs no browser.")
        case .notSetUp(let blocked):
            HStack(spacing: 8) {
                Text("Not set up for Claude Code").foregroundStyle(.secondary)
                Button("Set Up…", action: setUp)
                    .disabled(blocked != nil)
                    .help(blocked ?? String(localized: "Sign in once in the browser so Claude Code can switch to this account without it."))
            }
        case .signingIn(let message, let cancellable):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message).fixedSize(horizontal: false, vertical: true)
                if cancellable { Button("Cancel", action: cancel) }
            }
        }
    }
}
