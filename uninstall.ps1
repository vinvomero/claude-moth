# uninstall.ps1 - removes the widget cleanly.
#   1. Closes any running widget (this folder's widget.ps1 only).
#   2. Removes the Startup shortcut.
#   3. Removes the status-line entry from ~/.claude/settings.json - but only if it
#      is still ours; a statusLine the user changed since installing is left alone.
# Run:  powershell.exe -ExecutionPolicy Bypass -File uninstall.ps1

$ErrorActionPreference = 'SilentlyContinue'
$root     = $PSScriptRoot
$settings = Join-Path $env:USERPROFILE '.claude\settings.json'
$backup   = Join-Path $env:USERPROFILE '.claude\settings.json.usage-widget.bak'

function Write-Utf8NoBom($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# 1. Close a running widget - full-path match so unrelated widget.ps1 scripts are safe
$mine = '*' + [System.Management.Automation.WildcardPattern]::Escape((Join-Path $root 'widget.ps1')) + '*'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like $mine } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 2. Remove Startup shortcut
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Widget.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "  [ok] auto-start removed" -ForegroundColor Green }

# 3. Strip OUR statusLine from settings.json (leave a foreign one alone)
if (Test-Path $settings) {
    try {
        $cfg = Get-Content $settings -Raw | ConvertFrom-Json
        if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'statusLine')) {
            if ($cfg.statusLine.command -like '*capture-usage.ps1*') {
                Copy-Item $settings $backup -Force
                $cfg.PSObject.Properties.Remove('statusLine')
                Write-Utf8NoBom $settings ($cfg | ConvertTo-Json -Depth 100)
                Write-Host "  [ok] status line entry removed; settings.json still valid" -ForegroundColor Green
            } else {
                Write-Host "  [skip] statusLine now belongs to something else - leaving it alone" -ForegroundColor Yellow
            }
        }
    } catch { Write-Host "  [skip] could not edit settings.json" -ForegroundColor Yellow }
}
Write-Host "`nUninstalled. The project folder is still here if you want to reinstall later." -ForegroundColor Cyan
