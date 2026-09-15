# agent-bar

A local macOS menu bar app for monitoring **Codex and Claude Code subscription limits across multiple accounts**.

## Accounts and menu bar

Click a menu bar item to see the original usage cards for every assigned account, in order. The fixed footer offers **Accounts · Settings · Quit**.

- **Settings** controls the refresh interval and number of menu bar items. Reducing the count hides trailing items without losing their settings; increasing it restores them.
- The **sliders menu** on each usage popover controls service badges, bars, individual percentages, and **1–6 vertical rows** (default 2). Extra rows flow into columns within the same menu bar item.
- Assign any combination of Claude and Codex accounts. An account belongs to only one item; other active assignments are excluded from the picker. Use **Move to Another Item** to move it atomically, or **Move Up / Move Down** to reorder it.
- Select **5h, Weekly, and model-specific limits per account**. A selected but unavailable limit occupies no bar; it appears automatically when data becomes available. This includes Codex 5h. Each visible limit has its own percentage.
- Same-provider accounts in a combined item have numbered badges, matching their detail headings. Tooltip/accessibility text identifies every account and limit.
- An empty/hidden item remains reachable as **AB · number**. A non-blocking notice appears when AgentBar's combined width exceeds 40% of its display width; this is a heuristic, not a measurement of space available beside other apps.
- **Accounts** adds accounts and provides rename, menu-bar metric selection, reconnect, and delete through each row's ellipsis menu. The display-options account submenu also offers Rename. Each add/reconnect uses a fresh isolated macOS OAuth window; no shared-browser fallback is used.
- **Current CLI account** follows the external CLI login and never changes its credentials. A managed account's delete operation removes only its AgentBar credentials/cache.

The first display migration preserves existing provider visibility and badge/bar/percentage preferences. Hidden providers retain an inactive item; existing multi-account display settings are not migrated again. Other accounts remain available in Accounts. Reopening AgentBar opens the existing Settings window.

## Requirements

- macOS 14 or later; Swift 6.2 or later to build.
- `/usr/bin/python3` for isolated CLI process-group startup and cleanup.
- Official Codex and/or Claude Code CLI installed. Homebrew installations are preferred over user launch wrappers.
- A supported subscription login for every account to monitor. API keys and API billing usage are outside this app's scope.

The implementation was developed against Codex CLI 0.154.0 and Claude Code 2.1.263. Provider interfaces can change with CLI releases.

## How authentication and usage work

**Codex:** AgentBar launches the official `codex app-server` in a separate `CODEX_HOME` for each managed account. It uses managed ChatGPT OAuth login, `account/read`, and `account/rateLimits/read`. Managed accounts use the CLI's file credential storage in a private directory. Existing CLI launch wrappers and routing configuration are not modified.

**Claude:** A private per-login browser-opener helper captures the CLI's automatic OAuth URL for the macOS authentication session. The URL is validated and immediately removed from disk. The CLI keeps ownership of its PKCE state, local callback, and token exchange. AgentBar launches `claude auth login --claudeai` with a separate `CLAUDE_CONFIG_DIR`. It verifies the JSON login status and uses that directory's OAuth credential to query Anthropic's usage endpoint. The directory-specific Keychain entry is preferred, with the CLI's credential file as fallback. It never falls back to another account's default Keychain entry.

Claude credentials can expire. This version provides a reconnect button and does not promise unattended renewal. It never sends model prompts to keep authentication alive.

The old shared Claude status-line bridge is not used by the multi-account reader because its samples do not identify their owning account. The optional legacy script remains in the repository but is not installed or reconfigured by this app.

## Data, refresh, and privacy

Account data lives under `~/.agentbar/multi-account-v1/`:

- `accounts.json`: versioned account metadata, representative selections, and pending cleanup records. No passwords or tokens.
- `display-v1.json`: ordered display items, preserved inactive items, account metric selections, and rendering preferences. No credentials.
- `credentials/<UUID>/`: per-login CLI authentication/configuration directory. Its path remains fixed after login because Keychain storage may depend on it.
- `usage/<account UUID>/<credential UUID>/`: isolated usage cache and last-known-good snapshot.

Directories use mode `0700`; app-written files use `0600`. OAuth tokens stay in the CLI-managed credential store and are never written to usage caches or app logs. Treat credential directories and local backups as private.

The existing refresh interval is preserved (60, 120, 300, or 600 seconds). Accounts hidden from active menu bar items are excluded from both automatic and manual refresh. Turning off every display component or deselecting every metric also pauses the account. Selected but unavailable metrics continue polling so they can appear later. Showing an account again schedules its refresh while respecting retry cooldowns. Requests are serialized per provider. Changing the refresh interval applies immediately. Provider retry deadlines are preserved even if a response arrives after an account is hidden; manual refresh does not bypass a cooldown. Failures are isolated to the affected account.

Unknown usage is `--`, not `0%`. Old values retain their original timestamp and are marked stale. Existing global cache files are not imported into managed accounts. Current-CLI caches require a matching credential before reuse; Codex's current-CLI slot does not reuse a persisted snapshot.

No backend, telemetry, browser-cookie extraction, or session-log scanning is added. Authentication and usage requests go to the relevant provider through its CLI or usage endpoint.

## Build and install

```bash
swift test
./scripts/build-app.sh
```

To install, first quit the existing AgentBar, then run:

```bash
./scripts/build-app.sh --install
open ~/Applications/AgentBar.app
```

The installer copies the previous app, its preferences, and existing multi-account data to:

`~/Library/Application Support/AgentBar/Backups/<timestamp>/`

It verifies the staged app's signature before replacement and refuses to replace a running app. The bundle is ad-hoc signed for local use, not notarized for public distribution.

To roll back, quit AgentBar, restore `AgentBar.app` from the selected backup, and restore the corresponding AgentBar preferences if needed. Preserve the newer multi-account data separately before restoring its backup. Never restore over external `~/.codex`, `~/.claude`, or unrelated Keychain entries.

## Validation

`swift test` covers hidden-account refresh suspension/resumption, upstream preference migration, CLI process-tree cleanup, account storage and permissions, representative persistence, cache isolation, unknown-versus-zero values, credential mismatches, delayed-result rejection, process cancellation/timeouts, and SwiftUI rendering.

An explicit installed-CLI probe can exercise Codex OAuth startup and cancellation **without opening a browser or signing in**:

```bash
AGENTBAR_LIVE_AUTH_PROBE=1 swift test --filter isolatedCodexLoginCancellation
```

Real OAuth completion, multiple-account usage, and native UI interaction are separate manual acceptance checks. Passing unit tests or receiving an OAuth URL does not establish those results.

See [validation coverage and manual acceptance limits](docs/validation/multi-account/README.md).
