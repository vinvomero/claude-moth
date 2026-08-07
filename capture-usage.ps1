# capture-usage.ps1
# Registered as the Claude Code `statusLine` command.
# On each render it (1) prints a compact status line to stdout, and
# (2) if the official `rate_limits` payload is present, snapshots it to
# usage-cache.json for the desktop widget to read.
# Never throws: a bad/absent payload must not break the terminal status line.

$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
$cacheFile = Join-Path $PSScriptRoot 'usage-cache.json'

$data = $null
if ($raw) { try { $data = $raw | ConvertFrom-Json } catch { } }

$parts = @()

# Working directory + model, for a useful in-terminal status line
$dir = $null
if ($data.workspace.current_dir) { $dir = $data.workspace.current_dir }
elseif ($data.cwd)               { $dir = $data.cwd }
if ($dir) { $parts += (Split-Path $dir -Leaf) }
if ($data.model.display_name) { $parts += $data.model.display_name }

# Official usage feed (Claude Code >= 2.1.80)
$rl = $data.rate_limits
if ($rl -and $rl.five_hour -and $null -ne $rl.five_hour.used_percentage) {
    $obj = [ordered]@{
        five_hour   = [ordered]@{
            used_percentage = [double]$rl.five_hour.used_percentage
            resets_at       = [long]$rl.five_hour.resets_at
        }
        seven_day   = [ordered]@{
            used_percentage = [double]$rl.seven_day.used_percentage
            resets_at       = [long]$rl.seven_day.resets_at
        }
        captured_at = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    $json = $obj | ConvertTo-Json -Depth 5
    $tmp  = "$cacheFile.tmp"
    # Atomic write: temp file, then replace, so the widget never reads a half-written file.
    Set-Content -Path $tmp -Value $json -Encoding UTF8
    Move-Item -Path $tmp -Destination $cacheFile -Force

    $p5 = [math]::Round([double]$rl.five_hour.used_percentage)
    $p7 = [math]::Round([double]$rl.seven_day.used_percentage)
    $parts += ("5h {0}%  wk {1}%" -f $p5, $p7)
}

if ($parts.Count -eq 0) { $parts += 'Claude' }
[Console]::Out.Write(($parts -join '  |  '))
