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

# 1. Close a running widget - full-path match so unrelated widget.ps1 scripts are safe.
# Match only REAL launches (`-File ...\widget.ps1`); never a headless dev run or the
# -Command wrapper that merely references the path.
$mine = '*' + [System.Management.Automation.WildcardPattern]::Escape((Join-Path $root 'widget.ps1')) + '*'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like $mine -and $_.CommandLine -like '*-File*' -and
        $_.CommandLine -notlike '*-SelfTest*' -and $_.CommandLine -notlike '*-Screenshot*' -and $_.CommandLine -notlike '*-Command*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 2. Remove Startup shortcut
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Widget.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "  [ok] auto-start removed" -ForegroundColor Green }

# 2b. Remove the /moth slash command
$mothCmd = Join-Path $env:USERPROFILE '.claude\commands\moth.md'
if (Test-Path $mothCmd) { Remove-Item $mothCmd -Force; Write-Host "  [ok] /moth command removed" -ForegroundColor Green }

# 3. Strip OUR statusLine from settings.json (leave a foreign one alone)
if (Test-Path $settings) {
    try {
        $cfg = Get-Content $settings -Raw | ConvertFrom-Json
        if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'statusLine')) {
            if ($cfg.statusLine.command -like '*capture-usage.ps1*') {
                # If install replaced a status line the user already had, restore that
                # ONE property from the pristine pre-install backup - do NOT overwrite
                # the backup (it is the only pristine copy) and do NOT wipe unrelated
                # settings the user has added since installing.
                $priorSl = $null
                if (Test-Path $backup) {
                    try {
                        $pre = Get-Content $backup -Raw | ConvertFrom-Json
                        if ($pre.PSObject.Properties.Name -contains 'statusLine') { $priorSl = $pre.statusLine }
                    } catch { }
                }
                if ($priorSl -and ($priorSl.command -notlike '*capture-usage.ps1*')) {
                    $cfg.statusLine = $priorSl
                    Write-Host "  [ok] restored your pre-install status line" -ForegroundColor Green
                } else {
                    $cfg.PSObject.Properties.Remove('statusLine')
                    Write-Host "  [ok] status line entry removed; settings.json still valid" -ForegroundColor Green
                }
                Write-Utf8NoBom $settings ($cfg | ConvertTo-Json -Depth 100)
            } else {
                Write-Host "  [skip] statusLine now belongs to something else - leaving it alone" -ForegroundColor Yellow
            }
        }
    } catch { Write-Host "  [skip] could not edit settings.json" -ForegroundColor Yellow }
}
Write-Host "`nUninstalled. The project folder is still here if you want to reinstall later." -ForegroundColor Cyan
