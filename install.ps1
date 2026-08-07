# install.ps1 — one-time setup. Safe to re-run (idempotent).
#   1. Registers capture-usage.ps1 as the Claude Code status-line command (merged into
#      ~/.claude/settings.json, preserving everything already there).
#   2. Adds a Startup shortcut so the widget launches (hidden) on every login.
#   3. Starts the widget now.
# Run:  powershell.exe -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = 'Stop'
$root       = $PSScriptRoot
$capture    = Join-Path $root 'capture-usage.ps1'
$vbs        = Join-Path $root 'launch-widget.vbs'
$settings   = Join-Path $env:USERPROFILE '.claude\settings.json'

Write-Host "Installing Claude usage widget..." -ForegroundColor Cyan

# --- 1. Register the status-line capture command (merge, don't clobber) ---
$cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $capture + '"'
if (Test-Path $settings) {
    $cfg = Get-Content $settings -Raw | ConvertFrom-Json
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $settings) | Out-Null
    $cfg = [pscustomobject]@{}
}
$sl = [pscustomobject]@{ type = 'command'; command = $cmd; padding = 0 }
if ($cfg.PSObject.Properties.Name -contains 'statusLine') { $cfg.statusLine = $sl }
else { $cfg | Add-Member -NotePropertyName statusLine -NotePropertyValue $sl }
$cfg | ConvertTo-Json -Depth 100 | Set-Content -Path $settings -Encoding UTF8

# Validate we didn't corrupt settings.json
try { Get-Content $settings -Raw | ConvertFrom-Json | Out-Null; Write-Host "  [ok] status line registered; settings.json is valid JSON" -ForegroundColor Green }
catch { throw "settings.json became invalid - restore from backup. $_" }

# --- 2. Startup shortcut -> the hidden VBS launcher (idempotent) ---
$startup = [Environment]::GetFolderPath('Startup')
$lnk     = Join-Path $startup 'Claude Usage Widget.lnk'
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnk)
$sc.TargetPath  = 'wscript.exe'
$sc.Arguments   = '"' + $vbs + '"'
$sc.WorkingDirectory = $root
$sc.WindowStyle = 7
$sc.Description  = 'Claude usage widget'
$sc.Save()
Write-Host "  [ok] auto-start on login enabled" -ForegroundColor Green

# --- 3. Start it now (hidden) ---
Start-Process 'wscript.exe' -ArgumentList ('"' + $vbs + '"')
Write-Host "  [ok] widget started" -ForegroundColor Green

Write-Host "`nDone. The widget is on your desktop (top-left by default - drag it anywhere)." -ForegroundColor Cyan
Write-Host "It fills in the moment your next Claude Code session makes its first request." -ForegroundColor Cyan
Write-Host "To remove it later, run uninstall.ps1." -ForegroundColor DarkGray
