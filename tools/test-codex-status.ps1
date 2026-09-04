# test-codex-status.ps1
# Asserts the WINDOWS half of tools/fixtures/codex-status-strings.json against the widget
# that actually renders it.
#
# WHY THIS EXISTS: that fixture file claims to be one source of truth stopping the two
# platforms from telling the same user two different stories - but for a while only the
# Mac harness read it, so the Windows strings were free to drift and the file's own comment
# was untrue. The classification this covers is the whole point of the Codex work: telling
# someone to sign in when their install is broken, or that their plan has no limits when
# the CLI crashed, is worse than showing nothing.
#
# It drives the REAL widget headlessly (-SelfTest + -CodexFixture + -StatePath), so it
# asserts what a user sees, not what a helper function returns.
#
# Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\test-codex-status.ps1

$ErrorActionPreference = 'Stop'
$root     = Split-Path $PSScriptRoot -Parent
$widget   = Join-Path $root 'widget.ps1'
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$strings  = Get-Content (Join-Path $fixtures 'codex-status-strings.json') -Raw | ConvertFrom-Json
$src      = Get-Content $widget -Raw

$pass = 0; $fail = 0
function Check($name, $got, $expect) {
    if ($got -eq $expect) { $script:pass++; Write-Host "  PASS  $name -> $got" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $name`n          expected: $expect`n          got:      $got" -ForegroundColor Red }
}
function CheckThat($name, $ok, $detail) {
    if ($ok) { $script:pass++; Write-Host "  PASS  $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $name  $detail" -ForegroundColor Red }
}
function W8($p, $t) { [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false))) }

$tmp = Join-Path $env:TEMP ("moth-status-test-" + $PID)
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    # A throwaway state file with the flag on. -StatePath keeps the author's real
    # window-state.json and window size out of this entirely.
    $state = Join-Path $tmp 'state.json'; W8 $state '{ "codex": true }'
    # A healthy Claude cache, so anything that shows up in the status line came from the
    # Codex side and nothing else.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $claude = Join-Path $tmp 'claude.json'
    W8 $claude (@{
        five_hour = @{ used_percentage = 42; resets_at = ($now + 3600) }
        seven_day = @{ used_percentage = 19; resets_at = ($now + 300000) }
        captured_at = $now
    } | ConvertTo-Json)

    # Run the widget against one Codex cache and return the status text it painted.
    function Get-StatusText($codexCachePath) {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget `
            -SelfTest $claude -CodexFixture $codexCachePath -Provider codex -StatePath $state
        $line = @($out | Where-Object { $_ -like 'SELFTEST OK*' }) | Select-Object -First 1
        if (-not $line) { return "<no SELFTEST line: $out>" }
        # SELFTEST OK | Pct5=... | Pct7=... | <status text> | Win=... | ...
        return ([string]$line -split ' \| ')[3]
    }

    # Build a cache carrying one last_error, the shape capture-codex.ps1 publishes.
    function New-ErrorCache($name, $class, $code, $message) {
        $p = Join-Path $tmp "$name.json"
        $err = [ordered]@{ class = $class; code = $code; message = $message; at = $now }
        W8 $p ([pscustomobject]@{ last_error = $err } | ConvertTo-Json -Depth 5)
        return $p
    }

    Write-Host "`ncodex status: every failure class renders its own name"
    Check 'binary-missing' (Get-StatusText (New-ErrorCache 'bm' 'binary-missing' $null 'not found')) $strings.'binary-missing'.windows
    Check 'spawn-failed'   (Get-StatusText (New-ErrorCache 'sf' 'spawn-failed' $null 'could not start')) $strings.'spawn-failed'.windows
    Check 'exited'         (Get-StatusText (New-ErrorCache 'ex' 'exited' $null 'codex exited with status 1')) $strings.'exited'.windows
    Check 'no-reply'       (Get-StatusText (New-ErrorCache 'nr' 'no-reply' $null 'closed its output')) $strings.'no-reply'.windows
    Check 'parse-fail'     (Get-StatusText (New-ErrorCache 'pf' 'parse-fail' $null 'no usable primary')) $strings.'parse-fail'.windows
    Check 'timeout'        (Get-StatusText (New-ErrorCache 'to' 'timeout' $null 'no reply within 8000ms')) $strings.'timeout'.windows

    Write-Host "`ncodex status: JSON-RPC codes are told apart, not lumped together"
    Check 'rpc -32600 WITH an auth message' `
        (Get-StatusText (New-ErrorCache 'a1' 'rpc-error' -32600 'chatgpt authentication required to read rate limits')) `
        $strings.'rpc-auth'.windows
    # Same code, different cause. -32600 is JSON-RPC's generic "invalid request" and the
    # server also returns it for rejected params; telling that user to sign in is wrong.
    Check 'rpc -32600 WITHOUT an auth message' `
        (Get-StatusText (New-ErrorCache 'a2' 'rpc-error' -32600 'expected unit for params')) `
        ($strings.'rpc-other'.windows -f -32600)
    Check 'rpc -32601 (outdated build)' `
        (Get-StatusText (New-ErrorCache 'a3' 'rpc-error' -32601 'method not found')) $strings.'rpc-too-old'.windows
    Check 'rpc -32603 (backend)' `
        (Get-StatusText (New-ErrorCache 'a4' 'rpc-error' -32603 'upstream unavailable')) $strings.'rpc-backend'.windows
    Check 'rpc -32001 (overloaded)' `
        (Get-StatusText (New-ErrorCache 'a5' 'rpc-error' -32001 'server overloaded')) $strings.'rpc-overloaded'.windows
    Check 'rpc with an unknown code' `
        (Get-StatusText (New-ErrorCache 'a6' 'rpc-error' -32099 'something new')) ($strings.'rpc-other'.windows -f -32099)
    # A null code must not become 0 - PS 5.1 turns $null into 0 on a numeric cast, which
    # would render "Codex error 0" for a failure that carried no code at all.
    Check 'rpc with NO code at all' `
        (Get-StatusText (New-ErrorCache 'a7' 'rpc-error' $null 'no code supplied')) $strings.'rpc-backend'.windows

    Write-Host "`ncodex status: the committed fixtures render what they claim to"
    Check 'fixture: auth-error'   (Get-StatusText (Join-Path $fixtures 'codex-cache.auth-error.json'))   $strings.'rpc-auth'.windows
    Check 'fixture: backend-error'(Get-StatusText (Join-Path $fixtures 'codex-cache.backend-error.json'))$strings.'rpc-backend'.windows
    Check 'fixture: error-only'   (Get-StatusText (Join-Path $fixtures 'codex-cache.error-only.json'))   $strings.'binary-missing'.windows
    Check 'fixture: parse-fail'   (Get-StatusText (Join-Path $fixtures 'codex-cache.parse-fail.json'))   $strings.'parse-fail'.windows
    Check 'fixture: spawn-failed' (Get-StatusText (Join-Path $fixtures 'codex-cache.spawn-failed.json')) $strings.'spawn-failed'.windows
    # This one has a code-less rpc-error alongside good buckets: the bars stay, the hint
    # names the cause it can actually justify.
    Check 'fixture: signed-out'   (Get-StatusText (Join-Path $fixtures 'codex-cache.signed-out.json'))   $strings.'rpc-backend'.windows

    Write-Host "`ncodex status: a healthy cache says nothing alarming"
    $ok = Get-StatusText (Join-Path $fixtures 'codex-cache.no-weekly.json')
    CheckThat 'a fresh cache reports an age, not an error' ($ok -like 'codex: *synced*' -or $ok -like 'codex: updated*') $ok

    Write-Host "`ncodex status: the shared table and the widget agree"
    foreach ($p in $strings.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }
        $win = $p.Value.windows
        # A null is a deliberate claim that Windows has no such class, not a gap to skip
        # silently - the Mac harness makes the same claim from its side.
        if ($null -eq $win) {
            CheckThat "table declares no Windows string for '$($p.Name)'" ($null -eq $win) ''
            continue
        }
        $needle = ($win -split '\{0\}')[0].TrimEnd('. ')
        CheckThat "widget.ps1 contains the table's string for '$($p.Name)'" ($src -like "*$needle*") $win
    }
}
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "$pass passed, $fail failed" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($fail) { exit 1 }
