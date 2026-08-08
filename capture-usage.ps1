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

# --- DIAGNOSTIC BREADCRUMB (U1) ---------------------------------------------
# Gated debug flag, OFF by default. Flip to $true to diagnose capture invocation:
# it appends two lines per run to capture-debug.log ("IN" on entry with stdin length,
# "OUT" with parsed rate_limits) so you can tell apart never-invoked / dies-mid-script /
# full-run, and whether the payload carried rate_limits. Confirmed working 2026-08-07.
$DebugBreadcrumb = $false
$breadcrumbFile = Join-Path $PSScriptRoot 'capture-debug.log'
function Write-Breadcrumb($msg) {
    if (-not $DebugBreadcrumb) { return }
    try {
        $ts = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ',
            [System.Globalization.CultureInfo]::InvariantCulture)
        [System.IO.File]::AppendAllText($breadcrumbFile, "[$ts] $msg`r`n",
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}
Write-Breadcrumb ("IN  invoked; stdin length={0}" -f ($(if ($null -eq $raw) { -1 } else { $raw.Length })))
# ----------------------------------------------------------------------------

function Write-Utf8NoBom($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}
# Parse a percentage into [0,100], or $null if not a real finite number.
# InvariantCulture is required: JSON is always dot-decimal, but plain TryParse uses
# the OS locale - on comma-decimal locales (de-DE etc.) it reads "42.3" as 423.
function ConvertTo-Pct($v) {
    $d = 0.0
    if ([double]::TryParse([string]$v, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
        return [math]::Max(0.0, [math]::Min(100.0, $d))
    }
    return $null
}
# Parse an epoch-seconds value, or $null if not a real integer.
function ConvertTo-Epoch($v) {
    $l = [long]0
    if ([long]::TryParse([string]$v, [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$l)) { return $l }
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
    }
    # The statusLine feed has no per-model data; if the widget's optional endpoint
    # poll stored a fable bucket, carry it forward instead of wiping the third bar.
    if (Test-Path $cacheFile) {
        try {
            $prev = Get-Content $cacheFile -Raw | ConvertFrom-Json
            if ($prev.fable) { $obj.fable = $prev.fable }
        } catch { }
    }
    $obj.captured_at = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $json = $obj | ConvertTo-Json -Depth 5
    if ($json -and $json.Trim().Length -gt 2) {
        $tmp = "$cacheFile.$PID.tmp"
        # Atomic + BOM-less: temp file, then File.Replace (a true atomic swap -
        # Move-Item -Force is delete-then-move, leaving a gap a reader can hit).
        # [NullString]::Value, not $null: PowerShell turns $null into "" for .NET
        # string parameters, and Replace rejects "" as an illegal path.
        # Per-writer temp name ($PID): the widget's endpoint poll writes the same cache,
        # and a shared "$cacheFile.tmp" could collide mid-swap. The whole swap is wrapped
        # because .NET File.Replace throws a TERMINATING exception that
        # $ErrorActionPreference='SilentlyContinue' does not catch - unguarded, a rare
        # collision would kill this script before it finished the status line.
        try {
            Write-Utf8NoBom $tmp $json
            if (Test-Path $cacheFile) { [System.IO.File]::Replace($tmp, $cacheFile, [NullString]::Value) }
            else { Move-Item -Path $tmp -Destination $cacheFile -Force }
        } catch { try { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } catch { } }
    }
    $parts += ("5h {0}%  wk {1}%" -f [math]::Round($p5), [math]::Round($p7))
}

Write-Breadcrumb ("OUT rate_limits={0} p5={1} r5={2} p7={3} r7={4}" -f `
    ($(if ($rl) { 'yes' } else { 'no' })), $p5, $r5, $p7, $r7)

if ($parts.Count -eq 0) { $parts += 'Claude' }
[Console]::Out.Write(($parts -join '  |  '))

# --- ensure the Moth widget is running (U3) ---------------------------------
# Runs LAST, after the status line is already written to stdout, so a slow process
# query never delays the render or (worse) kills this process before the cache write.
# Strict full-path match (same as install.ps1) so an unrelated widget.ps1 is safe.
# In terminal sessions this launches the widget the moment Claude first renders; in
# the desktop app the status line isn't invoked at all, so this simply never runs.
try {
    $vbs  = Join-Path $PSScriptRoot 'launch-widget.vbs'
    $mine = '*' + [System.Management.Automation.WildcardPattern]::Escape((Join-Path $PSScriptRoot 'widget.ps1')) + '*'
    # Match only REAL launches (`-File ...\widget.ps1`); exclude the headless dev modes
    # and the -Command wrapper so a -SelfTest run is never counted as "already running".
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like $mine -and $_.CommandLine -like '*-File*' -and
            $_.CommandLine -notlike '*-SelfTest*' -and $_.CommandLine -notlike '*-Screenshot*' -and $_.CommandLine -notlike '*-Command*' })
    # Respect a user-close within the session: don't relaunch while the hidden marker
    # exists (a new session's SessionStart hook, or /moth, clears it and brings Moth back).
    $hidden = Join-Path $PSScriptRoot 'widget-hidden.flag'
    if ($running.Count -eq 0 -and (Test-Path $vbs) -and -not (Test-Path $hidden)) {
        Start-Process 'wscript.exe' -ArgumentList ('"' + $vbs + '"')
        Write-Breadcrumb 'LAUNCH widget not running -> started launcher'
    }
} catch { }
