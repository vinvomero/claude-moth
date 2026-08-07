# uninstall.ps1 — removes the widget cleanly.
#   1. Closes any running widget.
#   2. Removes the Startup shortcut.
#   3. Removes the status-line entry from ~/.claude/settings.json (leaves everything else).
# Run:  powershell.exe -ExecutionPolicy Bypass -File uninstall.ps1

$ErrorActionPreference = 'SilentlyContinue'
$settings = Join-Path $env:USERPROFILE '.claude\settings.json'

# 1. Close running widget (any powershell hosting widget.ps1)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*widget.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 2. Remove Startup shortcut
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Widget.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "  [ok] auto-start removed" -ForegroundColor Green }

# 3. Strip statusLine from settings.json
if (Test-Path $settings) {
    try {
        $cfg = Get-Content $settings -Raw | ConvertFrom-Json
        if ($cfg.PSObject.Properties.Name -contains 'statusLine') {
            $cfg.PSObject.Properties.Remove('statusLine')
            $cfg | ConvertTo-Json -Depth 100 | Set-Content -Path $settings -Encoding UTF8
            Write-Host "  [ok] status line entry removed; settings.json still valid" -ForegroundColor Green
        }
    } catch { Write-Host "  [skip] could not edit settings.json" -ForegroundColor Yellow }
}
Write-Host "`nUninstalled. The project folder is still here if you want to reinstall later." -ForegroundColor Cyan
