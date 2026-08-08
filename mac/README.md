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
Homebrew — `xcode-select --install` if you don't have it). No other dependencies.

**First run — a Keychain prompt:** macOS may ask whether `security` (the tool this
plugin uses to read your login token) can access the "Claude Code-credentials" key.
Click **Always Allow** so it stops asking. If you click Deny, Moth falls back to
`~/.claude/.credentials.json`; if that isn't present either, it just shows "Not logged
in" until you allow it.

## What the colors mean

Same as the Windows widget: **amber** normally, **orange** past 70%, **red** past 90% —
the flame rising as you approach the limit.

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

> **Community-tested.** The Windows widget is the author's daily driver; this Mac
> plugin is written to the same endpoint contract but tested against fixtures, not on
> the author's own Mac. Please report anything that misbehaves.
