# capture-codex.ps1
# Polls the LOCAL Codex app-server for ChatGPT usage limits and publishes a snapshot
# to %LOCALAPPDATA%\Moth\codex-cache.json for the Moth widget to read.
#
# Moth NEVER reads Codex credentials: `codex app-server` owns its own login and does
# the backend call itself. We only speak JSON-RPC to it over stdio.
#
# NEVER launches the bare `codex` TUI - that can start an interactive browser sign-in.
# Only the `app-server` subcommand, with no console window.
#
# Runs as its OWN process (launched hidden by the widget's Codex timer) so the widget's
# WPF dispatcher thread never blocks on a process spawn + live backend call. The widget
# is a pure reader of the cache.
#
# Run by hand:
#   powershell -NoProfile -ExecutionPolicy Bypass -File capture-codex.ps1
#
# Exit codes (the widget reads `last_error.class` from the cache, not these, but they
# make a hand-run legible):
#   0 ok | 2 timeout | 3 rpc-error | 4 parse-fail/no-reply | 5 binary-missing/spawn-failed
#   6 already-running | 7 exited (the CLI died before answering)

param(
    # Test hook: point at a stand-in executable. Overrides every discovery step below.
    [string]$CodexExe,
    # Hard deadline for the whole exchange. Must stay well under the widget's poll
    # interval and under its 30s anomaly-path kill.
    [int]$DeadlineMs = 8000,
    # Test hook: read the CODEX_CLI_PATH record from somewhere other than the real file.
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.codex\config.toml'),
    # Test hook: glob for codex.exe somewhere other than the real install root.
    [string]$BinRoot = (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin')
)

$ErrorActionPreference = 'SilentlyContinue'

$mothDir   = Join-Path $env:LOCALAPPDATA 'Moth'
$cacheFile = Join-Path $mothDir 'codex-cache.json'
$stateFile = Join-Path $PSScriptRoot 'window-state.json'
$logFile   = Join-Path $PSScriptRoot 'widget-error.log'

# --- shared idioms, mirrored from capture-usage.ps1 / widget.ps1 -------------------

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

# Parse an epoch-seconds value, or $null if not a real integer. Values larger than
# 1e11 are epoch MILLIseconds (the app-server documents seconds, but a future build
# changing units would otherwise render a countdown ~50000 years out).
function ConvertTo-Epoch($v) {
    $l = [long]0
    if ([long]::TryParse([string]$v, [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$l)) {
        if ($l -gt 100000000000) { return [long][math]::Floor($l / 1000) }
        return $l
    }
    return $null
}

# Clamp a reset stamp to a believable window before it reaches the widget's countdown
# arithmetic. This value comes from an undocumented external API; the Claude path does
# not need this because its feed is Anthropic's own.
# $now is injectable so fixture tests stay deterministic instead of ageing out.
function Limit-ResetsAt($epoch, $now) {
    if ($null -eq $epoch) { return $null }
    if ($null -eq $now) { $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    if ($epoch -lt ($now - 86400)) { return $null }
    if ($epoch -gt ($now + 31536000)) { return $null }
    return $epoch
}

function Write-ErrorLog($msg) {
    try {
        $ts = [DateTimeOffset]::UtcNow.ToString('u', [System.Globalization.CultureInfo]::InvariantCulture)
        Add-Content -Path $logFile -Value ("[{0}] {1}" -f $ts, $msg)
    } catch { }
}

# --- discovery --------------------------------------------------------------------

# Resolve the Codex executable. `codex` is NOT on PATH; the desktop app installs it
# under a per-build hash folder that is REPLACED on update (observed 2026-09-03: the
# folder changed and the app rewrote CODEX_CLI_PATH in its own config.toml one minute
# later). So: explicit override, then the app's own record, then newest-by-write-time.
# A sibling hash folder can exist holding only rg.exe, which is why the glob matches
# codex.exe specifically rather than picking a directory.
function Find-CodexExe($override, $configPath, $binRoot) {
    if ($override) {
        if (Test-Path -LiteralPath $override -PathType Leaf) { return $override }
        return $null
    }
    if ($configPath -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        try {
            $line = Select-String -LiteralPath $configPath -Pattern 'CODEX_CLI_PATH' |
                Select-Object -First 1
            if ($line) {
                $m = [regex]::Match([string]$line.Line, "CODEX_CLI_PATH\s*=\s*['""]([^'""]+)['""]")
                if ($m.Success) {
                    $p = $m.Groups[1].Value
                    if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
                }
            }
        } catch { }
    }
    # An npm install (`npm i -g @openai/codex`) has no desktop hash folder and no
    # CODEX_CLI_PATH, so PATH is the only way to find it. npm writes codex, codex.cmd AND
    # codex.ps1 side by side and PowerShell resolves the .ps1 FIRST - but Process.Start
    # with UseShellExecute=$false rejects a .ps1 outright ("not a valid application for
    # this OS platform"). So: take the first .exe, else the first .cmd, never the .ps1.
    try {
        $onPath = @(Get-Command 'codex' -CommandType Application -All -ErrorAction SilentlyContinue)
        $pick = @($onPath | Where-Object { $_.Source -match '\.exe$' }) | Select-Object -First 1
        if (-not $pick) { $pick = @($onPath | Where-Object { $_.Source -match '\.cmd$' }) | Select-Object -First 1 }
        if ($pick) { return $pick.Source }
    } catch { }
    if ($binRoot -and (Test-Path -LiteralPath $binRoot)) {
        try {
            $hit = @(Get-ChildItem -LiteralPath $binRoot -Filter 'codex.exe' -Recurse -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending) | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        } catch { }
    }
    return $null
}

# .NET Framework has no process-tree kill, and an npm .cmd shim runs as
# cmd.exe -> node -> codex.exe: killing the top process would leave a wedged app-server
# holding a dead pipe. taskkill /T is the same idiom the widget's anomaly path uses.
function Stop-ProcessTree($proc) {
    if (-not $proc) { return }
    try {
        if (-not $proc.HasExited) {
            Start-Process 'taskkill.exe' -ArgumentList '/PID', $proc.Id, '/T', '/F' `
                -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
        }
    } catch { }
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
}

# --- parsing ----------------------------------------------------------------------

# Map an app-server `result` payload to Moth's cache shape.
#
# WHITELIST, not passthrough: only the fields the widget renders are copied. accountId,
# credits, rateLimitUpsell, userAgent and codexHome are deliberately dropped - the cache
# is a plain JSON file and there is no reason for account identifiers to sit in it.
#
# Shape tolerance (every field in the snapshot is nullable per the generated schema):
#   - prefer rateLimitsByLimitId.codex, fall back to the legacy single-bucket rateLimits
#   - `primary` is REQUIRED (no 5-hour reading means no usable snapshot)
#   - `secondary` is OPTIONAL: some plans/sign-ins report no weekly bucket
#   - a null resetsAt is legitimate (no window open yet at 0% used), not a parse failure
# Returns an [ordered] hashtable, or $null when the payload carries no usable primary.
function ConvertFrom-CodexRateLimits($result, $now) {
    if ($null -eq $result) { return $null }

    $snap = $null
    if ($result.rateLimitsByLimitId -and $result.rateLimitsByLimitId.codex) {
        $snap = $result.rateLimitsByLimitId.codex
    } elseif ($result.rateLimits) {
        $snap = $result.rateLimits
    }
    if ($null -eq $snap) { return $null }

    $p5 = ConvertTo-Pct $snap.primary.usedPercent
    if ($null -eq $p5) { return $null }

    $obj = [ordered]@{}
    $obj.five_hour = [ordered]@{
        used_percentage = $p5
        resets_at       = Limit-ResetsAt (ConvertTo-Epoch $snap.primary.resetsAt) $now
        window_mins     = ConvertTo-Epoch $snap.primary.windowDurationMins
    }

    $p7 = ConvertTo-Pct $snap.secondary.usedPercent
    if ($null -ne $p7) {
        $obj.seven_day = [ordered]@{
            used_percentage = $p7
            resets_at       = Limit-ResetsAt (ConvertTo-Epoch $snap.secondary.resetsAt) $now
            window_mins     = ConvertTo-Epoch $snap.secondary.windowDurationMins
        }
    }

    if ($snap.planType) { $obj.plan_type = [string]$snap.planType }
    return $obj
}

# --- cache write ------------------------------------------------------------------

function Read-PreviousCache($path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { return $null }
}

# Atomic + BOM-less publish, same contract as capture-usage.ps1: temp file then
# File.Replace (a true atomic swap - Move-Item -Force is delete-then-move and leaves a
# gap a reader can hit). [NullString]::Value, not $null: PowerShell turns $null into ""
# for .NET string parameters and Replace rejects "" as an illegal path. Per-writer temp
# name ($PID) so two helper runs can never collide mid-swap. The whole swap is wrapped
# because File.Replace throws a TERMINATING exception that SilentlyContinue misses.
function Publish-Cache($path, $obj) {
    $json = [pscustomobject]$obj | ConvertTo-Json -Depth 6
    if (-not $json -or $json.Trim().Length -le 2) { return $false }
    $tmp = "$path.$PID.tmp"
    try {
        Write-Utf8NoBom $tmp $json
        if (Test-Path -LiteralPath $path) {
            [System.IO.File]::Replace($tmp, $path, [NullString]::Value)
        } else {
            Move-Item -LiteralPath $tmp -Destination $path -Force
        }
        return $true
    } catch {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
        return $false
    }
}

# Record a failure without discarding the last good snapshot: the widget keeps showing
# it (greying on its own captured_at) and reads last_error for honest status text.
# Logs ONE line per distinct failure - this helper is a fresh process every poll, so
# without the comparison a missing binary would write hundreds of lines a day.
function Set-LastError($class, $message, $code) {
    $prev = Read-PreviousCache $cacheFile
    $prevClass = $null
    if ($prev -and $prev.last_error) { $prevClass = [string]$prev.last_error.class }

    $obj = [ordered]@{}
    if ($prev) {
        if ($prev.five_hour)   { $obj.five_hour   = $prev.five_hour }
        if ($prev.seven_day)   { $obj.seven_day   = $prev.seven_day }
        if ($prev.plan_type)   { $obj.plan_type   = $prev.plan_type }
        if ($prev.captured_at) { $obj.captured_at = $prev.captured_at }
    }
    $trimmed = ''
    if ($message) {
        $trimmed = [string]$message
        if ($trimmed.Length -gt 200) { $trimmed = $trimmed.Substring(0, 200) }
    }
    # The CODE is recorded, not just the class: -32600 means "invalid request", which the
    # server also returns for rejected params, so "sign in" is only the right hint when
    # the message says so. -32603 is a backend failure and -32601 an outdated binary -
    # telling either of those users to sign in would send them somewhere useless.
    $obj.last_error = [ordered]@{
        class = $class
        # -as [int], never [int]. The code comes straight out of the app-server's JSON with
        # no shape check, and a hard cast on a string code ("auth_required") or one past
        # Int32 raises a TERMINATING error that SilentlyContinue does not suppress - it
        # would escape this function and both try blocks and end the run having written
        # nothing, so the widget would blame the spawn for a server that answered. -as
        # yields $null instead, and the read side already guards with Test-Numeric.
        code = $(if ($null -ne $code) { $code -as [int] } else { $null })
        message = $trimmed
        at = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    Publish-Cache $cacheFile $obj | Out-Null

    if ($prevClass -ne $class) { Write-ErrorLog ("codex: {0} - {1}" -f $class, $trimmed) }
}

# --- single-instance guard --------------------------------------------------------
# The widget skips a tick while a helper is running, but a widget restart forgets the
# in-flight child. Same idiom as the widget's own Global\MothWidget mutex.
$mutex = New-Object System.Threading.Mutex($false, 'Global\MothCodexCapture')
$holdsMutex = $false
try { $holdsMutex = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $holdsMutex = $true }
if (-not $holdsMutex) { exit 6 }

try {
    if (-not (Test-Path -LiteralPath $mothDir)) {
        New-Item -ItemType Directory -Path $mothDir -Force | Out-Null
    }

    # Override precedence: -CodexExe parameter (tests), then codex_exe in the gitignored
    # per-user state file, then discovery.
    $override = $CodexExe
    if (-not $override -and (Test-Path -LiteralPath $stateFile)) {
        try {
            $st = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            if ($st.codex_exe) { $override = [string]$st.codex_exe }
        } catch { }
    }

    $exe = Find-CodexExe $override $ConfigPath $BinRoot
    if (-not $exe) {
        Set-LastError 'binary-missing' 'codex.exe not found (override, CODEX_CLI_PATH, PATH, and bin glob all failed)'
        exit 5
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $exe
    # -s read-only -a never: the app-server never starts a thread for a rate-limit read,
    # so these are belt-and-braces, but they cost nothing and say plainly that this
    # process may not write or approve anything. --stdio is the documented default
    # transport, stated rather than assumed. All three verified accepted on codex-cli
    # 0.152.0; the Mac plugin uses the identical argument list.
    $psi.Arguments              = '-s read-only -a never app-server --stdio'
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    # CreateNoWindow maps to CREATE_NO_WINDOW: the child is a console app run with no
    # console window at all, regardless of how this script itself was launched.
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    # The app-server's tracing layer writes to stderr under RUST_LOG. Keep the drain quiet.
    try { $psi.EnvironmentVariables.Remove('RUST_LOG') } catch { }

    $proc = $null
    $reqId = 2
    $deadline = [DateTime]::UtcNow.AddMilliseconds($DeadlineMs)

    try {
        # A throwing Start used to fall straight through to the finally blocks and end the
        # script with exit 0 and NOTHING written - the launch "succeeded" from the widget's
        # side and the card silently showed no Codex at all. Record it instead.
        try { $proc = [System.Diagnostics.Process]::Start($psi) }
        catch {
            Set-LastError 'spawn-failed' ("could not start {0}: {1}" -f $exe, $_.Exception.Message)
            exit 5
        }
        if ($null -eq $proc) {
            Set-LastError 'spawn-failed' ("could not start {0}" -f $exe)
            exit 5
        }

        # Drain stderr with NO handler attached. With both streams redirected, a full
        # stderr pipe stalls the child forever - indistinguishable from a hang. The
        # internal reader null-checks the delegate, so this discards without any
        # PowerShell event machinery (which would not fire on a blocked pipeline anyway).
        $proc.BeginErrorReadLine()

        # Params are OMITTED on account/rateLimits/read: this app-server version types
        # them as unit and rejects an object with -32600 "expected unit". Newer builds
        # accept an object; omitting works on every version.
        $init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"moth","version":"0.1"},"capabilities":{"optOutNotificationMethods":["remoteControl/status/changed"]}}}'
        $proc.StandardInput.WriteLine($init)
        $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"initialized"}')
        $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}')
        $proc.StandardInput.Flush()

        # Bounded read against ONE absolute deadline. ReadLine() has no timeout, so a
        # server that accepts the connection and never answers would hang here forever
        # and WaitForExit would never be reached. Each Wait gets the REMAINING budget,
        # never a fixed per-line slice (notifications would otherwise multiply it).
        # stdin stays OPEN until the reply lands - closing it early makes the server
        # exit without answering.
        $reply = $null
        $rpcError = $null
        $lines = 0
        $bytes = 0
        while ($true) {
            $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($remaining -le 0) {
                Set-LastError 'timeout' ("no reply within {0}ms" -f $DeadlineMs)
                exit 2
            }
            $task = $proc.StandardOutput.ReadLineAsync()
            if (-not $task.Wait($remaining)) {
                # Leave the task pending: it dies with this process. Disposing the reader
                # here would fault a thread-pool thread mid-read.
                Set-LastError 'timeout' ("no reply within {0}ms" -f $DeadlineMs)
                exit 2
            }
            $line = $task.Result
            if ($null -eq $line) {
                # stdout closing does not mean the process is reaped yet, so a bare
                # HasExited check races. Wait for the real status: a codex that DIED on
                # startup (bad config, blocked by AV) is a broken install, and calling that
                # "no usable limits" sends the user to look at their plan instead.
                $rc = $null
                try { if ($proc.WaitForExit(2000)) { $rc = $proc.ExitCode } } catch { }
                if ($null -ne $rc -and $rc -ne 0) {
                    Set-LastError 'exited' ("codex exited with status {0} before answering" -f $rc)
                    exit 7
                }
                Set-LastError 'no-reply' 'app-server closed its output before answering'
                exit 4
            }
            $bytes += $line.Length
            if ($bytes -gt 1048576) {
                Set-LastError 'no-reply' 'app-server sent too much before answering'
                exit 4
            }

            $msg = $null
            try { $msg = $line | ConvertFrom-Json } catch { }
            # The line cap counts only what is NOT a well-formed notification, matching the
            # Mac plugin: a build that starts the user's MCP servers emits a burst of them
            # before answering, and counting those would pin that user at a permanent
            # failure with no knob to raise. The deadline and byte cap are the real bounds.
            if (-not ($msg -and $null -eq $msg.id -and $msg.method)) {
                $lines++
                if ($lines -gt 200) {
                    Set-LastError 'no-reply' 'app-server sent too much before answering'
                    exit 4
                }
            }
            if ($null -eq $msg) { continue }
            # Replies can arrive out of order and unsolicited notifications carry no id,
            # so match on the id we asked for rather than on position.
            $id = ConvertTo-Epoch $msg.id
            if ($null -eq $id -or $id -ne $reqId) { continue }
            # An error member wins even when a result is present alongside it.
            if ($msg.error) { $rpcError = $msg.error; break }
            $reply = $msg.result
            break
        }

        if ($rpcError) {
            # error.data may echo upstream response text - log the message only.
            Set-LastError 'rpc-error' ([string]$rpcError.message) $rpcError.code
            exit 3
        }

        $parsed = ConvertFrom-CodexRateLimits $reply
        if ($null -eq $parsed) {
            Set-LastError 'parse-fail' 'reply carried no usable primary rate-limit window'
            exit 4
        }

        $parsed.captured_at = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        # Read BEFORE the write. This used to read after Publish-Cache had already replaced
        # the file, so it always found the success snapshot it had just written and the
        # 'recovered' line could never fire - leaving widget-error.log showing every Codex
        # failure and never showing one clear.
        $prevErr = $null
        $prev = Read-PreviousCache $cacheFile
        if ($prev -and $prev.last_error) { $prevErr = $prev.last_error }

        if (-not (Publish-Cache $cacheFile $parsed)) {
            Set-LastError 'parse-fail' 'could not write codex-cache.json'
            exit 4
        }
        # Success clears the sticky error so the widget stops showing a stale hint.
        if ($prevErr) { Write-ErrorLog 'codex: recovered' }
        exit 0
    }
    finally {
        # Close stdin first (the app-server exits on stdio close), then give it a moment,
        # then kill. Kill() is asynchronous and throws if the process already exited, so
        # it is guarded and always followed by a wait. There is no process-tree kill in
        # .NET Framework - the child is killed here so the widget never has to.
        if ($proc) {
            try { $proc.StandardInput.Close() } catch { }
            try {
                if (-not $proc.WaitForExit(2000)) {
                    Stop-ProcessTree $proc
                    $proc.WaitForExit(2000) | Out-Null
                }
            } catch { }
            try { $proc.Dispose() } catch { }
        }
    }
}
finally {
    if ($holdsMutex) { try { $mutex.ReleaseMutex() } catch { } }
    try { $mutex.Dispose() } catch { }
}
