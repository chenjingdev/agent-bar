import SwiftUI

private struct AccountFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// Accounts manage identities; menu bar groups control display and polling.
struct AccountManagementView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var editing: UsageAccount?
    @State private var deleting: UsageAccount?
    @State private var choosingProvider = false
    @State private var accountFrames: [UUID: CGRect] = [:]
    @State private var accountDrag: ReorderDragPreview<UUID>?
    @State private var settlingAccountDrag = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = store.errorMessage {
                VStack(alignment: .leading) {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Dismiss") { store.errorMessage = nil }
                }
            }
            if store.isLoggingIn || store.pendingLogin != nil { LoginProgressView() }

            VStack(spacing: 12) {
                ForEach(store.orderedAccounts) { account in
                    row(account)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: AccountFrames.self, value: [account.id: proxy.frame(in: .named("account-order"))])
                        })
                        .opacity(accountDrag?.source == account.id ? 0 : 1)
                        .offset(accountDrag?.offset(for: account.id) ?? .zero)
                        .animation(.snappy(duration: 0.18), value: accountDrag?.target)
                }
            }
            .coordinateSpace(name: "account-order")
            .onPreferenceChange(AccountFrames.self) { accountFrames = $0 }
            .overlay(alignment: .topLeading) { accountDragOverlay.allowsHitTesting(false) }
            .zIndex(accountDrag == nil ? 0 : 1)
            Button { choosingProvider = true } label: {
                Label("Add Account", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(ChoiceButtonStyle(selected: false))
            .disabled(store.isLoggingIn || store.pendingLogin != nil || store.storageUnavailable)
            if (!store.registry.cleanupPending.isEmpty || store.accounts.contains(where: \.deletionPending))
                && !store.isLoggingIn && store.pendingLogin == nil {
                Button("Retry Pending Cleanup") { Task { await store.retryCleanup() } }
            }
        }
        .onDisappear { accountDrag = nil; settlingAccountDrag = false }
        .sheet(item: $editing) { account in AccountEditSheet(account: account, displayName: store.accountLabel(for: account)) }
        .sheet(isPresented: $choosingProvider) {
            AddAccountProviderSheet { provider in store.startLogin(provider) }
        }
        .alert("Delete this account from AgentBar?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let account = deleting { Task { await store.delete(account) } }; deleting = nil
            }
        } message: { Text("This removes only the selected account’s AgentBar credentials and usage cache. External CLI sign-ins are preserved.") }
    }
    private func row(_ account: UsageAccount, preview: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 14, height: 22).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("account-order"))
                    .onChanged { if !preview { updateAccountDrag(account.id, value: $0) } }
                    .onEnded { if !preview { finishAccountDrag(at: $0.location) } })
                .help("Drag to reorder accounts")
                .accessibilityLabel("Move \(store.accountLabel(for: account)) account")
                .accessibilityAction(named: "Move up") { moveAccount(account.id, offset: -1) }
                .accessibilityAction(named: "Move down") { moveAccount(account.id, offset: 1) }
            VStack(alignment: .leading, spacing: 4) {
                Button { editing = account } label: {
                    Text(store.accountLabel(for: account)).font(.headline).lineLimit(1)
                }.buttonStyle(.plain).help("Rename account")
                if let email = account.identity?.email, !email.isEmpty {
                    Text(email).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(account.isManaged ? "Account details unavailable" : "Sign-in required")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text([account.provider.displayName, account.identity?.organization]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if account.deletionPending {
                Text("Deletion pending").font(.caption).foregroundStyle(.orange)
            } else if store.snapshot(for: account).requiresLogin {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help("Sign-in required")
            }
            Menu {
                Button("Rename") { editing = account }
                    .disabled(account.deletionPending || store.storageUnavailable)
                Button("Reconnect") { store.startLogin(account.provider, replacing: account) }
                    .disabled(store.isLoggingIn || store.pendingLogin != nil || account.deletionPending || store.storageUnavailable)
                Button("Delete", role: .destructive) { deleting = account }
                    .disabled(store.isLoggingIn || store.pendingLogin != nil || store.storageUnavailable)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Account options")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder private var accountDragOverlay: some View {
        if let drag = accountDrag, let account = store.orderedAccounts.first(where: { $0.id == drag.source }) {
            DragSlotPlaceholder(cornerRadius: 10)
                .frame(width: drag.placeholder.width, height: drag.placeholder.height)
                .offset(x: drag.placeholder.minX, y: drag.placeholder.minY)
                .animation(.snappy(duration: 0.18), value: drag.target)
            row(account, preview: true)
                .frame(width: drag.floatingFrame.width, height: drag.floatingFrame.height)
                .modifier(FloatingDragCard(settling: settlingAccountDrag, liftScale: 1.02, cornerRadius: 10))
                .offset(x: drag.floatingFrame.minX, y: drag.floatingFrame.minY)
        }
    }

    private func updateAccountDrag(_ id: UUID, value: DragGesture.Value) {
        guard !settlingAccountDrag else { return }
        if accountDrag == nil {
            accountDrag = ReorderDragPreview(source: id, order: store.orderedAccounts.map(\.id), frames: accountFrames,
                                             location: value.location, translation: value.translation,
                                             hitPadding: CGSize(width: 3, height: 6))
        } else {
            accountDrag?.location = value.location
            accountDrag?.translation = value.translation
        }
    }

    private func finishAccountDrag(at point: CGPoint) {
        guard var drag = accountDrag, !settlingAccountDrag else { return }
        drag.location = point
        let target = drag.target
        accountDrag = drag
        withAnimation(.easeOut(duration: 0.16)) {
            settlingAccountDrag = true
            accountDrag?.translation = drag.landingTranslation
        } completion: {
            guard accountDrag?.source == drag.source else { return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let target, store.orderedAccounts.map(\.id) == drag.order { store.moveAccount(drag.source, to: target) }
                accountDrag = nil
                settlingAccountDrag = false
            }
        }
    }

    private func moveAccount(_ id: UUID, offset: Int) {
        let order = store.orderedAccounts.map(\.id)
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        store.moveAccount(id, to: order[index + offset])
    }
}

private struct AddAccountProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let select: (ProviderKind) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Account").font(.title3.bold())
            Text("Choose an agent to sign in with.").font(.callout).foregroundStyle(.secondary)
            Text("Sign in using your usual browser. AgentBar keeps a separate sign-in for usage monitoring.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ProviderKind.allCases) { provider in
                Button {
                    dismiss()
                    select(provider)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(AppTheme.tint(for: provider).opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName).font(.headline)
                            Text(provider.sourceDescription).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(ChoiceButtonStyle(selected: false))
                .accessibilityLabel("Add \(provider.displayName) account")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 390)
    }
}

// Sign-in states. The identity checks stay; only the button labels are unified.
struct LoginProgressView: View {
    @EnvironmentObject private var store: UsageStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isLoggingIn { ProgressView().controlSize(.small) }
            Text(store.loginMessage ?? "")
            if store.canOpenPrivateLogin {
                Button("Use Private Window Instead") { store.openPrivateLogin() }
            }
            if let pending = store.pendingLogin {
                Text(pending.account.identity?.description.isEmpty == false
                     ? pending.account.identity!.description : "The provider did not return account details.")
                    .font(.headline).textSelection(.enabled)
                if pending.replacing != nil {
                    if store.reconnectionComparison == .different {
                        Text("This is a different account from the one being reconnected. It can only be added as a new account.")
                        Button("Add Account") { store.confirmLogin(addAsNew: true) }.buttonStyle(.borderedProminent)
                    } else if store.reconnectionComparison != .same {
                        Text("The account identity could not be verified automatically. Reconnect only if this is the same account.")
                        HStack {
                            Button("Reconnect") { store.confirmLogin(replaceUnverified: true) }.buttonStyle(.borderedProminent)
                            Button("Add Account") { store.confirmLogin(addAsNew: true) }
                        }
                    } else { Button("Reconnect") { store.confirmLogin() }.buttonStyle(.borderedProminent) }
                } else { Button("Add Account") { store.confirmLogin() }.buttonStyle(.borderedProminent) }
            }
            Button("Cancel", role: .cancel) { store.cancelLogin() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }
}

struct AccountEditSheet: View {
    let account: UsageAccount
    @EnvironmentObject private var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    init(account: UsageAccount, displayName: String) {
        self.account = account
        _name = State(initialValue: displayName)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Account").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.provider.displayName).font(.subheadline)
                if let identity = account.identity?.description, !identity.isEmpty {
                    Text(identity).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            TextField("Account name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("Badge text and color are edited on usage lines in Menu Bar.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    store.rename(account, name: name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 380)
    }
}
