# Multi-account validation

## Automated checks

On macOS, `AGENTBAR_QA_ARTIFACT_DIR=/tmp/agentbar-pr-final-ui AGENTBAR_LIVE_AUTH_PROBE=1 swift test` passed 95 tests across 18 suites on 2026-09-15.
`git diff --check` and `zsh -n scripts/build-app.sh` also passed.
The integrated release bundle was built with `./scripts/build-app.sh` and signature-verified on 2026-09-15. It was not installed over the running personal app. Earlier local installation acceptance is listed separately below.

Coverage includes account registry persistence and permissions; credential/cache isolation;
identity comparison; rejection of results from replaced credentials; process cancellation,
and timeouts; the authentication callback actor hop; display assignment,
movement, inactive-item restoration, metric availability, and native image rendering.

Optional CLI probes require `AGENTBAR_LIVE_AUTH_PROBE=1`. They exercise OAuth startup
and cancellation without signing in. Ordinary tests do not establish live authentication.
Rendering artifacts can be generated with `AGENTBAR_QA_ARTIFACT_DIR=<directory> swift test`.
Fixture accounts and usage values are synthetic.

## Manual acceptance already performed

- One managed Claude account and two managed Codex accounts completed authentication.
- Both Codex accounts returned independent fresh usage from separate credential/cache directories.
- The Claude login window requested a fresh login independently of the shared browser session.
- Cancelling Codex authentication returned to the app without terminating it after the callback fix.
- Claude deletion, including exact Keychain cleanup after an invalid-owner error, and subsequent re-add succeeded.
- Global CLI credential/configuration fingerprints were unchanged during the checked installations and login attempts.
- Native Settings and the usage popover were inspected. Rendered fixtures cover 1–6 rows,
  both display scales, and all eight badge/bar/percentage combinations.

## Remaining acceptance limits

- A second real Claude account was unavailable; two-Claude-account isolation is not live-verified.
- The real Codex accounts did not report a 5-hour window; its later appearance is fixture-tested.
- Native rename and metric selection from both menus, account hiding/showing, and Accounts/Usage
  navigation were exercised in an isolated UI harness. Its only source difference was opening Accounts
  rather than Settings at startup; the views, menus, and persistence code were the product code.
  The harness used a separate bundle ID, defaults suite, and synthetic account store. It did not verify
  physical menu-bar click coordinates or complete the full account-move/reconnect interaction matrix.
- Earlier reports of an invisible OAuth window and one failed Claude-add attempt did not yield
  independent root causes; subsequent attempts succeeded. Do not treat those symptoms as fully explained.
- Full real-account OAuth completion was checked before upstream integration. After integration,
  installed-CLI startup/cancel probes passed for both providers; full login was not repeated.
- New interface strings use English consistently with upstream. Additional translations are not included.

## Upstream integration

Integrated on top of `a0634a2`, retaining its dependency pins and duration-based Codex mapping,
including mixed legacy/tagged windows and absent weekly windows. Provider preferences migrate once
into active/inactive items. Hiding an account stops manual and automatic polling; queued requests
are excluded, in-flight results are discarded, and newly shown accounts are queued without
refetching unaffected accounts. Unavailable but selected metrics remain eligible for polling.
Provider retry delays still apply. An already-dispatched HTTP request may finish in the background.

The provider-level visibility tests were ported to account-level scheduling with injected loaders.
The old provider-segment click tests now check each physical item's actual popover root and
restoration after hiding. Pure component layout tests remain. Launcher tests now exercise CodexRPC
and verify descendant cleanup, native/env-node launchers, timeout, and redaction of raw provider errors.
Registry-load failure is covered to ensure existing display assignments are not erased.

## Rendered fixtures

These images contain synthetic accounts and cached sample values, not live account information.

<img src="display-detail.png" alt="Multi-account usage popover with original usage cards" width="392" />

<img src="status-3-2x.png" alt="Fixture menu bar item with three rows per column" width="132" />

## Review fixes verified before submission

- The refresh timer uses the emitted new interval, rather than the previous stored value. The
  regression that previously observed 120 seconds after selecting 300 now passes.
- Retry deadlines are retained for the matching credential generation even when hiding prevents
  publication of its usage response. The hidden in-flight rate-limit regression now passes.
- Claude receives the account cancellation control, passes it through CLI status checking, and checks
  it again before starting subsequent credential/HTTP steps. Tests cover pre-cancellation and
  cancellation during the status step. Already-sent HTTP requests can finish; their usage is discarded.
- Re-showing an account clears the paused explanation while preserving sign-in-required state.
- CLI tests separate initialization from the requested response timeout and assert the specific
  sanitized provider error. Process cleanup remains tested against SIGTERM-ignoring descendants.
