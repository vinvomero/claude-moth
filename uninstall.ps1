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

# 2c. Remove any user-hide marker so a fresh reinstall starts clean.
Remove-Item (Join-Path $root 'widget-hidden.flag') -Force -ErrorAction SilentlyContinue

# 2d. Remove the provider-activity hooks and their out-of-repo script copy, if they were
# installed. These fire on EVERY prompt, so leaving them behind after the folder moves
# would run a missing script on every turn. Runs before step 3 so that re-reads the
# post-removal file. The hook installer fails loudly by design; never let that abort the
# rest of the uninstall.
$hookTool = Join-Path $root 'tools\install-activity-hooks.ps1'
if ((Test-Path $hookTool) -and (Test-Path $settings)) {
    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hookTool -Uninstall }
    catch { Write-Host "  [skip] could not remove activity hooks: $_" -ForegroundColor Yellow }
}

# 3. Strip OUR statusLine and SessionStart hook from settings.json (leave foreign ones
#    alone), then write once.
if (Test-Path $settings) {
    try {
        $cfg = Get-Content $settings -Raw | ConvertFrom-Json
        $changed = $false

        # 3a. statusLine - restore the user's pre-install one if install replaced it,
        #     else remove ours. Never overwrite the pristine backup, never wipe unrelated keys.
        if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'statusLine')) {
            if ($cfg.statusLine.command -like '*capture-usage.ps1*') {
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
                $changed = $true
            } else {
                Write-Host "  [skip] statusLine now belongs to something else - leaving it alone" -ForegroundColor Yellow
            }
        }

        # 3b. SessionStart hook - drop only OUR entry (the one calling ensure-widget.ps1),
        #     keep every other hook the user has. Collapse empty containers.
        if ($cfg -and $cfg.hooks -and $cfg.hooks.SessionStart) {
            $kept = @($cfg.hooks.SessionStart | Where-Object {
                -not (@($_.hooks) | Where-Object { $_.command -like '*ensure-widget.ps1*' })
            })
            if ($kept.Count -ne @($cfg.hooks.SessionStart).Count) {
                if ($kept.Count) { $cfg.hooks.SessionStart = $kept }
                else { $cfg.hooks.PSObject.Properties.Remove('SessionStart') }
                Write-Host "  [ok] SessionStart hook removed" -ForegroundColor Green
                $changed = $true
            }
        }

        if ($changed) { Write-Utf8NoBom $settings ($cfg | ConvertTo-Json -Depth 100) }
    } catch { Write-Host "  [skip] could not edit settings.json" -ForegroundColor Yellow }
}
Write-Host "`nUninstalled. The project folder is still here if you want to reinstall later." -ForegroundColor Cyan
