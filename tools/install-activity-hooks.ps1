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
function Test-HooksShape($path) {
    $cfg = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
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

# --- 1. Install or remove the execution copy -------------------------------------
if ($Uninstall) {
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Force
        Say "  [ok] removed $target" 'Green'
    }
} else {
    if (-not (Test-Path -LiteralPath $source)) { throw "source not found: $source" }
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $source -Destination $target -Force
    Say "  [ok] installed $target" 'Green'
}

# --- 2. Back up once, then read LATE ---------------------------------------------
# Both Claude Code and this script write settings.json; read immediately before the
# merge so a concurrent change is not clobbered by a stale in-memory copy.
if (-not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $SettingsPath -Destination $backup
    Say "  [ok] backed up settings.json -> $backup" 'Green'
}

$cfg = [System.IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
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
        # [object[]] cast: without it a single surviving group unrolls to a scalar and
        # the event serializes as an object instead of an array.
        $cfg.hooks.$evt = [object[]]$kept
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

# --- 4. Write, then validate what actually landed --------------------------------
Write-Utf8NoBom $SettingsPath ($cfg | ConvertTo-Json -Depth 100)

$bytes = [System.IO.File]::ReadAllBytes($SettingsPath)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    throw "settings.json was written with a BOM - restore from $backup"
}
try { [System.IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json | Out-Null }
catch { throw "settings.json became invalid JSON - restore from $backup. $_" }
if (-not (Test-HooksShape $SettingsPath)) {
    throw "settings.json hooks are malformed (an event is not an array) - restore from $backup"
}

if ($Uninstall) { Say "  [ok] removed $removed hook entr(ies); settings.json valid" 'Green' }
else { Say "  [ok] registered $added hook entr(ies) on $($EVENTS -join ' + '); settings.json valid" 'Green' }
if ($foreign) { Say "  [!!] $foreign entr(ies) point at touch-activity.ps1 with a different -Provider - inspect them" 'Yellow' }
Say "" 'Gray'
Say "  Codex hooks were NOT installed (see the header note). Codex activity comes from" 'Gray'
Say "  the newest ~/.codex/sessions rollout file until hook firing is confirmed." 'Gray'
