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
                    Section("Appearance") {
                        Picker("Theme", selection: $settings.theme) {
                            ForEach(AppearanceTheme.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        Text("Applies to AgentBar's windows and popovers. Menu bar items follow the menu bar.")
                            .font(.caption).foregroundStyle(.secondary)
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
    }
}
