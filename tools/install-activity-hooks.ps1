# install-activity-hooks.ps1
# Registers the Claude Code hooks that feed Moth's provider auto-follow, by installing
# a copy of touch-activity.ps1 outside the repo and pointing UserPromptSubmit + Stop at it.
#
# WHY A COPY: these hooks fire on EVERY prompt, not once per session like the widget's
# SessionStart hook. The repo lives in OneDrive, which dehydrates files and can rename
# or move the folder - either would break all the hooks at once and add a network
# round-trip to every prompt. The repo copy stays the source of truth; this installs the
# execution copy.
#
# CODEX HOOKS ARE NOT INSTALLED HERE. Whether the Codex desktop app fires the entries in
# ~/.codex/hooks.json is unconfirmed, and a hook that never fires (or that Codex's
# external-agent import copies across with the wrong -Provider) would silently mis-stamp
# activity. Moth reads Codex activity from the newest ~/.codex/sessions rollout file
# instead, which only advances on real turns. Cheap way to settle it: the Stop hook
# already in ~/.codex/hooks.json plays notify.wav - if that sound fires after a Codex
# desktop turn, hooks work there and a Codex entry can be added.
#
# Run with NO Claude Code session open (settings.json hot-reloads and both sides
# rewrite the file):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-activity-hooks.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-activity-hooks.ps1 -Uninstall

param(
    [switch]$Uninstall,
    # Overridable so the fixture test can exercise the merge against a throwaway copy
    # instead of the live file.
    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [string]$TargetDir    = (Join-Path $env:LOCALAPPDATA 'Moth'),
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$root   = Split-Path $PSScriptRoot -Parent
$source = Join-Path $root 'touch-activity.ps1'
$target = Join-Path $TargetDir 'touch-activity.ps1'
$backup = "$SettingsPath.moth-activity.bak"
$EVENTS = @('UserPromptSubmit', 'Stop')

function Say($msg, $color) { if (-not $Quiet) { Write-Host $msg -ForegroundColor $color } }
function Write-Utf8NoBom($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# Identifies OUR entries and nobody else's. Includes -Provider so an entry copied into
# another tool's hook file with the wrong provider is NOT counted as already-installed.
function Test-IsOurs($group) {
    $hooks = @($group.hooks)
    return [bool](@($hooks | Where-Object {
        $_.command -like '*touch-activity.ps1*' -and $_.command -like '*-Provider claude*'
    }).Count)
}

# Shape validation, not just "parses as JSON". PowerShell 5.1 unrolls a one-element
# array to a scalar in several code paths, and "Stop": { ... } instead of "Stop": [ ... ]
# is perfectly valid JSON that Claude Code will not accept.
function Test-HooksShape($cfg) {
    if ($null -eq $cfg) { return $true }
    if (-not ($cfg.PSObject.Properties.Name -contains 'hooks')) { return $true }
    foreach ($evt in $cfg.hooks.PSObject.Properties) {
        if ($evt.Value -isnot [System.Object[]]) { return $false }
        foreach ($group in $evt.Value) {
            if ($group.hooks -isnot [System.Object[]]) { return $false }
            foreach ($h in $group.hooks) {
                if (-not $h.type -or -not $h.command) { return $false }
            }
        }
    }
    return $true
}

if (-not (Test-Path -LiteralPath $SettingsPath)) {
    throw "settings.json not found at $SettingsPath - is Claude Code installed for this user?"
}
# The command string is executed by a shell, so the same characters install.ps1 refuses
# in the repo path would break the hook command here.
if ($TargetDir -match '[`$%]') {
    throw "the install folder's path contains a character (`$, `` or %) that breaks the hook command: $TargetDir"
}

# --- 0. Validate the INPUT before touching anything ------------------------------
# Read, parse and shape-check first. Doing this after the execution copy is removed
# would leave the hooks pointing at a script that no longer exists on any refusal - a
# missing command on every prompt. An unparseable settings.json is left byte-identical;
# an empty one is treated as fresh, the same as install.ps1 treats it.
$rawSettings = [System.IO.File]::ReadAllText($SettingsPath)
$cfg = $null
if ($rawSettings.Trim().Length -gt 0) {
    try { $cfg = $rawSettings | ConvertFrom-Json }
    catch { throw "settings.json at $SettingsPath is not valid JSON - nothing was changed. Fix or restore it, then re-run. $_" }
}
if (-not (Test-HooksShape $cfg)) {
    throw "settings.json at $SettingsPath has a malformed hooks section (an event is not an array) - nothing was changed."
}
# Claude Code hot-reloads this file and rewrites it itself; a concurrent write would be
# clobbered. Warn rather than block - the window is milliseconds.
try {
    if (@(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count) {
        Say "  [!!] a 'claude' process is running - close your Claude Code sessions before installing" 'Yellow'
    }
} catch { }

# --- 1. Install or remove the execution copy -------------------------------------
# UNINSTALL DELETES NOTHING YET. The header above promises the hooks can never end up
# pointing at a script that no longer exists, but only the step-0 validation runs before
# this point - the LATE re-read at step 2 can still fail (Claude Code holds the file open
# mid-hot-reload, or a torn read fails to parse). Deleting here and then throwing left the
# copy gone, both hook entries registered, and a message that said "nothing was changed".
# Every prompt in every session then launched powershell.exe against a missing path.
# The removal now happens at step 5, once the hooks that point at it are provably gone.
if (-not $Uninstall) {
    if (-not (Test-Path -LiteralPath $source)) { throw "source not found: $source" }
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $source -Destination $target -Force
    Say "  [ok] installed $target" 'Green'
}

# --- 2. Back up (install only), then re-read LATE ---------------------------------
# Uninstall takes no backup: it would create a .bak for a user who never installed
# anything, which is a file appearing out of nowhere on a cleanup path.
if (-not $Uninstall -and -not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $SettingsPath -Destination $backup
    Say "  [ok] backed up settings.json -> $backup" 'Green'
}

# Both Claude Code and this script write settings.json; re-read immediately before the
# merge so a change made since the step-0 validation is not clobbered.
$cfg = $null
# The READ is guarded too, not just the parse: Claude Code rewriting the file at this
# instant raises an IOException here, and an unguarded one would surface as a raw .NET
# stack trace in the middle of an uninstall instead of this script's own message.
$rawLate = $null
try { $rawLate = [System.IO.File]::ReadAllText($SettingsPath) }
catch { throw "settings.json could not be read while this script was running (a Claude Code session may have it open) - nothing was changed. $_" }
if ($rawLate.Trim().Length -gt 0) {
    try { $cfg = $rawLate | ConvertFrom-Json }
    catch { throw "settings.json became unparseable while this script was running - nothing was changed. $_" }
}
# Shape-check the LATE read as well. The step-0 check validated a file that may since have
# been replaced; merging into a shape Claude Code will not accept, and only catching it
# after the write, would mean discovering the problem with the file already rewritten.
if (-not (Test-HooksShape $cfg)) {
    throw "settings.json hooks became malformed while this script was running - nothing was changed."
}
if ($null -eq $cfg) { $cfg = [pscustomobject]@{} }
if (-not ($cfg.PSObject.Properties.Name -contains 'hooks') -or -not $cfg.hooks) {
    $cfg | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
}

# --- 3. Merge --------------------------------------------------------------------
$hookCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $target + '" -Provider claude'
$added = 0; $removed = 0; $foreign = 0

foreach ($evt in $EVENTS) {
    if (-not ($cfg.hooks.PSObject.Properties.Name -contains $evt) -or -not $cfg.hooks.$evt) {
        if ($Uninstall) { continue }
        $cfg.hooks | Add-Member -NotePropertyName $evt -NotePropertyValue @() -Force
    }

    $existing = @($cfg.hooks.$evt)
    # Report - never silently count - an entry that points at our script with a
    # different -Provider. Codex's external-agent import can copy hooks across tools.
    $foreign += @($existing | Where-Object {
        @($_.hooks | Where-Object { $_.command -like '*touch-activity.ps1*' }).Count -and -not (Test-IsOurs $_)
    }).Count

    $kept = @($existing | Where-Object { -not (Test-IsOurs $_) })
    $removed += ($existing.Count - $kept.Count)

    if ($Uninstall) {
        if (@($kept).Count -eq 0) {
            # Collapse an event we emptied, matching uninstall.ps1's own convention -
            # leaving "UserPromptSubmit": [] behind is litter from a tool that claims to
            # reverse itself cleanly.
            $cfg.hooks.PSObject.Properties.Remove($evt)
        } else {
            # [object[]] cast: without it a single surviving group unrolls to a scalar and
            # the event serializes as an object instead of an array.
            $cfg.hooks.$evt = [object[]]$kept
        }
    } else {
        $entry = [pscustomobject]@{
            hooks = [object[]]@([pscustomobject]@{
                type = 'command'; command = $hookCmd; async = $true; timeout = 5
            })
        }
        $cfg.hooks.$evt = [object[]](@($kept) + $entry)
        $added++
    }
}

# --- 4. Write only if something changed, then validate what landed ---------------
# An uninstall that removed nothing must not rewrite (and reformat) the file of a user
# who never installed the hooks. uninstall.ps1 calls this for everyone.
if ($added -eq 0 -and $removed -eq 0) {
    if ($Uninstall) {
        Say "  [ok] no activity hooks were installed; settings.json untouched" 'Green'
        # Nothing pointed at the copy, so removing it strands nothing.
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force; Say "  [ok] removed $target" 'Green' }
    }
    if ($foreign) { Say "  [!!] $foreign entr(ies) point at touch-activity.ps1 with a different -Provider - inspect them" 'Yellow' }
    return
}

# No backup is taken on the uninstall path (step 2), so "restore from $backup" would send
# a user to a file that does not exist at the exact moment their settings.json has just
# been rewritten and they most need a real recovery route.
$restoreHint = if (Test-Path -LiteralPath $backup) { "restore from $backup" }
               else { "restore settings.json from your own backup" }

Write-Utf8NoBom $SettingsPath ($cfg | ConvertTo-Json -Depth 100)

$bytes = [System.IO.File]::ReadAllBytes($SettingsPath)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    throw "settings.json was written with a BOM - $restoreHint"
}
$written = $null
try { $written = [System.IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json }
catch { throw "settings.json became invalid JSON - $restoreHint. $_" }
if (-not (Test-HooksShape $written)) {
    throw "settings.json hooks are malformed (an event is not an array) - $restoreHint"
}

# --- 5. NOW remove the execution copy -------------------------------------------
# Only here: the hook entries that referenced it are gone from a settings.json that has
# been written AND validated, so there is no window in which a registered hook points at
# a deleted file.
if ($Uninstall -and (Test-Path -LiteralPath $target)) {
    Remove-Item -LiteralPath $target -Force
    Say "  [ok] removed $target" 'Green'
}

if ($Uninstall) { Say "  [ok] removed $removed hook entr(ies); settings.json valid" 'Green' }
else { Say "  [ok] registered $added hook entr(ies) on $($EVENTS -join ' + '); settings.json valid" 'Green' }
if ($foreign) { Say "  [!!] $foreign entr(ies) point at touch-activity.ps1 with a different -Provider - inspect them" 'Yellow' }
Say "" 'Gray'
Say "  Codex hooks were NOT installed (see the header note). Codex activity comes from" 'Gray'
Say "  the newest ~/.codex/sessions rollout file until hook firing is confirmed." 'Gray'
