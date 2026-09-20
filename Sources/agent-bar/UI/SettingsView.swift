import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case accounts, menuBar, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accounts: return "Accounts"
        case .menuBar: return "Menu Bar"
        case .general: return "General"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: UsageStore
    @State private var restoring = false
    @State private var tab: SettingsTab
    init(tab: SettingsTab = .accounts) { _tab = State(initialValue: tab) }
    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $tab) {
                ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.top, 14)
            switch tab {
            case .accounts:
                ScrollView { AccountManagementView().padding(20) }
            case .menuBar:
                MenuBarSettingsView()
            case .general:
                Form {
                    Section("Refresh") {
                        Picker("Refresh Interval", selection: $settings.refreshIntervalSeconds) {
                            Text("60 sec").tag(60.0); Text("120 sec").tag(120.0)
                            Text("300 sec").tag(300.0); Text("600 sec").tag(600.0)
                        }
                        Text("Only accounts used by visible groups are refreshed. Hidden groups keep their settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.hasOriginalDisplayConfiguration {
                        Section("Recovery") {
                            Button("Restore Original Groups…") { restoring = true }
                            Text("Restore the saved layout from before the UX changes. The current layout is backed up first; account names and colors are kept.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.formStyle(.grouped)
            }
            if tab != .accounts {
                if let error = store.errorMessage {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Button("Dismiss") { store.errorMessage = nil }
                    }.padding(10)
                }
            }
            if let error = store.displayError {
                Text(error).font(.caption).foregroundStyle(.orange).padding(10)
            }
        }.frame(width: 540, height: 660)
        .alert("Restore the original menu bar layout?", isPresented: $restoring) {
            Button("Cancel", role: .cancel) { }
            Button("Restore") { store.restoreOriginalDisplayConfiguration(); tab = .menuBar }
        } message: { Text("This restores the original groups, account order, selected limits and display options. Your current layout is saved as a backup first.") }
    }
}
