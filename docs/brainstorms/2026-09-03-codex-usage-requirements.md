---
date: 2026-09-03
topic: codex-usage
---

# Requirements: Codex usage in Moth

## Summary

Moth becomes a two-provider card. It shows usage for either Claude Code or Codex, switches itself to whichever tool was used most recently, and a tab in the title bar overrides that choice. The halo keeps warning on the hottest limit across both providers. Personal build first; public release later only if it earns it.

---

## Problem Frame

Moth exists so usage is visible without clicking anywhere. Codex is now a daily tool on the same machine, with its own 5-hour and weekly limits, and Moth is blind to it. Checking Codex usage means opening the Codex app or running `/status` — the exact interruption Moth was built to remove.

Existing multi-provider tools (CodexBar on macOS, ClaudeBar on Windows) are tray or menu-bar apps that require a click to reveal the numbers. They solve the data problem, not the glance problem.

---

## Key Decisions

- **Auto-follow with manual override.** The card shows the provider most recently active. A title-bar tab switches manually and the manual choice sticks until the other provider shows activity again. Chosen over manual-only (a click every tool switch) and over stacking both providers (doubles card height).
- **Halo tracks the hottest limit across both providers.** The glow is the early-warning system. It reacts to a hot limit on the hidden provider too; the tab is how you find out which one.
- **Codex data comes from Codex's own app-server.** Codex owns its login; Moth asks it for rate limits over the local JSON-RPC protocol. No copying tokens out of `auth.json`, no private web endpoint. This is the route every existing Codex tracker uses.
- **Never launch the bare Codex TUI.** Only the app-server entry point is invoked. The interactive CLI can open a browser login on its own.
- **Personal scope.** Built and tuned for this machine. No README, no binary discovery across app updates, no Mac cousin changes.
- **Opt-in gated in the working copy.** The code lives in the main widget but does nothing unless a flag in the gitignored per-user state turns it on — the `live_sync` pattern. Nothing is committed or pushed until the user says so. A public release later is a documentation task, not a rewrite.

---

## Requirements

**Provider selection**

- R1. Moth shows one provider at a time: Claude Code or Codex.
- R2. Moth switches to a provider automatically when that provider shows activity more recently than the other.
- R3. A tab in the title bar lets the user pick a provider manually; the pick persists across restarts.
- R4. A manual pick holds until the other provider shows new activity, at which point auto-follow resumes.
- R5. With no Codex data ever captured, Moth behaves exactly as today: Claude only, no tab shown.

**Codex bars**

- R6. The Codex view shows a 5-hour bar and a weekly bar with used percentage and reset countdown, matching the Claude bars in look and behavior.
- R7. Codex bars go stale (greyed) under the same rules as Claude bars when Codex data stops refreshing.
- R8. Codex usage is read through Codex's app-server; Moth never reads or stores Codex credentials.
- R9. Codex polling never launches the interactive Codex CLI.

**Halo**

- R10. The halo reflects the hottest limit across both providers regardless of which is visible.

**Card**

- R11. The Codex view has no per-model bar; the card is one bar shorter than the full Claude view.
- R12. Switching providers keeps the user's remembered window size and position.

---

## Key Flows

- F1. Switching tools during the day
  - **Trigger:** User finishes a Claude session and starts working in Codex.
  - **Steps:** Codex shows activity; Moth switches to the Codex view; bars update on the next poll.
  - **Outcome:** Codex usage visible without a click. **Covers R2, R6.**

- F2. Checking the other provider
  - **Trigger:** Halo turns orange while the Codex view is showing; Claude is the hot one.
  - **Steps:** User taps the Claude tab; Claude bars show; the pick holds.
  - **Outcome:** User sees why the halo warned. Next Codex activity returns the card to Codex. **Covers R3, R4, R10.**

- F3. Codex unavailable
  - **Trigger:** Codex app-server fails to answer (not installed, signed out, update in progress).
  - **Steps:** Moth keeps the last Codex snapshot and greys it after the stale threshold; Claude view unaffected.
  - **Outcome:** No crash, no false zero. **Covers R7.**

---

## Acceptance Examples

- AE1. **Covers R2, R4.** Given the user manually picked Claude at 10:00, when Codex shows activity at 10:30, then the card switches to Codex.
- AE2. **Covers R4.** Given the user manually picked Claude, when only Claude shows activity afterward, then the card stays on Claude indefinitely.
- AE3. **Covers R5.** Given Codex has never been polled successfully, then the title bar shows no provider tab and the card is identical to the current release.
- AE4. **Covers R10.** Given the Codex view is showing at 20% and Claude weekly is at 88%, then the halo renders the 88% color.
- AE5. **Covers R7.** Given the last good Codex snapshot is older than the stale threshold, then Codex bars render grey while Claude bars stay live.
- AE6. **Covers R9.** Given Codex is signed out, when Moth polls, then no browser window or login prompt appears.

---

## Scope Boundaries

- Public release: README section, opt-in documentation, binary discovery that survives Codex app updates, the macOS SwiftBar cousin.
- Codex credits balance and plan type, even though the app-server returns them.
- Per-model bars for Codex.
- Cost or token tracking for either provider.
- Showing both providers at once, or running two Moth instances.

---

## Dependencies / Assumptions

- Codex desktop app installed and signed in with a ChatGPT account. API-key-only sign-in may not expose subscription limits.
- Codex app-server exposes the rate-limit read; verified against the installed `codex-cli 0.152.0`. Fields: used percentage, reset timestamp, and window length per limit.
- Codex's hook system mirrors Claude Code's (`SessionStart`, `Stop`), giving an activity signal on the Codex side equivalent to the Claude statusLine heartbeat.
- The shared app-server daemon is Unix-only; on Windows each poll spawns its own short-lived app-server.
- Assumed, not confirmed in dialogue: Codex limits have not yet cut a session short; the motivation is parity and staying glanceable, not a specific incident.

---

## Outstanding Questions

**Deferred to Planning**

- How the Codex activity signal is captured (hook-written marker vs. file-activity fallback) and how "more recent" is compared across providers.
- How the Codex binary is located on this machine, given the hashed install folder changes on updates.
- Poll interval and stale threshold for Codex, and whether they share Claude's settings.
- Where the provider tab lives in the title bar and how it reads at the current card width.

---

## Sources

- Codex app-server protocol schema, generated locally from the installed binary: method `account/rateLimits/read`, notification `account/rateLimits/updated`, types `RateLimitSnapshot` (`primary`, `secondary`, `planType`, `credits`) and `RateLimitWindow` (`usedPercent`, `resetsAt`, `windowDurationMins`).
- Moth's existing endpoint path and per-model bar: `widget.ps1` (`live_sync`, `Select-ScopedWeekly`, halo logic), `capture-usage.ps1` (statusLine heartbeat and cache carry-forward).
- Prior art using the same route: [CodexBar](https://github.com/steipete/codexbar) (`docs/codex.md` — spawn `codex app-server`, `initialize`, `account/rateLimits/read`; warns against bare TUI), [CodexLimitsWidget](https://github.com/testpassword/CodexLimitsWidget), [YASB Codex widget](https://github.com/amnweb/yasb/blob/main/docs/widgets/(Widget)-Codex-Usage.md), [codex-hud changelog](https://github.com/davepoon/buildwithclaude/blob/main/plugins/codex-hud/README.md) (Codex 0.142+ stopped writing limits to disk; RPC is the only reliable source), [ClaudeBar](https://github.com/marvinfs/public/blob/main/claudebar/README.md) (Windows tray, both providers, click-to-view).
