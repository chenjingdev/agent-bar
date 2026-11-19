import AppKit
import Foundation

// Every `agentbar` command. Each one does what a button in the menu bar popover or in Settings does, through the same
// UsageStore methods, so the app's own checks (locks during a Claude Code switch, sign-in review, valid layouts) apply.
enum CLICommands {
    static let all: [CLISpec] = [
        // MARK: Usage
        CLISpec(path: ["status"], arguments: ["[account]"],
                summary: "Show usage of every account (or one): % used of each limit, reset times, credits and resets.",
                details: "Reads what AgentBar last loaded; it does not wait for a refresh (use `agentbar refresh` for fresh values).\nA limit without data shows --, never 0%. Warnings AgentBar shows on screen are listed last (see `agentbar warnings`).",
                run: { await freshClaudeCode(); return try status($0) }),
        CLISpec(path: ["refresh"], arguments: ["[account]"],
                summary: "Refresh usage now (like the popover's refresh button) and show the result.",
                details: "Only accounts used by a shown menu bar group are refreshed. Provider cooldowns still apply.",
                options: [CLIOption("no-wait", nil, "Start the refresh and return at once.")],
                run: { try await refresh($0) }),

        // MARK: Accounts
        CLISpec(path: ["accounts"], arguments: [], summary: "List accounts in their saved order with id, provider, email and state.",
                details: "--json also gives, per account, why Delete/Reconnect wait (claudeCodeLock), why Claude Code's Use is blocked\n(claudeCodeBlocked), the last failed sign-in for Claude Code (claudeCodeSetupFailure) and whether it is paused.",
                run: { _ in await freshClaudeCode(); try requireStorage(); return withWarnings(accountsList()) }),
        CLISpec(path: ["account", "add"], arguments: ["<claude|codex|antigravity>"],
                summary: "Sign in a new account in the browser and register it (needs --yes; waits up to 5 minutes).",
                details: "Opens the provider's sign-in page in the default browser. A person has to finish the sign-in there, so ask them\nfirst and pass --yes. Claude: the first time, the notice Settings shows (how AgentBar keeps the sign-in, which\nAnthropic could block) must be accepted by the person; --yes accepts it. Without --yes nothing opens and the\nnotice is printed. The signed-in account (email, organization) is registered at once and printed; undo with\n`agentbar account remove <account> --yes`. An account already registered is refused.\nAntigravity needs no browser and no --yes: the one account signed in to agy or the Antigravity app is added.",
                options: [CLIOption("yes", nil, "The person agreed to sign in (and, for Claude, accepted the notice)."),
                          CLIOption("private", nil, "Open the sign-in in a private browser window instead.")],
                run: { try await accountAdd($0) }),
        CLISpec(path: ["account", "reconnect"], arguments: ["<account>"],
                summary: "Sign an existing account in again in the browser (needs --yes; waits up to 5 minutes).",
                details: "A person finishes the sign-in in the browser; pass --yes once they agreed (Claude: also accepts the notice,\nas for `account add`). The browser must be signed in to the same account. A different account changes nothing\nunless --add-as-new adds it as a new account (as Settings' Add Account button there). When AgentBar cannot verify\nit is the same account, --force reconnects anyway and --add-as-new adds it as a new one.",
                options: [CLIOption("yes", nil, "The person agreed to sign in (and, for Claude, accepted the notice)."),
                          CLIOption("private", nil, "Open the sign-in in a private browser window instead."),
                          CLIOption("force", nil, "Replace even when AgentBar cannot verify it is the same account."),
                          CLIOption("add-as-new", nil, "When the browser signed in to another (or unverified) account, add it as a new account.")],
                run: { try await accountReconnect($0) }),
        CLISpec(path: ["account", "cancel"], arguments: [], summary: "Cancel the account sign-in that is running.",
                run: { _ in accountCancel() }),
        CLISpec(path: ["account", "remove"], arguments: ["<account>"],
                summary: "Delete an account and its AgentBar login from this Mac (needs --yes).",
                details: "Removes the account, its credentials, usage cache and saved Claude Code sign-in. Claude Code's own login and\nthe provider account itself are not touched. This cannot be undone; signing in again needs the browser.",
                options: [CLIOption("yes", nil, "Confirm the deletion.")],
                run: { try await accountRemove($0) }),
        CLISpec(path: ["account", "enable"], arguments: ["<account>"],
                summary: "Resume a paused account (Settings' pause icon \"Enable this account\"): its lines show and refresh again.",
                details: "An account is paused when `accounts --json` says \"paused\": true (left from older settings or a service that was off).",
                run: { try accountEnable($0) }),
        CLISpec(path: ["account", "move"], arguments: ["<account>"],
                summary: "Move an account to another position in the account order.",
                options: [CLIOption("to", "ACCOUNT|N", "The account (or position number) whose place it takes.")],
                run: { try accountMove($0) }),
        CLISpec(path: ["account", "rename"], arguments: ["<account>", "<name>"],
                summary: "Name an account (the name lists and menus show; an empty name goes back to the email).",
                run: { try accountRename($0) }),
        CLISpec(path: ["account", "retry-cleanup"], arguments: [], summary: "Retry deletions and clean-ups that could not finish.",
                run: { _ in await retryCleanup() }),

        // MARK: Claude Code
        CLISpec(path: ["claude-code"], arguments: [], summary: "Show which account Claude Code uses, which accounts are ready, and the last switch result.",
                details: "Reads Claude Code's login again first, so a `claude auth login` in a terminal shows. Per account: its state,\nwhy Use is blocked, the last failed sign-in for Claude Code, and the lines its panel row shows. `lastResult` is\nthe last switch (or the recovery of a switch cut short when AgentBar started), kept after the panel drops it.",
                run: { _ in await freshClaudeCode(); return claudeCodeStatus() }),
        CLISpec(path: ["claude-code", "use"], arguments: ["<account>"],
                summary: "Switch Claude Code's default login to this account (open sessions switch within 30 s).",
                details: "Needs the account set up once with `agentbar claude-code setup`. Remote Control disconnects.\nWhen Claude Code is signed in to an account AgentBar does not have, the switch removes that login: pass --yes to allow it.",
                options: [CLIOption("yes", nil, "Allow removing a Claude Code login that AgentBar does not have.")],
                run: { try await claudeCodeUse($0) }),
        CLISpec(path: ["claude-code", "setup"], arguments: ["<account>"],
                summary: "Sign a Claude account in once in the browser so Claude Code can use it (needs --yes; waits up to 5 minutes).",
                details: "A person finishes the sign-in in the browser, signed in to the account's own email; pass --yes once they agreed.",
                options: [CLIOption("yes", nil, "The person agreed to sign in in the browser.")],
                run: { try await claudeCodeSetup($0) }),
        CLISpec(path: ["claude-code", "cancel"], arguments: [], summary: "Cancel a running `claude-code setup` browser sign-in.",
                run: { _ in claudeCodeCancel() }),

        // MARK: Usage limit resets
        CLISpec(path: ["resets"], arguments: ["<account>"], summary: "List an account's usage reset coupons: what each kind resets, how many, expiry.",
                details: "Coupons come only with fresh usage; refresh first if the account's usage is stale.",
                run: { try resets($0) }),
        CLISpec(path: ["resets", "use"], arguments: ["<account>", "[kind]"],
                summary: "Use one usage reset coupon (cannot be undone; needs --yes).",
                details: "[kind] is the number from `agentbar resets <account>` when the account has several kinds (Claude);\nwithout it the coupon the panel offers first is used.",
                options: [CLIOption("yes", nil, "Confirm using the coupon.")],
                run: { try await resetUse($0) }),

        // MARK: Menu bar groups
        CLISpec(path: ["groups"], arguments: [], summary: "List menu bar groups with their style, options and usage lines.",
                details: "--json per group: `inMenuBar` (shown and something to show), `allOff` (every component off: hidden, refresh\npaused); per line `accountPaused`. Warnings (menu bar width, display settings) come last.",
                run: { _ in groupsList() }),
        CLISpec(path: ["group", "add"], arguments: [], summary: "Add a menu bar group.",
                options: [CLIOption("name", "NAME", "Group name (default: Group N)."),
                          CLIOption("style", "STYLE", "bars, ring, capsule or text (default: bars).")],
                run: { try groupAdd($0) }),
        CLISpec(path: ["group", "set"], arguments: ["<group>"], summary: "Change a group's name, style, visibility, name badge, percentage and list order.",
                details: "Styles: bars (Multi Bar), ring (Ring Gauge, first line only), capsule (Capsule Fill), text (Text Only, any number of lines).\nThe name is also the badge shown in front of the group's usage with --show-name on.\nComponents: the name (--show-name), the percentage (--percent) and the bar (--bar). A Multi Bar group with every\ncomponent off shows only its lines' bars; with no lines it shows nothing, is hidden and not refreshed (`agentbar warnings`).",
                options: [CLIOption("name", "NAME", "New group name (up to 24 characters)."),
                          CLIOption("style", "STYLE", "bars, ring, capsule or text."),
                          CLIOption("show", nil, "Show the group in the menu bar."),
                          CLIOption("hide", nil, "Hide the group (its settings are kept)."),
                          CLIOption("show-name", "on|off", "Show the group name in front of its usage in the menu bar."),
                          CLIOption("percent", "on|off", "Show the percentage (Multi Bar shows the first line's unless `line set --percent`)."),
                          CLIOption("bar", "on|off", "Show the bar (Multi Bar always does)."),
                          CLIOption("sort", "ORDER", "How the group's panel lists its accounts: manual, 5h or weekly (soonest reset first).")],
                run: { try groupSet($0) }),
        CLISpec(path: ["group", "remove"], arguments: ["<group>"], summary: "Delete a menu bar group and its line layout (never its accounts; needs --yes).",
                details: "The group's name, style and lines cannot be brought back. To keep them for later, hide it instead:\n`agentbar group set <group> --hide`.",
                options: [CLIOption("yes", nil, "Confirm deleting the group.")],
                run: { try groupRemove($0) }),
        CLISpec(path: ["group", "move"], arguments: ["<group>"], summary: "Move a group to another position in the menu bar.",
                options: [CLIOption("to", "GROUP|N", "The group (or position number) whose place it takes.")],
                run: { try groupMove($0) }),
        CLISpec(path: ["group", "account", "add"], arguments: ["<group>", "<account>"],
                summary: "Add an account to a group's panel list (a line's account always belongs to its group).",
                run: { try memberAdd($0) }),
        CLISpec(path: ["group", "account", "remove"], arguments: ["<group>", "<account>"],
                summary: "Remove an account and its usage lines from a group.",
                run: { try memberRemove($0) }),
        CLISpec(path: ["group", "account", "move"], arguments: ["<group>", "<account>"],
                summary: "Move an account within a group's list.",
                options: [CLIOption("to", "ACCOUNT", "The account whose place it takes.")],
                run: { try memberMove($0) }),
        CLISpec(path: ["line", "add"], arguments: ["<group>", "<account>"], summary: "Add a usage line (an account's limit) to a group.",
                details: "Limits: 5h, weekly, or a model's weekly limit such as fable (model:fable). Groups other than Text Only hold 3 lines.\n<account> is from `agentbar accounts`; with no accounts yet, add one first (`agentbar account add`).",
                options: [CLIOption("limit", "LIMIT", "5h, weekly or a model name (default: weekly)."),
                          CLIOption("slot", "N", "The empty slot to use (default: the first empty one).")],
                run: { try lineAdd($0) }),
        CLISpec(path: ["line", "set"], arguments: ["<group>", "<slot>"], summary: "Change a usage line's account or limit, or make it the shown percentage.",
                options: [CLIOption("account", "ACCOUNT", "Another account for the line."),
                          CLIOption("limit", "LIMIT", "5h, weekly or a model name."),
                          CLIOption("percent", nil, "Use this line's percentage as the group's large percentage (Multi Bar).")],
                run: { try lineSet($0) }),
        CLISpec(path: ["line", "remove"], arguments: ["<group>", "<slot>"], summary: "Remove a usage line from a group.",
                run: { try lineRemove($0) }),
        CLISpec(path: ["line", "move"], arguments: ["<group>", "<slot>"], summary: "Move a usage line to another slot (swaps with a line already there).",
                options: [CLIOption("to", "SLOT", "The slot to move it to.")],
                run: { try lineMove($0) }),

        // MARK: Settings and app
        CLISpec(path: ["settings"], arguments: [], summary: "Show settings: refresh interval, language, open at login, updates, version, data folder.",
                details: "Also: whether a restart is needed to show the chosen language, whether Open at Login waits for approval in\nSystem Settings (`agentbar open login-items`), the Claude sign-in notice, the last update check, and whether\nthe original groups can be restored (`agentbar settings restore-groups`).",
                run: { _ in settingsShow() }),
        CLISpec(path: ["settings", "restore-groups"], arguments: [],
                summary: "Restore the original menu bar groups from before the layout change (needs --yes).",
                details: "Settings › General › Recovery. Only when `settings --json` says hasOriginalGroups. Restores the original groups,\naccount order, selected limits and display options; the current layout is saved as a backup file first.",
                options: [CLIOption("yes", nil, "Confirm replacing the current layout.")],
                run: { try restoreGroups($0) }),
        CLISpec(path: ["warnings"], arguments: [], summary: "Show the errors and warnings AgentBar shows on screen now (banners, panel notes).",
                details: "Kinds: error (dismissable), storage-unavailable (accounts file unreadable: every change is blocked), display,\nmenu-bar-width, group-all-off, account-paused, claude-code, open-at-login-approval, restart-needed, cleanup-pending.",
                run: { _ in warningsList() }),
        CLISpec(path: ["warnings", "dismiss"], arguments: [], summary: "Dismiss the error banner (as its close button in Settings does).",
                run: { _ in warningsDismiss() }),
        CLISpec(path: ["settings", "set"], arguments: ["<key>", "<value>"],
                summary: "Change a setting: refresh-interval 60|120|300|600, language en|ko, open-at-login on|off.",
                details: "A new language applies after `agentbar restart`.",
                run: { try settingsSet($0) }),
        CLISpec(path: ["update"], arguments: [], summary: "Check whether a newer AgentBar exists (no window) and print the answer.",
                details: "Asks the update feed quietly and waits up to 60 s. Installing is a person's click: --show opens Sparkle's\nwindow (Settings' Check for Updates…), where they press Install. The last answer stays in `agentbar settings\n--json` (update.outcome: available, up-to-date, failed, installing).",
                options: [CLIOption("show", nil, "Open Sparkle's update window on screen instead (for a person to install).")],
                run: { try await updateCheck($0) }),
        CLISpec(path: ["restart"], arguments: [], summary: "Restart AgentBar (to apply a new language).", run: { _ in try restartApp() }),
        CLISpec(path: ["open"], arguments: ["[accounts|menu-bar|general|login-items]"],
                summary: "Open the Settings window on a tab, or login-items: System Settings › Login Items (for a person).",
                details: "login-items is where a person allows Open at Login when `settings` says it waits for approval.",
                options: [CLIOption("group", "GROUP", "Select this group in the Menu Bar tab.")],
                run: { try openSettings($0) }),
        CLISpec(path: ["quit"], arguments: [], summary: "Quit AgentBar.", run: { _ in quitApp() }),

        // MARK: In the command itself
        CLISpec(path: ["version"], arguments: [], summary: "Show this command's AgentBar version.", local: { _ in version() }),
        CLISpec(path: ["paths"], arguments: [], summary: "Show AgentBar's data folder, logs and command socket.", local: { _ in paths() }),
        CLISpec(path: ["install-cli"], arguments: [], summary: "Link `agentbar` into a folder on PATH (default ~/.local/bin).",
                options: [CLIOption("dir", "DIR", "The folder for the link.")], local: { try installCLI($0) }),
    ]

    // MARK: - Helpers

    @MainActor static var store: UsageStore { AppContainer.shared.store }

    private static func date(_ value: Date?) -> Any { value.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull() }
    // A JSON value, or null.
    private static func json<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
    private static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    // Waits on the main actor until `condition` holds, the time runs out, or the command was interrupted.
    @MainActor
    private static func wait(_ invocation: CLIInvocation, seconds: TimeInterval, every: (() -> Void)? = nil,
                             until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline || !invocation.isOpen() { return false }
            every?()
            try? await Task.sleep(for: .milliseconds(150))
        }
        return true
    }

    @MainActor
    static func account(_ reference: String, among list: [UsageAccount]? = nil) throws -> UsageAccount {
        let accounts = list ?? store.orderedAccounts
        let ref = reference.trimmingCharacters(in: .whitespaces)
        if let number = Int(ref), ref.count < 4 {
            guard accounts.indices.contains(number - 1) else { throw CLIError("No account number \(number). Run `agentbar accounts`.") }
            return accounts[number - 1]
        }
        if let exact = accounts.first(where: { $0.id.uuidString.caseInsensitiveCompare(ref) == .orderedSame }) { return exact }
        if let provider = ProviderKind(rawValue: ref.lowercased()) {
            let matching = accounts.filter { $0.provider == provider }
            if matching.count == 1 { return matching[0] }
            throw CLIError(matching.isEmpty ? "No \(provider.displayName) account." : "Several \(provider.displayName) accounts: name one by number or email (`agentbar accounts`).")
        }
        var matching = accounts.filter { $0.identity?.email?.caseInsensitiveCompare(ref) == .orderedSame || $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        if matching.isEmpty, ref.count >= 4 { matching = accounts.filter { $0.id.uuidString.lowercased().hasPrefix(ref.lowercased()) } }
        if matching.isEmpty { matching = accounts.filter { $0.title.lowercased().contains(ref.lowercased()) } }
        if matching.count == 1 { return matching[0] }
        if matching.isEmpty { throw CLIError("No account matches \"\(ref)\". Run `agentbar accounts`.") }
        throw CLIError("\"\(ref)\" matches several accounts: " + matching.map { "\($0.title) (\(short($0.id)))" }.joined(separator: ", "))
    }

    @MainActor
    static func group(_ reference: String) throws -> MenuBarLayout {
        let groups = store.displayConfiguration.effectiveLayouts
        let ref = reference.trimmingCharacters(in: .whitespaces)
        if let number = Int(ref), ref.count < 4 {
            guard groups.indices.contains(number - 1) else { throw CLIError("No group number \(number). Run `agentbar groups`.") }
            return groups[number - 1]
        }
        var matching = groups.filter { $0.id.uuidString.caseInsensitiveCompare(ref) == .orderedSame || $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        if matching.isEmpty, ref.count >= 4 { matching = groups.filter { $0.id.uuidString.lowercased().hasPrefix(ref.lowercased()) } }
        if matching.count == 1 { return matching[0] }
        if matching.isEmpty { throw CLIError("No group matches \"\(ref)\". Run `agentbar groups`.") }
        throw CLIError("\"\(ref)\" matches several groups; use the group's number from `agentbar groups`.")
    }

    // Reads Claude Code's login again, as Settings and a panel do when they open, and waits for the reading: it may have
    // been changed in a terminal. The reading only asks whether a login exists and whose it is (no Keychain window).
    @MainActor
    static func freshClaudeCode() async {
        guard store.claudeCodeEnabled else { return }
        if store.claudeCodeStarting { for _ in 0..<200 where store.claudeCodeStarting { try? await Task.sleep(for: .milliseconds(150)) } }
        store.refreshClaudeCodeState()
        await store.claudeCodeReading?.value
    }

    // What AgentBar shows on screen as a banner, a note under a panel's header or under a group, for `warnings` and the
    // `warnings` key of status, groups and settings.
    @MainActor
    static func warnings() -> [[String: Any]] {
        var list: [[String: Any]] = []
        func add(_ kind: String, _ message: String, _ extra: [String: Any] = [:]) {
            list.append(["kind": kind, "message": message].merging(extra) { $1 })
        }
        if store.storageUnavailable {
            add("storage-unavailable", (store.errorMessage ?? "AgentBar could not read its accounts file.") + " Every change is blocked until AgentBar can read it.")
        } else if let error = store.errorMessage {
            add("error", error, ["dismiss": "agentbar warnings dismiss"])
        }
        if let display = store.displayError { add("display", display) }
        if store.displayWidthWarning { add("menu-bar-width", "These groups use a large portion of the menu bar.") }
        for (index, group) in store.displayConfiguration.effectiveLayouts.enumerated() where !group.showsAnything {
            add("group-all-off", "Group \(index + 1) \(group.name): all components are off. This group is hidden and its refresh is paused. "
                + "Turn one on: `agentbar group set \(index + 1) --percent on` or `--show-name on`, or add a usage line: `agentbar line add \(index + 1) <account>`.",
                ["group": group.id.uuidString])
        }
        let paused = Set(store.displayConfiguration.effectiveLayouts.flatMap(\.rows).map(\.accountID))
            .filter { !store.displayConfiguration.isVisible($0) }
        for account in store.orderedAccounts where paused.contains(account.id) {
            add("account-paused", "\(account.title) is paused: its lines are not shown or refreshed. Resume it with `agentbar account enable \(short(account.id))`.",
                ["account": account.id.uuidString])
        }
        if let notice = store.claudeCodeListNotice { add("claude-code", notice) }
        launchAtLogin.refresh()
        if launchAtLogin.needsApproval {
            add("open-at-login-approval", "Open at Login waits for approval: a person allows AgentBar in System Settings › Login Items (`agentbar open login-items`).")
        }
        if let error = launchAtLogin.errorMessage { add("open-at-login", error) }
        if AppContainer.shared.settings.language != AppLanguage.inUse && AppRelauncher.canRelaunch {
            add("restart-needed", "Restart AgentBar to show it in the chosen language (`agentbar restart`).")
        }
        if !store.registry.cleanupPending.isEmpty || store.accounts.contains(where: \.deletionPending) {
            add("cleanup-pending", "Some deletions or clean-ups have not finished. Retry with `agentbar account retry-cleanup`.")
        }
        return list
    }

    // When the accounts file cannot be read, "no accounts" would be wrong and every change is refused: say why instead.
    @MainActor
    static func requireStorage() throws {
        guard store.storageUnavailable else { return }
        let reason = (store.errorMessage ?? "unknown error").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        throw CLIError("AgentBar cannot read its accounts file: \(reason). Accounts are not shown and every change "
                       + "is blocked until it can (see `agentbar paths` for the file).")
    }

    @MainActor
    private static func withWarnings(_ result: CLIResult) -> CLIResult {
        let list = warnings()
        var result = result
        if var json = result.json as? [String: Any] { json["warnings"] = list; result.json = json }
        if !list.isEmpty { result.text += "\nWarnings:\n" + list.map { "  ! " + ($0["message"] as? String ?? "") }.joined(separator: "\n") }
        return result
    }

    @MainActor
    static func warningsList() -> CLIResult {
        let list = warnings()
        let text = list.isEmpty ? "No warnings." : list.map { "[\($0["kind"]!)] \($0["message"]!)" }.joined(separator: "\n")
        return CLIResult(text, json: ["warnings": list])
    }

    @MainActor
    static func warningsDismiss() -> CLIResult {
        guard !store.storageUnavailable, store.errorMessage != nil else {
            return CLIResult(store.storageUnavailable ? "The accounts file cannot be read; that error stays." : "No error to dismiss.", json: ["dismissed": false])
        }
        store.errorMessage = nil
        return CLIResult("Dismissed the error.", json: ["dismissed": true])
    }

    // MARK: - Usage

    @MainActor
    static func state(_ account: UsageAccount) -> String {
        let snapshot = store.snapshot(for: account)
        if snapshot.requiresLogin { return "sign-in required" }
        if !store.refreshAccountIDs.contains(account.id) { return "not in menu bar (not refreshed)" }
        if store.refreshingAccounts.contains(account.id) && snapshot.isStale { return "refreshing" }
        if snapshot.isStale && snapshot.note == ProviderSnapshot.notLoadedNote { return "loading" }
        return snapshot.isStale ? "stale" : "ok"
    }

    @MainActor
    static func claudeCodeState(_ account: UsageAccount) -> String? {
        switch store.claudeCodeSetup(for: account).status {
        case .hidden: return nil
        case .inClaudeCode: return "in Claude Code"
        case .ready: return "ready for Claude Code"
        case .notSetUp: return "not set up for Claude Code"
        case .signingIn: return "signing in for Claude Code"
        }
    }

    // Why the panel's Use is greyed out for the account, or why it cannot be set up; nil when nothing stands in the way.
    @MainActor
    static func claudeCodeBlocked(_ account: UsageAccount) -> String? {
        if case .use(false, let help) = store.claudeCodePanel(for: account).control { return help }
        if case .notSetUp(let blocked?) = store.claudeCodeSetup(for: account).status { return blocked }
        return nil
    }

    @MainActor
    static func limitID(_ id: String) -> String { id.hasPrefix("model:") ? String(id.dropFirst(6)) : id }

    @MainActor
    static func accountJSON(_ account: UsageAccount, detail: Bool) -> [String: Any] {
        let snapshot = store.snapshot(for: account)
        let number = (store.orderedAccounts.firstIndex { $0.id == account.id } ?? -1) + 1
        var value: [String: Any] = [
            "number": number, "id": account.id.uuidString, "provider": account.provider.rawValue, "name": account.name,
            "email": account.identity?.email ?? NSNull(), "organization": account.identity?.organization ?? NSNull(),
            "state": state(account), "inMenuBar": store.refreshAccountIDs.contains(account.id),
            "claudeCode": claudeCodeState(account) ?? NSNull(),
            "paused": !store.displayConfiguration.isVisible(account.id),
            "claudeCodeLock": json(store.claudeCodeLockNote(for: account)),
            "claudeCodeBlocked": json(claudeCodeBlocked(account)),
            "claudeCodeSetupFailure": json(store.claudeCodeSetupFailures[account.id]),
        ]
        guard detail else { return value }
        value["plan"] = snapshot.planName ?? NSNull()
        value["note"] = snapshot.isStale ? (snapshot.note ?? NSNull()) : NSNull()
        value["updatedAt"] = snapshot.note == ProviderSnapshot.notLoadedNote ? NSNull() : date(snapshot.updatedAt)
        value["retryAt"] = date(store.providerRetryDate(for: account.id) ?? snapshot.retryAt)
        value["limits"] = DisplayMetric.all(snapshot).map { metric -> [String: Any] in
            ["id": limitID(metric.id), "title": metric.title,
             "usedPercent": metric.window?.utilization.map { ($0 * 1000).rounded() / 10 } ?? NSNull(),
             "resetsAt": date(metric.window?.resetAt)]
        }
        value["coupons"] = snapshot.resetCoupons.map(couponsJSON) ?? NSNull()
        value["credits"] = snapshot.credits.map(creditsJSON) ?? NSNull()
        return value
    }

    private static func scopeID(_ scope: UsageResetCoupons.Scope) -> String {
        switch scope {
        case .fiveHourAndWeekly: "5h+weekly"
        case .fiveHour: "5h"
        case .weekly: "weekly"
        case .fableWeekly: "fable"
        case .fiveHourAndFableWeekly: "5h+fable"
        }
    }

    // The kinds of coupon an account has, numbered as `resets use` takes them.
    static func couponKinds(_ coupons: UsageResetCoupons) -> [UsageResetCoupons.Option] {
        coupons.options ?? [coupons.selectedOption]
    }

    @MainActor
    static func couponsJSON(_ coupons: UsageResetCoupons) -> [String: Any] {
        ["total": coupons.totalCount ?? coupons.count, "summary": CouponWords.summary(coupons),
         "kinds": couponKinds(coupons).enumerated().map { index, option -> [String: Any] in
             ["kind": index + 1, "resets": scopeID(option.scope), "title": CouponWords.selectionTitle(option), "count": option.count,
              "expiries": option.expiries.map { date($0) }, "usable": option.canRedeem,
              "blockedBecause": option.canRedeem ? NSNull() : CouponWords.unavailable(option.blockReason),
              "affectedUsedPercent": json(option.affectedUsagePercent)]
         }]
    }

    @MainActor
    static func creditsJSON(_ credits: AccountCredits) -> [String: Any] {
        ["summary": CreditWords.summary(credits),
         "items": credits.items.map { item -> [String: Any] in
             ["kind": item.kind.rawValue, "text": CreditWords.item(item), "title": json(item.title), "used": json(item.used),
              "limit": json(item.limit), "balance": json(item.balance), "currency": json(item.currency),
              "endsAt": date(item.endsAt), "enabled": json(item.enabled), "unlimited": item.unlimited]
         }]
    }

    @MainActor
    static func accountText(_ account: UsageAccount) -> String {
        let snapshot = store.snapshot(for: account)
        let number = (store.orderedAccounts.firstIndex { $0.id == account.id } ?? -1) + 1
        var head = "\(number). \(account.provider.shortName) \(account.title)"
        if let email = account.identity?.email, email != account.title { head += " <\(email)>" }
        if let org = account.identity?.organization, !org.isEmpty { head += " · \(org)" }
        if let plan = snapshot.planName { head += " · \(plan)" }
        var status = state(account)
        if status != "loading" && snapshot.note != ProviderSnapshot.placeholder(for: account.provider).note {
            status += ", updated \(TokenFormatters.relativeUpdateString(updatedAt: snapshot.updatedAt))"
        }
        if snapshot.isStale, let note = snapshot.note, status.hasPrefix("stale") { status += " (\(note))" }
        if let retry = store.providerRetryDate(for: account.id) {
            status += "; \(account.provider.displayName) asked to wait, next read after \(TokenFormatters.relativeUpdateString(updatedAt: retry))"
        }
        var lines = [head + "  [\(status)]"]
        for metric in DisplayMetric.all(snapshot) {
            let percent = TokenFormatters.percentageString(for: metric.window?.utilization)
            let reset = metric.window?.utilization == nil ? "" : TokenFormatters.resetLabelString(resetAt: metric.window?.resetAt)
            lines.append("   " + limitID(metric.id).padding(toLength: 8, withPad: " ", startingAt: 0) + percent.padding(toLength: 6, withPad: " ", startingAt: 0) + reset)
        }
        if let coupons = snapshot.resetCoupons { lines.append("   coupons \(CouponWords.summary(coupons))") }
        if let credits = snapshot.credits, !credits.isEmpty { lines.append("   credits \(CreditWords.summary(credits))") }
        if let claudeCode = claudeCodeState(account) { lines.append("   \(claudeCode)") }
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func status(_ invocation: CLIInvocation) throws -> CLIResult {
        let accounts = try invocation.positional(0).map { [try account($0)] } ?? store.orderedAccounts
        try requireStorage()
        if accounts.isEmpty { return withWarnings(CLIResult("No accounts. Add one with `agentbar account add claude` or `agentbar account add codex`.", json: ["accounts": []])) }
        var text = accounts.map(accountText).joined(separator: "\n")
        if store.isRefreshing { text += "\n(refresh in progress)" }
        return withWarnings(CLIResult(text, json: ["accounts": accounts.map { accountJSON($0, detail: true) },
                                                   "refreshing": store.isRefreshing, "lastRefresh": date(store.lastRefresh)]))
    }

    @MainActor
    static func refresh(_ invocation: CLIInvocation) async throws -> CLIResult {
        if let reference = invocation.positional(0) {
            let target = try account(reference)
            guard store.refreshAccountIDs.contains(target.id) else {
                throw CLIError("\(target.title) is not used by a shown menu bar group, so it is not refreshed. Add a line with `agentbar line add`.")
            }
        }
        if invocation.flag("no-wait") { store.refreshNow(); return CLIResult("Refresh started.") }
        await store.refresh()
        return try status(invocation)
    }

    // MARK: - Accounts

    @MainActor
    static func accountsList() -> CLIResult {
        let accounts = store.orderedAccounts
        let text = accounts.isEmpty ? "No accounts." : accounts.map { account in
            var line = "\(store.orderedAccounts.firstIndex { $0.id == account.id }! + 1). \(account.provider.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(account.title)"
            if let org = account.identity?.organization, !org.isEmpty { line += " · \(org)" }
            line += "  [\(state(account))]"
            if let claudeCode = claudeCodeState(account) { line += " [\(claudeCode)]" }
            if let lock = store.claudeCodeLockNote(for: account) { line += " [\(lock)]" }
            if !store.displayConfiguration.isVisible(account.id) { line += " [paused: `agentbar account enable`]" }
            if let failure = store.claudeCodeSetupFailures[account.id] { line += " [last Claude Code sign-in failed: \(failure)]" }
            return line + "  id \(short(account.id))"
        }.joined(separator: "\n")
        var json: [String: Any] = ["accounts": accounts.map { accountJSON($0, detail: false) }]
        if !store.registry.cleanupPending.isEmpty || store.accounts.contains(where: \.deletionPending) { json["cleanupPending"] = true }
        return CLIResult(text, json: json)
    }

    static let claudeNotice = "How AgentBar reads Claude usage: AgentBar signs in through Claude Code and keeps that sign-in to read this "
        + "account's usage. Anthropic's terms limit apps that keep Claude sign-ins, so Anthropic could block these reads at any time."

    // What Settings asks before it opens a browser sign-in: a person has to do the sign-in, and the first Claude one shows
    // the notice that has to be accepted (Continue). Without --yes the command stops here and says what the person agrees to.
    @MainActor
    private static func requireSignInConsent(_ invocation: CLIInvocation, provider: ProviderKind) throws {
        let settings = AppContainer.shared.settings
        let needsNotice = provider == .claude && !settings.claudeAccessNoticeAccepted
        guard invocation.flag("yes") else {
            var text = "This opens the \(provider.displayName) sign-in in the browser; a person has to finish it there."
            if needsNotice { text += "\nThe person must first accept this notice (Settings shows it once, with Cancel and Continue):\n" + claudeNotice }
            text += "\nNothing was opened. Ask the person, then run again with --yes."
            throw CLIError(text, code: 2)
        }
        if needsNotice { settings.claudeAccessNoticeAccepted = true; invocation.emit("Notice accepted: " + claudeNotice) }
    }

    // Runs a browser sign-in to its review and returns it, telling the person what to do meanwhile.
    @MainActor
    private static func signIn(_ invocation: CLIInvocation, provider: ProviderKind, replacing: UsageAccount?) async throws -> PendingAccountLogin? {
        if let replacing, let note = store.claudeCodeLockNote(for: replacing) { throw CLIError("\(replacing.title): \(note). Try again after it finishes.") }
        if store.storageUnavailable { throw CLIError((store.errorMessage ?? "AgentBar cannot read its accounts file.") + " Sign-ins are blocked.") }
        guard !store.isLoggingIn, store.pendingLogin == nil else {
            throw CLIError("Another account sign-in is running. Finish it, or run `agentbar account cancel`.")
        }
        if provider != .antigravity { try requireSignInConsent(invocation, provider: provider) }
        store.errorMessage = nil
        store.startLogin(provider, replacing: replacing)
        guard store.isLoggingIn else { throw CLIError(store.errorMessage ?? "Could not start the sign-in.") }
        var said: String?
        var openedPrivate = false
        let finished = await wait(invocation, seconds: 330, every: {
            if let message = store.loginMessage, message != said { said = message; invocation.emit(message) }
            if invocation.flag("private"), !openedPrivate, store.canOpenPrivateLogin { openedPrivate = true; store.openPrivateLogin() }
        }, until: { store.pendingLogin != nil || !store.isLoggingIn })
        if !finished { store.cancelLogin(); throw CLIError("Sign-in cancelled.") }
        if let pending = store.pendingLogin { return pending }
        // A reconnect proven to be the same account registers without review.
        if replacing != nil, store.errorMessage == nil { return nil }
        throw CLIError(store.errorMessage ?? "The sign-in was cancelled or timed out.")
    }

    @MainActor
    static func accountAdd(_ invocation: CLIInvocation) async throws -> CLIResult {
        guard let provider = ProviderKind(rawValue: invocation.positional(0)!.lowercased()) else {
            throw CLIError("Unknown provider \(invocation.positional(0)!). Use claude, codex or antigravity.", code: 2)
        }
        guard let pending = try await signIn(invocation, provider: provider, replacing: nil) else { throw CLIError("The sign-in did not finish.") }
        store.confirmLogin()
        if store.pendingLogin != nil {
            let reason = store.errorMessage ?? "The account could not be registered."
            store.cancelLogin()
            throw CLIError(reason)
        }
        guard let added = store.accounts.first(where: { $0.id == pending.account.id }) else { throw CLIError(store.errorMessage ?? "The account could not be registered.") }
        let who = [added.identity?.email, added.identity?.visibleOrganization].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return CLIResult("Added \(added.provider.displayName) account \(added.title) (id \(short(added.id)))\(who.isEmpty || who == added.title ? "" : ", signed in as \(who)"). "
                         + "It has its own menu bar group. Not the right account? `agentbar account remove \(short(added.id)) --yes`.",
                         json: ["added": accountJSON(added, detail: false)])
    }

    @MainActor
    static func accountReconnect(_ invocation: CLIInvocation) async throws -> CLIResult {
        let target = try account(invocation.positional(0)!)
        guard let pending = try await signIn(invocation, provider: target.provider, replacing: target) else {
            let updated = store.accounts.first { $0.id == target.id } ?? target
            return CLIResult("Reconnected \(updated.title).", json: ["reconnected": accountJSON(updated, detail: false)])
        }
        // Codex reports no account ID: the same email (and workspace) is as close to "the same account" as it gets.
        let sameEmail = UsageStore.sameLogin(pending.account.identity, target.identity)
        let force = invocation.flag("force") || sameEmail
        if invocation.flag("add-as-new"), store.reconnectionComparison != .same, !sameEmail {
            // Settings' Add Account button beside a different or unverified sign-in.
            store.confirmLogin(addAsNew: true)
            if store.pendingLogin != nil {
                let reason = store.errorMessage ?? "The account could not be added."
                store.cancelLogin()
                throw CLIError(reason)
            }
            guard let added = store.accounts.first(where: { $0.id == pending.account.id }) else { throw CLIError(store.errorMessage ?? "The account could not be added.") }
            return CLIResult("The browser signed in as \(added.identity?.email ?? added.title), not \(target.title): added it as a new account (id \(short(added.id))). \(target.title) is unchanged.",
                             json: ["added": accountJSON(added, detail: false), "reconnected": NSNull()])
        }
        switch store.reconnectionComparison {
        case .different:
            let email = store.pendingLogin?.account.identity?.email ?? "another account"
            store.cancelLogin()
            throw CLIError("The browser signed in as \(email), not \(target.title). Nothing changed. Run again with --add-as-new to add \(email) as a new account.")
        case .unverified where !force, nil where !force:
            let email = store.pendingLogin?.account.identity?.email ?? "an account"
            store.cancelLogin()
            throw CLIError("AgentBar cannot verify that \(email) is \(target.title). Nothing changed. Run again with --force to reconnect anyway, or --add-as-new to add it as a new account.")
        default: break
        }
        store.confirmLogin(replaceUnverified: force)
        if store.pendingLogin != nil {
            let reason = store.errorMessage ?? "The account could not be reconnected."
            store.cancelLogin()
            throw CLIError(reason)
        }
        let updated = store.accounts.first { $0.id == target.id } ?? target
        return CLIResult("Reconnected \(updated.title).", json: ["reconnected": accountJSON(updated, detail: false)])
    }

    @MainActor
    static func accountCancel() -> CLIResult {
        guard store.isLoggingIn || store.pendingLogin != nil else { return CLIResult("No account sign-in is running.", json: ["cancelled": false]) }
        store.cancelLogin()
        return CLIResult("Sign-in cancelled.", json: ["cancelled": true])
    }

    @MainActor
    static func accountRemove(_ invocation: CLIInvocation) async throws -> CLIResult {
        let target = try account(invocation.positional(0)!)
        guard invocation.flag("yes") else {
            throw CLIError("This deletes \(target.title) and its AgentBar login from this Mac. Run again with --yes to confirm.", code: 2)
        }
        if let note = store.claudeCodeLockNote(for: target) { throw CLIError("\(target.title): \(note). Delete it after that finishes.") }
        store.errorMessage = nil
        await store.delete(target)
        if let left = store.accounts.first(where: { $0.id == target.id }) {
            if left.deletionPending, store.errorMessage == nil {
                return CLIResult("Removed \(target.title). Its saved Claude Code sign-in is removed when the running Claude Code switch ends.",
                                 json: ["removed": target.id.uuidString, "pending": true])
            }
            throw CLIError(store.errorMessage ?? "\(target.title) could not be removed. Retry with `agentbar account retry-cleanup`.")
        }
        return CLIResult("Removed \(target.title).", json: ["removed": target.id.uuidString])
    }

    @MainActor
    static func accountEnable(_ invocation: CLIInvocation) throws -> CLIResult {
        let target = try account(invocation.positional(0)!)
        guard !store.displayConfiguration.isVisible(target.id) else {
            return CLIResult("\(target.title) is not paused.", json: ["account": accountJSON(target, detail: false), "changed": false])
        }
        let before = store.displayConfiguration
        store.updateDisplay { $0.setVisible(target.id, true) }
        try requireDisplayChange(before, "resume the account")
        return CLIResult("\(target.title) is enabled again: its lines show and refresh.", json: ["account": accountJSON(target, detail: false), "changed": true])
    }

    @MainActor
    static func accountMove(_ invocation: CLIInvocation) throws -> CLIResult {
        let source = try account(invocation.positional(0)!)
        guard let to = invocation.value("to") else { throw CLIError("Say where with --to ACCOUNT|N.", code: 2) }
        let target = try account(to)
        if source.id != target.id { store.moveAccount(source.id, to: target.id) }
        return accountsList()
    }

    @MainActor
    static func accountRename(_ invocation: CLIInvocation) throws -> CLIResult {
        let target = try account(invocation.positional(0)!)
        let name = invocation.positional(1)!.trimmingCharacters(in: .whitespacesAndNewlines)
        store.rename(target, name: name.isEmpty ? (target.identity?.email ?? target.provider.displayName) : name)
        let updated = store.accounts.first { $0.id == target.id } ?? target
        return CLIResult("Named \(updated.identity?.email ?? short(updated.id)) \"\(updated.name)\".", json: ["account": accountJSON(updated, detail: false)])
    }

    @MainActor
    static func retryCleanup() async -> CLIResult {
        store.errorMessage = nil
        await store.retryCleanup()
        if let error = store.errorMessage { return CLIResult("Clean-up still pending: \(error)", json: ["done": false, "error": error]) }
        return CLIResult("Clean-up done.", json: ["done": true])
    }

    // MARK: - Claude Code

    @MainActor
    static func claudeCodeStatus() -> CLIResult {
        guard store.claudeCodeEnabled else {
            return CLIResult("Use in Claude Code is off in this AgentBar (a development run with its own data folder).", json: ["available": "off"])
        }
        let availability: String
        switch store.claudeCodeAvailability {
        case .unknown: availability = "checking"
        case .missing: availability = "Claude Code is not installed"
        case .blocked(let reason): availability = reason
        case .ready: availability = "ready"
        }
        let current = store.accounts.first { $0.id == store.claudeCodeAccountID }
        let claude = store.orderedAccounts.filter { $0.provider == .claude }
        var lines = ["Claude Code: \(availability)", "Uses: " + (current?.title ?? "no account AgentBar has")]
        if let activity = store.claudeCodeActivity { lines.append("Switching: \(activity.message)") }
        let last = store.claudeCodeLastResult
        let lastJSON: Any = last.map { result -> [String: Any] in
            ["account": result.accountID.uuidString, "name": json(store.accounts.first { $0.id == result.accountID }?.title),
             "succeeded": result.succeeded, "message": result.message, "at": date(result.at)]
        } ?? NSNull()
        if let last {
            lines.append("Last switch: \(last.succeeded ? "done" : "failed"), \(TokenFormatters.relativeUpdateString(updatedAt: last.at)): \(last.message)"
                         + (last.succeeded ? "" : " Log: \(store.claudeCodeLogURL.path)"))
        }
        func rowLines(_ account: UsageAccount) -> [String] {
            store.claudeCodeListRow(for: account).lines.map { line in
                switch line {
                case .progress(let text), .notice(let text): return text
                case .confirmation(let email): return ClaudeCodePanel.confirmationText(email: email)
                case .result(_, let message): return message
                }
            }
        }
        for account in claude {
            var line = "  \(account.title): \(claudeCodeState(account) ?? "-")"
            if let blocked = claudeCodeBlocked(account) { line += " (blocked: \(blocked))" }
            if let failure = store.claudeCodeSetupFailures[account.id] { line += " (last sign-in for Claude Code failed: \(failure))" }
            lines.append(line)
        }
        if let notice = store.claudeCodeListNotice { lines.append("Note: \(notice)") }
        return CLIResult(lines.joined(separator: "\n"), json: [
            "available": availability, "account": current.map { accountJSON($0, detail: false) } ?? NSNull(),
            "switching": store.claudeCodeActivity != nil, "switchMessage": json(store.claudeCodeActivity?.message),
            "lastResult": lastJSON, "notice": json(store.claudeCodeListNotice), "log": store.claudeCodeLogURL.path,
            "accounts": claude.map { account -> [String: Any] in
                ["id": account.id.uuidString, "email": json(account.identity?.email), "state": json(claudeCodeState(account)),
                 "blocked": json(claudeCodeBlocked(account)), "setupFailure": json(store.claudeCodeSetupFailures[account.id]),
                 "lock": json(store.claudeCodeLockNote(for: account)), "panelLines": rowLines(account)]
            },
        ])
    }

    @MainActor
    static func claudeCodeUse(_ invocation: CLIInvocation) async throws -> CLIResult {
        let target = try account(invocation.positional(0)!)
        guard target.provider == .claude else { throw CLIError("\(target.title) is not a Claude account.") }
        guard store.claudeCodeEnabled else { throw CLIError("Use in Claude Code is off in this AgentBar (a development run with its own data folder).") }
        if store.claudeCodeStarting || store.claudeCodeAvailability == .unknown {
            _ = await wait(invocation, seconds: 30, until: { !store.claudeCodeStarting && store.claudeCodeAvailability != .unknown })
        }
        switch store.claudeCodePanel(for: target).control {
        case .hidden: throw CLIError(store.claudeCodeEnabled ? "Claude Code is not installed." : "Use in Claude Code is off in this AgentBar.")
        case .inClaudeCode: return CLIResult("Claude Code already uses \(target.title).", json: ["switched": false, "account": target.id.uuidString])
        case .setUp: throw CLIError("\(target.title) is not set up for Claude Code yet. Run `agentbar claude-code setup \(target.identity?.email ?? short(target.id))` first.")
        case .use(let enabled, let help): if !enabled { throw CLIError(help) }
        }
        store.useInClaudeCode(target)
        var said: String?
        let progress = {
            if let message = store.claudeCodeActivity?.message, message != said { said = message; invocation.emit(message) }
        }
        _ = await wait(invocation, seconds: 300, every: progress, until: { store.claudeCodeActivity == nil })
        if let confirmation = store.claudeCodeConfirmation, confirmation.accountID == target.id {
            guard invocation.flag("yes") else {
                store.cancelClaudeCodeConfirmation()
                throw CLIError(ClaudeCodePanel.confirmationText(email: confirmation.login.email) + " Nothing changed. Run again with --yes to switch.")
            }
            store.confirmClaudeCodeSwitch()
            _ = await wait(invocation, seconds: 300, every: progress, until: { store.claudeCodeActivity == nil })
        }
        if let result = store.claudeCodeResults[target.id] {
            guard result.succeeded else { throw CLIError(result.message + " Log: \(store.claudeCodeLogURL.path)") }
            return CLIResult(result.message, json: ["switched": true, "account": target.id.uuidString, "message": result.message])
        }
        if store.claudeCodeAccountID == target.id {
            return CLIResult("Claude Code already uses \(target.title).", json: ["switched": false, "account": target.id.uuidString])
        }
        throw CLIError("The switch did not finish. Log: \(store.claudeCodeLogURL.path)")
    }

    @MainActor
    static func claudeCodeSetup(_ invocation: CLIInvocation) async throws -> CLIResult {
        let target = try account(invocation.positional(0)!)
        guard target.provider == .claude else { throw CLIError("\(target.title) is not a Claude account.") }
        guard store.claudeCodeEnabled else { throw CLIError("Use in Claude Code is off in this AgentBar (a development run with its own data folder).") }
        if store.claudeCodeStarting || store.claudeCodeAvailability == .unknown {
            _ = await wait(invocation, seconds: 30, until: { !store.claudeCodeStarting && store.claudeCodeAvailability != .unknown })
        }
        switch store.claudeCodeSetup(for: target).status {
        case .hidden: throw CLIError(store.claudeCodeEnabled ? "Claude Code is not installed." : "Use in Claude Code is off in this AgentBar.")
        case .inClaudeCode: return CLIResult("Claude Code already uses \(target.title).", json: ["ready": true])
        case .ready: return CLIResult("\(target.title) is already ready for Claude Code.", json: ["ready": true])
        case .signingIn: throw CLIError("\(target.title) is already signing in for Claude Code.")
        case .notSetUp(let blocked): if let blocked { throw CLIError(blocked) }
        }
        guard invocation.flag("yes") else {
            throw CLIError("This opens the Claude sign-in in the browser; a person has to finish it there, signed in as \(target.identity?.email ?? target.title). "
                           + "Nothing was opened. Ask the person, then run again with --yes.", code: 2)
        }
        store.prepareForClaudeCode(target)
        guard store.claudeCodePreparation?.accountID == target.id else { throw CLIError("The sign-in could not start.") }
        var said: String?
        let finished = await wait(invocation, seconds: 330, every: {
            if let message = store.claudeCodePreparation?.message, message != said { said = message; invocation.emit(message) }
        }, until: { store.claudeCodePreparation == nil })
        if !finished { store.cancelClaudeCodePreparation(); throw CLIError("Sign-in cancelled.") }
        if store.claudeCodeReady.contains(target.id) || store.claudeCodeAccountID == target.id {
            return CLIResult("\(target.title) is ready for Claude Code. Switch with `agentbar claude-code use`.", json: ["ready": true])
        }
        throw CLIError(store.claudeCodeSetupFailures[target.id].map { "\($0) Log: \(store.claudeCodeLogURL.path)" } ?? "The sign-in was cancelled.")
    }

    @MainActor
    static func claudeCodeCancel() -> CLIResult {
        guard store.claudeCodePreparation?.canCancel == true else { return CLIResult("No cancellable Claude Code sign-in is running.", json: ["cancelled": false]) }
        store.cancelClaudeCodePreparation()
        return CLIResult("Cancelling the Claude Code sign-in.", json: ["cancelled": true])
    }

    // MARK: - Usage limit resets

    @MainActor
    static func resets(_ invocation: CLIInvocation) throws -> CLIResult {
        let target = try account(invocation.positional(0)!)
        let snapshot = store.snapshot(for: target)
        let panel = store.couponPanel(for: target)
        guard let coupons = panel.coupons ?? snapshot.resetCoupons else {
            let why = snapshot.isStale || snapshot.requiresLogin ? " (coupons come with fresh usage; usage is \(state(target)))" : ""
            return CLIResult("\(target.title): no usage reset coupons\(why).", json: ["account": target.id.uuidString, "coupons": NSNull()])
        }
        var lines = ["\(target.title): \(CouponWords.summary(coupons))"]
        if panel.coupons == nil { lines.append("  (usage is \(state(target)); refresh before using one)") }
        for (index, option) in couponKinds(coupons).enumerated() {
            var line = "  \(index + 1). \(CouponWords.selectionTitle(option))  resets \(scopeID(option.scope))"
            if let detail = CouponWords.selectionDetail(option) { line += "  · \(detail)" }
            if let used = option.affectedUsagePercent { line += "  · \(used)% used now" }
            line += option.canRedeem ? "  [usable]" : "  [not usable]"
            lines.append(line)
        }
        if case .result(let outcome, let left, let scope) = panel.line {
            lines.append("Last use: " + CouponWords.message(outcome, left: left, scope: scope ?? coupons.scope))
        }
        return CLIResult(lines.joined(separator: "\n"), json: ["account": target.id.uuidString, "coupons": couponsJSON(coupons)])
    }

    @MainActor
    static func resetUse(_ invocation: CLIInvocation) async throws -> CLIResult {
        let target = try account(invocation.positional(0)!)
        guard let coupons = store.couponPanel(for: target).coupons else {
            throw CLIError("\(target.title) has no coupon to use now (they come with fresh usage: try `agentbar refresh`).")
        }
        let kinds = couponKinds(coupons)
        var option = coupons.selectedOption
        if let text = invocation.positional(1) {
            guard let number = Int(text), kinds.indices.contains(number - 1) else {
                throw CLIError("No coupon kind \(text). Run `agentbar resets \(invocation.positional(0)!)`.", code: 2)
            }
            option = kinds[number - 1]
        } else if !option.canRedeem, let usable = kinds.first(where: \.canRedeem) {
            option = usable
        }
        guard option.canRedeem else { throw CLIError("This coupon cannot be used now: \(CouponWords.unavailable(option.blockReason)).") }
        guard invocation.flag("yes") else {
            throw CLIError(CouponWords.question(option.scope, usedPercent: option.affectedUsagePercent) + " This cannot be undone. Run again with --yes.", code: 2)
        }
        // The panel's own steps: Reset, the kind (when there are several), OK.
        store.cancelCoupon(target)
        store.askToUseCoupon(target)
        if case .choosing = store.couponPanel(for: target).line { store.chooseCoupon(option.claim, for: target) }
        guard case .confirmation = store.couponPanel(for: target).line else { throw CLIError("AgentBar did not offer this coupon. Run `agentbar resets` again.") }
        if case .confirmation(let claim?, _) = store.couponPanel(for: target).line, claim != option.claim {
            store.cancelCoupon(target)
            throw CLIError("Claude offers another coupon first. Run `agentbar resets` to see which.")
        }
        store.confirmCoupon(target)
        invocation.emit(CouponWords.resetting())
        _ = await wait(invocation, seconds: 120, until: {
            if case .progress = store.couponLines[target.id] { return false }
            return true
        })
        guard case .result(let outcome, let left, let scope) = store.couponLines[target.id] else { throw CLIError("No result yet; see `agentbar resets`.") }
        let message = CouponWords.message(outcome, left: left, scope: scope ?? option.scope)
        guard outcome == .reset else { throw CLIError(message) }
        return CLIResult(message, json: ["reset": scopeID(option.scope), "left": json(left), "message": message])
    }

    // MARK: - Menu bar groups

    private static func style(_ name: String) throws -> MenuBarStyle {
        switch name.lowercased() {
        case "bars", "multi-bar", "multibar", "badge": return .bars
        case "ring", "ring-gauge": return .ring
        case "capsule", "capsule-fill": return .capsule
        case "text", "text-only": return .text
        default: throw CLIError("Unknown style \(name). Use bars, ring, capsule or text.", code: 2)
        }
    }

    private static func onOff(_ value: String, _ name: String) throws -> Bool {
        switch value.lowercased() {
        case "on", "true", "yes", "1": return true
        case "off", "false", "no", "0": return false
        default: throw CLIError("--\(name) takes on or off.", code: 2)
        }
    }

    private static func limit(_ value: String) -> String {
        let lower = value.lowercased()
        if ["5h", "weekly"].contains(lower) || lower.hasPrefix("model:") { return lower }
        if lower == "week" { return "weekly" }
        return "model:" + lower
    }

    @MainActor
    static func groupJSON(_ group: MenuBarLayout, number: Int) -> [String: Any] {
        let percentID = group.shownPercentageLineID
        return ["number": number, "id": group.id.uuidString, "name": group.name, "shown": group.enabled, "style": group.style.selection.rawValue,
                "showName": group.effectiveBadgeMode.includesCommon, "percent": group.style == .text ? true : group.showPercent,
                "bar": group.style.selection == .bars ? true : group.showBar, "sort": (group.listSort ?? .manual).rawValue,
                "allOff": !group.showsAnything, "inMenuBar": group.enabled && group.showsAnything,
                "accounts": store.panelAccountIDs(for: group).compactMap { id in store.accounts.first { $0.id == id } }.map { ["id": $0.id.uuidString, "name": $0.name] },
                "lines": slotted(group).map { slot, line -> [String: Any] in
                    let account = store.accounts.first { $0.id == line.accountID }
                    let entry = store.entries(for: group).first { $0.lineID == line.id }
                    return ["slot": slot, "account": line.accountID.uuidString, "name": json(account?.name),
                            "limit": limitID(line.metricID), "usedPercent": entry?.metric.window?.utilization.map { ($0 * 1000).rounded() / 10 } ?? NSNull(),
                            "percentLine": (group.style == .bars || group.style == .text) && line.id == percentID,
                            "accountPaused": !store.displayConfiguration.isVisible(line.accountID),
                            "displayed": group.displayedRows.contains { $0.id == line.id }]
                }]
    }

    // Lines by their 1-based slot.
    static func slotted(_ group: MenuBarLayout) -> [(Int, MenuBarLine)] {
        group.rows.enumerated().map { (($0.element.slot ?? $0.offset) + 1, $0.element) }.sorted { $0.0 < $1.0 }
    }

    // Whether the group is in the menu bar, as `groups` and every command that changes a group say it.
    static func groupState(_ group: MenuBarLayout) -> String {
        group.enabled ? (group.showsAnything ? "shown" : "hidden: all components off, refresh paused") : "hidden"
    }

    @MainActor
    static func groupsList() -> CLIResult {
        let groups = store.displayConfiguration.effectiveLayouts
        let text = groups.isEmpty ? "No menu bar groups. Add one with `agentbar group add`." : groups.enumerated().map { index, group in
            var head = "\(index + 1). \(group.name)  [\(groupState(group))] \(group.style.selection.title)"
            if group.effectiveBadgeMode.includesCommon { head += " · name shown" }
            if group.style != .text && !group.showPercent { head += " · no percentage" }
            if let sort = group.listSort, sort != .manual { head += " · sorted by \(sort == .fiveHourReset ? "5h" : "weekly") reset" }
            let members = store.panelAccountIDs(for: group).compactMap { id in store.accounts.first { $0.id == id }?.title }

            head += "  id \(short(group.id))"
            if !members.isEmpty { head += "\n   accounts: " + members.joined(separator: ", ") }
            let percentID = group.shownPercentageLineID
            let lines = slotted(group).map { slot, line -> String in
                let account = store.accounts.first { $0.id == line.accountID }
                let entry = store.entries(for: group).first { $0.lineID == line.id }
                var text = "   slot \(slot): \(account.map { "\($0.provider.shortName) \($0.title)" } ?? "?") · \(limitID(line.metricID)) "
                    + TokenFormatters.percentageString(for: entry?.metric.window?.utilization)
                if group.style == .bars && line.id == percentID { text += "  (large %)" }
                if !group.displayedRows.contains(where: { $0.id == line.id }) { text += "  (not shown in this style)" }
                if !store.displayConfiguration.isVisible(line.accountID) { text += "  (account paused: `agentbar account enable`)" }
                return text
            }
            return ([head] + (lines.isEmpty ? ["   (no lines)"] : lines)).joined(separator: "\n")
        }.joined(separator: "\n")
        return withWarnings(CLIResult(text, json: ["groups": groups.enumerated().map { groupJSON($1, number: $0 + 1) }]))
    }

    @MainActor
    private static func requireDisplayChange(_ before: DisplayConfiguration, _ what: String) throws {
        if store.displayConfiguration == before {
            try requireStorage()
            throw CLIError(store.displayError ?? "AgentBar did not accept the change: \(what).")
        }
    }

    @MainActor
    static func groupAdd(_ invocation: CLIInvocation) throws -> CLIResult {
        let count = store.displayConfiguration.effectiveLayouts.count
        var group = MenuBarLayout(name: invocation.value("name") ?? "Group \(count + 1)")
        if let name = invocation.value("style") { group.style = try style(name) }
        let before = store.displayConfiguration
        store.updateDisplay { $0.editLayouts { $0.append(group) } }
        try requireDisplayChange(before, "add a group")
        let added = (try? self.group(group.id.uuidString)) ?? group
        return withWarnings(CLIResult("Added group \(count + 1): \(added.name) [\(groupState(added))] (id \(short(group.id))). Add lines with `agentbar line add \(count + 1) <account>`.",
                                      json: ["added": groupJSON(added, number: count + 1)]))
    }

    @MainActor
    static func groupSet(_ invocation: CLIInvocation) throws -> CLIResult {
        let group = try group(invocation.positional(0)!)
        if invocation.flag("show") && invocation.flag("hide") { throw CLIError("Use --show or --hide, not both.", code: 2) }
        let newStyle = try invocation.value("style").map(style)
        if let newStyle, newStyle != .text, group.style == .text, group.rows.count > MenuBarLayout.maximumLines {
            throw CLIError("This Text Only group has \(group.rows.count) lines. Remove lines until three remain to use another style.")
        }
        let showName = try invocation.value("show-name").map { try onOff($0, "show-name") }
        let percent = try invocation.value("percent").map { try onOff($0, "percent") }
        let bar = try invocation.value("bar").map { try onOff($0, "bar") }
        let sort = try invocation.value("sort").map { value -> GroupListSort in
            switch value.lowercased() {
            case "manual": return .manual
            case "5h", "five-hour", "fivehourreset": return .fiveHourReset
            case "weekly", "week", "weeklyreset": return .weeklyReset
            default: throw CLIError("--sort takes manual, 5h or weekly.", code: 2)
            }
        }
        if let name = invocation.value("name"), name.trimmingCharacters(in: .whitespaces).isEmpty { throw CLIError("A group needs a name.", code: 2) }
        let before = store.displayConfiguration
        store.updateDisplay { $0.editLayout(group.id) { value in
            if let name = invocation.value("name") { value.name = String(name.prefix(MenuBarLayout.nameLimit)) }
            if invocation.flag("show") { value.enabled = true }
            if invocation.flag("hide") { value.enabled = false }
            if let newStyle {
                value.style = newStyle
                if newStyle == .bars { value.showBar = true }
                if newStyle == .text { value.showPercent = true }
            }
            if let showName { value.badgeMode = showName ? .common : BadgeDisplayMode.none }
            if let percent { value.showPercentage(of: percent ? value.effectivePercentageLineID : nil) }
            if let bar { value.showBar = bar }
            if let sort { value.listSort = sort }
        } }
        let after = try self.group(group.id.uuidString)
        if store.displayConfiguration == before && after != group { try requireDisplayChange(before, "change the group") }
        let number = store.displayConfiguration.effectiveLayouts.firstIndex { $0.id == group.id }! + 1
        let unchanged = after == group ? " Nothing changed: it already was so." : ""
        return withWarnings(CLIResult("Group \(number): \(after.name) [\(groupState(after))] \(after.style.selection.title).\(unchanged)",
                                      json: ["group": groupJSON(after, number: number)]))
    }

    @MainActor
    static func groupRemove(_ invocation: CLIInvocation) throws -> CLIResult {
        let group = try group(invocation.positional(0)!)
        guard invocation.flag("yes") else {
            throw CLIError("This deletes group \(group.name) and its \(group.rows.count) usage line(s); its accounts remain. It cannot be undone "
                           + "(`agentbar group set \(group.name) --hide` keeps it for later). Run again with --yes to confirm.", code: 2)
        }
        let before = store.displayConfiguration
        store.updateDisplay { $0.editLayouts { $0.removeAll { $0.id == group.id } } }
        try requireDisplayChange(before, "remove the group")
        return CLIResult("Removed group \(group.name). Its accounts are kept.", json: ["removed": group.id.uuidString])
    }

    @MainActor
    static func groupMove(_ invocation: CLIInvocation) throws -> CLIResult {
        let source = try group(invocation.positional(0)!)
        guard let to = invocation.value("to") else { throw CLIError("Say where with --to GROUP|N.", code: 2) }
        let target = try group(to)
        if source.id != target.id { store.moveMenuBarGroup(source.id, to: target.id) }
        return groupsList()
    }

    @MainActor
    static func memberAdd(_ invocation: CLIInvocation) throws -> CLIResult {
        let group = try group(invocation.positional(0)!)
        let target = try account(invocation.positional(1)!)
        store.addGroupMember(target.id, to: group.id)
        guard store.groupMembers(group.id)?.contains(target.id) == true else { throw CLIError(store.displayError ?? "AgentBar did not add the account.") }
        return groupsList()
    }

    @MainActor
    static func memberRemove(_ invocation: CLIInvocation) throws -> CLIResult {
        let group = try group(invocation.positional(0)!)
        let target = try account(invocation.positional(1)!)
        guard group.effectiveMemberIDs.contains(target.id) else { throw CLIError("\(target.title) is not in \(group.name).") }
        store.removeGroupMember(target.id, from: group.id)
        return groupsList()
    }

    @MainActor
    static func memberMove(_ invocation: CLIInvocation) throws -> CLIResult {
        let group = try group(invocation.positional(0)!)
        let members = group.effectiveMemberIDs.compactMap { id in store.accounts.first { $0.id == id } }
        let source = try account(invocation.positional(1)!, among: members)
        guard let to = invocation.value("to") else { throw CLIError("Say where with --to ACCOUNT.", code: 2) }
        let target = try account(to, among: members)
        if source.id != target.id { store.moveGroupMember(source.id, to: target.id, in: group.id) }
        return groupsList()
    }

    @MainActor
    private static func slotIndex(_ text: String, in group: MenuBarLayout) throws -> MenuBarLine {
        guard let slot = Int(text), let line = slotted(group).first(where: { $0.0 == slot })?.1 else {
            throw CLIError("Group \(group.name) has no line in slot \(text). Run `agentbar groups`.")
        }
        return line
    }

    @MainActor
    static func lineAdd(_ invocation: CLIInvocation) throws -> CLIResult {
        let group = try group(invocation.positional(0)!)
        let target = try account(invocation.positional(1)!)
        let metric = limit(invocation.value("limit") ?? "weekly")
        let used = Set(slotted(group).map { $0.0 })
        let capacity = group.style == .text ? Int.max : MenuBarLayout.maximumLines
        let slot: Int
        if let text = invocation.value("slot") {
            guard let value = Int(text), value >= 1, value <= capacity else { throw CLIError("--slot is 1 to \(MenuBarLayout.maximumLines).", code: 2) }
            guard !used.contains(value) else { throw CLIError("Slot \(value) of \(group.name) is taken. Use `agentbar line set` or another slot.") }
            slot = value
        } else {
            guard let free = (1...max(capacity == Int.max ? used.count + 1 : capacity, 1)).first(where: { !used.contains($0) }) else {
                throw CLIError("\(group.name) is full (three lines). Remove a line first, or use a Text Only group.")
            }
            slot = free
        }
        let before = store.displayConfiguration
        store.updateDisplay { config in
            config.setVisible(target.id, true)
            let badge = config.display(target).badge
            config.editLayout(group.id) { layout in
                guard layout.style == .text || layout.rows.count < MenuBarLayout.maximumLines else { return }
                layout.rows.append(MenuBarLine(accountID: target.id, metricID: metric, slot: slot - 1, badgeText: badge))
                layout.rows.sort { ($0.slot ?? 0) < ($1.slot ?? 0) }
            }
        }
        try requireDisplayChange(before, "add the line")
        let after = (try? self.group(group.id.uuidString)) ?? group
        return withWarnings(CLIResult("Added \(target.title) · \(limitID(metric)) to \(group.name) [\(groupState(after))], slot \(slot).", json: ["group": group.id.uuidString, "slot": slot]))
    }

    @MainActor
    static func lineSet(_ invocation: CLIInvocation) throws -> CLIResult {
        let group = try group(invocation.positional(0)!)
        let line = try slotIndex(invocation.positional(1)!, in: group)
        let newAccount = try invocation.value("account").map { try account($0) }
        let metric = invocation.value("limit").map(limit)
        guard newAccount != nil || metric != nil || invocation.flag("percent") else {
            throw CLIError("Say what to change: --account, --limit or --percent.", code: 2)
        }
        let before = store.displayConfiguration
        store.updateDisplay { config in
            if let newAccount { config.setVisible(newAccount.id, true) }
            config.editLayout(group.id) { layout in
                guard let i = layout.rows.firstIndex(where: { $0.id == line.id }) else { return }
                if let newAccount {
                    layout.rows[i].accountID = newAccount.id
                    if metric == nil, !DisplayMetric.all(store.snapshot(for: newAccount)).contains(where: { $0.id == line.metricID }) {
                        layout.rows[i].metricID = "weekly"
                    }
                }
                if let metric { layout.rows[i].metricID = metric }
                if invocation.flag("percent") { layout.showPercentage(of: line.id) }
            }
        }
        if store.displayConfiguration == before && !(invocation.flag("percent") && group.shownPercentageLineID == line.id) {
            try requireDisplayChange(before, "change the line")
        }
        return groupsList()
    }

    @MainActor
    static func lineRemove(_ invocation: CLIInvocation) throws -> CLIResult {
        let group = try group(invocation.positional(0)!)
        let line = try slotIndex(invocation.positional(1)!, in: group)
        let before = store.displayConfiguration
        store.updateDisplay { $0.editLayout(group.id) { layout in
            layout.rows.removeAll { $0.id == line.id }
            if layout.percentageLineID == line.id { layout.percentageLineID = nil }
        } }
        try requireDisplayChange(before, "remove the line")
        let after = (try? self.group(group.id.uuidString)) ?? group
        return withWarnings(CLIResult("Removed slot \(invocation.positional(1)!) from \(group.name) [\(groupState(after))].",
                                      json: ["group": group.id.uuidString, "removed": Int(invocation.positional(1)!) ?? 0]))
    }

    @MainActor
    static func lineMove(_ invocation: CLIInvocation) throws -> CLIResult {
        let group = try group(invocation.positional(0)!)
        let line = try slotIndex(invocation.positional(1)!, in: group)
        guard let to = invocation.value("to").flatMap(Int.init) else { throw CLIError("Say where with --to SLOT.", code: 2) }
        let from = Int(invocation.positional(1)!)!
        let upper = group.style == .text ? group.rows.count : MenuBarLayout.maximumLines
        guard (1...upper).contains(to) else { throw CLIError("--to is 1 to \(upper).", code: 2) }
        if to != from {
            store.updateDisplay { $0.editLayout(group.id) { $0.moveLine(line.id, offset: to - from) } }
        }
        return groupsList()
    }

    // MARK: - Settings and app

    @MainActor static let launchAtLogin = LaunchAtLogin()

    @MainActor
    static func settingsShow() -> CLIResult {
        let settings = AppContainer.shared.settings
        launchAtLogin.refresh()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        let restartNeeded = settings.language != AppLanguage.inUse
        let updates = UpdateStatus.shared
        let values: [String: Any] = [
            "refreshInterval": Int(settings.refreshIntervalSeconds), "language": settings.language.rawValue,
            "languageInUse": AppLanguage.inUse.rawValue, "restartNeeded": restartNeeded,
            "openAtLogin": launchAtLogin.isOn, "openAtLoginNeedsApproval": launchAtLogin.needsApproval,
            "openAtLoginError": json(launchAtLogin.errorMessage),
            "claudeNoticeAccepted": settings.claudeAccessNoticeAccepted, "hasOriginalGroups": store.hasOriginalDisplayConfiguration,
            "version": version, "updates": updates.isAvailable,
            "update": ["selfUpdating": updates.isAvailable, "canCheck": updates.canCheck, "lastCheck": date(updates.lastCheckDate()),
                       "outcome": json(updates.outcome), "foundVersion": json(updates.foundVersion), "failure": json(updates.failure)] as [String: Any],
            "dataFolder": store.files.root.path, "app": Bundle.main.bundlePath,
        ]
        var update = updates.isAvailable ? "checked \(updates.lastCheckDate().map { TokenFormatters.relativeUpdateString(updatedAt: $0) } ?? "never")" : "this build does not update itself"
        switch updates.outcome {
        case "available": update += ", \(updates.foundVersion ?? "a new version") is available (a person installs it: `agentbar update --show`)"
        case "up-to-date": update += ", up to date"
        case "failed": update += ", the check failed: \(updates.failure ?? "")"
        case "installing": update += ", installing \(updates.foundVersion ?? "")"
        default: break
        }
        var text = """
        refresh-interval  \(Int(settings.refreshIntervalSeconds)) s
        language          \(settings.language.rawValue) (\(settings.language.nativeName))\(restartNeeded ? " — restart needed: shown after `agentbar restart` (now \(AppLanguage.inUse.rawValue))" : ", in use (no restart needed)")
        open-at-login     \(launchAtLogin.isOn ? "on" : "off")\(launchAtLogin.needsApproval ? " (waiting for approval in System Settings › Login Items: `agentbar open login-items`)" : launchAtLogin.isOn ? " (approved)" : "")
        claude notice     \(settings.claudeAccessNoticeAccepted ? "accepted" : "not accepted yet (asked before the first Claude sign-in)")
        version           \(version)
        updates           \(update)
        data folder       \(store.files.root.path)
        app               \(Bundle.main.bundlePath)
        """
        if store.hasOriginalDisplayConfiguration { text += "\noriginal groups   can be restored: `agentbar settings restore-groups --yes`" }
        return withWarnings(CLIResult(text, json: values))
    }

    @MainActor
    static func settingsSet(_ invocation: CLIInvocation) throws -> CLIResult {
        let settings = AppContainer.shared.settings
        let value = invocation.positional(1)!
        var note = ""
        switch invocation.positional(0)!.lowercased() {
        case "refresh-interval", "refresh", "interval":
            guard let seconds = Double(value.replacingOccurrences(of: "s", with: "")), [60, 120, 300, 600].contains(seconds) else {
                throw CLIError("refresh-interval is 60, 120, 300 or 600 (seconds).", code: 2)
            }
            settings.refreshIntervalSeconds = seconds
        case "language", "lang":
            guard let language = AppLanguage.allCases.first(where: { $0.rawValue == value.lowercased() || $0.nativeName.lowercased() == value.lowercased() }) else {
                throw CLIError("language is en or ko.", code: 2)
            }
            // As the screen's picker: saved and applied; a restart is needed only when it differs from the one shown now.
            settings.language = language
            language.apply()
            if language != AppLanguage.inUse { note = "\nThe new language applies after `agentbar restart`." }
        case "open-at-login", "login":
            launchAtLogin.set(try onOff(value, "open-at-login"))
            if let error = launchAtLogin.errorMessage { throw CLIError(error) }
        default:
            throw CLIError("Unknown setting \(invocation.positional(0)!). Use refresh-interval, language or open-at-login.", code: 2)
        }
        var result = settingsShow()
        result.text += note
        return result
    }

    @MainActor
    static func restoreGroups(_ invocation: CLIInvocation) throws -> CLIResult {
        guard store.hasOriginalDisplayConfiguration else { throw CLIError("There are no original groups to restore (`settings --json` says hasOriginalGroups).") }
        guard invocation.flag("yes") else {
            throw CLIError("This restores the original groups, account order, selected limits and display options. "
                           + "Your current layout is saved as a backup first. Run again with --yes to confirm.", code: 2)
        }
        store.displayError = nil
        let before = store.displayConfiguration
        store.restoreOriginalDisplayConfiguration()
        if let error = store.displayError { throw CLIError(error) }
        var result = groupsList()
        if store.displayConfiguration == before { result.text = "The original groups are already in place.\n" + result.text }
        else { result.text = "Restored the original groups (the layout before is kept as a backup in \(store.files.root.path)).\n" + result.text }
        return result
    }

    @MainActor
    static func updateCheck(_ invocation: CLIInvocation) async throws -> CLIResult {
        let updates = UpdateStatus.shared
        guard updates.isAvailable else { return CLIResult("This AgentBar build does not update itself.", json: ["checking": false, "outcome": NSNull()]) }
        guard updates.canCheck else { return CLIResult("Sparkle is already checking (it also checks when AgentBar starts). Try again in a few seconds.", json: ["checking": false, "outcome": json(updates.outcome)]) }
        if invocation.flag("show") {
            Updates.checkNow()
            return CLIResult("Opened Sparkle's update window. A person installs from there.", json: ["checking": true, "window": true])
        }
        let started = Date()
        Updates.probe()
        // Sparkle drops a probe asked for while its updater is still starting (just after AgentBar opened): ask again
        // every two seconds until a check is under way or answered.
        var asked = Date()
        let answered = await wait(invocation, seconds: 60, every: {
            if !updates.sessionInProgress(), Date().timeIntervalSince(asked) > 2 { asked = Date(); Updates.probe() }
        }, until: { (updates.answeredAt ?? .distantPast) >= started })
        guard answered else { throw CLIError("The update feed did not answer within 60 s.") }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        let message: String
        switch updates.outcome {
        case "available": message = "AgentBar \(updates.foundVersion ?? "") is available (this is \(current)). A person installs it: `agentbar update --show`."
        case "up-to-date": message = "AgentBar \(current) is up to date."
        case "installing": message = "Installing AgentBar \(updates.foundVersion ?? "")."
        default: throw CLIError("The update check failed: \(updates.failure ?? "unknown error").")
        }
        return CLIResult(message, json: ["outcome": json(updates.outcome), "foundVersion": json(updates.foundVersion), "version": current])
    }

    @MainActor
    static func restartApp() throws -> CLIResult {
        guard AppRelauncher.canRelaunch else { throw CLIError("A development run cannot restart itself; quit it with `agentbar quit`.") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { AppRelauncher.relaunch(reopeningSettings: false) }
        return CLIResult("AgentBar restarts.", json: ["restarting": true])
    }

    @MainActor
    static func openSettings(_ invocation: CLIInvocation) throws -> CLIResult {
        let tab: SettingsTab
        switch (invocation.positional(0) ?? "accounts").lowercased() {
        case "accounts": tab = .accounts
        case "menu-bar", "menubar", "groups": tab = .menuBar
        case "general", "settings": tab = .general
        case "login-items":
            launchAtLogin.openLoginItems()
            return CLIResult("Opened System Settings › Login Items. A person allows AgentBar there.", json: ["opened": "login-items"])
        default: throw CLIError("Tabs: accounts, menu-bar, general, login-items.", code: 2)
        }
        let groupID = try invocation.value("group").map { try group($0).id }
        SettingsWindowController.shared.show(tab: groupID == nil ? tab : .menuBar, groupID: groupID)
        return CLIResult("Opened Settings › \(tab.title).")
    }

    @MainActor
    static func quitApp() -> CLIResult {
        // After the answer is sent.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApplication.shared.terminate(nil) }
        return CLIResult("AgentBar quits.", json: ["quit": true])
    }

    // MARK: - In the command itself

    static func version() -> CLIResult {
        // Run through a link on PATH, Bundle.main is the link's folder: read the app bundle the link leads to.
        let info = CLIClient.appBundleURL.flatMap { Bundle(url: $0)?.infoDictionary } ?? Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "development"
        return CLIResult("agentbar \(version)", json: ["version": version, "executable": CLIClient.executableURL.path])
    }

    static func paths() -> CLIResult {
        let root = CLI.dataRoot()
        let values = ["dataFolder": root.path, "socket": CLI.socketPath(root: root),
                      "claudeCodeLog": ActivityLog.claudeCodeSwitchURL(root: root).path,
                      "accounts": root.appendingPathComponent("accounts.json").path, "display": root.appendingPathComponent("display-v2.json").path]
        return CLIResult(values.sorted { $0.key < $1.key }.map { "\($0.key.padding(toLength: 14, withPad: " ", startingAt: 0)) \($0.value)" }.joined(separator: "\n"), json: values)
    }

    static func installCLI(_ invocation: CLIInvocation) throws -> CLIResult {
        let directory = invocation.value("dir").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let link = try CLIInstaller.link(in: directory, replace: true)
        let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { URL(fileURLWithPath: String($0)).standardizedFileURL == directory.standardizedFileURL }
        return CLIResult("Linked \(link.path) → \(CLIClient.executableURL.path)" + (onPath ? "" : "\n\(directory.path) is not on PATH; add it to use `agentbar`."),
                         json: ["link": link.path, "target": CLIClient.executableURL.path, "onPath": onPath])
    }
}

enum CLIInstaller {
    // Links `agentbar` in `directory` to this executable. Without `replace`, an existing file or link that is not ours stays.
    @discardableResult
    static func link(in directory: URL, replace: Bool) throws -> URL {
        let link = directory.appendingPathComponent("agentbar")
        let target = CLIClient.executableURL
        let manager = FileManager.default
        if let existing = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            if URL(fileURLWithPath: existing).resolvingSymlinksInPath() == target { return link }
            // Without `replace`, only a link to an AgentBar that is gone is replaced.
            let dangling = existing.hasSuffix("/Contents/MacOS/agent-bar") && !manager.fileExists(atPath: existing)
            guard replace || dangling else { return link }
            try manager.removeItem(at: link)
        } else if manager.fileExists(atPath: link.path) {
            guard replace else { return link }
            throw CLIError("\(link.path) exists and is not a link. Remove it first.")
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        return link
    }

    // At launch of an installed app: makes `agentbar` available when ~/.local/bin exists and has no `agentbar` yet, or
    // has one that points to an AgentBar that is gone.
    static func linkAtLaunch() {
        guard CLIClient.appBundleURL != nil else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        _ = try? link(in: directory, replace: false)
    }
}
