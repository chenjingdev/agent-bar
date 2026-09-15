import Foundation

struct DisplayItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var accountIDs: [UUID] = []
    var showService = true
    var showBars = true
    var showPercent = true
    var maxRows = 2
}
struct DisplayConfiguration: Codable, Equatable {
    var version = 1
    var activeCount = 2
    var items = [DisplayItem(), DisplayItem()]
    var metrics: [String: Set<String>] = [:]
    var activeItems: [DisplayItem] { Array(items.prefix(activeCount)) }
    @MainActor static func initial(_ registry: AccountRegistry, settings: AppSettings? = nil) -> Self {
        var value = Self()
        for (index, provider) in ProviderKind.allCases.enumerated() {
            if let id = registry.representatives[provider.rawValue] { value.items[index].accountIDs = [id] }
            if let preference = settings?.getProviderDisplaySettings(provider) {
                value.items[index].showService = preference.showsBadge
                value.items[index].showBars = preference.showsUsageBars
                value.items[index].showPercent = preference.showsPercentage
            }
        }
        if let settings {
            let providers = ProviderKind.allCases
            let enabled = providers.indices.filter { settings.getProviderDisplaySettings(providers[$0]).isEnabled }
            let disabled = providers.indices.filter { !settings.getProviderDisplaySettings(providers[$0]).isEnabled }
            value.items = (enabled + disabled).map { value.items[$0] }
            value.activeCount = max(1, enabled.count)
        }
        return value
    }
    // Selected but unavailable metrics still need polling so they can appear later.
    var refreshAccountIDs: Set<UUID> {
        Set(activeItems.filter { $0.showService || $0.showBars || $0.showPercent }
            .flatMap(\.accountIDs).filter { metrics[$0.uuidString]?.isEmpty != true })
    }
    func selection(_ account: UsageAccount) -> Set<String> {
        metrics[account.id.uuidString] ?? (account.provider == .claude ? ["5h", "weekly", "model:fable"] : ["5h", "weekly"])
    }
    func available(_ account: UUID, for itemID: UUID) -> Bool {
        !activeItems.contains { $0.id != itemID && $0.accountIDs.contains(account) }
    }
    mutating func resize(_ count: Int) {
        activeCount = max(1, count)
        while items.count < activeCount { items.append(DisplayItem()) }
    }
    mutating func assign(_ account: UUID, to itemID: UUID, moving: Bool = false) {
        guard let index = activeItems.firstIndex(where: { $0.id == itemID }), moving || available(account, for: itemID) else { return }
        if items[index].accountIDs.contains(account) { return }
        for i in items.indices { items[i].accountIDs.removeAll { $0 == account } }
        items[index].accountIDs.append(account)
    }
    mutating func remove(_ account: UUID, from itemID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[i].accountIDs.removeAll { $0 == account }
    }
    mutating func reorder(_ account: UUID, in itemID: UUID, offset: Int) {
        guard let i = items.firstIndex(where: { $0.id == itemID }), let j = items[i].accountIDs.firstIndex(of: account), items[i].accountIDs.indices.contains(j + offset) else { return }
        items[i].accountIDs.swapAt(j, j + offset)
    }
    mutating func prune(_ ids: Set<UUID>) {
        for i in items.indices { items[i].accountIDs.removeAll { !ids.contains($0) } }
        metrics = metrics.filter { UUID(uuidString: $0.key).map(ids.contains) ?? false }
    }
    var valid: Bool {
        let ids = items.flatMap(\.accountIDs)
        return version == 1 && activeCount >= 1 && activeCount <= items.count && Set(items.map(\.id)).count == items.count && Set(ids).count == ids.count && items.allSatisfy { (1...6).contains($0.maxRows) }
    }
}
struct DisplayMetric: Identifiable {
    var id: String
    var title: String
    var window: WindowSummary?
    static func all(_ snapshot: ProviderSnapshot) -> [Self] {
        var result = [Self(id: "5h", title: "5-Hour Session", window: snapshot.fiveHour), Self(id: "weekly", title: "Weekly Limit", window: snapshot.weekly)]
        for model in snapshot.displayedModelWeeklies {
            let key = "model:" + model.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !result.contains(where: { $0.id == key }) { result.append(Self(id: key, title: model.label + " Weekly", window: model.window)) }
        }
        return result
    }
}
struct DisplayRow: Identifiable {
    var account: UsageAccount
    var metric: DisplayMetric
    var badge: String
    var stale: Bool
    var id: String { account.id.uuidString + metric.id }
    static func make(item: DisplayItem, accounts: [UsageAccount], snapshots: [UUID: ProviderSnapshot], config: DisplayConfiguration) -> [Self] {
        let selected = item.accountIDs.compactMap { id in accounts.first { $0.id == id && !$0.deletionPending } }
        return selected.flatMap { account -> [Self] in
            let siblings = selected.filter { $0.provider == account.provider }
            let index = siblings.firstIndex(where: { $0.id == account.id }) ?? 0
            let badge = account.provider.shortName + (siblings.count > 1 ? "\(index + 1)" : "")
            let snapshot = snapshots[account.id] ?? .placeholder(for: account.provider)
            return DisplayMetric.all(snapshot).filter { config.selection(account).contains($0.id) && $0.window?.utilization != nil }.map {
                Self(account: account, metric: $0, badge: badge, stale: snapshot.isStale)
            }
        }
    }
    static func columns(_ rows: [Self], maximum: Int) -> [[Self]] {
        stride(from: 0, to: rows.count, by: max(1, maximum)).map { Array(rows[$0..<min(rows.count, $0 + max(1, maximum))]) }
    }
}
