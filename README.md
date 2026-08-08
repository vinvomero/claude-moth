# /moth

<p align="center">
  <img src="assets/moth-demo.gif" alt="Moth — a desktop widget showing Claude Code 5-hour and weekly usage, glowing warm amber then orange then red as usage climbs" width="306">
</p>

**Your Claude Code usage, always in the corner of your eye — so you never stop to click into the app just to check.**

## Why this exists

Seeing how much Claude Code you've used means stopping what you're doing, opening the
app, and clicking into the usage screen — every single time. I just wanted to *know*,
at a glance, without breaking focus.

So Moth is a tiny always-on-top card that keeps your **5-hour** and **weekly** usage in
the corner of your screen. It glows warm amber when you're fine, deepens to orange past
70%, and burns red as you get close to the limit — so you feel the number without even
reading it. No clicking, no context-switch. Like its namesake, it lives beside the
light: the more you burn, the warmer it glows.

The numbers come straight from Claude Code's own official usage feed, so they match the
`/usage` screen exactly. Nothing is sent anywhere; everything runs on your PC.

## Setup (one time)

1. Open PowerShell in this folder.
2. Run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File install.ps1
   ```

That's it. Moth appears in the top-left of your desktop (drag it wherever you like —
it remembers). It launches automatically whenever a Claude Code session is active,
and you can bring it back any time by typing **`/moth`** in Claude Code.

The bars fill in the moment your **next** Claude Code session makes its first request.
Until then it shows "waiting for Claude usage data…".

> Prefer it to start when you log into Windows instead? Run
> `install.ps1 -AutoStart`. By default Moth only launches with Claude.

## What the bars mean

- **5-hour** — how much of your rolling 5-hour allowance you've used, and when it
  resets. The tiny hourglass beside the reset time turns as the window burns down.
- **Weekly** — same, for the 7-day window.
- The glow tells the story: **warm amber** normally, **deep orange** past 70%,
  **red** past 90% — the flame rising as you get close to the limit.
- "updated Nm ago" tells you how fresh the numbers are. If data ever goes stale, the
  bars mute to grey and the label says "last synced Nm ago" — the card stays fully
  solid, never see-through.

## Keeping it fresh — live sync

Claude Code's status-line feed (Moth's default source) only runs in the **terminal**,
not the desktop app. If you live in the desktop app, turn on **live sync** so Moth
reads your usage directly instead:

```json
// in config.json, or your gitignored window-state.json
"live_sync": true
```

Live sync pulls the same numbers the `/usage` command shows, using the login token
Claude Code already keeps on your machine. See the honesty section below before
enabling — it's off by default on purpose.

## Mac

There's a menu-bar Moth for macOS too — a [SwiftBar](https://github.com/swiftbar/SwiftBar)
plugin in [`mac/`](mac/). Same real 5-hour + weekly numbers, same amber palette, in
your menu bar. See [`mac/README.md`](mac/README.md) for setup.

## The `/moth` command

Closed the widget? Type `/moth` in any Claude Code session and it restarts —
same position, fresh numbers.

## Turn it off / remove it

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

This closes the widget, removes the `/moth` command, removes any login auto-start,
and removes its status-line entry from your Claude settings. Everything else is left
untouched. To hide it just for now, click the small **×** in its top-right corner — it
stays hidden for the rest of this session and returns the next time a Claude session
starts (or right away if you type **`/moth`**).

## Files

| File | What it does |
|------|--------------|
| `install.ps1` / `uninstall.ps1` | one-time setup / removal |
| `capture-usage.ps1` | saves your latest usage whenever a Claude session is active (also relaunches Moth if it's not running) |
| `widget.ps1` | the moth itself |
| `restart-widget.ps1` | what `/moth` runs — stop + relaunch |
| `commands/moth.md.tmpl` | template for the `/moth` command install |
| `launch-widget.vbs` | starts the widget with no console window |
| `assets/moth-logo.svg` | the Moth mark |
| `config.json` | refresh rate, "stale" threshold, bar width, default position — edit if you like |
| `usage-cache.json` | the latest saved numbers (created automatically) |
| `window-state.json` | remembers where you dragged the widget (created automatically) |
| `widget-error.log` | startup errors, written only if the widget fails to launch |

## Requirements

- **Claude Code 2.1.80 or newer** — that version is when the official status-line usage
  feed shipped. Check with `claude --version`; upgrade with `winget upgrade Anthropic.ClaudeCode`
  or `claude update`.
- **Windows PowerShell 5.1** (the built-in `powershell.exe`, present on every Windows 10/11).
  The widget uses WPF, which needs the Desktop edition's single-threaded apartment; the
  launcher calls `powershell.exe` explicitly for this reason. If the widget ever fails to
  appear, check `widget-error.log` in this folder.

## What install does (full disclosure)

`install.ps1` makes exactly two changes by default and backs up your settings first:

- Adds a `statusLine` entry to `~/.claude/settings.json` (your pre-install file is saved once to
  `settings.json.usage-widget.bak`). If you already had a custom status line, it warns you before
  replacing it — and uninstall leaves a status line alone if it's no longer this widget's.
- Adds a `/moth` command file at `~/.claude/commands/moth.md` so you can restart the
  widget from inside Claude Code.

Optionally (only with `-AutoStart`): a Startup shortcut that runs the widget **hidden**
(`-WindowStyle Hidden`) with **`-ExecutionPolicy Bypass`**, from this folder. That's a normal
way to run a personal script on login, but you should know it's happening — and keep this
folder somewhere only you can write to, so nobody can swap `widget.ps1` out from under it.

> **Run install from a normal (non-admin) PowerShell.** If you install from an
> elevated "Run as administrator" window, the widget runs elevated too — and Claude
> Code (running normally) then can't see it to refresh or restart it, so `/moth` and
> auto-relaunch stop working. A normal window is the right way to run a personal script.

`uninstall.ps1` reverses all of it cleanly.

## Privacy

By default it does **not** touch your login token or call any private endpoints — it only reads
the usage numbers Claude Code already shows you. Everything stays on your machine.

## Live sync — the honest details (`live_sync`)

Off by default. Setting `"live_sync": true` (in `config.json`, or in your personal
`window-state.json` to keep the repo clean) makes Moth refresh directly from Anthropic
every ~3 minutes — even in the desktop app, even when no terminal session is running —
and shows a third **per-model weekly** bar (Opus/Sonnet/Fable) when available.
*(The old key name `fable_bar` still works.)*

**Why you'd want it:** the status-line feed only runs in the terminal. In the desktop
app, live sync is the only way to keep the numbers current.

**Read this before enabling:** this mode calls an **undocumented** Anthropic endpoint
(`api/oauth/usage`) using the login token Claude Code already stores on your machine. Several
public tools do the same and it works reliably today, but Anthropic's policy language says
subscription tokens are for Claude Code/claude.ai use, and the endpoint could change or break
at any time. The widget never runs its own login, never logs or transmits the token anywhere
except to Anthropic, sends the `User-Agent` the endpoint expects, backs off politely on errors,
and degrades to the status-line feed if the endpoint fails. If any of that makes you
uncomfortable, leave it off — the default mode is fully within documented behavior.

```text
       *

  .~\     /~.
  \  \   /  /
   `-.\ /.-'
     (o o)
      ) (
     '   `
```
<p align="center"><em>drawn to the light</em></p>
