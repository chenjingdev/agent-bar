import AppKit
import SwiftUI

struct DisplayPopoverView: View {
    let itemID: UUID
    @EnvironmentObject private var store: UsageStore
    @State private var showingAccounts = false
    @State private var selectedAccount: UUID?
    @State private var renaming: UsageAccount?
    init(itemID: UUID, showAccounts: Bool = false) {
        self.itemID = itemID
        self._showingAccounts = State(initialValue: showAccounts)
    }
    private var item: DisplayItem { store.displayConfiguration.items.first { $0.id == itemID } ?? DisplayItem(id: itemID) }
    private var number: Int { (store.displayConfiguration.items.firstIndex { $0.id == itemID } ?? 0) + 1 }
    private var details: [UsageAccount] {
        if let selectedAccount { return store.accounts.filter { $0.id == selectedAccount } }
        return store.displayAccounts(item)
    }
    var body: some View {
        ZStack {
            GlassPanelBackground(cornerRadius: 14)
            VStack(spacing: 0) {
                HStack {
                    Text(showingAccounts ? "Accounts" : "Usage").font(.system(size: 22, weight: .heavy, design: .rounded))
                    Spacer()
                    DisplayOptionsMenu(itemID: itemID, rename: { renaming = $0 })
                    Button { store.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh")
                }.padding(16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if showingAccounts {
                            AccountManagementView { account in selectedAccount = account.id; showingAccounts = false }
                        } else if selectedAccount == nil && (details.isEmpty || store.displayRows(item).isEmpty || (!item.showService && !item.showBars && !item.showPercent)) {
                            Text(details.isEmpty ? "표시 \(number)에 계정을 선택하세요." : "선택한 데이터가 없거나 표시 요소가 꺼져 있습니다. 로그인 상태는 Accounts에서 확인하세요.").foregroundStyle(AppTheme.muted)
                            DisplayOptionsContent(itemID: itemID, rename: { renaming = $0 })
                        } else {
                            if let error = store.displayError { Text(error).font(.caption).foregroundStyle(.orange) }
                            ForEach(details) { account in
                                accountDetail(account)
                            }
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 14)
                }
                Divider().overlay(AppTheme.stroke).padding(.horizontal, 16)
                HStack {
                    Text(store.isRefreshing ? "Refreshing…" : "Last updated \(store.lastRefresh.map { TokenFormatters.relativeUpdateString(updatedAt: $0) } ?? "—")")
                        .font(.system(size: 9)).foregroundStyle(AppTheme.muted).lineLimit(1)
                    Spacer(minLength: 4)
                    Button(showingAccounts ? "Usage" : "Accounts") { showingAccounts.toggle(); selectedAccount = nil }
                    Button("Settings") { SettingsWindowController.shared.show() }
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }.buttonStyle(.plain).font(.system(size: 12, weight: .bold, design: .rounded)).padding(14)
            }
        }.foregroundStyle(.white).frame(width: 392)
            .sheet(item: $renaming) { account in AccountRenameSheet(account: account) }
    }
    private func accountDetail(_ account: UsageAccount) -> some View {
        let snapshot = store.snapshot(for: account)
        let peers = details.filter { $0.provider == account.provider }
        let index = (peers.firstIndex { $0.id == account.id } ?? 0) + 1
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                ProviderBadge(provider: account.provider)
                Text((peers.count > 1 ? "\(account.provider.shortName)\(index) · " : "") + account.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded)).textSelection(.enabled)
            }
            if snapshot.isStale || snapshot.requiresLogin {
                Text(snapshot.requiresLogin ? "Login required · Accounts에서 재연결하세요." : "최신 값 확인 필요 · 저장된 사용량")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(DisplayMetric.all(snapshot).filter { $0.id != "5h" || $0.window != nil }) { metric in
                if let window = metric.window { WindowCard(title: metric.title, window: window, provider: account.provider) }
            }
            if let note = snapshot.note { Text(note).font(.system(size: 11)).foregroundStyle(AppTheme.muted) }
            Text("Last updated \(TokenFormatters.relativeUpdateString(updatedAt: snapshot.updatedAt))")
                .font(.system(size: 10)).foregroundStyle(AppTheme.muted)
        }
    }
}

struct DisplayOptionsMenu: View {
    var itemID: UUID
    var rename: (UsageAccount) -> Void
    var body: some View {
        Menu { DisplayOptionsContent(itemID: itemID, rename: rename) } label: { Image(systemName: "slider.horizontal.3") }
            .menuStyle(.borderlessButton).fixedSize().help("메뉴 막대 표시 설정")
    }
}
struct DisplayOptionsContent: View {
    let itemID: UUID
    var rename: (UsageAccount) -> Void
    @EnvironmentObject private var store: UsageStore
    private var config: DisplayConfiguration { store.displayConfiguration }
    private var item: DisplayItem { config.items.first { $0.id == itemID } ?? DisplayItem(id: itemID) }
    private func binding<T>(_ key: WritableKeyPath<DisplayItem,T>) -> Binding<T> {
        Binding(get: { item[keyPath: key] }, set: { value in store.updateDisplay { config in
            if let i = config.items.firstIndex(where: { $0.id == itemID }) { config.items[i][keyPath: key] = value }
        } })
    }
    var body: some View {
        Toggle("서비스 표시", isOn: binding(\.showService))
        Toggle("사용량 바", isOn: binding(\.showBars))
        Toggle("퍼센트", isOn: binding(\.showPercent))
        Picker("세로 줄 수", selection: binding(\.maxRows)) {
            ForEach(1...6, id: \.self) { Text("\($0)줄").tag($0) }
        }
        if item.maxRows >= 4 { Text("퍼센트가 작게 표시됩니다.") }
        if store.displayWidthWarning { Text("메뉴 막대 공간을 많이 사용합니다.") }
        if let error = store.displayError { Text(error) }
        Divider()
        Text("메뉴 막대에 표시할 사용량")
        ForEach(store.accounts.filter { !$0.deletionPending && config.available($0.id, for: itemID) }) { account in
            Menu(account.title + " · " + account.provider.shortName) {
                Toggle("이 표시에서 보기", isOn: Binding(get: { item.accountIDs.contains(account.id) }, set: { selected in
                    store.updateDisplay { value in
                        if selected { value.assign(account.id, to: itemID) } else { value.remove(account.id, from: itemID) }
                    }
                }))
                Button("이름 변경") { rename(account) }
                Divider()
                AccountMetricOptions(account: account)
                if item.accountIDs.contains(account.id) {
                    Divider()
                    Menu("다른 표시로 이동") {
                        ForEach(Array(config.activeItems.enumerated()), id: \.element.id) { index, other in
                            if other.id != itemID { Button("표시 \(index + 1)") { store.updateDisplay { $0.assign(account.id, to: other.id, moving: true) } } }
                        }
                    }
                    Button("위로") { store.updateDisplay { $0.reorder(account.id, in: itemID, offset: -1) } }
                        .disabled(item.accountIDs.first == account.id)
                    Button("아래로") { store.updateDisplay { $0.reorder(account.id, in: itemID, offset: 1) } }
                        .disabled(item.accountIDs.last == account.id)
                }
            }
        }
    }
}
