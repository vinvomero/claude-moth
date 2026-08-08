# install.ps1 - one-time setup. Safe to re-run (idempotent).
#   1. Registers capture-usage.ps1 as the Claude Code status-line command (merged into
#      ~/.claude/settings.json, preserving everything already there).
#   2. Adds a Startup shortcut so the widget launches (hidden) on every login.
#   3. Starts the widget now (replacing any instance already running from this folder).
# Run:  powershell.exe -ExecutionPolicy Bypass -File install.ps1
#   Pass -AutoStart to also create a Windows login shortcut (OFF by default; the widget
#   is meant to launch from Claude sessions, not Windows startup).

param([switch]$AutoStart)

$ErrorActionPreference = 'Stop'
$root       = $PSScriptRoot
$capture    = Join-Path $root 'capture-usage.ps1'
$vbs        = Join-Path $root 'launch-widget.vbs'
$settings   = Join-Path $env:USERPROFILE '.claude\settings.json'
# Per-tool backup name: never clobbered by other tools that also back up settings.json.
$backup     = Join-Path $env:USERPROFILE '.claude\settings.json.usage-widget.bak'

function Write-Utf8NoBom($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# The install path gets embedded into a shell-executed command and a VBS launcher.
# $, backtick and % survive quoting in those contexts and would break (or expand in)
# the command - refuse early with a clear message instead of failing silently later.
if ($root -match '[`$%]') {
    throw "This folder's path contains a character (`$, `` or %) that breaks the status-line command: $root`nMove the folder to a plain path (e.g. C:\Tools\claude-usage-widget) and run install again."
}

Write-Host "Installing Claude usage widget..." -ForegroundColor Cyan

# --- 1. Register the status-line capture command (merge, don't clobber) ---
$cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $capture + '"'
if (Test-Path $settings) {
    $cfg = Get-Content $settings -Raw | ConvertFrom-Json
    if (-not $cfg) { $cfg = [pscustomobject]@{} }   # empty/whitespace file -> start fresh
    # Preserve the PRISTINE pre-install settings: only write the backup once, so
    # re-running install never replaces the original with an already-modified copy.
    if (-not (Test-Path $backup)) { Copy-Item $settings $backup }
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $settings) | Out-Null
    $cfg = [pscustomobject]@{}
}

# Don't silently replace a status line the user set for something else.
if (($cfg.PSObject.Properties.Name -contains 'statusLine') -and
    $cfg.statusLine.command -and ($cfg.statusLine.command -notlike '*capture-usage.ps1*')) {
    Write-Host "  [warn] You already have a custom statusLine command:" -ForegroundColor Yellow
    Write-Host "         $($cfg.statusLine.command)" -ForegroundColor DarkGray
    Write-Host "         Replacing it with the usage widget's. Your pre-install settings are saved at:" -ForegroundColor Yellow
    Write-Host "         $backup" -ForegroundColor DarkGray
}

$sl = [pscustomobject]@{ type = 'command'; command = $cmd; padding = 0; refreshInterval = 15 }
if ($cfg.PSObject.Properties.Name -contains 'statusLine') { $cfg.statusLine = $sl }
else { $cfg | Add-Member -NotePropertyName statusLine -NotePropertyValue $sl }
Write-Utf8NoBom $settings ($cfg | ConvertTo-Json -Depth 100)

# Validate what was written: no BOM at the byte level, and parseable JSON.
$bytes = [System.IO.File]::ReadAllBytes($settings)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    throw "settings.json was written with a BOM (should be impossible) - restore from $backup"
}
try {
    [System.IO.File]::ReadAllText($settings) | ConvertFrom-Json | Out-Null
    Write-Host "  [ok] status line registered; settings.json is valid JSON" -ForegroundColor Green
} catch { throw "settings.json became invalid - restore from $backup. $_" }

# --- 1b. Install the /moth slash command (restarts the widget from any session) ---
$tmpl = Join-Path $root 'commands\moth.md.tmpl'
if (Test-Path $tmpl) {
    $cmdsDir = Join-Path $env:USERPROFILE '.claude\commands'
    New-Item -ItemType Directory -Force -Path $cmdsDir | Out-Null
    $mothMd = (Get-Content $tmpl -Raw).Replace('__RESTART_PATH__', (Join-Path $root 'restart-widget.ps1')).Replace('__ROOT__', $root)
    Write-Utf8NoBom (Join-Path $cmdsDir 'moth.md') $mothMd
    Write-Host "  [ok] /moth restart command installed" -ForegroundColor Green
}

# --- 2. Startup shortcut -> hidden VBS launcher. OPT-IN, default OFF: the widget is
#        meant to launch from Claude sessions (see below), not Windows login. Pass
#        -AutoStart to create it; without it, remove any shortcut a prior install left. ---
$startup = [Environment]::GetFolderPath('Startup')
$lnk     = Join-Path $startup 'Claude Usage Widget.lnk'
if ($AutoStart) {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath  = 'wscript.exe'
    $sc.Arguments   = '"' + $vbs + '"'
    $sc.WorkingDirectory = $root
    $sc.WindowStyle = 7
    $sc.Description  = 'Moth usage widget'
    $sc.Save()
    Write-Host "  [ok] auto-start on login ENABLED (-AutoStart)" -ForegroundColor Green
} else {
    if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue }
    Write-Host "  [ok] auto-start on login OFF (launches from Claude sessions; pass -AutoStart to enable)" -ForegroundColor Green
}

# --- 3. (Re)start it now, hidden. Stop only an instance running THIS folder's
#        widget.ps1 (full-path match) so unrelated scripts named widget.ps1 are safe. ---
try {
    $mine = '*' + [System.Management.Automation.WildcardPattern]::Escape((Join-Path $root 'widget.ps1')) + '*'
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like $mine } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }
# Let the old process fully tear down so it releases the single-instance mutex before
# the new widget tries to acquire it (otherwise the fresh instance would exit as a dup).
Start-Sleep -Milliseconds 700
Start-Process 'wscript.exe' -ArgumentList ('"' + $vbs + '"')
Write-Host "  [ok] widget started" -ForegroundColor Green

Write-Host "`nDone. The widget is on your desktop (top-left by default - drag it anywhere)." -ForegroundColor Cyan
Write-Host "It fills in the moment your next Claude Code session makes its first request." -ForegroundColor Cyan
Write-Host "To remove it later, run uninstall.ps1." -ForegroundColor DarkGray
