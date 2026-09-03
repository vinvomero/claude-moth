# Fixture test for Resolve-ProviderState (which provider the card shows). Extracts the
# REAL reducer from widget.ps1 via the PowerShell AST - no WPF launch, no copy to drift.
#
# The cases that matter most are the heartbeat ones: Claude's statusLine rewrites its
# cache every ~15s while a session is merely open, so if auto-follow ever keyed on data
# freshness instead of turn events, the card would yank back to Claude seconds after
# every Codex turn. Those are asserted here as "a data refresh is not activity".
# Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\test-resolve-provider.ps1
$widget = Join-Path (Split-Path $PSScriptRoot -Parent) 'widget.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($widget, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | Where-Object { $_.Name -eq 'Resolve-ProviderState' } | Select-Object -First 1
if (-not $fn) { Write-Host 'FAIL: Resolve-ProviderState not found in widget.ps1' -ForegroundColor Red; exit 1 }
Invoke-Expression $fn.Extent.Text

$script:pass = 0; $script:fail = 0
# Expect is "provider|tabVisible|changed" so one assertion covers the whole result.
function Check($name, $r, $expect) {
    $got = '{0}|{1}|{2}' -f $r.provider, $r.tabVisible, $r.changed
    if ($got -eq $expect) { Write-Host "  PASS  $name -> $got" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  FAIL  $name -> got '$got' want '$expect'" -ForegroundColor Red; $script:fail++ }
}
$T = 1000000    # a pick made at T; activity stamps sit either side of it

Write-Host "`n-- opt-in and presence gates --"
Check 'flag off'                  (Resolve-ProviderState $false $true  $T ($T+50) $null $null) 'claude|False|False'
Check 'flag off ignores pick'     (Resolve-ProviderState $false $true  $T ($T+50) 'codex' $T)  'claude|False|False'
Check 'no codex snapshot'         (Resolve-ProviderState $true  $false $T ($T+50) $null $null) 'claude|False|False'
Check 'no snapshot ignores pick'  (Resolve-ProviderState $true  $false $T ($T+50) 'codex' $T)  'claude|False|False'

Write-Host "`n-- auto-follow --"
Check 'codex used more recently'  (Resolve-ProviderState $true $true $T ($T+50) $null $null) 'codex|True|False'
Check 'claude used more recently' (Resolve-ProviderState $true $true ($T+50) $T $null $null) 'claude|True|False'
Check 'tie -> claude (incumbent)' (Resolve-ProviderState $true $true $T $T       $null $null) 'claude|True|False'
Check 'both missing -> claude'    (Resolve-ProviderState $true $true $null $null $null $null) 'claude|True|False'
Check 'only codex ever seen'      (Resolve-ProviderState $true $true $null $T    $null $null) 'codex|True|False'
Check 'only claude ever seen'     (Resolve-ProviderState $true $true $T $null    $null $null) 'claude|True|False'

Write-Host "`n-- manual pick holds until the OTHER tool is used --"
Check 'pick claude, no codex use' (Resolve-ProviderState $true $true ($T+90) ($T-10) 'claude' $T) 'claude|True|False'
Check 'pick claude, codex used'   (Resolve-ProviderState $true $true ($T-10) ($T+10) 'claude' $T) 'codex|True|True'
Check 'pick codex, no claude use' (Resolve-ProviderState $true $true ($T-10) ($T+90) 'codex' $T)  'codex|True|False'
Check 'pick codex, claude used'   (Resolve-ProviderState $true $true ($T+10) ($T-10) 'codex' $T)  'claude|True|True'
# Clearing the pick resumes auto-follow rather than jumping to whoever broke it: if the
# user used Codex and then came back to Claude, the card belongs on Claude.
Check 'cleared, then back to claude' (Resolve-ProviderState $true $true ($T+90) ($T+10) 'claude' $T) 'claude|True|True'
Check 'cleared, then back to codex'  (Resolve-ProviderState $true $true ($T+10) ($T+90) 'codex' $T)  'codex|True|True'
Check 'pick survives restart'     (Resolve-ProviderState $true $true $null $null 'codex' $T)      'codex|True|False'
Check 'activity exactly at pick'  (Resolve-ProviderState $true $true ($T+90) $T 'claude' $T)      'claude|True|False'
Check 'pick with null pickedAt'   (Resolve-ProviderState $true $true $null ($T+10) 'claude' $null) 'codex|True|True'
Check 'garbage pick ignored'      (Resolve-ProviderState $true $true $T ($T+50) 'banana' $T)      'codex|True|False'

Write-Host "`n-- a data refresh is not activity (the whole reason for a separate signal) --"
# Both of these model the same trap: Claude's cache captured_at moves constantly while a
# session is open, and live_sync rewrites it every 3 minutes with no session at all. The
# reducer only ever sees turn stamps, so a refresh cannot move the card.
Check 'claude heartbeat, on codex'  (Resolve-ProviderState $true $true $T ($T+50) $null $null) 'codex|True|False'
Check 'claude heartbeat vs pick'    (Resolve-ProviderState $true $true $T ($T+50) 'codex' ($T+60)) 'codex|True|False'
# A Moth poll of the Codex app-server must not advance the Codex stamp either.
Check 'our own poll is not a turn'  (Resolve-ProviderState $true $true ($T+90) $T 'claude' ($T+80)) 'claude|True|False'

Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail) { exit 1 }
