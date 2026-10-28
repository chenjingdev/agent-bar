import AppKit
import SwiftUI

// What one Claude account window shows about using that account in Claude Code: a control in the header and a few
// lines under it. Plain values, so every state can be drawn without a store. `UsageStore.claudeCodePanel(for:)`
// makes it from the store's state.
struct ClaudeCodePanel: Equatable {
    enum Control: Equatable {
        // Nothing: the feature is off, Claude Code is not installed, or the account is not a Claude account.
        case hidden
        // The login Claude Code uses now is this account's.
        case inClaudeCode
        // "Use in Claude Code". `help` says what it does, or why it cannot be pressed.
        case use(enabled: Bool, help: String)
    }

    enum Line: Equatable {
        // A switch is running. The browser wait is the only step that can be cancelled.
        case progress(String, cancellable: Bool)
        // Claude Code holds a login AgentBar does not have; switching would remove it.
        case confirmation(email: String?)
        // How the last switch ended.
        case result(succeeded: Bool, message: String, finishedAt: Date)
        // Why the button is blocked.
        case notice(String)
    }

    var control: Control
    var lines: [Line]

    static let hidden = ClaudeCodePanel(control: .hidden, lines: [])

    static func confirmationText(email: String?) -> String {
        let signedIn = email.map { "signed in as \($0), which isn't" } ?? "signed in to an account that isn't"
        return "Claude Code is \(signedIn) in AgentBar. Switching removes that login from Claude Code."
    }

    // Rough height of the lines under the header, for sizing the popover.
    var estimatedHeight: Int {
        guard !lines.isEmpty else { return 0 }
        func wrapped(_ text: String) -> Int { 15 * max(1, (text.count + 52) / 53) }
        return lines.reduce(10) { total, line in
            switch line {
            case .progress(let message, _): return total + wrapped(message) + 6
            case .confirmation(let email): return total + wrapped(Self.confirmationText(email: email)) + 40
            case .result(_, let message, _): return total + wrapped(message) + 6
            case .notice(let message): return total + wrapped(message) + 6
            }
        }
    }
}

// The header control: "Use in Claude Code", or "In Claude Code" for the account Claude Code already uses.
struct ClaudeCodeControlView: View {
    let control: ClaudeCodePanel.Control
    var use: () -> Void = {}

    var body: some View {
        switch control {
        case .hidden:
            EmptyView()
        case .inClaudeCode:
            HStack(spacing: 5) {
                Circle().fill(AppTheme.tint(for: .claude)).frame(width: 6, height: 6)
                Text("In Claude Code")
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .fixedSize()
            .help("Claude Code is signed in to this account.")
            .accessibilityLabel("In Claude Code")
        case .use(let enabled, let help):
            Button(action: use) {
                Text("Use in Claude Code")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    // A blocked button is grey, not a fainter green, so it still reads as a button that is there.
                    .foregroundStyle(enabled ? AppTheme.tint(for: .claude) : Color.white.opacity(0.38))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(enabled ? 0.10 : 0.05)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .fixedSize()
            .help(help)
        }
    }
}

// The lines under the header: progress, the question, the last result, or why the button is blocked.
struct ClaudeCodeLinesView: View {
    let lines: [ClaudeCodePanel.Line]
    // Cancel while waiting for the browser.
    var cancel: () -> Void = {}
    // "Switch" on the question.
    var confirm: () -> Void = {}
    // "Cancel" on the question.
    var decline: () -> Void = {}
    var openLog: (() -> Void)? = nil

    private static let detailFont = Font.system(size: 11, weight: .medium, design: .rounded)

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func row(_ line: ClaudeCodePanel.Line) -> some View {
        switch line {
        case .progress(let message, let cancellable):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message).fixedSize(horizontal: false, vertical: true)
                if cancellable {
                    Spacer(minLength: 4)
                    Button("Cancel", action: cancel)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .font(Self.detailFont)
            .foregroundStyle(AppTheme.muted)
        case .confirmation(let email):
            VStack(alignment: .leading, spacing: 6) {
                Text(ClaudeCodePanel.confirmationText(email: email))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: decline) { pill("Cancel", tint: .white.opacity(0.85)) }
                    Button(action: confirm) { pill("Switch", tint: AppTheme.tint(for: .claude)) }
                }
                .buttonStyle(.plain)
            }
            .font(Self.detailFont)
        case .result(let succeeded, let message, let finishedAt):
            AttemptResultLine(succeeded: succeeded, message: message, finishedAt: finishedAt, tint: AppTheme.tint(for: .claude),
                              logHelp: "Opens the Claude Code switch log, which records each step of every switch.", openLog: openLog)
        case .notice(let message):
            Text(message)
                .font(Self.detailFont)
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pill(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .contentShape(Capsule())
    }
}
