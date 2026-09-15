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
            Section("Menu Bar") {
                Stepper("Items: \(store.displayConfiguration.activeCount)", value: Binding(
                    get: { store.displayConfiguration.activeCount },
                    set: { count in store.updateDisplay { $0.resize(count) } }), in: 1...Int.max)
                Text("Reducing the count preserves settings. Configure each item from its display menu.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.displayWidthWarning { Text("These items use a large portion of the menu bar.").font(.caption).foregroundStyle(.orange) }
                if let error = store.displayError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }.formStyle(.grouped).padding(20).frame(width: 430, height: 320)
    }
}
