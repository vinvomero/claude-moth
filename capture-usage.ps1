# capture-usage.ps1
# Registered as the Claude Code `statusLine` command.
# On each render it (1) prints a compact status line to stdout, and
# (2) if the official `rate_limits` payload is present AND fully valid,
# atomically snapshots it to usage-cache.json for the desktop widget.
# Never throws, and never overwrites a good cache with garbage: a partial,
# non-numeric, or out-of-range payload leaves the previous snapshot intact.

$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
$cacheFile = Join-Path $PSScriptRoot 'usage-cache.json'

function Write-Utf8NoBom($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}
# Parse a percentage into [0,100], or $null if not a real number.
function ConvertTo-Pct($v) {
    $d = 0.0
    if ([double]::TryParse([string]$v, [ref]$d)) { return [math]::Max(0.0, [math]::Min(100.0, $d)) }
    return $null
}
# Parse an epoch-seconds value, or $null if not a real integer.
function ConvertTo-Epoch($v) {
    $l = [long]0
    if ([long]::TryParse([string]$v, [ref]$l)) { return $l }
    return $null
}

$data = $null
if ($raw) { try { $data = $raw | ConvertFrom-Json } catch { } }

$parts = @()

# Working directory + model, for a useful in-terminal status line
$dir = $null
if ($data.workspace.current_dir) { $dir = $data.workspace.current_dir }
elseif ($data.cwd)               { $dir = $data.cwd }
if ($dir) { $parts += (Split-Path $dir -Leaf) }
if ($data.model.display_name) { $parts += $data.model.display_name }

# Official usage feed (Claude Code >= 2.1.80).
$rl = $data.rate_limits
$p5 = $null; $r5 = $null; $p7 = $null; $r7 = $null
if ($rl) {
    $p5 = ConvertTo-Pct   $rl.five_hour.used_percentage
    $r5 = ConvertTo-Epoch $rl.five_hour.resets_at
    $p7 = ConvertTo-Pct   $rl.seven_day.used_percentage
    $r7 = ConvertTo-Epoch $rl.seven_day.resets_at
}

# Only publish when BOTH windows parsed cleanly — never poison the cache.
if ($null -ne $p5 -and $null -ne $r5 -and $null -ne $p7 -and $null -ne $r7) {
    $obj = [ordered]@{
        five_hour   = [ordered]@{ used_percentage = $p5; resets_at = $r5 }
        seven_day   = [ordered]@{ used_percentage = $p7; resets_at = $r7 }
        captured_at = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    $json = $obj | ConvertTo-Json -Depth 5
    if ($json -and $json.Trim().Length -gt 2) {
        $tmp = "$cacheFile.tmp"
        # Atomic + BOM-less: temp file, then replace, so the widget never
        # reads a half-written file and downstream JSON parsers stay happy.
        Write-Utf8NoBom $tmp $json
        Move-Item -Path $tmp -Destination $cacheFile -Force
    }
    $parts += ("5h {0}%  wk {1}%" -f [math]::Round($p5), [math]::Round($p7))
}

if ($parts.Count -eq 0) { $parts += 'Claude' }
[Console]::Out.Write(($parts -join '  |  '))
