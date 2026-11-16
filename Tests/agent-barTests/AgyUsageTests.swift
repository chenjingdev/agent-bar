import Foundation
import Testing
@testable import agent_bar

// Recorded from `agy -p /usage --output-format json` (Antigravity CLI 1.5.2, a
// free account), with the second group's fraction changed to show some use.
// The report itself names no account; agy's log does.
private let agyReport = #"""
{"conversation_id":"","status":"SUCCESS","response":"Gemini Models\tWeekly Limit Remaining\t100%\t2026-11-14T01:39:25Z\n","duration_seconds":0,"num_turns":0,
 "usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},
 "command":{"name":"usage","data":{"description":"Within each group, models share a weekly limit.","groups":[
  {"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[
    {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-11-14T01:39:25Z"}]},
  {"name":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[
    {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.25,"reset_time":"2026-11-14T01:39:25Z"}]}]}}}
"""#

// The lines agy logs while it signs in from its keyring.
private let signedInLog = """
I1107 10:46:44.597190       1 printmode.go:409] Print mode: not authenticated, trying silent auth
E1107 10:46:44.598000      82 errorreport.go:247] error getting token source: You are not logged into Antigravity.
I1107 10:46:44.613796       1 auth.go:157] ChainedAuth: authenticated via keyring (effective: keyring)
I1107 10:46:44.613812       1 server_oauth.go:226] OAuth: authenticated successfully as Someone@gmail.com
"""

private let fakeAgy = URL(fileURLWithPath: "/nonexistent/agy")

struct AgyUsageTests {
    @Test func agysReportGivesEachModelGroupItsLimits() throws {
        let groups = try AntigravityUsageProvider.groups(fromQuotaSummary: Data(agyReport.utf8))
        #expect(groups.map(\.label) == ["Gemini Models", "Claude and GPT models"])
        // Free accounts have weekly limits only.
        #expect(groups[0].weekly?.utilization == 0 && groups[0].fiveHour == nil)
        #expect(groups[1].weekly?.utilization == 0.75)
        #expect(groups[0].weekly?.resetAt == ISO8601DateFormatter().date(from: "2026-11-14T01:39:25Z"))
    }

    @Test func theAccountComesFromAgysOwnLog() {
        #expect(AntigravityUsageProvider.signedInEmail(fromLog: signedInLog) == "Someone@gmail.com")
        #expect(AntigravityUsageProvider.signedInEmail(fromLog: "E1107 x] You are not logged into Antigravity.") == nil)
        // A signed-in run also logs "not logged in" while it starts; only a
        // failed silent sign-in means signed out.
        #expect(!AntigravityUsageProvider.showsSignedOut(signedInLog))
        #expect(AntigravityUsageProvider.showsSignedOut("""
        I1107 10:54:00.465997       1 printmode.go:415] Print mode: silent auth failed
        W1107 10:54:00.466224       1 printmode.go:427] Print mode: not logged in and no controlling terminal; cannot complete interactive login
        """))
    }

    @Test func agyIsAskedOnlyForUsageWithALogOfLimisOwn() {
        let arguments = AntigravityUsageProvider.usageArguments(log: URL(fileURLWithPath: "/tmp/run/agy.log"))
        #expect(Array(arguments.prefix(4)) == ["-p", "/usage", "--output-format", "json"])
        #expect(Array(arguments.suffix(2)) == ["--log-file", "/tmp/run/agy.log"])
    }

    @Test func readingThroughAgyNeedsItSignedInToTheSameAccount() async {
        func provider(as email: String, run: AntigravityUsageProvider.AgyRun) -> AntigravityUsageProvider {
            AntigravityUsageProvider(expectedIdentity: AccountIdentity(email: email), agy: { fakeAgy }, runAgy: { _, _ in run },
                                     locate: { Issue.record("The app's server is not asked while agy is installed."); return nil })
        }
        let signedIn = AntigravityUsageProvider.AgyRun(output: Data(agyReport.utf8), log: signedInLog, signedOut: false)
        let live = await provider(as: "someone@gmail.com", run: signedIn).load()
        #expect(!live.isStale && live.limitGroups?.count == 2 && live.weekly?.utilization == 0)
        let other = await provider(as: "other@gmail.com", run: signedIn).load()
        #expect(other.isStale && other.note?.contains("Someone@gmail.com") == true)
        // Signed out: a note to sign in to agy, not an AgentBar reconnect.
        let signedOut = await provider(as: "someone@gmail.com", run: .init(output: Data(), log: "", signedOut: true)).load()
        #expect(signedOut.isStale && !signedOut.requiresLogin && signedOut.note == AntigravityUsageProvider.agySignInMessage)
    }

    @Test func connectingTakesTheAccountAgySignedInWith() async throws {
        let signedIn = AntigravityUsageProvider(agy: { fakeAgy }, runAgy: { _, _ in
            .init(output: Data(agyReport.utf8), log: signedInLog, signedOut: false)
        })
        let identity = try await signedIn.signedInAccount()
        #expect(identity.email == "Someone@gmail.com" && identity.stableID == "antigravity:someone@gmail.com")

        let signedOut = AntigravityUsageProvider(agy: { fakeAgy }, runAgy: { _, _ in .init(output: Data(), log: "", signedOut: true) })
        do {
            _ = try await signedOut.signedInAccount()
            Issue.record("A signed-out agy has no account to connect.")
        } catch AccountError.message(let text) {
            #expect(text == AntigravityUsageProvider.agySignInMessage)
        }
    }

    @Test func aCLIRunStopsAsSoonAsItsCheckSaysSo() throws {
        let session = try ProcessSession(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                         environment: ProviderCLI.processEnvironment(),
                                         directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        let started = Date()
        #expect(throws: ProcessSession.StoppedEarly.self) {
            try session.collect(until: Date().addingTimeInterval(20), control: OperationControl()) {
                Date().timeIntervalSince(started) > 0.3
            }
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

/// Runs the real `agy` on this Mac, which must be installed and signed in:
/// `LIMI_LIVE_AGY=1 swift test --filter AgyLiveTests`. It uses no quota.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIMI_LIVE_AGY"] == "1"))
struct AgyLiveTests {
    @Test func theSignedInAgyReportsItsAccountAndLimits() async throws {
        _ = try #require(AntigravityUsageProvider.installedAgy())
        let account = try await AntigravityUsageProvider().signedInAccount()
        #expect(account.email?.contains("@") == true)
        let snapshot = await AntigravityUsageProvider(expectedIdentity: account).load()
        #expect(!snapshot.isStale, "\(snapshot.note ?? "")")
        #expect(snapshot.limitGroups?.isEmpty == false)
    }

    @Test func anAgyThatIsNotSignedInStopsAtOnce() throws {
        let agy = try #require(AntigravityUsageProvider.installedAgy())
        // An empty home folder has no agy sign-in.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("limi-agy-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let started = Date()
        let run = try AntigravityUsageProvider.run(agy: agy, control: OperationControl(), home: home)
        #expect(run.signedOut, "\(String(decoding: run.output, as: UTF8.self))")
        #expect(Date().timeIntervalSince(started) < 20)
    }
}
