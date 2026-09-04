# touch-activity.ps1
# Records "this tool was actively used just now" for Moth's provider auto-follow,
# in %LOCALAPPDATA%\Moth\activity.json:  { "claude": <epoch>, "codex": <epoch> }
#
# WHY A SEPARATE SIGNAL: Moth cannot infer "the user is working in Claude" from the
# usage cache. The statusLine writes it every ~15s while a session is merely OPEN, and
# the live_sync poll rewrites it every 3 minutes with no session at all. Auto-following
# those would snap the card back to Claude seconds after every Codex turn. This file
# records TURN EVENTS only - it moves when the user actually does something.
#
# WHY OUTSIDE THE REPO: the repo folder is OneDrive-synced, and sync rewrites mtimes.
# It is also the execution path problem - see the contract below.
#
# HARD CONTRACT (do not relax any of these):
#   This script runs inside EVERY Claude Code prompt via a UserPromptSubmit hook.
#   A UserPromptSubmit hook's stdout is INJECTED INTO THE MODEL'S CONTEXT, a non-zero
#   exit surfaces as a hook error, and exit code 2 BLOCKS the prompt outright. Its
#   stdin carries the prompt text.
#   Therefore: never write to stdout or stderr, never read stdin, never log, and
#   ALWAYS exit 0 - including on bad input, a read-only disk, or a missing folder.
#   Deliberately NOT using [ValidateSet] on -Provider: a binding failure would write to
#   stderr and exit non-zero before the body could stop it. Validation happens inside.
#
# Run by hand:  powershell -NoProfile -ExecutionPolicy Bypass -File touch-activity.ps1 -Provider claude

param([string]$Provider)

$ErrorActionPreference = 'SilentlyContinue'

try {
    if ($Provider -ne 'claude' -and $Provider -ne 'codex') { exit 0 }

    $dir = Join-Path $env:LOCALAPPDATA 'Moth'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $file = Join-Path $dir 'activity.json'

    # Read-merge-write: the other provider's stamp must survive our write.
    $claude = $null
    $codex  = $null
    if (Test-Path -LiteralPath $file) {
        try {
            $prev = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            if ($prev.claude) { $claude = [long]$prev.claude }
            if ($prev.codex)  { $codex  = [long]$prev.codex }
        } catch { }
    }

    $now = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($Provider -eq 'claude') { $claude = $now } else { $codex = $now }

    $json = [pscustomobject]([ordered]@{ claude = $claude; codex = $codex }) | ConvertTo-Json -Depth 3
    $tmp = "$file.$PID.tmp"
    # Same atomic, BOM-less publish as the caches: a reader must never see a partial file.
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $file) {
        [System.IO.File]::Replace($tmp, $file, [NullString]::Value)
    } else {
        Move-Item -LiteralPath $tmp -Destination $file -Force
    }
} catch { }

exit 0
