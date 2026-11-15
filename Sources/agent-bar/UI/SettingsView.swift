import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case accounts, menuBar, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accounts: return String(localized: "Accounts")
        case .menuBar: return String(localized: "Menu Bar")
        case .general: return String(localized: "General")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: UsageStore
    @State private var restoring = false
    @State private var tab: SettingsTab
    @StateObject private var launchAtLogin = LaunchAtLogin()
    @ObservedObject private var updates = UpdateStatus.shared
    /// The tallest a tab's content may grow before it scrolls; the window
    /// controller fits it to the display Settings opens on.
    private let maxContentHeight: CGFloat
    init(tab: SettingsTab = .accounts, maxContentHeight: CGFloat = 700) {
        _tab = State(initialValue: tab)
        self.maxContentHeight = maxContentHeight
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $tab) {
                ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.top, 14)
            banners
            // The window takes this height, so each tab gets the room it needs.
            CappedHeight(maximum: maxContentHeight) {
                ScrollView {
                    Group {
                        switch tab {
                        case .accounts: AccountManagementView()
                        case .menuBar: MenuBarSettingsView()
                        case .general: general
                        }
                    }.padding(20)
                }
            }
        }
        .frame(width: 540)
        .alert("Restore the original menu bar layout?", isPresented: $restoring) {
            Button("Cancel", role: .cancel) { }
            Button("Restore") { store.restoreOriginalDisplayConfiguration(); tab = .menuBar }
        } message: { Text("This restores the original groups, account order, selected limits and display options. Your current layout is saved as a backup first.") }
    }

    // Errors and warnings for every tab in one place, under the tab picker.
    @ViewBuilder private var banners: some View {
        if let error = store.errorMessage {
            SettingsBanner(symbol: "exclamationmark.triangle.fill", tint: .red, text: error) { store.errorMessage = nil }
        }
        if let warning = store.displayError {
            SettingsBanner(symbol: "exclamationmark.circle.fill", tint: .orange, text: warning, dismiss: nil)
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
            SettingsSection("Refresh") {
                SettingsRow {
                    HStack {
                        Text("Refresh Interval")
                        Spacer()
                        Picker("Refresh Interval", selection: $settings.refreshIntervalSeconds) {
                            Text("1 minute").tag(60.0); Text("2 minutes").tag(120.0)
                            Text("5 minutes").tag(300.0); Text("10 minutes").tag(600.0)
                        }.labelsHidden().fixedSize()
                    }
                }
                SettingsRow(divided: true) {
                    Text("Accounts used by a visible menu bar group refresh at this interval.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsSection("Language") {
                SettingsRow {
                    HStack {
                        Text("Language")
                        Spacer()
                        Picker("Language", selection: Binding(get: { settings.language }, set: { language in
                            settings.language = language
                            language.apply()
                        })) {
                            ForEach(AppLanguage.allCases) { Text(verbatim: $0.nativeName).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                }
                // Text on screen keeps the language AgentBar started with, so a
                // change applies on restart, all at once.
                if settings.language != AppLanguage.inUse && AppRelauncher.canRelaunch {
                    SettingsRow(divided: true) {
                        HStack {
                            Text("Restart \(AppInfo.name) to show it in the chosen language.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Restart Now") { AppRelauncher.relaunch(reopeningSettings: true) }
                                .disabled(store.isLoggingIn || store.pendingLogin != nil)
                        }
                    }
                }
            }
            SettingsSection("Startup") {
                SettingsRow {
                    HStack {
                        Text("Open at Login")
                        Spacer()
                        Toggle("Open at Login", isOn: Binding(get: { launchAtLogin.isOn }, set: { launchAtLogin.set($0) }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
                if launchAtLogin.needsApproval {
                    SettingsRow(divided: true) {
                        HStack {
                            Text("Allow \(AppInfo.name) in Login Items to finish turning this on.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Login Items") { launchAtLogin.openLoginItems() }
                        }
                    }
                }
                if let error = launchAtLogin.errorMessage {
                    SettingsRow(divided: true) { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            if store.hasOriginalDisplayConfiguration {
                SettingsSection("Recovery") {
                    SettingsRow { Button("Restore Original Groups…") { restoring = true } }
                    SettingsRow(divided: true) {
                        Text("Restore the saved layout from before the UX changes. The current layout is backed up first; account names and colors are kept.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            SettingsSection {
                SettingsRow {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Self.version).foregroundStyle(.secondary).textSelection(.enabled)
                        // Only a build that updates itself has the button.
                        if updates.isAvailable {
                            Button("Check for Updates…") { Updates.checkNow() }
                                .disabled(!updates.canCheck)
                        }
                    }
                }
            }
        }
        .onAppear { launchAtLogin.refresh() }
    }

    // The build number stays out: the build script fixes it at 1, so it tells nothing.
    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development build"
    }
}

/// One message across the top of Settings: an error to dismiss or a standing warning.
private struct SettingsBanner: View {
    let symbol: String
    let tint: Color
    let text: String
    let dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let dismiss { Button("Dismiss", action: dismiss) }
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 20).padding(.top, 12)
    }
}
