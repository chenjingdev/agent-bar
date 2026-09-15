import SwiftUI

struct AccountListView: View {
    let provider: ProviderKind
    @EnvironmentObject private var store: UsageStore
    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let account = store.accounts(for: provider).first(where: { $0.id == selectedID && !$0.deletionPending }) {
                HStack {
                    Button { selectedID = nil } label: { Label("계정 목록", systemImage: "chevron.left") }
                    Spacer()
                    Text(account.title).lineLimit(1).font(.headline)
                }.padding(12)
                ProviderPopoverView(snapshot: store.snapshot(for: account))
            } else {
                HStack {
                    Text("\(provider.displayName) 계정").font(.title2.bold())
                    Spacer()
                    Button { store.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(store.isRefreshing)
                }.padding(.horizontal, 16).frame(height: 64)
                ScrollView {
                    VStack(spacing: 12) {
                        if store.accounts(for: provider).isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 36)).foregroundStyle(.secondary)
                                Text("연결된 계정 없음").font(.headline)
                                Text("설정에서 계정을 추가하세요.").foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 50)
                        }
                        ForEach(store.accounts(for: provider)) { account in
                            accountRow(account)
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 12)
                }.frame(height: 447)
                Divider()
                HStack {
                    Button("계정 관리…") { SettingsWindowController.shared.show() }
                    Spacer()
                    Button("종료") { NSApplication.shared.terminate(nil) }
                }.padding(.horizontal, 16).frame(height: 56)
            }
        }
        .frame(width: 392, height: 568)
        .background(AppTheme.surface)
        .preferredColorScheme(.dark)
    }

    private func accountRow(_ account: UsageAccount) -> some View {
        let snapshot = store.snapshot(for: account)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { selectedID = account.id } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.title).font(.headline).lineLimit(1)
                        if let identity = account.identity, !identity.description.isEmpty {
                            Text(identity.description).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(account.deletionPending)
                Button { store.selectRepresentative(account) } label: {
                    Image(systemName: store.representative(for: provider)?.id == account.id ? "star.fill" : "star")
                        .foregroundStyle(.orange)
                }.help("메뉴 막대 대표 계정으로 표시").disabled(account.deletionPending)
            }
            HStack {
                window("5시간", snapshot.fiveHour)
                Spacer()
                window("주간", snapshot.weekly)
            }
            HStack {
                if account.deletionPending { Text("삭제 대기").foregroundStyle(.red) }
                else if snapshot.requiresLogin { Text("재연결 필요").foregroundStyle(.orange) }
                else if store.refreshingAccounts.contains(account.id) { Text("확인 중…").foregroundStyle(.secondary) }
                else if snapshot.isStale { Text("최신 값 확인 필요").foregroundStyle(.orange) }
                else { Text("업데이트 \(TokenFormatters.relativeUpdateString(updatedAt: snapshot.updatedAt))").foregroundStyle(.secondary) }
                Spacer()
                if snapshot.requiresLogin && account.isManaged {
                    Button("재연결") {
                        SettingsWindowController.shared.show()
                        store.startLogin(provider, replacing: account)
                    }.disabled(store.isLoggingIn || store.pendingLogin != nil)
                } else { Button("상세") { selectedID = account.id }.disabled(account.deletionPending) }
            }.font(.caption)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
    }
    private func window(_ title: String, _ window: WindowSummary?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title)  \(TokenFormatters.percentageString(for: window?.utilization))").font(.subheadline.bold())
            Text(window?.resetAt.map { TokenFormatters.resetLabelString(resetAt: $0) } ?? "초기화 시각 미확인")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}
