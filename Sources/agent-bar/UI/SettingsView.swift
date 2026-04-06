import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        Form {
            Section("Refresh") {
                Picker("Refresh Interval", selection: $settings.refreshIntervalSeconds) {
                    Text("60 sec").tag(60.0)
                    Text("120 sec").tag(120.0)
                    Text("300 sec").tag(300.0)
                    Text("600 sec").tag(600.0)
                }
                Button("Refresh Now") {
                    store.refreshNow()
                }
            }

            Section("Notes") {
                Text("Claude prefers live Claude Code rate_limits from the local status line bridge when available, then falls back to the Anthropic account usage API. Codex comes directly from the Codex account rate limits API.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Text("The This Mac token summaries and recent sessions in the popover are based on local logs on this Mac.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Text("The Claude usage API can be rate-limited if polled too frequently, so very short refresh intervals are usually not useful.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 430, height: 280)
    }
}
