import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: UsageStore
    var body: some View {
        Form {
            Section("Refresh") {
                Picker("Refresh Interval", selection: $settings.refreshIntervalSeconds) {
                    Text("60 sec").tag(60.0); Text("120 sec").tag(120.0)
                    Text("300 sec").tag(300.0); Text("600 sec").tag(600.0)
                }
                Button("Refresh Now") { store.refreshNow() }.disabled(store.isRefreshing)
            }
            Section("메뉴 막대") {
                Stepper("표시 개수: \(store.displayConfiguration.activeCount)", value: Binding(
                    get: { store.displayConfiguration.activeCount },
                    set: { count in store.updateDisplay { $0.resize(count) } }), in: 1...Int.max)
                Text("개수를 줄여도 설정은 보존됩니다. 각 표시의 내용은 해당 표시 메뉴에서 선택하세요.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.displayWidthWarning { Text("항목이 많아 메뉴 막대 공간을 많이 사용합니다.").font(.caption).foregroundStyle(.orange) }
                if let error = store.displayError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }.formStyle(.grouped).padding(20).frame(width: 430, height: 320)
    }
}
