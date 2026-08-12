# Provider-Specific Menu Bar Settings Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent, provider-specific menu bar visibility controls, stop refresh work for
hidden providers, and make the Settings window reliably open from the status-item popover.

**Architecture:** `AppSettings` owns validated value settings for each available provider.
`UsageStore` and `StatusBarController` observe the same provider settings so refresh work and
visible status items cannot diverge. Small pure seams describe menu-label composition and
Settings activation, while injected `UsageProviding` implementations make refresh gating
deterministic to test.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, Combine, UserDefaults, Swift Testing, Swift Package
Manager.

---

## Chunk 1: Persistent provider settings

### Task 1: Establish the Swift test target

**Files:**
- Modify: `Package.swift`
- Create: `Tests/agent-barTests/AppSettingsTests.swift`

- [ ] Add the pinned Swift Testing dependency and `agent_barTests` test target used by PR1.
- [ ] Add tests proving all available providers default to enabled with badge, bars, and
  percentage enabled.
- [ ] Add a suite-local `UserDefaults` domain and clear it without sleeps.
- [ ] Run `swift test --filter AppSettingsTests`; expect compile failures because the new
  provider settings API does not exist.

### Task 2: Implement provider settings and persistence

**Files:**
- Modify: `Sources/agent-bar/Core/AppSettings.swift`
- Test: `Tests/agent-barTests/AppSettingsTests.swift`

- [ ] Add:

```swift
enum MenuBarComponent: CaseIterable, Equatable {
    case badge
    case usageBars
    case percentage
}

struct ProviderDisplaySettings: Equatable {
    var isEnabled: Bool
    var showsBadge: Bool
    var showsUsageBars: Bool
    var showsPercentage: Bool

    static let defaultValue = ProviderDisplaySettings(
        isEnabled: true,
        showsBadge: true,
        showsUsageBars: true,
        showsPercentage: true
    )

    var visibleComponents: [MenuBarComponent] { ... }
}
```

- [ ] Initialize `AppSettings` with `availableProviders`, load stable provider-specific keys,
  and normalize all-disabled/all-components-hidden persisted states.
- [ ] Add validated `setProviderEnabled(_:provider:)` and
  `setComponent(_:isVisible:provider:)` mutations.
- [ ] Add tests for persistence, last-provider protection, last-component protection, and
  invalid-state normalization.
- [ ] Run `swift test --filter AppSettingsTests`; expect all tests to pass.

## Chunk 2: Refresh gating

### Task 3: Write deterministic hidden-provider refresh tests

**Files:**
- Modify: `Sources/agent-bar/Providers/UsageProviding.swift`
- Create: `Tests/agent-barTests/UsageStoreProviderVisibilityTests.swift`
- Modify later: `Sources/agent-bar/Core/UsageStore.swift`

- [ ] Make `UsageProviding` safe to inject across Swift concurrency boundaries.
- [ ] Add actor-backed recording providers that return fixed snapshots and expose call counts.
- [ ] Instantiate `UsageStore` without an automatic first refresh, hide Claude, invoke and
  await refresh, then assert Claude count is zero and Codex count is one.
- [ ] Re-enable Claude, await the exact refresh completion, and assert Claude count becomes one.
- [ ] Run the focused test; expect compile failures because provider injection and awaitable
  refresh do not exist.

### Task 4: Gate every refresh through active provider settings

**Files:**
- Modify: `Sources/agent-bar/Core/UsageStore.swift`
- Modify: `Sources/agent-bar/App/AppContainer.swift`
- Test: `Tests/agent-barTests/UsageStoreProviderVisibilityTests.swift`

- [ ] Inject `UsageProviding` values with production defaults.
- [ ] Make refresh awaitable and guard overlapping refreshes without timing waits.
- [ ] Derive active providers from available providers intersected with enabled settings.
- [ ] Ensure timer and manual refresh paths use the same active-provider gate.
- [ ] Map provider-settings changes to enabled-provider sets so visual-only changes do not
  trigger data work and newly enabled providers refresh immediately.
- [ ] Move the initial refresh trigger to `AppContainer` so tests can construct an idle store.
- [ ] Run focused tests; expect hidden-provider and re-enable cases to pass.

## Chunk 3: Menu label and status items

### Task 5: Write provider-specific composition tests

**Files:**
- Create: `Tests/agent-barTests/MenuBarLabelCompositionTests.swift`
- Modify later: `Sources/agent-bar/UI/MenuBarLabelView.swift`

- [ ] Test all seven valid combinations of badge, bars, and percentage.
- [ ] Assert each combination produces the exact ordered `MenuBarComponent` list.
- [ ] Render representative views through `NSHostingView` and assert positive, bounded fitting
  sizes.
- [ ] Run the focused test; expect compile failures until the view accepts display settings.

### Task 6: Render settings and visibility live

**Files:**
- Modify: `Sources/agent-bar/UI/MenuBarLabelView.swift`
- Modify: `Sources/agent-bar/App/StatusBarController.swift`
- Modify: `Sources/agent-bar/App/AgentBarApp.swift`
- Test: `Tests/agent-barTests/MenuBarLabelCompositionTests.swift`

- [ ] Pass `ProviderDisplaySettings` into `MenuBarLabelView`.
- [ ] Conditionally render badge, stacked bars, and percentage in component order.
- [ ] Pass `AppSettings` through coordinator/controller construction.
- [ ] Observe the current provider's settings, set `NSStatusItem.isVisible`, and rerender on
  display changes.
- [ ] Run focused and full tests.

## Chunk 4: Settings presentation

### Task 7: Lock the Settings activation regression

**Files:**
- Create: `Tests/agent-barTests/SettingsWindowPresenterTests.swift`
- Modify later: `Sources/agent-bar/UI/ProviderPopoverView.swift`

- [ ] Add a small `SettingsWindowPresenter` seam accepting activation and open closures.
- [ ] Test that presentation invokes activation before opening exactly once.
- [ ] Run the focused test; expect a compile failure because the presenter does not exist.

### Task 8: Build the provider-specific Settings UI

**Files:**
- Modify: `Sources/agent-bar/UI/ProviderPopoverView.swift`
- Modify: `Sources/agent-bar/UI/SettingsView.swift`
- Test: `Tests/agent-barTests/SettingsWindowPresenterTests.swift`

- [ ] Replace `SettingsLink` with a button using `OpenSettingsAction` and explicit app
  activation.
- [ ] Render one provider section for every available provider.
- [ ] Bind `Show in Menu Bar`, `Badge`, `Usage Bars`, and `Percentage` to validated settings
  mutations.
- [ ] Disable the last-provider and last-component controls rather than allowing invalid
  transitions.
- [ ] Keep refresh interval/manual refresh controls; manual refresh only reaches active
  providers.
- [ ] Expand the window only as required by the new controls and preserve the existing Form
  styling.
- [ ] Run focused and full tests.

## Chunk 5: Verification and delivery

### Task 9: Automated gates

**Files:**
- All changed Swift and test files

- [ ] Run LSP diagnostics on every changed Swift file.
- [ ] Run `swift test` once; require zero failures.
- [ ] Run `swift build -c release --product agent-bar`; require exit zero.
- [ ] Run `./scripts/build-app.sh`; require strict code-sign verification on the bundle.

### Task 10: Manual macOS QA

- [ ] Launch an isolated QA bundle through LaunchServices.
- [ ] Open Settings from the real provider popover.
- [ ] Verify independent Claude/Codex provider visibility.
- [ ] Verify all seven valid label combinations render without clipping for each provider.
- [ ] Confirm hidden-provider injected call counts and live cache timestamps remain unchanged.
- [ ] Confirm re-enabling performs an immediate refresh.
- [ ] Capture fresh screenshots and obtain two read-only visual-review verdicts.
- [ ] Terminate every QA process and restore user preferences.

### Task 11: Independent PR2 and integrated install

- [ ] Inspect current commit-message style and the complete diff.
- [ ] Commit the settings behavior, tests, and approved design/plan atomically.
- [ ] Push `feature/provider-display-settings` to the user's fork.
- [ ] Open a second PR against `chenjingdev/agent-bar:main`; verify it excludes PR1 commits.
- [ ] Build a temporary integration worktree containing PR1 plus PR2, resolve by intent, run
  tests/build, and install `/Users/buggie/Applications/AgentBar.app`.
- [ ] Verify the installed bundle includes both the Codex-window fix and provider settings.

### Task 12: Cleanup

- [ ] Remove isolated QA bundles, screenshots/logs not required for the PR, temporary
  integration worktree/branch, and build products.
- [ ] Keep only source, tests, design/plan documents, commits, installed app, and PR metadata.
- [ ] Verify PR2 worktree and original PR1 worktree are clean and no AgentBar/QA process remains.
