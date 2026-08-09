# Fixture test for Select-ScopedWeekly (the per-model limits[] pick). Extracts the REAL
# function from widget.ps1 via the PowerShell AST - no WPF launch, no copy to drift - and
# asserts the chosen model across hand-built endpoint shapes, including the crash/edge
# cases the undocumented endpoint could throw at it.
# Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\test-scoped-weekly.ps1
$widget = Join-Path (Split-Path $PSScriptRoot -Parent) 'widget.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($widget, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Select-ScopedWeekly'
}, $true) | Select-Object -First 1
if (-not $fn) { Write-Host 'FAIL: Select-ScopedWeekly not found in widget.ps1' -ForegroundColor Red; exit 1 }
Invoke-Expression $fn.Extent.Text

function L($group, $model, $active, $percent) {
    $scope = if ($null -eq $model) { $null } else { [pscustomobject]@{ model = [pscustomobject]@{ display_name = $model } } }
    [pscustomobject]@{ group = $group; is_active = $active; percent = $percent; scope = $scope }
}
$script:pass = 0; $script:fail = 0
function Check($name, $limits, $expect) {
    $r = Select-ScopedWeekly $limits
    $got = if ($null -eq $r) { '<null>' } else { [string]$r.scope.model.display_name }
    if ($got -eq $expect) { Write-Host "  PASS  $name -> $got" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  FAIL  $name -> got '$got' want '$expect'" -ForegroundColor Red; $script:fail++ }
}

Check 'null limits'              $null                                                                 '<null>'
Check 'empty limits'             @()                                                                   '<null>'
Check 'no scoped (weekly_all)'   @((L 'session' $null $false 20), (L 'weekly' $null $false 48))         '<null>'
Check 'single active Fable'      @((L 'weekly' 'Fable' $true 61))                                       'Fable'
Check 'inactive only still shows' @((L 'weekly' 'Opus' $false 30))                                     'Opus'
Check 'active beats bigger-inactive' @((L 'weekly' 'Opus' $false 90), (L 'weekly' 'Fable' $true 61))   'Fable'
Check 'two active -> higher pct' @((L 'weekly' 'Opus' $true 40), (L 'weekly' 'Fable' $true 61))         'Fable'
Check 'two active tie -> name asc' @((L 'weekly' 'Opus' $true 50), (L 'weekly' 'Fable' $true 50))       'Fable'
Check 'string percent tolerated' @((L 'weekly' 'Sonnet' $true 'oops'))                                 'Sonnet'
Check 'realistic Max payload'    @((L 'session' $null $false 20), (L 'weekly' $null $false 48), (L 'weekly' 'Fable' $true 61)) 'Fable'

Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail) { exit 1 }
