import Foundation
import Testing
@testable import agent_bar

struct CLITests {
    private func invocation(_ words: [String]) throws -> CLIInvocation {
        guard case .invocation(let value) = try CLI.parse(words) else { Issue.record("expected an invocation"); throw CLIError("help") }
        return value
    }

    @Test func commandWordsStartTheCommandAndLaunchArgumentsStartTheApp() {
        #expect(CLI.isCommand(["agent-bar", "status"]))
        #expect(CLI.isCommand(["agent-bar", "--help"]))
        #expect(!CLI.isCommand(["agent-bar"]))
        #expect(!CLI.isCommand(["agent-bar", "-psn_0_12345"]))
        #expect(!CLI.isCommand(["agent-bar", "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    @Test func parsesTheLongestCommandPathWithOptionsAndFlags() throws {
        let line = try invocation(["line", "add", "2", "a@example.test", "--limit", "5h", "--slot=3", "--json"])
        #expect(line.spec.name == "line add")
        #expect(line.positionals == ["2", "a@example.test"])
        #expect(line.value("limit") == "5h" && line.value("slot") == "3")
        #expect(line.json)
        #expect(try invocation(["resets", "1"]).spec.name == "resets")
        #expect(try invocation(["resets", "use", "1", "coupon"]).spec.name == "resets use")
        #expect(try invocation(["account", "remove", "1", "--yes"]).flag("yes"))
    }

    @Test func wrongCommandLinesExitWithTwoAndShowUsage() {
        for words in [["account", "add"], ["status", "1", "2"], ["groups", "--nope"], ["line", "add", "1", "2", "--limit"], ["bogus"]] {
            #expect(throws: CLIError.self) { try CLI.parse(words) }
            do { _ = try CLI.parse(words) } catch let error as CLIError { #expect(error.code == 2) } catch {}
        }
    }

    @Test func everyCommandHasHelp() throws {
        for spec in CLICommands.all {
            guard case .help(let found?, _) = try CLI.parse(spec.path + ["--help"]) else { Issue.record("no help for \(spec.name)"); continue }
            #expect(found.name == spec.name)
            #expect(CLI.help(found, []).contains("Usage: agentbar \(spec.name)"))
            #expect(!spec.summary.isEmpty)
            #expect((spec.run == nil) != (spec.local == nil))
        }
        #expect(CLI.help(nil, []).contains("account add <claude|codex|antigravity>"))
        guard case .help(nil, _) = try CLI.parse(["help"]) else { Issue.record("help"); return }
    }

    @Test func longDataFoldersUseAShortSocketPath() {
        let short = URL(fileURLWithPath: "/Users/someone/.agentbar/multi-account-v1")
        #expect(CLI.socketPath(root: short) == short.path + "/control.sock")
        let long = URL(fileURLWithPath: "/private/tmp/" + String(repeating: "x", count: 120))
        let path = CLI.socketPath(root: long)
        #expect(path.hasPrefix("/tmp/agentbar-") && path.utf8.count < 100)
        #expect(path == CLI.socketPath(root: long))
    }

    @MainActor @Test func localCommandsRunWithoutTheApp() async {
        let (code, out, _) = await CLIRunner.execute(["version", "--json"], connection: nil)
        #expect(code == 0 && out.contains("\"version\""))
        let (bad, _, err) = await CLIRunner.execute(["account", "add"], connection: nil)
        #expect(bad == 2 && err.contains("Usage: agentbar account add"))
    }
}

struct CLIFoundBugTests {
    @Test func badgeNumbersDoNotRepeatAfterADeletion() {
        let a = UsageAccount(id: UUID(), provider: .claude, name: "A")
        let b = UsageAccount(id: UUID(), provider: .claude, name: "B")
        let c = UsageAccount(id: UUID(), provider: .claude, name: "C")
        let d = UsageAccount(id: UUID(), provider: .claude, name: "D")
        var value = DisplayConfiguration()
        value.sync([a]); value.sync([a, b]); value.sync([a, b, c])
        value.sync([a, c]); value.sync([a, c, d])
        let badges = [a, c, d].map { value.display($0).badge }
        #expect(Set(badges).count == 3)
        #expect(value.display(d).badge == "CL2")
    }

    @Test func changingALineRemakesItsBadgeLabel() {
        let claude = UsageAccount(id: UUID(), provider: .claude, name: "C")
        let codex = UsageAccount(id: UUID(), provider: .codex, name: "X")
        var old = DisplayConfiguration()
        old.sync([claude, codex])
        old.layouts = [MenuBarLayout(name: "G", rows: [MenuBarLine(id: "line", accountID: claude.id, metricID: "weekly")])]
        old.freezeBadgeLabels()
        #expect(old.layouts![0].rows[0].badgeText == "CL·WK")
        var next = old
        next.layouts![0].rows[0].metricID = "5h"
        next.releaseBadgeLabels(changedFrom: old); next.freezeBadgeLabels()
        #expect(next.layouts![0].rows[0].badgeText == "CL·5H")
        let before = next
        next.layouts![0].rows[0].accountID = codex.id
        next.releaseBadgeLabels(changedFrom: before); next.freezeBadgeLabels()
        #expect(next.layouts![0].rows[0].badgeText == "CX·5H")
        // A label that did not change stays as it was frozen.
        let same = next
        next.releaseBadgeLabels(changedFrom: same)
        #expect(next.layouts![0].rows[0].badgeText == "CX·5H")
    }

    @Test func codexLoginsWithTheSameEmailAreTheSameAccount() {
        let existing = AccountIdentity(email: "same@example.test")
        #expect(UsageStore.sameLogin(AccountIdentity(email: "Same@example.test", organization: "Personal"), existing))
        #expect(!UsageStore.sameLogin(AccountIdentity(email: "other@example.test"), existing))
        #expect(!UsageStore.sameLogin(AccountIdentity(email: "same@example.test", organization: "Team"),
                                      AccountIdentity(email: "same@example.test", organization: "Personal")))
        #expect(UsageStore.sameLogin(AccountIdentity(email: "a@example.test", organizationID: "o", stableID: "1"),
                                     AccountIdentity(email: "a@example.test", organizationID: "o", stableID: "1")))
        #expect(!UsageStore.sameLogin(AccountIdentity(email: "a@example.test", organizationID: "o", stableID: "1"),
                                      AccountIdentity(email: "a@example.test", organizationID: "o", stableID: "2")))
    }
}

struct CLISecondBugTests {
    @Test func antigravityGroupLinesGetReadableDistinctLabels() {
        #expect(DisplayMetric(id: "group:claude-and-gpt-models:weekly", title: "x", window: nil).shortLabel == "CLA WK")
        #expect(DisplayMetric(id: "group:gemini-pro:5h", title: "x", window: nil).shortLabel == "GEM 5H")
        #expect(DisplayMetric(id: "weekly", title: "Weekly", window: nil).shortLabel == "WK")
    }

    @Test func aUsedCodexCreditIsNotNamedAgain() {
        let coupons = UsageResetCoupons(count: 2, scope: .fiveHourAndWeekly, claim: .codex(creditID: "A"))
        #expect(coupons.usingOne()?.claim == .codex(creditID: nil))
        #expect(coupons.usingOne()?.count == 1)
    }

    @Test func cachedUsageBeingRefreshedIsNotAFailure() {
        let window = WindowSummary(tokens: 10, limitTokens: 100, resetAt: nil, displayStyle: .percentage)
        let cached = ProviderSnapshot(provider: .claude, updatedAt: .now.addingTimeInterval(-3 * 3600), fiveHour: window, weekly: window,
                                      modelWeeklies: [], planName: nil, sourceDescription: "", note: "Cached", isStale: true, requiresLogin: false)
        #expect(AccountCardStatus.make(snapshot: cached, deletionPending: false, refreshed: true, refreshing: true).tone == .quiet)
        #expect(AccountCardStatus.make(snapshot: cached, deletionPending: false, refreshed: true, refreshing: false).tone == .attention)
    }

    @Test func anUnansweredCodexClaimIsRetriedUnderItsOwnKey() async {
        let memory = CodexClaimMemory()
        await memory.remember("key-1", for: "folder|A")
        #expect(await memory.pendingKey(for: "folder|A") == "key-1")
        #expect(await memory.pendingKey(for: "folder|A", now: .now.addingTimeInterval(601)) == nil)
        await memory.remember("key-2", for: "folder|A"); await memory.forget("folder|A")
        #expect(await memory.pendingKey(for: "folder|A") == nil)
    }
}
