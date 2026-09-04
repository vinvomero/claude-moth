# Moth for macOS 🦋

A little menu-bar moth, drawn to your Claude Code usage — the Mac cousin of the
Windows desktop widget. It lives in your menu bar and shows your real 5-hour and
weekly limit percentages, with reset countdowns.

It's a [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin (also works with
[xbar](https://github.com/matryer/xbar)) — a single script, no app to sign or install.

## Setup

1. Install SwiftBar: `brew install --cask swiftbar` (or grab it from the SwiftBar repo).
   SwiftBar itself is signed and notarized by its maintainers.
2. On first launch, SwiftBar asks you to pick a **Plugins Folder**.
3. Copy `moth.5m.sh` into that folder and make it executable:

   ```bash
   cp moth.5m.sh "<your SwiftBar plugins folder>/"
   chmod +x "<your SwiftBar plugins folder>/moth.5m.sh"
   ```

4. Refresh SwiftBar (or it picks it up automatically). A percentage appears in your
   menu bar; click it for both bars and reset times.

The `5m` in the filename means it refreshes every 5 minutes.

**Requirements:** `python3` (present on any Mac with the Xcode Command Line Tools or
Homebrew — `xcode-select --install` if you don't have it). No other dependencies. For the
optional Codex section: the `codex` CLI signed in with your **ChatGPT account** (not an
API key), tested against codex-cli **0.152.0**.

**First run — a Keychain prompt:** macOS may ask whether `security` (the tool this
plugin uses to read your login token) can access the "Claude Code-credentials" key.
Click **Always Allow** so it stops asking. If you click Deny, Moth falls back to
`~/.claude/.credentials.json`; if that isn't present either, it just shows "Not logged
in" until you allow it.

## What the colors mean

Same as the Windows widget: **amber** normally, **orange** past 70%, **red** past 90% —
the flame rising as you approach the limit.

## Codex too, if you use it

Off by default. Switch it on and the menu grows a second group with your **Codex
(ChatGPT)** 5-hour and weekly numbers, and the title becomes `Cl 42% · Co 17%` — Claude
always first, so the menu bar never reshuffles under you.

**SwiftBar 2.1.0 or newer:** open the plugin's settings (click the menu-bar item ▸
**Preferences** ▸ the plugin) and turn on **Also show Codex (ChatGPT) usage**. SwiftBar
reads the `<xbar.var>` tags at the top of the script and passes your answer in.

**On older SwiftBar, or on xbar:** export it yourself, in `~/.bash_profile`:

```bash
export MOTH_CODEX=1
export CODEX_CLI_PATH=/opt/homebrew/bin/codex   # only if it isn't found on its own
```

`~/.bash_profile` specifically. SwiftBar runs plugins under `bash -l`, so it never reads
`~/.zshrc` or `~/.zprofile` no matter what your own shell is — a very common reason an
export "doesn't work".

Then refresh the plugin (click ▸ **Refresh**, or open `swiftbar://refreshplugin?name=moth`).

**Where it looks for `codex`,** in order: `CODEX_CLI_PATH`, then `codex` on your `PATH`,
then `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.bun/bin`, `~/.volta/bin`,
and each `~/.nvm/versions/node/*/bin`. If it can't find it, the menu says so and lists
every path it tried.

### What each Codex row means when something is wrong

Every failure shows one sentence, the path it used (or the paths it tried), and a link to
open an issue. The Claude rows above it are never affected.

| Row | What happened |
|-----|---------------|
| **Codex CLI not found.** | Nothing at any of the paths listed under it. Set `CODEX_CLI_PATH`. |
| **Found the Codex CLI, but not the interpreter it needs** | An npm shim whose `node` is gone. Reinstall Node, or use the desktop app's own build. |
| **The Codex CLI is not executable** | The execute bit is missing — a tarball, an unzip, or a copy off a share all drop it. Run the `chmod +x` the row prints. |
| **macOS blocked it** | Gatekeeper quarantine: the file *is* executable and macOS still refused it. Run it once from a terminal, or `xattr -d com.apple.quarantine <path>`. |
| **Sign in to Codex to sync.** | The app-server started but has no ChatGPT login. Run `codex` once and sign in. |
| **This Codex build is too old to report rate limits.** | Your `codex` predates `account/rateLimits/read`. Update it. |
| **Codex sync failed.** / **Codex is overloaded** | OpenAI's side, not yours. It'll clear on its own. |
| **Codex didn't answer in time.** | The app-server started and went quiet. Moth gives up after 12 seconds so your menu never hangs. |
| **The Codex CLI exited before answering.** | It died on startup; the exit status and the first line of its own error are shown beneath. |
| **Codex started but never answered.** | It ran, and either closed its output or talked without ever replying. Different from the row below — nothing came back to parse. |
| **Codex replied, but with no usable limits.** | It *did* answer; the answer carried no rate-limit window. Usually a plan or account thing, not an install thing. |
| **Weekly   --%** | Not an error. Your plan reports no weekly window, and `0%` would be a claim rather than a gap. |

## How it gets the numbers (honest disclosure)

Moth reads your usage from the same place the `/usage` command does: an
**undocumented** Anthropic endpoint (`api/oauth/usage`), using the login token Claude
Code already stores on your Mac (macOS Keychain, or `~/.claude/.credentials.json`).

It **never runs its own login**, never stores or transmits the token anywhere except
to Anthropic, sends the `User-Agent` header the endpoint expects, and refreshes no
faster than every 5 minutes. Several community tools (CCSeva, claude-monitor, and
others) use the same endpoint and it's reliable today — but Anthropic's policy
language says subscription tokens are for Claude Code / claude.ai use, and an
undocumented endpoint can change or break at any time. If that makes you
uncomfortable, don't install this. If it stops working, [open an issue](https://github.com/vinvomero/claude-moth/issues).

## Codex — the honest details

The Claude side of this plugin only reads. The Codex side **runs a program**, so:

- It launches `codex -s read-only -a never app-server --stdio` — never the bare `codex`
  command, which can open an interactive browser sign-in — with a hard 12-second deadline,
  in its own process group, and kills that group when it's done.
- **Moth never reads `~/.codex/auth.json`.** The app-server owns its own login and calls
  OpenAI itself, which also means it may refresh and rewrite that file, exactly as any
  Codex session would.
- Starting it loads your `~/.codex/config.toml`, **including any MCP servers** you have
  configured. On codex-cli 0.152.0 a rate-limit read was measured not to start them; that
  is one version observed, not a promise about every version.
- Nothing is cached and nothing is written. Each refresh asks fresh, and the answer lives
  only in the menu until the next one.
- The reply is copied field by field: percentages, reset times, window lengths. The
  account id and credit balance that arrive alongside them are dropped.
- **Your Claude token is not passed to it.** The plugin reads that token to call
  Anthropic, and explicitly strips it from the environment `codex` is started with — by
  name and by value — so it cannot reach OpenAI's binary or anything that binary forks.
- **First run will likely prompt.** macOS may ask to confirm running `codex` from a
  background process, and the Keychain may prompt again for Codex's own credentials.

**One known limitation.** Unlike the Windows helper, this plugin holds no lock while it
talks to Codex. If you click **Refresh** repeatedly during the ~12 seconds an exchange can
take, each click can start another `codex app-server`, and concurrent app-servers are
concurrent writers to `~/.codex/auth.json`. Whether SwiftBar already serialises repeat runs
of one plugin is unverified — this file has never run on a Mac — so the honest advice is:
click Refresh once and let it finish. If you hit this, please
[open an issue](https://github.com/vinvomero/claude-moth/issues); a lock is easy to add
once someone can confirm the behavior on real hardware.

The Windows widget documents the same things in more depth — see the root
[README](../README.md#codex--the-honest-details-codex).

> **Community-tested.** The Windows widget is the author's daily driver; this Mac
> plugin is written to the same endpoint contract but tested against fixtures, not on
> the author's own Mac. Please report anything that misbehaves.
>
> That applies double to the Codex section. It is exercised by an automated harness
> (`tools/test-mac-plugin.py`) that runs this exact script against a fake `codex` — 116
> assertions covering every error row above, and a byte-for-byte diff proving a
> Claude-only menu is unchanged. But a harness is not a Mac. The parts that have never
> run on real hardware are the ones macOS owns: Gatekeeper quarantine, the Keychain
> prompt, and `killpg` on a real process group.
