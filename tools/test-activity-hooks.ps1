# Fixture test for the activity signal: touch-activity.ps1's hard contract (silent,
# always exit 0 - it runs inside every Claude prompt) and install-activity-hooks.ps1's
# merge, idempotency, shape validation and uninstall.
#
# Runs entirely against throwaway copies: LOCALAPPDATA is redirected for the child
# processes and the installer is pointed at a temp settings.json. The live Claude Code
# configuration is never read or written.
# Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\test-activity-hooks.ps1
$root     = Split-Path $PSScriptRoot -Parent
$toucher  = Join-Path $root 'touch-activity.ps1'
$installer= Join-Path $PSScriptRoot 'install-activity-hooks.ps1'
$tmp      = Join-Path $env:TEMP ('moth-activity-test-' + $PID)
$fakeLocal= Join-Path $tmp 'local'
New-Item -ItemType Directory -Path $fakeLocal -Force | Out-Null

$script:pass = 0; $script:fail = 0
# [string]$r.Out binds as ([string]$r).Out in PowerShell, which is $null - so an empty
# stream would throw on .Trim() and the assertion would never run. Stringify explicitly.
function Str($v) { if ($null -eq $v) { return '' } return ([string]$v).Trim() }
function Check($name, $got, $expect) {
    $g = if ($null -eq $got) { '<null>' } else { [string]$got }
    $e = if ($null -eq $expect) { '<null>' } else { [string]$expect }
    if ($g -eq $e) { Write-Host "  PASS  $name -> $g" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  FAIL  $name -> got '$g' want '$e'" -ForegroundColor Red; $script:fail++ }
}
# Run the toucher as a real child process with LOCALAPPDATA redirected, capturing both
# streams and the exit code - the contract is about what the HOST tool observes.
function RunToucher($provider, $stdin) {
    $o = Join-Path $tmp 'out.txt'; $e = Join-Path $tmp 'err.txt'
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $toucher)
    if ($null -ne $provider) { $args += @('-Provider', $provider) }
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $fakeLocal
    try {
        if ($null -ne $stdin) {
            $stdin | & powershell.exe @args > $o 2> $e
        } else {
            & powershell.exe @args > $o 2> $e
        }
        $code = $LASTEXITCODE
    } finally { $env:LOCALAPPDATA = $saved }
    return [pscustomobject]@{
        Code = $code
        Out  = (Get-Content $o -Raw -ErrorAction SilentlyContinue)
        Err  = (Get-Content $e -Raw -ErrorAction SilentlyContinue)
    }
}
function Activity { Get-Content (Join-Path $fakeLocal 'Moth\activity.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json }

Write-Host "`n-- toucher: hard contract (runs inside every Claude prompt) --"
$r = RunToucher 'claude' $null
Check 'exit 0'                 $r.Code 0
Check 'stdout empty'           (Str $r.Out) ''
Check 'stderr empty'           (Str $r.Err) ''
Check 'claude stamped'         ($null -ne (Activity).claude) 'True'
Check 'codex still null'       (Activity).codex $null
$bytes = [IO.File]::ReadAllBytes((Join-Path $fakeLocal 'Moth\activity.json'))
Check 'no BOM'                 ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) 'False'

$claudeStamp = (Activity).claude
Start-Sleep -Seconds 1
$r = RunToucher 'codex' $null
Check 'codex stamped'          ($null -ne (Activity).codex) 'True'
Check 'claude preserved'       (Activity).claude $claudeStamp

Write-Host "`n-- toucher: never break the host tool --"
# A [ValidateSet] here would emit a binding error to stderr and exit non-zero, which on
# a UserPromptSubmit hook surfaces as a hook failure. Validation is inside the body.
$r = RunToucher 'bogus' $null
Check 'bad provider exit 0'    $r.Code 0
Check 'bad provider silent'    ((Str $r.Out) + (Str $r.Err)) ''
Check 'bad provider no write'  (Activity).claude $claudeStamp
$r = RunToucher $null $null
Check 'no provider exit 0'     $r.Code 0
Check 'no provider silent'     ((Str $r.Out) + (Str $r.Err)) ''
# Claude pipes the hook payload (which contains the prompt text) on stdin; the script
# must neither read it nor choke on it.
$r = RunToucher 'claude' '{"prompt":"secret user text","session_id":"x"}'
Check 'stdin ignored, exit 0'  $r.Code 0
Check 'stdin ignored, silent'  ((Str $r.Out) + (Str $r.Err)) ''

Write-Host "`n-- installer: merge into a throwaway settings.json --"
$settings = Join-Path $tmp 'settings.json'
$seed = @'
{
  "hooks": {
    "Stop": [
      { "hooks": [
          { "type": "command", "command": "powershell -NoProfile -Command \"beep\"" },
          { "type": "command", "command": "curl -s https://example.invalid", "async": true, "timeout": 15 }
      ] }
    ],
    "SessionStart": [
      { "matcher": "startup|resume", "hooks": [ { "type": "command", "command": "ensure-widget.ps1" } ] }
    ]
  },
  "statusLine": { "type": "command", "command": "capture-usage.ps1" }
}
'@
[IO.File]::WriteAllText($settings, $seed, (New-Object Text.UTF8Encoding($false)))
function Cfg { [IO.File]::ReadAllText($settings) | ConvertFrom-Json }
function OursIn($evt) {
    $c = Cfg
    if (-not ($c.hooks.PSObject.Properties.Name -contains $evt)) { return 0 }
    return @(@($c.hooks.$evt) | Where-Object { @($_.hooks | Where-Object { $_.command -like '*touch-activity.ps1*' }).Count }).Count
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $settings -TargetDir (Join-Path $fakeLocal 'Moth') -Quiet
Check 'installer exit 0'       $LASTEXITCODE 0
Check 'UserPromptSubmit added' (OursIn 'UserPromptSubmit') 1
Check 'Stop added'             (OursIn 'Stop') 1
Check 'existing Stop kept'     @(Cfg).hooks.Stop.Count 2
Check 'existing sound intact'  (@(Cfg).hooks.Stop[0].hooks.Count) 2
Check 'SessionStart untouched' @(Cfg).hooks.SessionStart.Count 1
Check 'statusLine untouched'   (Cfg).statusLine.command 'capture-usage.ps1'
Check 'hook is async'          (@(Cfg).hooks.UserPromptSubmit[0].hooks[0].async) 'True'
Check 'hook timeout 5'         (@(Cfg).hooks.UserPromptSubmit[0].hooks[0].timeout) 5
$b = [IO.File]::ReadAllBytes($settings)
Check 'settings no BOM'        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB) 'False'
# The PS 5.1 unroll trap: a one-entry event must still serialize as a JSON array,
# because "UserPromptSubmit": { ... } is valid JSON that Claude Code will not accept.
Check 'event is a JSON array'  ([bool]([regex]::IsMatch([IO.File]::ReadAllText($settings), '"UserPromptSubmit"\s*:\s*\['))) 'True'
Check 'script copy installed'  (Test-Path (Join-Path $fakeLocal 'Moth\touch-activity.ps1')) 'True'

Write-Host "`n-- installer: idempotency and foreign-entry detection --"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $settings -TargetDir (Join-Path $fakeLocal 'Moth') -Quiet
Check 'still one after re-run' (OursIn 'UserPromptSubmit') 1
Check 'Stop still one'         (OursIn 'Stop') 1

# Simulate Codex's external-agent import copying our hook across with a wrong provider.
$c = Cfg
$foreignGroup = [pscustomobject]@{ hooks = [object[]]@([pscustomobject]@{
    type = 'command'; command = 'powershell.exe -File "X:\Moth\touch-activity.ps1" -Provider codex' }) }
$c.hooks.UserPromptSubmit = [object[]](@($c.hooks.UserPromptSubmit) + $foreignGroup)
[IO.File]::WriteAllText($settings, ($c | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $settings -TargetDir (Join-Path $fakeLocal 'Moth') -Quiet
Check 'foreign entry preserved' (@(@(Cfg).hooks.UserPromptSubmit | Where-Object { @($_.hooks | Where-Object { $_.command -like '*-Provider codex*' }).Count }).Count) 1
Check 'ours still exactly one'  (@(@(Cfg).hooks.UserPromptSubmit | Where-Object { @($_.hooks | Where-Object { $_.command -like '*-Provider claude*' }).Count }).Count) 1

Write-Host "`n-- installer: uninstall --"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $settings -TargetDir (Join-Path $fakeLocal 'Moth') -Uninstall -Quiet
Check 'uninstall exit 0'       $LASTEXITCODE 0
Check 'ours gone from prompt'  (@(@(Cfg).hooks.UserPromptSubmit | Where-Object { @($_.hooks | Where-Object { $_.command -like '*-Provider claude*' }).Count }).Count) 0
Check 'foreign still there'    (@(@(Cfg).hooks.UserPromptSubmit | Where-Object { @($_.hooks | Where-Object { $_.command -like '*-Provider codex*' }).Count }).Count) 1
Check 'Stop back to original'  @(Cfg).hooks.Stop.Count 1
Check 'sound hook survived'    (@(Cfg).hooks.Stop[0].hooks.Count) 2
Check 'script copy removed'    (Test-Path (Join-Path $fakeLocal 'Moth\touch-activity.ps1')) 'False'
Check 'still valid JSON'       ([bool](Cfg)) 'True'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail) { exit 1 }
