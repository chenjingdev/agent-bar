import SwiftUI

// What a Claude account's line in Settings › Accounts says about using the account in Claude Code: whether its sign-in
// for Claude Code is done, and the button that does it once in the browser. Plain values, so every state can be drawn
// without a store. `UsageStore.claudeCodeSetup(for:)` makes it from the store's state.
struct ClaudeCodeSetup: Equatable {
    enum Status: Equatable {
        // Nothing is shown: the feature is off, Claude Code is not installed, or the account is not a Claude account.
        case hidden
        // The login Claude Code uses now is this account's; there is nothing to prepare.
        case inClaudeCode
        // The account's own folder holds a login to hand over, so switching to it needs no browser.
        case ready
        // No sign-in is saved yet. "Sign In…" does it in the browser; `blocked` is why it cannot be pressed now.
        case notSetUp(blocked: String?)
        // This account's sign-in is running. The wait for the browser can be cancelled.
        case signingIn(message: String, cancellable: Bool)
    }

    var status: Status
    // Why the last sign-in did not work. Shown with "Open Log" while the account is not set up.
    var failure: String? = nil

    static let hidden = ClaudeCodeSetup(status: .hidden)
    // What "Sign In…" does, as its help text.
    static let signInHelp = "Sign in once in the browser so Claude Code can use this account."
}

struct ClaudeCodeSetupView: View {
    let setup: ClaudeCodeSetup
    var signIn: () -> Void = {}
    var cancel: () -> Void = {}
    var openLog: (() -> Void)? = nil

    var body: some View {
        if setup.status != .hidden {
            VStack(alignment: .leading, spacing: 4) {
                status
                if let failure = setup.failure, case .notSetUp = setup.status {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(failure)
                            .foregroundStyle(Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let openLog {
                            Spacer(minLength: 8)
                            Button("Open Log", action: openLog)
                                .help("Opens the Claude Code log, which records each step of every sign-in and switch.")
                        }
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch setup.status {
        case .hidden:
            EmptyView()
        case .inClaudeCode:
            HStack(spacing: 6) {
                Circle().fill(AppTheme.tint(for: .claude)).frame(width: 7, height: 7)
                Text("In Claude Code")
            }
            .help("Claude Code is signed in to this account.")
        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                Text("Ready for Claude Code")
            }
            .help("Switching Claude Code to this account needs no browser.")
        case .notSetUp(let blocked):
            HStack(spacing: 8) {
                Text("Not set up for Claude Code").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Sign In…", action: signIn)
                    .disabled(blocked != nil)
                    .help(blocked ?? ClaudeCodeSetup.signInHelp)
            }
        case .signingIn(let message, let cancellable):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if cancellable { Button("Cancel", action: cancel) }
            }
        }
    }
}
