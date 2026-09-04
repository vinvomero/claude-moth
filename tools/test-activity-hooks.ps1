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

Write-Host "`n-- installer: never touch a file it did not change --"
# A user who never installed the hooks still runs uninstall.ps1, which calls this tool
# for everyone. Rewriting (and reformatting) their settings.json, and inventing a .bak,
# would contradict "everything else is left untouched".
$virgin = Join-Path $tmp 'virgin.json'
[IO.File]::WriteAllText($virgin, $seed, (New-Object Text.UTF8Encoding($false)))
$virginBefore = [IO.File]::ReadAllBytes($virgin)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $virgin -TargetDir (Join-Path $fakeLocal 'Moth') -Uninstall -Quiet
Check 'uninstall-nothing exit 0'  $LASTEXITCODE 0
Check 'virgin file byte-identical' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($virgin))) ([Convert]::ToBase64String($virginBefore))
Check 'no backup invented'        (Test-Path "$virgin.moth-activity.bak") 'False'

Write-Host "`n-- installer: refuse a file it cannot parse, before touching anything --"
$broken = Join-Path $tmp 'broken.json'
# A trailing comma is the classic hand-edit that makes a config unparseable.
[IO.File]::WriteAllText($broken, "{`n  `"hooks`": { `"Stop`": [] },`n}", (New-Object Text.UTF8Encoding($false)))
$brokenBefore = [IO.File]::ReadAllBytes($broken)
# Pre-install the execution copy so we can prove a refusal does not delete it.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $settings -TargetDir (Join-Path $fakeLocal 'Moth') -Quiet | Out-Null
Check 'copy present before refusal' (Test-Path (Join-Path $fakeLocal 'Moth\touch-activity.ps1')) 'True'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $broken -TargetDir (Join-Path $fakeLocal 'Moth') -Uninstall -Quiet 2>$null
Check 'malformed uninstall fails'  ($LASTEXITCODE -ne 0) 'True'
Check 'malformed file untouched'   ([Convert]::ToBase64String([IO.File]::ReadAllBytes($broken))) ([Convert]::ToBase64String($brokenBefore))
Check 'copy SURVIVES refusal'      (Test-Path (Join-Path $fakeLocal 'Moth\touch-activity.ps1')) 'True'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $broken -TargetDir (Join-Path $fakeLocal 'Moth') -Quiet 2>$null
Check 'malformed install fails'    ($LASTEXITCODE -ne 0) 'True'
Check 'still untouched on install' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($broken))) ([Convert]::ToBase64String($brokenBefore))

Write-Host "`n-- installer: refuse a non-array event before writing --"
$objEvt = Join-Path $tmp 'objevent.json'
[IO.File]::WriteAllText($objEvt, '{"hooks":{"Stop":{"hooks":[{"type":"command","command":"x"}]}}}', (New-Object Text.UTF8Encoding($false)))
$objBefore = [IO.File]::ReadAllBytes($objEvt)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $objEvt -TargetDir (Join-Path $fakeLocal 'Moth') -Quiet 2>$null
Check 'non-array event refused'    ($LASTEXITCODE -ne 0) 'True'
Check 'non-array file untouched'   ([Convert]::ToBase64String([IO.File]::ReadAllBytes($objEvt))) ([Convert]::ToBase64String($objBefore))

Write-Host "`n-- installer: an empty file is fresh, not broken --"
$empty = Join-Path $tmp 'empty.json'
[IO.File]::WriteAllText($empty, '', (New-Object Text.UTF8Encoding($false)))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $empty -TargetDir (Join-Path $fakeLocal 'Moth') -Quiet
Check 'empty file install exit 0'  $LASTEXITCODE 0
$emptyCfg = [IO.File]::ReadAllText($empty) | ConvertFrom-Json
Check 'hooks written to empty'     (@(@($emptyCfg.hooks.UserPromptSubmit) | Where-Object { @($_.hooks | Where-Object { $_.command -like '*touch-activity.ps1*' }).Count }).Count) 1

Write-Host "`n-- installer: emptied events collapse, not left as [] --"
$solo = Join-Path $tmp 'solo.json'
[IO.File]::WriteAllText($solo, '{"statusLine":{"type":"command","command":"x"}}', (New-Object Text.UTF8Encoding($false)))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $solo -TargetDir (Join-Path $fakeLocal 'Moth') -Quiet
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $solo -TargetDir (Join-Path $fakeLocal 'Moth') -Uninstall -Quiet
$soloCfg = [IO.File]::ReadAllText($solo) | ConvertFrom-Json
Check 'emptied event removed'      ($soloCfg.hooks.PSObject.Properties.Name -contains 'UserPromptSubmit') 'False'
Check 'unrelated keys survive'     $soloCfg.statusLine.command 'x'

Write-Host "`n-- installer: a refused uninstall must not strand the hooks --"
# The race the script's own header warns about: settings.json is fine at the step-0
# validation and broken by the time of the late re-read (Claude Code hot-reloads and
# rewrites this file). The execution copy used to be deleted BEFORE that read, so a
# refusal left the hook entries registered and pointing at a file that no longer existed -
# a missing command on every prompt, under a message that said "nothing was changed".
$raceDir  = Join-Path $fakeLocal 'MothRace'
$raceJson = Join-Path $tmp 'race.json'
[IO.File]::WriteAllText($raceJson, '{}', (New-Object Text.UTF8Encoding($false)))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $raceJson -TargetDir $raceDir -Quiet
$raceCopy = Join-Path $raceDir 'touch-activity.ps1'
Check 'race: install put the copy in place' (Test-Path -LiteralPath $raceCopy) 'True'

# Break the file the way a torn concurrent write would.
[IO.File]::WriteAllText($raceJson, '{ "hooks": { "Stop": [ }', (New-Object Text.UTF8Encoding($false)))
$raceBefore = [IO.File]::ReadAllBytes($raceJson)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $raceJson -TargetDir $raceDir -Uninstall -Quiet 2>$null
Check 'race: uninstall refuses'             ($LASTEXITCODE -ne 0) 'True'
Check 'race: settings.json byte-identical'  ([Convert]::ToBase64String([IO.File]::ReadAllBytes($raceJson))) ([Convert]::ToBase64String($raceBefore))
# The point of the fix: the hooks still reference the copy, so the copy must still exist.
Check 'race: the execution copy SURVIVES'   (Test-Path -LiteralPath $raceCopy) 'True'

# And on the happy path it is still removed - deferring the delete must not skip it.
[IO.File]::WriteAllText($raceJson, '{}', (New-Object Text.UTF8Encoding($false)))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $raceJson -TargetDir $raceDir -Quiet
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SettingsPath $raceJson -TargetDir $raceDir -Uninstall -Quiet
Check 'clean uninstall removes the copy'    (Test-Path -LiteralPath $raceCopy) 'False'
Check 'clean uninstall exit 0'              $LASTEXITCODE 0

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail) { exit 1 }
