# Claude Usage Widget

A small bar that floats on your desktop and shows your real Claude Code usage — the
5-hour window and the weekly window — so you never have to open `/usage` again.

The numbers come straight from Claude Code's own official usage feed, so they match
the `/usage` screen. Nothing is sent anywhere; everything runs on this PC.

## Setup (one time)

1. Open PowerShell in this folder.
2. Run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File install.ps1
   ```

That's it. The widget appears in the top-left of your desktop (drag it wherever you
like — it remembers). From now on it also starts automatically when you log in.

The bars fill in the moment your **next** Claude Code session makes its first request.
Until then it shows "waiting for first Claude session…".

## What the bars mean

- **5-hour** — how much of your rolling 5-hour allowance you've used, and when it resets.
- **Weekly** — same, for the 7-day window.
- Bars turn **amber** past 70% and **red** past 90%.
- "updated Nm ago" tells you how fresh the numbers are. The widget refreshes while
  you're using Claude Code; when you're idle it dims slightly and keeps counting down
  the reset timers. (That's expected — usage only changes while you're working.)

## Turn it off / remove it

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

This closes the widget, stops it starting on login, and removes its status-line entry
from your Claude settings. Everything else is left untouched. To hide it just for now,
click the small **×** in its top-right corner.

## Files

| File | What it does |
|------|--------------|
| `install.ps1` / `uninstall.ps1` | one-time setup / removal |
| `capture-usage.ps1` | saves your latest usage whenever a Claude session is active |
| `widget.ps1` | the floating bar itself |
| `launch-widget.vbs` | starts the widget with no console window |
| `config.json` | position, refresh rate, and "stale" threshold — edit if you like |
| `usage-cache.json` | the latest saved numbers (created automatically) |

## Note

This relies on Claude Code **2.1.80 or newer** (that version is when the official
status-line usage feed shipped). Check with `claude --version`; upgrade with
`winget upgrade Anthropic.ClaudeCode` or `claude update`.

It does **not** touch your login token or call any private endpoints — it only reads
the usage numbers Claude Code already shows you. Everything stays on your machine.
