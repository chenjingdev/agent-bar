import SwiftUI

struct AccountManagementView: View {
    @EnvironmentObject private var store: UsageStore
    var select: (UsageAccount) -> Void = { _ in }
    @State private var editing: UsageAccount?
    @State private var deleting: UsageAccount?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = store.errorMessage {
                VStack(alignment: .leading) {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Dismiss") { store.errorMessage = nil }
                }
            }
            if store.isLoggingIn || store.pendingLogin != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if store.isLoggingIn { ProgressView().controlSize(.small) }
                    Text(store.loginMessage ?? "")
                    if let pending = store.pendingLogin {
                        Text(pending.account.identity?.description.isEmpty == false
                             ? pending.account.identity!.description : "The provider did not return account details.")
                            .font(.headline).textSelection(.enabled)
                        if pending.replacing != nil {
                            if store.reconnectionComparison == .different {
                                Text("This differs from the existing account. Add it separately to preserve the original.")
                                Button("Add as New Account") { store.confirmLogin(addAsNew: true) }
                            } else if store.reconnectionComparison != .same {
                                Text("Account identity could not be verified automatically. Confirm the displayed account.")
                                Button("Confirm Reconnection") { store.confirmLogin(replaceUnverified: true) }
                                Button("Add Separately") { store.confirmLogin(addAsNew: true) }
                            } else { Button("Complete Reconnection") { store.confirmLogin() } }
                        } else { Button("Register Account") { store.confirmLogin() }.buttonStyle(.borderedProminent) }
                    }
                    Button("Cancel", role: .cancel) { store.cancelLogin() }
                }
            }

            ForEach(store.accounts) { account in
                HStack {
                    Button { select(account) } label: {
                        HStack {
                            ProviderBadge(provider: account.provider)
                            VStack(alignment: .leading) {
                                Text(account.title).font(.headline).lineLimit(1)
                                Text(account.isManaged ? (account.identity?.description ?? "") : "Follows the current CLI sign-in.")
                                    .font(.caption).foregroundStyle(AppTheme.muted).lineLimit(2)
                                if !store.refreshAccountIDs.contains(account.id) {
                                    Text("Hidden · refresh paused").font(.caption).foregroundStyle(AppTheme.muted)
                                }
                                if account.deletionPending { Text("Deletion pending").font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer()
                        }
                    }.buttonStyle(.plain)
                    Menu {
                        Button("Rename") { editing = account }
                        Divider()
                        Text("Limits Shown in Menu Bar")
                        AccountMetricOptions(account: account).disabled(account.deletionPending)
                        Divider()
                        if account.isManaged {
                            Button("Reconnect") { store.startLogin(account.provider, replacing: account) }
                                .disabled(store.isLoggingIn || store.pendingLogin != nil || account.deletionPending)
                            Button(account.deletionPending ? "Retry Deletion" : "Delete", role: .destructive) { deleting = account }
                        }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }.padding(12).background(GlassCardBackground(cornerRadius: 16))
            }
            Menu {
                ForEach(ProviderKind.allCases) { provider in
                    Button(provider.displayName) { store.startLogin(provider) }
                }
            } label: { Label("Add Account", systemImage: "plus") }
                .disabled(store.isLoggingIn || store.pendingLogin != nil || store.storageUnavailable)
            if !store.registry.cleanupPending.isEmpty && !store.isLoggingIn && store.pendingLogin == nil {
                Button("Retry Pending Cleanup") { Task { await store.retryCleanup() } }
            }
        }
        .sheet(item: $editing) { account in AccountRenameSheet(account: account) }
        .alert("Delete this account from AgentBar?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let account = deleting { Task { await store.delete(account) } }; deleting = nil
            }
        } message: { Text("This removes only the selected account’s AgentBar credentials and usage cache. External CLI sign-ins are preserved.") }
    }
}

// Both entry points use the same persisted metric selection and rename sheet.
struct AccountMetricOptions: View {
    let account: UsageAccount
    @EnvironmentObject private var store: UsageStore
    var body: some View {
        ForEach(DisplayMetric.all(store.snapshot(for: account))) { metric in
            Toggle(metric.title + (metric.window?.utilization == nil ? " · unavailable" : ""), isOn: Binding(
                get: { store.displayConfiguration.selection(account).contains(metric.id) },
                set: { selected in
                    store.updateDisplay { value in
                        var metrics = value.selection(account)
                        if selected { metrics.insert(metric.id) } else { metrics.remove(metric.id) }
                        value.metrics[account.id.uuidString] = metrics
                    }
                }))
        }
    }
}
struct AccountRenameSheet: View {
    let account: UsageAccount
    @EnvironmentObject private var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    init(account: UsageAccount) { self.account = account; self._name = State(initialValue: account.name) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Account").font(.headline)
            TextField("Account Name", text: $name)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { store.rename(account, name: name); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 350)
    }
}
