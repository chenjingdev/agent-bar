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
                    Button("닫기") { store.errorMessage = nil }
                }
            }
            if store.isLoggingIn || store.pendingLogin != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if store.isLoggingIn { ProgressView().controlSize(.small) }
                    Text(store.loginMessage ?? "")
                    if let pending = store.pendingLogin {
                        Text(pending.account.identity?.description.isEmpty == false
                             ? pending.account.identity!.description : "제공자가 계정 정보를 반환하지 않았습니다.")
                            .font(.headline).textSelection(.enabled)
                        if pending.replacing != nil {
                            if store.reconnectionComparison == .different {
                                Text("기존 연결과 다른 계정입니다. 기존 계정을 보존하고 새 계정으로 추가할 수 있습니다.")
                                Button("새 계정으로 추가") { store.confirmLogin(addAsNew: true) }
                            } else if store.reconnectionComparison != .same {
                                Text("동일 계정임을 자동으로 확정할 수 없습니다. 표시된 계정이 맞는지 확인하세요.")
                                Button("이 계정으로 재연결 확인") { store.confirmLogin(replaceUnverified: true) }
                                Button("별도 계정으로 추가") { store.confirmLogin(addAsNew: true) }
                            } else { Button("재연결 완료") { store.confirmLogin() } }
                        } else { Button("이 계정 등록") { store.confirmLogin() }.buttonStyle(.borderedProminent) }
                    }
                    Button("취소", role: .cancel) { store.cancelLogin() }
                }
            }

            ForEach(store.accounts) { account in
                HStack {
                    Button { select(account) } label: {
                        HStack {
                            ProviderBadge(provider: account.provider)
                            VStack(alignment: .leading) {
                                Text(account.title).font(.headline).lineLimit(1)
                                Text(account.isManaged ? (account.identity?.description ?? "") : "현재 CLI 로그인을 따라갑니다.")
                                    .font(.caption).foregroundStyle(AppTheme.muted).lineLimit(2)
                                if !store.refreshAccountIDs.contains(account.id) {
                                    Text("숨김 · 새로고침 중단").font(.caption).foregroundStyle(AppTheme.muted)
                                }
                                if account.deletionPending { Text("삭제 대기").font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer()
                        }
                    }.buttonStyle(.plain)
                    Menu {
                        Button("이름 변경") { editing = account }
                        Divider()
                        Text("메뉴 막대에 표시할 사용량")
                        AccountMetricOptions(account: account).disabled(account.deletionPending)
                        Divider()
                        if account.isManaged {
                            Button("재연결") { store.startLogin(account.provider, replacing: account) }
                                .disabled(store.isLoggingIn || store.pendingLogin != nil || account.deletionPending)
                            Button(account.deletionPending ? "삭제 재시도" : "삭제", role: .destructive) { deleting = account }
                        }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }.padding(12).background(GlassCardBackground(cornerRadius: 16))
            }
            Menu {
                ForEach(ProviderKind.allCases) { provider in
                    Button(provider.displayName) { store.startLogin(provider) }
                }
            } label: { Label("계정 추가", systemImage: "plus") }
                .disabled(store.isLoggingIn || store.pendingLogin != nil || store.storageUnavailable)
            if !store.registry.cleanupPending.isEmpty && !store.isLoggingIn && store.pendingLogin == nil {
                Button("완료되지 않은 연결 정리 재시도") { Task { await store.retryCleanup() } }
            }
        }
        .sheet(item: $editing) { account in AccountRenameSheet(account: account) }
        .alert("AgentBar에서 계정을 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("취소", role: .cancel) { deleting = nil }
            Button("삭제", role: .destructive) {
                if let account = deleting { Task { await store.delete(account) } }; deleting = nil
            }
        } message: { Text("선택한 계정의 AgentBar 전용 로그인과 사용량 캐시가 삭제됩니다. 외부 CLI 로그인은 유지됩니다.") }
    }
}

// Both entry points use the same persisted metric selection and rename sheet.
struct AccountMetricOptions: View {
    let account: UsageAccount
    @EnvironmentObject private var store: UsageStore
    var body: some View {
        ForEach(DisplayMetric.all(store.snapshot(for: account))) { metric in
            Toggle(metric.title + (metric.window?.utilization == nil ? " · 데이터 대기" : ""), isOn: Binding(
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
            Text("계정 이름 변경").font(.headline)
            TextField("계정 이름", text: $name)
            HStack {
                Button("취소") { dismiss() }
                Spacer()
                Button("저장") { store.rename(account, name: name); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 350)
    }
}
