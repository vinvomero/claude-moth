# Fixture test for the Codex snapshot parser and binary discovery. Extracts the REAL
# functions from capture-codex.ps1 via the PowerShell AST - no process spawn, no copy to
# drift - and asserts the mapped cache shape across the payload variations the
# undocumented app-server can return (every snapshot field is nullable per its schema).
# Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\test-codex-parse.ps1
$root   = Split-Path $PSScriptRoot -Parent
$helper = Join-Path $root 'capture-codex.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($helper, [ref]$null, [ref]$null)
$allFns = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)
foreach ($name in 'ConvertTo-Pct','ConvertTo-Epoch','Limit-ResetsAt','ConvertFrom-CodexRateLimits','Find-CodexExe') {
    $fn = $allFns | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL: $name not found in capture-codex.ps1" -ForegroundColor Red; exit 1 }
    Invoke-Expression $fn.Extent.Text
}

# Fixture epochs are fixed, so the reset-bounding window is pinned to a fixed "now"
# just before them - otherwise these assertions would age out and start failing.
$NOW = 1788440000

$script:pass = 0; $script:fail = 0
function Check($name, $got, $expect) {
    $g = if ($null -eq $got) { '<null>' } else { [string]$got }
    $e = if ($null -eq $expect) { '<null>' } else { [string]$expect }
    if ($g -eq $e) { Write-Host "  PASS  $name -> $g" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  FAIL  $name -> got '$g' want '$e'" -ForegroundColor Red; $script:fail++ }
}
function Load($file) {
    $p = Join-Path $PSScriptRoot ("fixtures\" + $file)
    return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)
}
# Hand-built snapshot, mirroring the app-server's RateLimitSnapshot shape.
function Snap($primary, $secondary, $plan) {
    [pscustomobject]@{ rateLimits = [pscustomobject]@{
        primary = $primary; secondary = $secondary; planType = $plan } }
}
function Win($pct, $resets, $mins) {
    [pscustomobject]@{ usedPercent = $pct; resetsAt = $resets; windowDurationMins = $mins }
}

Write-Host "`n-- full payload (verified live shape) --"
$full = ConvertFrom-CodexRateLimits (Load 'codex-ratelimits-full.json').result $NOW
Check 'five_hour percent'        $full.five_hour.used_percentage   100
Check 'five_hour resets_at'      $full.five_hour.resets_at         1788441300
Check 'five_hour window_mins'    $full.five_hour.window_mins       300
Check 'seven_day percent'        $full.seven_day.used_percentage   69
Check 'seven_day resets_at'      $full.seven_day.resets_at         1788832075
Check 'seven_day window_mins'    $full.seven_day.window_mins       10080
Check 'plan_type'                $full.plan_type                   'team'
# Whitelist, not passthrough: account identifiers must never reach the cache file.
Check 'accountId dropped'        $full.Contains('accountId')       'False'
Check 'credits dropped'          $full.Contains('credits')         'False'
Check 'upsell dropped'           $full.Contains('rateLimitUpsell') 'False'
Check 'reset credits dropped'    $full.Contains('rateLimitResetCredits') 'False'

Write-Host "`n-- secondary null (no weekly bucket on this plan) --"
$nosec = ConvertFrom-CodexRateLimits (Load 'codex-ratelimits-secondary-null.json').result $NOW
Check 'five_hour still present'  $nosec.five_hour.used_percentage  0
Check 'null resetsAt kept null'  $nosec.five_hour.resets_at        $null
Check 'seven_day omitted'        $nosec.Contains('seven_day')      'False'
Check 'plan_type'                $nosec.plan_type                  'plus'

Write-Host "`n-- error reply --"
$err = Load 'codex-ratelimits-error.json'
Check 'error member present'     ($null -ne $err.error)            'True'
Check 'error code'               $err.error.code                   -32600
# Even if a caller passed the (absent) result through, the parser must refuse it.
Check 'no result to parse'       (ConvertFrom-CodexRateLimits $err.result $NOW) $null

Write-Host "`n-- bucket selection --"
$byId = [pscustomobject]@{
    rateLimits = [pscustomobject]@{ primary = (Win 11 $null 300); secondary = $null; planType = 'legacy' }
    rateLimitsByLimitId = [pscustomobject]@{ codex = [pscustomobject]@{
        primary = (Win 22 $null 300); secondary = $null; planType = 'preferred' } } }
Check 'byLimitId preferred'      (ConvertFrom-CodexRateLimits $byId $NOW).five_hour.used_percentage 22
Check 'falls back to rateLimits' (ConvertFrom-CodexRateLimits (Snap (Win 33 $null 300) $null 'x') $NOW).five_hour.used_percentage 33
Check 'no snapshot at all'       (ConvertFrom-CodexRateLimits ([pscustomobject]@{ nothing = 1 }) $NOW) $null
Check 'null result'              (ConvertFrom-CodexRateLimits $null $NOW) $null

Write-Host "`n-- value tolerance --"
Check 'string percent parses'    (ConvertFrom-CodexRateLimits (Snap (Win '42' $null 300) $null 'x') $NOW).five_hour.used_percentage 42
# $null -as [double] is 0 in PS 5.1, so a junk percent must NOT become a fresh 0% bar.
Check 'junk percent -> no snap'  (ConvertFrom-CodexRateLimits (Snap (Win 'abc' $null 300) $null 'x') $NOW) $null
Check 'missing primary -> null'  (ConvertFrom-CodexRateLimits (Snap $null (Win 50 $null 10080) 'x') $NOW) $null
Check 'percent clamped high'     (ConvertFrom-CodexRateLimits (Snap (Win 250 $null 300) $null 'x') $NOW).five_hour.used_percentage 100
Check 'percent clamped low'      (ConvertFrom-CodexRateLimits (Snap (Win -5 $null 300) $null 'x') $NOW).five_hour.used_percentage 0
Check 'secondary junk dropped'   (ConvertFrom-CodexRateLimits (Snap (Win 10 $null 300) (Win 'abc' $null 10080) 'x') $NOW).Contains('seven_day') 'False'

Write-Host "`n-- reset bounding --"
Check 'reset in window kept'     (Limit-ResetsAt ($NOW + 3600) $NOW)      ($NOW + 3600)
Check 'reset far future dropped' (Limit-ResetsAt ($NOW + 63072000) $NOW)  $null
Check 'reset long past dropped'  (Limit-ResetsAt ($NOW - 200000) $NOW)    $null
Check 'reset just past kept'     (Limit-ResetsAt ($NOW - 60) $NOW)        ($NOW - 60)
Check 'epoch millis normalized'  (ConvertTo-Epoch 1788441300000)          1788441300
Check 'epoch junk -> null'       (ConvertTo-Epoch 'nope')                 $null

Write-Host "`n-- binary discovery --"
$tmp = Join-Path $env:TEMP ('moth-codex-test-' + $PID)
$binA = Join-Path $tmp 'bin\aaa'; $binB = Join-Path $tmp 'bin\bbb'
New-Item -ItemType Directory -Path $binA -Force | Out-Null
New-Item -ItemType Directory -Path $binB -Force | Out-Null
$exeA = Join-Path $binA 'codex.exe'; $exeB = Join-Path $binB 'codex.exe'
Set-Content -LiteralPath $exeA -Value 'stub'
Set-Content -LiteralPath $exeB -Value 'stub'
# bbb is the NEWEST by write time, so any result of aaa proves the config record won.
(Get-Item $exeA).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
(Get-Item $exeB).LastWriteTimeUtc = [DateTime]::UtcNow
$cfgGood = Join-Path $tmp 'good.toml'
$cfgDead = Join-Path $tmp 'dead.toml'
Set-Content -LiteralPath $cfgGood -Value ("CODEX_CLI_PATH = '" + $exeA + "'") -Encoding UTF8
Set-Content -LiteralPath $cfgDead -Value ("CODEX_CLI_PATH = '" + (Join-Path $tmp 'gone\codex.exe') + "'") -Encoding UTF8
$binRoot = Join-Path $tmp 'bin'

Check 'override wins'            (Find-CodexExe $exeB $cfgGood $binRoot)   $exeB
Check 'missing override -> null' (Find-CodexExe (Join-Path $tmp 'nope.exe') $cfgGood $binRoot) $null
Check 'config path beats glob'   (Find-CodexExe $null $cfgGood $binRoot)   $exeA
Check 'dead config -> glob'      (Find-CodexExe $null $cfgDead $binRoot)   $exeB
Check 'no config -> glob'        (Find-CodexExe $null (Join-Path $tmp 'absent.toml') $binRoot) $exeB
Check 'nothing anywhere -> null' (Find-CodexExe $null (Join-Path $tmp 'absent.toml') (Join-Path $tmp 'empty')) $null
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail) { exit 1 }
