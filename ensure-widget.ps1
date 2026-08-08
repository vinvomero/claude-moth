# ensure-widget.ps1 - start the widget if it isn't already running.
# Registered as a Claude Code SessionStart hook so the widget reappears whenever
# a Claude session starts, even if it was closed earlier. Safe to run repeatedly.
#
# The match requires the path separator before widget.ps1 ('\widget.ps1') and
# excludes this script's own process: this file's name ALSO ends in "widget.ps1",
# so a looser match would see itself and always skip the launch.
$root = $PSScriptRoot
$running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-File.*\\widget\.ps1' })
if ($running.Count -eq 0) {
    Start-Process 'wscript.exe' -ArgumentList ('"' + (Join-Path $root 'launch-widget.vbs') + '"')
}
