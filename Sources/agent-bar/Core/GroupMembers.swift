import Foundation

// A group holds the accounts its usage lines use (`memberIDs` nil), or an ordered list of its own,
// which always includes every line's account. Groups that never had one behave as before.
extension MenuBarLayout {
    /// The accounts of the lines the menu bar draws, each once, in the order they first appear.
    var lineAccountIDs: [UUID] { Self.unique(displayedRows.map(\.accountID)) }
    /// The accounts of every line, Ring's undrawn ones too: the drawn ones first, then the rest in slot order.
    fileprivate var everyLineAccountID: [UUID] {
        let inSlotOrder = rows.enumerated().sorted {
            ($0.element.slot ?? $0.offset) < ($1.element.slot ?? $1.offset)
        }.map(\.element.accountID)
        return Self.unique(lineAccountIDs + inSlotOrder)
    }
    /// The accounts this group holds, in order. The first edit of a group's accounts starts from these.
    var effectiveMemberIDs: [UUID] { memberIDs ?? everyLineAccountID }
    /// The accounts refreshed while this group is shown: its lines' accounts and every other account its panel lists,
    /// such as that of a line Ring does not draw, so no row of the list waits.
    var refreshedAccountIDs: [UUID] { Self.unique(lineAccountIDs + effectiveMemberIDs) }
    /// The accounts a usage line may use: the group's own, or else every account in `ordered`.
    func lineAccountChoices(_ ordered: [UUID]) -> [UUID] {
        memberIDs.map { $0.filter(ordered.contains) } ?? ordered
    }
    /// The account a new line starts with: the last line's when it can be chosen, otherwise the first choice.
    func defaultLineAccount(_ ordered: [UUID]) -> UUID? {
        let choices = lineAccountChoices(ordered)
        if let last = rows.last?.accountID, choices.contains(last) { return last }
        return choices.first
    }

    /// Adds an account at the end. A group without accounts of its own first takes its lines' accounts.
    mutating func addMember(_ id: UUID) {
        let members = effectiveMemberIDs
        guard !members.contains(id) else { return }
        memberIDs = members + [id]
    }
    /// Removes an account with its lines. The other lines keep their slots, a removed percentage line
    /// gives way to the first line, and a group left with no accounts uses its lines' accounts again.
    mutating func removeMember(_ id: UUID) {
        var members = effectiveMemberIDs
        guard let index = members.firstIndex(of: id) else { return }
        members.remove(at: index)
        if rows.contains(where: { $0.accountID == id }) {
            for row in rows.indices where rows[row].slot == nil { rows[row].slot = row }
            if rows.contains(where: { $0.id == percentageLineID && $0.accountID == id }) { percentageLineID = nil }
            rows.removeAll { $0.accountID == id }
        }
        memberIDs = members.isEmpty ? nil : members
    }
    /// Moves an account to the target's place, as groups move: after it when moving down, before it when moving up.
    mutating func moveMember(_ id: UUID, to targetID: UUID) {
        var members = effectiveMemberIDs
        guard id != targetID, let source = members.firstIndex(of: id), let target = members.firstIndex(of: targetID) else { return }
        members.insert(members.remove(at: source), at: target)
        memberIDs = members
    }

    static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }
}

extension DisplayConfiguration {
    /// Repairs each group's own accounts: the first of any repeat stays, unknown accounts go, every line's
    /// account is added at the end, and a group left with none uses its lines' accounts again.
    /// agent-bar's panel lists every account, and it saves groups without `showBadge` or members. Such a group holds
    /// every visible account here, in the account list's order, so its panel lists what agent-bar's did.
    mutating func adoptAgentBarPanels(raw: Data, accounts ids: [UUID]) {
        guard layouts != nil,
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let saved = object["layouts"] as? [[String: Any]], saved.count == layouts!.count else { return }
        for index in layouts!.indices where saved[index]["showBadge"] == nil && saved[index]["memberIDs"] == nil {
            layouts![index].memberIDs = ids.filter { isVisible($0) }
        }
    }

    mutating func normalizeMembers() {
        guard layouts != nil else { return }
        for index in layouts!.indices {
            guard let ids = layouts![index].memberIDs else { continue }
            let members = MenuBarLayout.unique(ids.filter { accounts[$0.uuidString] != nil } + layouts![index].everyLineAccountID)
            layouts![index].memberIDs = members.isEmpty ? nil : members
        }
    }
}

extension UsageStore {
    /// The accounts a group's panel lists, in the group's order: every account it holds, which for a group holding none
    /// of its own are its lines' accounts. Hidden ones and ones being deleted are left out, as the menu bar leaves them out.
    func panelAccountIDs(for layout: MenuBarLayout) -> [UUID] {
        layout.effectiveMemberIDs.filter { id in
            displayConfiguration.isVisible(id) && accounts.contains { $0.id == id && !$0.deletionPending }
        }
    }
    /// The accounts a group holds, nil for a group that does not exist.
    func groupMembers(_ groupID: UUID) -> [UUID]? {
        displayConfiguration.effectiveLayouts.first { $0.id == groupID }?.effectiveMemberIDs
    }
    /// Adds an account to a group and turns it on, as choosing it for a line does.
    func addGroupMember(_ id: UUID, to groupID: UUID) {
        guard groupMembers(groupID) != nil, accounts.contains(where: { $0.id == id && !$0.deletionPending }) else { return }
        updateDisplay { config in
            config.setVisible(id, true)
            config.editLayout(groupID) { $0.addMember(id) }
        }
    }
    /// Removes an account and its lines from a group.
    func removeGroupMember(_ id: UUID, from groupID: UUID) {
        updateDisplay { $0.editLayout(groupID) { $0.removeMember(id) } }
    }
    /// Moves an account within a group, returning whether the order changed.
    @discardableResult
    func moveGroupMember(_ id: UUID, to targetID: UUID, in groupID: UUID) -> Bool {
        let before = groupMembers(groupID)
        updateDisplay { $0.editLayout(groupID) { $0.moveMember(id, to: targetID) } }
        return groupMembers(groupID) != before
    }
}
