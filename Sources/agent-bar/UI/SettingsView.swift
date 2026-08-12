import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        Form {
            ForEach(settings.availableProviders) { provider in
                providerSection(provider)
            }

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

                Text("The Claude usage API can be rate-limited if polled too frequently, so very short refresh intervals are usually not useful.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 430, height: settings.availableProviders.count > 1 ? 840 : 640)
    }

    private func providerSection(_ provider: ProviderKind) -> some View {
        let displaySettings = settings.getProviderDisplaySettings(provider)

        return Section("\(provider.displayName) Menu Bar") {
            Toggle(
                "Show in Menu Bar",
                isOn: providerEnabledBinding(provider)
            )
            .accessibilityLabel("\(provider.displayName) Show in Menu Bar")
            .disabled(
                displaySettings.isEnabled
                    && settings.providerSettings.values.filter(\.isEnabled).count == 1
            )

            if displaySettings.isEnabled {
                Toggle(
                    "Badge",
                    isOn: componentBinding(.badge, provider: provider)
                )
                .accessibilityLabel("\(provider.displayName) Badge")
                .disabled(componentIsDisabled(.badge, provider: provider))

                Toggle(
                    "Usage Bars",
                    isOn: componentBinding(.bars, provider: provider)
                )
                .accessibilityLabel("\(provider.displayName) Usage Bars")
                .disabled(componentIsDisabled(.bars, provider: provider))

                Toggle(
                    "Percentage",
                    isOn: componentBinding(.percentage, provider: provider)
                )
                .accessibilityLabel("\(provider.displayName) Percentage")
                .disabled(componentIsDisabled(.percentage, provider: provider))
            } else {
                Text("Hidden from the menu bar. Data refresh is paused.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func providerEnabledBinding(_ provider: ProviderKind) -> Binding<Bool> {
        Binding(
            get: {
                settings.getProviderDisplaySettings(provider).isEnabled
            },
            set: { isEnabled in
                _ = settings.setProviderEnabled(provider, enabled: isEnabled)
            }
        )
    }

    private func componentBinding(
        _ component: MenuBarComponent,
        provider: ProviderKind
    ) -> Binding<Bool> {
        Binding(
            get: {
                settings.getProviderDisplaySettings(provider).visibleComponents.contains(component)
            },
            set: { isVisible in
                _ = settings.setComponentShown(
                    provider,
                    component: component,
                    shown: isVisible
                )
            }
        )
    }

    private func componentIsDisabled(
        _ component: MenuBarComponent,
        provider: ProviderKind
    ) -> Bool {
        let displaySettings = settings.getProviderDisplaySettings(provider)
        return displaySettings.isEnabled == false
            || displaySettings.visibleComponents == [component]
    }
}
