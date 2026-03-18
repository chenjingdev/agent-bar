import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        Form {
            Section("Refresh") {
                Picker("Refresh Interval", selection: $settings.refreshIntervalSeconds) {
                    Text("10 sec").tag(10.0)
                    Text("30 sec").tag(30.0)
                    Text("60 sec").tag(60.0)
                    Text("120 sec").tag(120.0)
                }
                Button("Refresh Now") {
                    store.refreshNow()
                }
            }

            Section("Notes") {
                Text("상단 5시간/주간 퍼센트는 Claude와 Codex 계정에서 직접 조회합니다.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Text("팝오버의 This Mac 토큰 요약과 최근 세션은 이 Mac에 남은 로컬 로그를 보조 정보로 보여줍니다.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 430, height: 280)
    }
}
