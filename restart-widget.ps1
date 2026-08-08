# restart-widget.ps1 - stop this folder's widget (if running) and relaunch it.
# Invoked by the /moth slash command. Uses the SAME strict full-path match as
# install.ps1 so an unrelated widget.ps1 elsewhere on the machine is never killed.
# Prints a single OK:/ERROR: line on stdout for the slash command to relay.
#
# Note on window position: Stop-Process is a forceful kill that bypasses widget.ps1's
# WPF Closing handler. widget.ps1 persists its position periodically (not only on
# close), so a restart reloads the most recent position rather than a stale one.
$ErrorActionPreference = 'SilentlyContinue'
$root = $PSScriptRoot
$vbs  = Join-Path $root 'launch-widget.vbs'
# Strict full-path match, identical to install.ps1, so we never touch a stranger's widget.ps1.
$mine = '*' + [System.Management.Automation.WildcardPattern]::Escape((Join-Path $root 'widget.ps1')) + '*'

# 1. Stop any instance running THIS folder's widget.ps1.
$stopped = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like $mine } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; $stopped++ }

# 2. Let the OS tear the old process down and release the single-instance mutex
#    before the new instance tries to acquire it.
Start-Sleep -Milliseconds 700

# 3. Relaunch hidden via the VBS (no console window).
Start-Process 'wscript.exe' -ArgumentList ('"' + $vbs + '"')

# 4. Confirm the new instance came up and report.
Start-Sleep -Milliseconds 1300
$now = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like $mine })
if ($now.Count -ge 1) {
    $pids = ($now | ForEach-Object { $_.ProcessId }) -join ', '
    "OK: Moth restarted (stopped $stopped, now running PID $pids)."
} else {
    "ERROR: Moth did not relaunch. Check $root\widget-error.log"
}
