import AppKit
import SwiftUI

// Clicking a menu bar item shows one account. A Compact item holds several,
// switched with tabs above the header.
struct AccountPopoverView: View {
    let accountIDs: [UUID]
    let groupID: UUID?
    @EnvironmentObject private var store: UsageStore
    @State private var selected: UUID?
    init(accountID: UUID, groupID: UUID? = nil) { self.accountIDs = [accountID]; self.groupID = groupID }
    init(accountIDs: [UUID], groupID: UUID? = nil) { self.accountIDs = accountIDs; self.groupID = groupID }
    private var accounts: [UsageAccount] { accountIDs.compactMap { id in store.accounts.first { $0.id == id && !$0.deletionPending } } }
    private var account: UsageAccount? { accounts.first { $0.id == selected } ?? accounts.first }
    var body: some View {
        ZStack {
            GlassPanelBackground(cornerRadius: 14)
            VStack(spacing: 0) {
                if accounts.count > 1 {
                    Picker("Account", selection: Binding(get: { account?.id ?? accounts[0].id }, set: { selected = $0 })) {
                        ForEach(accounts) { Text(store.displayConfiguration.display($0).badge).tag($0.id) }
                    }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.top, 14)
                }
                if let account {
                    header(account)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let error = store.displayError { Text(error).font(.caption).foregroundStyle(.orange) }
                            content(account)
                        }.padding(.horizontal, 16).padding(.bottom, 14)
                    }
                } else {
                    Text("This account was removed.").foregroundStyle(AppTheme.muted).padding(16)
                    Spacer()
                }
                Divider().overlay(AppTheme.stroke).padding(.horizontal, 16)
                footer
            }
        }.foregroundStyle(.white).frame(width: 392)
    }
    private func header(_ account: UsageAccount) -> some View {
        let display = store.displayConfiguration.display(account)
        return HStack(spacing: 10) {
            AccountBadge(text: display.badge, color: display.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.title).font(.system(size: 18, weight: .heavy, design: .rounded)).lineLimit(1).textSelection(.enabled)
                Text(account.provider.displayName)
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(AppTheme.muted)
            }
            Spacer(minLength: 8)
            Button { store.refreshNow() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            Button { SettingsWindowController.shared.show(tab: .menuBar, groupID: groupID) } label: { Image(systemName: "gearshape") }.help("Settings")
        }.buttonStyle(.plain).font(.system(size: 14, weight: .semibold)).padding(16)
    }
    @ViewBuilder private func content(_ account: UsageAccount) -> some View {
        let snapshot = store.snapshot(for: account)
        let primary = store.displayConfiguration.display(account).primary
        let metrics = DisplayMetric.all(snapshot)
        let ordered = metrics.filter { $0.id == primary } + metrics.filter { $0.id != primary }
        Text(statusLine(snapshot))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(snapshot.requiresLogin || snapshot.isStale ? .orange : AppTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(ordered) { metric in
            if let window = metric.window, window.utilization != nil {
                WindowCard(title: metric.title, window: window, provider: account.provider)
            } else if metric.id.hasPrefix("model:") {
                Text("\(metric.title) · no data yet").font(.system(size: 11)).foregroundStyle(AppTheme.muted)
            }
        }
    }
    private func statusLine(_ snapshot: ProviderSnapshot) -> String {
        let updated = "Updated \(TokenFormatters.relativeUpdateString(updatedAt: snapshot.updatedAt))"
        if snapshot.requiresLogin { return "Sign-in required · reconnect in Settings › Accounts" }
        if snapshot.isStale { return (snapshot.note ?? "Cached usage.") + " · " + updated }
        return updated + (snapshot.planName.map { " · " + $0 } ?? "")
    }
    private var footer: some View {
        HStack {
            let count = store.visibleAccounts.count
            Text(store.isRefreshing ? "Refreshing…" : "\(count) account\(count == 1 ? "" : "s") in menu bar")
                .font(.system(size: 10)).foregroundStyle(AppTheme.muted).lineLimit(1)
            Spacer(minLength: 4)
            Button("Accounts…") { SettingsWindowController.shared.show(tab: .accounts, groupID: groupID) }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }.buttonStyle(.plain).font(.system(size: 12, weight: .bold, design: .rounded)).padding(14)
    }
}

struct AccountBadge: View {
    let text: String
    let color: AccountColor
    var compact = false
    var body: some View {
        Text(text)
            .font(.system(size: compact ? 9 : 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 5 : 7).frame(height: compact ? 16 : 22)
            .background(RoundedRectangle(cornerRadius: compact ? 4 : 6, style: .continuous).fill(color.color))
            .lineLimit(1).fixedSize()
    }
}
