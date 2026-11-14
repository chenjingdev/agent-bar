import Foundation

/// What an account card in Settings says about the account's usage.
struct AccountCardStatus: Equatable {
    enum Tone: Equatable { case ok, attention, quiet }
    let tone: Tone
    let text: String
    /// The reason behind a warning, shown on hover.
    var detail: String? = nil

    static func make(snapshot: ProviderSnapshot, deletionPending: Bool, refreshed: Bool,
                     refreshing: Bool, now: Date = .now) -> Self {
        if deletionPending { return Self(tone: .attention, text: String(localized: "Deletion pending")) }
        if snapshot.requiresLogin { return Self(tone: .attention, text: String(localized: "Sign-in required"), detail: snapshot.note) }
        // An old time would read as a fault; these accounts are simply not refreshed.
        guard refreshed else {
            return Self(tone: .quiet, text: String(localized: "Not shown in the menu bar"),
                        detail: String(localized: "Accounts refresh only while a visible menu bar group uses them."))
        }
        guard snapshot.fiveHour?.utilization != nil || snapshot.weekly?.utilization != nil else {
            if refreshing || snapshot.note == ProviderSnapshot.notLoadedNote { return Self(tone: .quiet, text: String(localized: "Loading usage…")) }
            return Self(tone: .attention, text: snapshot.note ?? String(localized: "Could not load usage"))
        }
        if snapshot.isStale {
            guard snapshot.hasKnownUpdateTime else {
                return Self(tone: .attention, text: String(localized: "Couldn't refresh"), detail: snapshot.note)
            }
            let updated = TokenFormatters.relativeUpdateString(from: now, updatedAt: snapshot.updatedAt)
            return Self(tone: .attention, text: String(localized: "Couldn't refresh · updated \(updated)"), detail: snapshot.note)
        }
        guard snapshot.hasKnownUpdateTime else { return Self(tone: .ok, text: "") }
        let updated = TokenFormatters.relativeUpdateString(from: now, updatedAt: snapshot.updatedAt)
        return Self(tone: .ok, text: String(localized: "Updated \(updated)"))
    }
}
