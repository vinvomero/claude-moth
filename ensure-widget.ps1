# ensure-widget.ps1 - start the widget if it isn't already running.
# Registered as a Claude Code SessionStart hook so the widget reappears whenever
# a Claude session starts, even if it was closed earlier. Safe to run repeatedly.
#
# The match requires the path separator before widget.ps1 ('\widget.ps1') and
# excludes this script's own process: this file's name ALSO ends in "widget.ps1",
# so a looser match would see itself and always skip the launch.
$root = $PSScriptRoot
# Strict full-path match (same pattern as install.ps1 and restart-widget.ps1): match
# only THIS folder's widget.ps1, never an unrelated script that happens to be named
# widget.ps1. The old loose regex ('-File.*\widget.ps1') matched any of them.
$mine = '*' + [System.Management.Automation.WildcardPattern]::Escape((Join-Path $root 'widget.ps1')) + '*'
# Match only REAL launches (`-File ...\widget.ps1`); exclude the headless dev modes and
# the -Command wrapper so a -SelfTest run is never mistaken for the running widget.
$running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like $mine -and $_.CommandLine -like '*-File*' -and
        $_.CommandLine -notlike '*-SelfTest*' -and $_.CommandLine -notlike '*-Screenshot*' -and $_.CommandLine -notlike '*-Command*' })
if ($running.Count -eq 0) {
    Start-Process 'wscript.exe' -ArgumentList ('"' + (Join-Path $root 'launch-widget.vbs') + '"')
}
