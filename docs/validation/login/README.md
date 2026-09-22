# Account connection validation — 2026-09-22

Changes:

- All usage readers require an explicit AgentBar credential directory. Startup never imports CLI accounts; provider discovery checks executable availability only. Legacy unconnected rows keep their names and layouts but require a separate sign-in and are excluded from polling.
- Account rows show login email, provider and organization directly. All account menus contain Rename, Reconnect and Delete.

- The normal default browser is used for sign-in. Codex adds `prompt=login` without re-encoding the other OAuth parameters. Private Chromium/ASWebAuthenticationSession windows are an explicit fallback via Use Private Window Instead.
- Completion/cancellation stops an owned private browser and removes its temporary profile; normal browser tabs remain user-owned. Late browser callbacks cannot cancel another login, and CLI credential cleanup keeps the attempt busy until it finishes.
- Claude connection success requires saving a usable credential in the isolated account directory. Keychain authorization is allowed only during explicit connection completion; polling stays noninteractive.
- Expired managed Claude credentials are renewed with the existing refresh token. Concurrent requests share one exchange; rotated tokens survive UI cancellation; changed/deleted files are not overwritten. External CLI credentials are not refreshed.

Validation on this Mac:

- 148 regression tests passed, including session lifecycle, refresh rotation/failures/concurrency, account isolation, credential persistence, legacy-row migration and absence of automatic CLI imports.
- Installed Claude Code 2.1.278 and Codex 0.154.0 both produced valid authorization URLs and handled cancellation without signing in.
- An additional opt-in installed-browser test ran two real Chromium sessions against a local HTTP fixture. Both began without the previous session's cookie, retained their own cookie through the redirect, delivered the HTTP loopback callback, and removed their temporary profiles after completion.
- The installed Accounts screen was checked visually: identity details fit beneath all account names, the legacy unconnected row shows Sign-in required, and existing account names/order are preserved.
- The optional private flow opened a separate incognito browser process using its own profile. Cancelling in Accounts returned the UI to an enabled Add Account button.
- Release build and installed app signature verification passed. Existing app and settings were backed up by the installer.

Commands:

```sh
swift test --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
AGENTBAR_LIVE_AUTH_PROBE=1 AGENTBAR_LIVE_BROWSER_PROBE=1 swift test \
  --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --filter 'installedBrowserKeepsCookiesIsolatedAndDeliversLoopbackCallback|installedClaudeUsesCapturedAutomaticCallback|isolatedCodexLoginCancellation'
```

The live browser probe opens and closes two temporary browser windows and sends no account credentials. The live CLI probes never open provider pages. macOS SDK 26.5/native SwiftPM was used because this machine's default SDK 27 installation is missing the SwiftUIMacros plugin.

Actual provider sign-in completion, Google/SSO authentication, the interactive Keychain grant, and Safari fallback require manual acceptance. These checks did not enter passwords, register another real account, or establish successful renewal of the user's already-invalid credentials.

Reference implementation review:

- Orca `4aaa6c7fb48513e1e1e037eb648f0ab81826aeb3`: `claude-login-session.ts` runs official CLI login in a temporary configuration directory; `claude-command-process.ts` sets both configuration and secure-storage directories. AgentBar uses the same explicit storage boundary, without Orca's legacy shared-Keychain backup/restore behavior.
- OpenCodex `7c625fc9755c9824653ab944190e243091a2c85c`: `src/codex/auth-api/login-flow.ts` enables `forceLogin`; `src/oauth/chatgpt.ts` adds `prompt=login`; `src/lib/open-url.ts` uses the normal system browser. Its Anthropic flow adds no equivalent forced-login parameter.
- Direct browser check on this Mac: the Codex URL with `prompt=login` displayed saved accounts and Sign in with another account in ordinary Chrome. Claude ignored the same parameter and displayed its existing approval page, whose Switch account link targets `claude.ai/logout` with a return URL. AgentBar leaves that provider action to the user. No approval was submitted during these checks.
