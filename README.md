<p align="center">
  <img src="docs/images/limi-512.png" width="160" alt="Limi icon: three usage bars">
</p>

<h1 align="center">Limi</h1>

<h3 align="center">Your AI usage limits, in one menu bar.</h3>

<p align="center">
  See the 5-hour and weekly limits of several Claude Code and Codex accounts right in your menu bar.<br>
  Switch the account Claude Code uses in one click, without signing in again. Your account details stay on your Mac.
</p>

<p align="center">
  Works with <b>Claude Code</b> (Claude Pro and Max), <b>Codex</b> (ChatGPT sign-in) and <b>Antigravity</b> (experimental).
</p>

<p align="center">
  <a href="https://github.com/kalti-lab/limi/releases/latest/download/Limi.zip"><img src="https://img.shields.io/badge/Download_for_Mac-Limi.zip-3b82f6?style=for-the-badge&logo=apple&logoColor=white&labelColor=0f1115" alt="Download Limi.zip for Mac"></a>
</p>

<p align="center">
  <a href="https://kalti.co.kr/limi"><b>Website</b></a> &nbsp;·&nbsp; <a href="https://kalti.co.kr"><b>KALTI</b></a> &nbsp;·&nbsp; <b>English</b> | <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <a href="https://github.com/kalti-lab/limi/releases/latest"><img src="https://img.shields.io/github/v/release/kalti-lab/limi" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-555?logo=apple" alt="macOS 14 or later">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
</p>

<p align="center">
  <img src="docs/images/readme-hero.jpg" width="840" alt="Limi in the menu bar with a group's account list open: each account's 5-hour and weekly limits, and when they reset">
</p>

## IN ACTION

<table>
  <tr>
    <td align="center" valign="top" width="50%">
      <img src="docs/images/settings-accounts.png" width="400" alt="Limi Settings, Accounts tab: three Claude accounts and one Codex account, with the one Claude Code uses marked In use"><br>
      <b>Several accounts</b><br><sub>Claude Code and Codex accounts side by side</sub>
    </td>
    <td align="center" valign="top" width="50%">
      <img src="docs/images/settings-general.png" width="400" alt="Limi Settings, General tab: refresh interval, language, open at login"><br>
      <b>General settings</b><br><sub>Refresh interval, language, open at login</sub>
    </td>
  </tr>
  <tr>
    <td align="center" valign="top">
      <img src="docs/images/settings-menubar.png" width="320" alt="Limi Settings, Menu Bar tab: groups, the accounts in a group, styles and usage lines"><br>
      <b>Make the menu bar yours</b><br><sub>Groups and their accounts, styles and the limits to show</sub>
    </td>
    <td align="center" valign="top">
      <img src="docs/images/readme-popover-claude2.png" width="400" alt="Limi panel: a group's accounts in one list with a Sort button, each with its limits and when they reset"><br>
      <b>One list per group</b><br><sub>Every account in the group, with its limits, sorted your way</sub>
    </td>
  </tr>
</table>

## KEY CAPABILITIES

<table>
  <tr>
    <td valign="top" colspan="2">
      <img src="docs/images/cap-switch.svg" width="52" height="52" alt=""><br>
      <b>Switch Claude Code accounts in one click</b> <sup>NEW</sup><br>
      Choose which of your Claude accounts your own <code>claude</code> uses. After a one-time sign-in no browser opens, and open sessions follow within 30 seconds.<br><br>
      <img src="docs/images/claude-code-switch.png" width="396" alt="Limi panel: a Claude account's row in a group's list, marked In use. Point at another Claude account's row to see its Use button">
    </td>
  </tr>
  <tr>
    <td valign="top" width="50%">
      <img src="docs/images/cap-accounts.svg" width="52" height="52" alt=""><br>
      <b>All your accounts at a glance</b><br>
      Add Claude Code and Codex accounts together and see each one's 5-hour and weekly limits.
    </td>
    <td valign="top" width="50%">
      <img src="docs/images/cap-style.svg" width="52" height="52" alt=""><br>
      <b>The look you want</b><br>
      Choose Multi Bar, Ring Gauge, Capsule Fill or Text Only, and group your accounts. It turns red past 90%.
    </td>
  </tr>
  <tr>
    <td valign="top">
      <img src="docs/images/cap-private.svg" width="52" height="52" alt=""><br>
      <b>Your accounts stay on your Mac</b><br>
      Sign-in details stay on this Mac. Nothing is sent to KALTI.
    </td>
    <td valign="top">
      <img src="docs/images/cap-language.svg" width="52" height="52" alt=""><br>
      <b>English and Korean</b><br>
      English by default, or pick Korean in Settings.
    </td>
  </tr>
</table>

Also in Limi:

- **Use in Claude Code**: press **Use** on a Claude account in a group's list to switch the login your own `claude` uses to that account in one click, without the browser each time ([how it works](#use-in-claude-code)).
- **Reset coupons** appear below the account's limits with the count and expiry information. When Claude offers several kinds, such as weekly and Fable weekly, **Reset** lets you choose one and shows why an option is unavailable. **OK** confirms the reset. Codex uses the earliest-expiring coupon. [How it works](#how-it-works-and-privacy)
- **Antigravity** (experimental): the one account signed in to `agy` or the Antigravity app on this Mac.
- Claude's per-model weekly limits and Antigravity's model groups, when the service reports them.
- Put any number of accounts in a menu bar group (**Accounts in this group** in **Settings › Menu Bar**), and click the group to see them all in one list. Each row has the account's badge, plan and address, its 5-hour and weekly limits, and each model's weekly limit when the service reports it, every cell with a percentage and when it resets. Click **Sort** above the list to keep your own order (**Manual**) or put the soonest **5-hour reset** or **Weekly reset** first. Each group remembers its choice.
- Up to three usage lines in each menu bar group, taken from the group's accounts and their limits (Ring Gauge shows one, Text Only any number). Drag groups, lines and accounts to reorder them, and a group's accounts by their chips in Settings or their rows in the list.
- A value Limi could not read shows as `--`, never a made-up 0%, and older values are marked as cached.
- Refreshes every 1, 2, 5 or 10 minutes, or on demand. Every account in a group is refreshed, even one without a line in the menu bar: one account at a time per service, with a short pause between requests (1 second for Claude, 0.5 seconds for Codex). Groups with **Show in menu bar** turned off are skipped.
- Open at Login.

## DOWNLOAD

<table>
  <tr>
    <td>
      <h3>OPEN SOURCE &nbsp;<sub>Free</sub></h3>
      <ul>
        <li>Multiple accounts</li>
        <li>Add groups, change styles, edit lines</li>
        <li>Language choice, reconnect and error messages</li>
        <li>Open source under the MIT License</li>
      </ul>
      <p><b>$0</b> / free forever</p>
      <p>
        <a href="https://github.com/kalti-lab/limi/releases/latest/download/Limi.zip"><img src="https://img.shields.io/badge/Download-0f1115?style=for-the-badge&logo=apple&logoColor=white" alt="Download"></a>
        <a href="https://kalti.co.kr/limi"><img src="https://img.shields.io/badge/kalti.co.kr%2Flimi-eef1f5?style=for-the-badge" alt="Limi on kalti.co.kr"></a>
      </p>
    </td>
  </tr>
</table>

Runs on Macs with Apple silicon and macOS 14 or later.

1. Download **Limi.zip** from [kalti.co.kr/limi](https://kalti.co.kr/limi) or the [latest GitHub release](https://github.com/kalti-lab/limi/releases/latest).
2. Unzip it, move **Limi.app** to Applications and open it.

> **This fork (chenjingdev/limi)** brings back agent-bar's way of asking Anthropic and does not update itself: a build from this repository has no update feed, so the official Limi never replaces it. Build it from source ([below](#build-from-source)).

## REQUIREMENTS

<p>
  <img src="docs/images/need-mac.svg" width="22" height="22" align="absmiddle" alt=""> &nbsp;A Mac with Apple silicon, macOS 14 (Sonoma) or later<br>
  <img src="docs/images/need-cli.svg" width="22" height="22" align="absmiddle" alt=""> &nbsp;The official Claude Code or Codex command-line tool (installed with Homebrew, ideally)<br>
  <img src="docs/images/need-api.svg" width="22" height="22" align="absmiddle" alt=""> &nbsp;A subscription sign-in for each account. Usage on API keys isn't shown.
</p>

## GETTING STARTED

Limi starts with no accounts, so it opens **Settings › Accounts**. Click **Add Account…** and choose a service. Each service you add needs its official command-line tool:

| Service | Needs | How you sign in |
|---|---|---|
| Claude | [Claude Code](https://code.claude.com/docs/en/setup) (`claude`) | Limi runs `claude auth login --claudeai` in a folder of its own for that account and opens Claude's sign-in page in your browser. |
| Codex | [Codex CLI](https://github.com/openai/codex) (`codex`) | Limi starts `codex app-server` in a folder of its own for that account and opens the ChatGPT sign-in page. |
| Antigravity (experimental) | [`agy`](https://antigravity.google/cli), signed in | Run `agy` once in Terminal and sign in. Limi reads the account signed in there. Without `agy`, Limi reads the Antigravity app while the app is open. |

- Before your first Claude account, Limi explains how it keeps Claude sign-ins and asks you to agree (see [Claude and Anthropic's terms](#claude-and-anthropics-terms)).
- To add an account other than the one your browser is signed in to, choose **Switch account** on Claude's approval page (this also switches your claude.ai login) or **Sign in with another account** on the ChatGPT page. **Use Private Window Instead** in Limi signs in from a private browser window, apart from your usual browser session.
- Signing in through Limi does not change the login of your own `claude` or `codex`. Only **Use** changes your `claude` login, when you press it.
- Limi looks for the tools in these places, not in your shell's `PATH`:
  - `claude`: `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.bun/bin`
  - `codex`: `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin`
  - `agy`: `~/.local/bin` (or the Antigravity app in `/Applications`)
- Limi starts these tools through `/usr/bin/python3`, which comes with the Xcode Command Line Tools (`xcode-select --install`).

Then set up the menu bar in **Settings › Menu Bar**: add groups, put accounts in each one under **Accounts in this group**, pick a style and choose the limits each group shows. Click a group in the menu bar to see all its accounts in one list. Opening Limi again from Applications brings Settings back.

## BUILD FROM SOURCE

Requires macOS 14 or later and Swift 6.2 or later (Xcode 26 or later).

```sh
git clone https://github.com/chenjingdev/limi.git
cd limi
swift test
./scripts/build-app.sh --install   # into ~/Applications
open ~/Applications/Limi.app
```

The first build downloads [Sparkle](https://github.com/sparkle-project/Sparkle) and checks it against a fixed SHA-256. `./scripts/build-app.sh --help` lists the options. Signing is optional: unless you give the script a signing identity, it signs the app ad hoc, which is enough to run it on your own Mac.

## HOW IT WORKS AND PRIVACY

Limi has no server and no account of its own. It reads the sign-ins stored on this Mac and asks each service directly.

- **Sign-ins.** Every account you add gets a private folder under `~/.agentbar/multi-account-v1/` that only your macOS user can read, and Limi reads the sign-in it keeps there. Limi never imports, follows or changes the logins of your own `claude`, `codex` or `agy`, except that **Use** changes your `claude` login when you press it ([below](#use-in-claude-code)). Deleting an account in Settings removes its sign-ins and cached usage.
- **Claude.** Limi calls Anthropic's OAuth usage API (`api.anthropic.com/api/oauth/usage`) with the managed account's token. After sign-in it copies the credential from Keychain into the account's folder and renews the token there when needed. As agent-bar does, every Claude request (usage, coupons and resets) sends `User-Agent: claude-cli/<installed version> (external, cli)`, the version `claude --version` prints when Limi starts; an older or unreadable Claude Code sends 2.1.295, the oldest version the reset program accepts. About every 30 minutes the usage read also asks for coupons by adding `cedar_ember=1&skip_spend=1`; if Claude refuses that flag, Limi reads plain usage and asks for coupons again 5 minutes later. When you confirm a reset, Limi reads the coupons again to check the one you chose (if that read is refused because it comes right after the last one, Limi goes ahead), then sends `POST api.anthropic.com/api/organizations/<organization>/reset_rate_limits` with a lowercase `request_id`. The coupon interfaces are undocumented.
- **Codex.** Limi reads through the official `codex app-server` (`account/read` and `account/rateLimits/read`), started separately for each account with its own `CODEX_HOME`. It calls `account/rateLimitResetCredit/consume` only when you press **OK** on a reset coupon. The Codex CLI makes the network requests.
- **Antigravity.** Limi never holds the Antigravity sign-in. It runs `agy -p /usage`, which prints the quota report without starting a model turn, so it uses no quota. Limi runs it without a terminal and with nothing it could open a browser with, so a signed-out `agy` stops at once and the account asks you to sign in. Without `agy`, Limi asks the Antigravity app's local server (`127.0.0.1`) while the app is open.
- **Nothing goes to KALTI.** Limi has no analytics or telemetry. A build of this fork never checks for updates, so it does not connect to kalti.co.kr or GitHub Releases.

### Use in Claude Code

On a Claude account's row in a group's list, **Use** (it shows when you point at the row) switches the login your own `claude` uses (its default login, the Keychain item `Claude Code-credentials`) to that account. Every Claude Code session moves to it, open ones within about 30 seconds, and Remote Control disconnects. The account Claude Code uses shows **In use**.

- **Set up once per account.** In **Settings › Accounts**, **Set Up…** has Claude Code sign that account in through your browser, into a folder of its own (`~/.agentbar/multi-account-v1/lend/<account ID>/`). This login is separate from the one Limi reads usage with, so switching never stops the usage display.
- **Only Claude Code writes a login.** Limi runs `claude auth login` with the account's refresh token in `CLAUDE_CODE_OAUTH_REFRESH_TOKEN` ([Claude Code's environment variables](https://code.claude.com/docs/en/env-vars)), and for this reads Keychain items only through `/usr/bin/security`, so no Keychain prompt appears.
- **A refresh token is used once.** Handing a login over uses it up, so Limi never hands the same one over twice. The login Claude Code had goes back to its own account, so switching back needs no browser either. If an open session renews that login in the middle of a switch, that account is set up once more.
- **Checked afterwards.** Limi reads Claude Code's login again after switching and says so if it is not the account you chose. If Claude Code is signed in to an account that isn't in Limi, Limi asks first, since switching removes that login from Claude Code. Quitting waits for a running switch to finish (up to 90 seconds); if Limi still stops halfway, it finishes or undoes the switch on its next launch.
- **Read only when you look.** To show **In use**, Limi checks which account Claude Code uses when you open a panel or **Settings › Accounts**, or press refresh: whether its Keychain item exists (never the token) and the account in `~/.claude.json`. The periodic refresh does not, so nothing can bring up a Keychain window while you are away.
- **Logged without tokens** in `~/.agentbar/multi-account-v1/logs/claude-code-switch.log` (**Open Log**).
- Needs Claude Code 2.1.309 or later. Deleting an account removes its saved sign-in for Claude Code; Claude Code's own login stays as it is. Only the app has it: `swift run` and development runs with `AGENTBAR_DATA_DIR` or `AGENTBAR_DEFAULTS_SUITE` set do not.

### Claude and Anthropic's terms

Anthropic's [terms for Claude Code](https://code.claude.com/docs/en/legal-and-compliance) limit apps that keep Claude sign-ins, so Anthropic could block these reads at any time. Limi says so and asks once, before your first Claude account. If Anthropic blocks the reads, the account tells you so instead of asking you to reconnect, since reconnecting cannot help. **Use** switches only when you press it, and only between accounts you signed in to yourself; it never switches on its own, for example when a limit is reached. Claude's reset coupons go through an undocumented part of the same API, so they may stop working at any time, and Limi uses one only when you press **OK**.

### Antigravity and Google's terms

Google's [Antigravity terms](https://antigravity.google/terms) do not allow other software to use an Antigravity sign-in, which is why Limi asks `agy` or the app instead. Neither is a documented interface, so an Antigravity update may stop it from working.

## DISCLAIMER

Limi is an unofficial app. It is not affiliated with, endorsed by or sponsored by Anthropic, OpenAI or Google. It reads usage in ways these companies can change or block at any time, and Limi may stop working when they do. Claude, Claude Code, ChatGPT, Codex, Antigravity and other product names are trademarks of their respective owners.

## CREDITS

Limi by [jsiksn](https://github.com/jsiksn). Based on [AgentBar](https://github.com/chenjingdev/agent-bar) by [chenjingdev](https://github.com/chenjingdev).

## LICENSE

[MIT](LICENSE)

<br>

<p align="center">
  <a href="https://kalti.co.kr"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/kalti-wordmark-dark.svg"><img src="docs/images/kalti-wordmark.svg" height="26" alt="KALTI"></picture></a>
</p>
<p align="center">
  <sub>Made by KALTI — <a href="https://kalti.co.kr">kalti.co.kr</a> · <a href="mailto:support@kalti.co.kr">support@kalti.co.kr</a></sub>
</p>
