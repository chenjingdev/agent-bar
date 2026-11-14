import Foundation
import Testing
@testable import agent_bar

struct AccountCardStatusTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(updatedSecondsAgo: TimeInterval = 120, usage: Bool = true, stale: Bool = false,
                          signIn: Bool = false, note: String? = nil) -> ProviderSnapshot {
        let window = WindowSummary(tokens: usage ? 42 : 0, limitTokens: usage ? 100 : 0, resetAt: nil, displayStyle: .percentage)
        return ProviderSnapshot(provider: .claude, updatedAt: now.addingTimeInterval(-updatedSecondsAgo),
                                fiveHour: window, weekly: window, modelWeeklies: [], planName: "Team",
                                sourceDescription: "", note: note, isStale: stale, requiresLogin: signIn)
    }

    private func status(_ snapshot: ProviderSnapshot, deletionPending: Bool = false, refreshed: Bool = true,
                        refreshing: Bool = false) -> AccountCardStatus {
        .make(snapshot: snapshot, deletionPending: deletionPending, refreshed: refreshed, refreshing: refreshing, now: now)
    }

    @Test func healthyUsageSaysWhenItWasUpdated() {
        #expect(status(snapshot()) == AccountCardStatus(tone: .ok, text: "Updated 2 min. ago"))
    }

    @Test func failedRefreshKeepsTheLastTimeAndGivesTheReason() {
        let result = status(snapshot(updatedSecondsAgo: 7200, stale: true, note: "The request timed out."))
        #expect(result == AccountCardStatus(tone: .attention, text: "Couldn't refresh · updated 2 hr. ago",
                                            detail: "The request timed out."))
    }

    @Test func invalidLastUpdateTimeDoesNotAppearInARefreshWarning() {
        let result = status(snapshot(updatedSecondsAgo: now.timeIntervalSince1970, stale: true, note: "The request timed out."))
        #expect(result == AccountCardStatus(tone: .attention, text: "Couldn't refresh", detail: "The request timed out."))
    }

    @Test func signInAndDeletionComeBeforeUsage() {
        #expect(status(snapshot(signIn: true)).text == "Sign-in required")
        #expect(status(snapshot(signIn: true)).tone == .attention)
        #expect(status(snapshot(), deletionPending: true).text == "Deletion pending")
    }

    @Test func accountsNoVisibleGroupUsesSaySoInsteadOfAnOldTime() {
        let result = status(snapshot(updatedSecondsAgo: 90_000), refreshed: false)
        #expect(result.tone == .quiet)
        #expect(result.text == "Not shown in the menu bar")
    }

    @Test func usageNotLoadedYetWaitsQuietlyButAFirstFailureShows() {
        let waiting = ProviderSnapshot.placeholder(for: .codex)
        #expect(status(waiting) == AccountCardStatus(tone: .quiet, text: "Loading usage…"))
        #expect(status(snapshot(usage: false, stale: true, note: "Codex is not installed."), refreshing: true).text == "Loading usage…")
        #expect(status(snapshot(usage: false, stale: true, note: "Codex is not installed."))
            == AccountCardStatus(tone: .attention, text: "Codex is not installed."))
    }

    @Test func personalOrganizationNamedAfterTheEmailIsNotRepeated() {
        let personal = AccountIdentity(email: "someone@example.com", organization: "someone@example.com's Organization")
        #expect(personal.visibleOrganization == nil)
        let team = AccountIdentity(email: "someone@example.com", organization: "Example Team")
        #expect(team.visibleOrganization == "Example Team")
        #expect(AccountIdentity(email: "someone@example.com", organization: "  ").visibleOrganization == nil)
    }

    @Test func limitChoicesSayAModelLimitIsWeeklyWhenThereIsRoom() {
        let model = DisplayMetric(id: "model:fable", title: "Fable Weekly", window: nil)
        #expect(model.choiceTitle == "Fable weekly")
        #expect(model.compactChoiceTitle == "Fable")
        let session = DisplayMetric(id: "5h", title: "5-Hour Session", window: nil)
        #expect(session.choiceTitle == "5 hours" && session.compactChoiceTitle == "5 hours")
        let weekly = DisplayMetric(id: "weekly", title: "Weekly Limit", window: nil)
        #expect(weekly.choiceTitle == "Weekly" && weekly.compactChoiceTitle == "Weekly")
    }

    @Test func limitChoicesKeepTheirTextAndShareTheRestOfTheRow() {
        // 5 hours, Weekly and Fable weekly at caption size, plus button padding,
        // in the room a Multi Bar line leaves them.
        let three = FillingHStack.widths([53, 51, 78], spacing: 4, available: 213)
        #expect(abs(three.reduce(0, +) + 8 - 213) < 0.001)
        #expect(zip(three, [53.0, 51, 78]).allSatisfy { $0 >= $1 })
        // A Codex line still fills the row with two nearly equal buttons.
        #expect(FillingHStack.widths([53, 51], spacing: 4, available: 213) == [105.5, 103.5])
        // Without room to share, each keeps its own width.
        #expect(FillingHStack.widths([53, 51, 78], spacing: 4, available: 150) == [53, 51, 78])
    }
}
