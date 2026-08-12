# Provider-Specific Menu Bar Settings Design

## Status

Approved by the user on 2026-08-11:

- Display settings must be provider-specific.
- Claude and Codex can each be shown or hidden.
- Badge, usage bars, and percentage can each be shown or hidden per provider.
- Hidden providers must stop all automatic and manual refresh work.
- Keep the remaining recommended behavior: safe minimum visibility, persistent settings,
  immediate refresh when a provider is re-enabled, unchanged popover detail, and a working
  Settings button.
- Deliver this work as a second pull request and remove temporary QA/debug artifacts afterward.

Review note: three independent external review routes were attempted before implementation.
They were unavailable because of provider rate limits, a fetch failure, and exhausted model
credits. The fallback self-audit added the normalization and observable call-count criteria
below; no unresolved design decision remains.

## User-visible behavior

The Settings window contains one "Menu Bar" section for every locally available provider.
Each provider section contains:

- `Show in Menu Bar`
- `Badge`
- `Usage Bars`
- `Percentage`

All settings default to enabled, preserving current behavior.

Turning off `Show in Menu Bar` immediately hides that provider's status item and excludes the
provider from timer-driven and manual refreshes. Turning it back on immediately refreshes that
provider and resumes scheduled refreshes.

If a provider load has already started when it is hidden, the underlying operation may finish,
but its returned snapshot is discarded and the hidden provider receives no later refresh calls.

The three visual components are independent. A provider that is enabled must retain at least
one visible component. At least one locally available provider must remain enabled so the
menu-bar-only application remains accessible.

These controls affect only the compact menu bar label. The provider popover retains all quota
cards and numerical detail.

## Architecture

### Persistent settings

`AppSettings` owns a value-type `ProviderDisplaySettings` for each `ProviderKind`:

- `isEnabled`
- `showsBadge`
- `showsUsageBars`
- `showsPercentage`

Values persist in `UserDefaults` under stable provider-specific keys. `AppSettings` exposes
validated mutation methods and SwiftUI bindings. Validation rejects attempts to disable the
last available provider or the last visible component of an enabled provider.

### Status item rendering

`StatusBarCoordinator` passes `AppSettings` to each `StatusBarController`. Controllers observe
their provider's settings, update `NSStatusItem.isVisible`, and rerender immediately.

`MenuBarLabelView` receives the provider-specific display settings and conditionally renders
the badge, stacked usage bars, and percentage. It preserves the existing visual language,
spacing, background, tooltip, and popover.

### Refresh gating

`UsageStore` derives its active provider set from the intersection of locally available
providers and enabled provider settings. Every refresh consults this set before invoking a
provider. Display-only changes do not trigger network or process work. Re-enabling a provider
triggers a deterministic immediate refresh.

Provider implementations are injected through `UsageProviding` so tests can prove which
providers were called without timing sleeps or external API access.

### Settings presentation

The popover replaces `SettingsLink` with an explicit button that activates the accessory
application and invokes SwiftUI's `openSettings` action. This ensures the Settings window is
frontmost when launched from a transient status-item popover.

## Failure handling and constraints

- Persisted invalid states are normalized on load: the first available provider is enabled
  when all available providers were stored as disabled, and the badge is enabled when an
  enabled provider has no stored visible component.
- If only one provider is locally available, it cannot be hidden.
- If only one visual component remains enabled, its control cannot be turned off.
- Unavailable providers are not shown in Settings and are never refreshed.
- A hidden provider retains its last snapshot only for restoration; it performs no work.
- Refresh remains bounded by the existing minimum 60-second interval.

## Verification

Automated tests cover:

- defaults, persistence, and invalid-state normalization;
- provider-specific component combinations;
- hidden-provider refresh suppression and re-enable refresh;
- menu-label component composition;
- Settings activation ordering.

Manual macOS QA covers:

- Settings opens from the real popover;
- independent Claude/Codex controls update status items live;
- every valid badge/bar/percentage combination renders without clipping;
- hidden-provider cache timestamps remain unchanged across refresh;
- injected provider call counts prove hidden providers receive no manual or scheduled load;
- re-enabling refreshes immediately;
- the final installed app contains this feature and the first PR's Codex window fix.
