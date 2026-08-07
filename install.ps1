# install.ps1 - one-time setup. Safe to re-run (idempotent).
#   1. Registers capture-usage.ps1 as the Claude Code status-line command (merged into
#      ~/.claude/settings.json, preserving everything already there).
#   2. Adds a Startup shortcut so the widget launches (hidden) on every login.
#   3. Starts the widget now (replacing any instance already running).
# Run:  powershell.exe -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = 'Stop'
$root       = $PSScriptRoot
$capture    = Join-Path $root 'capture-usage.ps1'
$vbs        = Join-Path $root 'launch-widget.vbs'
$settings   = Join-Path $env:USERPROFILE '.claude\settings.json'

function Write-Utf8NoBom($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "Installing Claude usage widget..." -ForegroundColor Cyan

# --- 1. Register the status-line capture command (merge, don't clobber) ---
$cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $capture + '"'
if (Test-Path $settings) {
    $cfg = Get-Content $settings -Raw | ConvertFrom-Json
    if (-not $cfg) { $cfg = [pscustomobject]@{} }   # empty/whitespace file -> start fresh
    # Back up the current settings before touching them (matches the error message below).
    Copy-Item $settings "$settings.bak" -Force
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $settings) | Out-Null
    $cfg = [pscustomobject]@{}
}

# Don't silently replace a status line the user set for something else.
if (($cfg.PSObject.Properties.Name -contains 'statusLine') -and
    $cfg.statusLine.command -and ($cfg.statusLine.command -notlike '*capture-usage.ps1*')) {
    Write-Host "  [warn] You already have a custom statusLine command:" -ForegroundColor Yellow
    Write-Host "         $($cfg.statusLine.command)" -ForegroundColor DarkGray
    Write-Host "         Replacing it with the usage widget's. Your previous settings.json is at:" -ForegroundColor Yellow
    Write-Host "         $settings.bak" -ForegroundColor DarkGray
}

$sl = [pscustomobject]@{ type = 'command'; command = $cmd; padding = 0 }
if ($cfg.PSObject.Properties.Name -contains 'statusLine') { $cfg.statusLine = $sl }
else { $cfg | Add-Member -NotePropertyName statusLine -NotePropertyValue $sl }
Write-Utf8NoBom $settings ($cfg | ConvertTo-Json -Depth 100)

# Validate: parse the raw BYTES the way a JSON consumer would (no BOM-stripping reader).
try {
    [System.IO.File]::ReadAllText($settings) | ConvertFrom-Json | Out-Null
    Write-Host "  [ok] status line registered; settings.json is valid JSON" -ForegroundColor Green
} catch { throw "settings.json became invalid - restore from $settings.bak. $_" }

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

# --- 3. (Re)start it now, hidden -- stop any existing instance first so re-running
#        install.ps1 never stacks duplicate windows. ---
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*$([IO.Path]::GetFileName($root))\widget.ps1*" -or $_.CommandLine -like '*\widget.ps1*' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
Start-Process 'wscript.exe' -ArgumentList ('"' + $vbs + '"')
Write-Host "  [ok] widget started" -ForegroundColor Green

Write-Host "`nDone. The widget is on your desktop (top-left by default - drag it anywhere)." -ForegroundColor Cyan
Write-Host "It fills in the moment your next Claude Code session makes its first request." -ForegroundColor Cyan
Write-Host "To remove it later, run uninstall.ps1." -ForegroundColor DarkGray
