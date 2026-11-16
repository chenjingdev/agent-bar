# AgentBar for Windows

A notification-area app for Windows 11 (x64): the limits, reset times and reset coupons of your Claude Code and
Codex accounts, and switching the Claude Code account. It is separate code from the Mac app in `Sources/`, and asks
Anthropic and Codex the same way the Mac app does.

## How it is made

There is nothing to compile. The install file is the official Node.js `node.exe`, byte for byte as the OpenJS
Foundation signed it, and the scripts in `app/`. Windows is called from the scripts with `node:ffi`: the
notification-area icon, the panel (drawn with GDI and GDI+) and its menus. AgentBar starts without a console window
through `conhost.exe --headless`.

This is so that Smart App Control has nothing to judge: it blocks unsigned programs it does not know, and it judges
each new build of one again. Here the only program is signed by its makers and the rest is text.

| | |
| --- | --- |
| `app/main.mjs` | the start: icon, panel, schedule |
| `app/store.mjs` | the accounts: add, remove, switch, use a coupon |
| `app/claude.mjs`, `app/codex.mjs`, `app/coupons.mjs` | asking Anthropic and Codex's app-server |
| `app/win32.mjs`, `app/view.mjs`, `app/words.mjs` | Windows calls, the panel's layout, Korean and English words |
| `install.ps1`, `uninstall.ps1`, `build.sh` | install, remove, build the install file |

## Where things are kept

- Claude Code's own sign-in (`%USERPROFILE%\.claude`) is the account in use. AgentBar reads it there.
- Other Claude accounts wait in `%USERPROFILE%\.agentbar\windows-v1\claude\<id>`. Switching hands the chosen one to
  Claude Code (`claude auth login`, Claude Code 2.1.309 or later) and puts the previous one in its folder.
- Codex accounts are `CODEX_HOME` folders; Codex reads and renews its own sign-in. `%USERPROFILE%\.codex` is listed as it is.

## Build, test, try

```sh
./build.sh                 # build/AgentBar-windows-x64.zip (on a Mac or Linux)
node --test test/          # the accounts and the panel's layout, against stand-ins (any system, Node 26)
```

On Windows, `node.exe --disable-warning=ExperimentalWarning test\demo.mjs` opens AgentBar with made-up accounts and
stand-ins for Anthropic, Claude Code and Codex, so switching and using a coupon can be tried against nothing real.

A release is the zip on a GitHub release tagged `windows-v<VERSION>`, **not marked latest** (the Mac app updates from
the latest release): `gh release create windows-v$(cat VERSION) build/AgentBar-windows-x64.zip --latest=false`.
