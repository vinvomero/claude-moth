# Fixture test for Resolve-OnScreenPosition (the off-screen window rescue). Extracts the
# REAL function from widget.ps1 via the PowerShell AST - no WPF launch, no copy to drift.
#
# WHY THIS EXISTS: the widget restores its saved position faithfully, which is correct
# right up until the monitor it was saved on is gone. Undock a laptop and the card is
# dutifully restored to coordinates no screen covers; it runs, paints and polls, and you
# simply cannot see it. /moth appears to work every time without helping, because
# restoring the saved position IS the failure. Observed live: a card saved at -440,77 on
# a second display, on a machine now down to one 1280x800 screen.
#
# The desktop rectangle is a parameter, so these cases place monitors anywhere without
# touching the real display arrangement.
# Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\test-onscreen.ps1
$widget = Join-Path (Split-Path $PSScriptRoot -Parent) 'widget.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($widget, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | Where-Object { $_.Name -eq 'Resolve-OnScreenPosition' } | Select-Object -First 1
if (-not $fn) { Write-Host 'FAIL: Resolve-OnScreenPosition not found in widget.ps1' -ForegroundColor Red; exit 1 }
Invoke-Expression $fn.Extent.Text

$script:pass = 0; $script:fail = 0
function Check($name, $r, $expect) {
    $got = '{0},{1}|{2}' -f [int]$r.left, [int]$r.top, $r.moved
    if ($got -eq $expect) { Write-Host "  PASS  $name -> $got" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  FAIL  $name -> got '$got' want '$expect'" -ForegroundColor Red; $script:fail++ }
}
# A 393x267 card (the size actually in use) on a single 1280x800 screen at the origin.
$W = 393; $H = 267
function OnSingle($left, $top) { Resolve-OnScreenPosition $left $top $W $H 0 0 1280 800 }

Write-Host "`n-- a window already on screen is never touched --"
Check 'top-left corner'          (OnSingle 0 0)      '0,0|False'
Check 'middle'                   (OnSingle 400 300)  '400,300|False'
Check 'flush against the right'  (OnSingle 887 533)  '887,533|False'
# Partly off, but with plenty still grabbable: leave it exactly where the user put it.
Check 'hanging off the right'    (OnSingle 1200 400) '1200,400|False'
Check 'hanging off the bottom'   (OnSingle 400 720)  '400,720|False'
Check 'hanging off the left'     (OnSingle -300 400) '-300,400|False'

Write-Host "`n-- the real bug: a second monitor that is gone --"
# The exact case observed on the author's machine.
Check 'saved at -440,77'         (OnSingle -440 77)  '0,77|True'
Check 'monitor was above'        (OnSingle 300 -600) '300,0|True'
Check 'monitor was below'        (OnSingle 300 1400) '300,533|True'
Check 'monitor was to the right' (OnSingle 2400 100) '887,100|True'
Check 'diagonal, both axes off'  (OnSingle -900 -900) '0,0|True'

Write-Host "`n-- the 80px threshold, from both sides --"
# 80px of the card visible = keep. One pixel less = rescue. Asserting only the far side
# of a boundary lets an off-by-one live forever.
Check 'exactly 80px visible L'   (OnSingle ($W - 80) 100)      "$($W - 80),100|False"
Check 'one pixel less L'         (OnSingle ($W - 79) 100)      "$($W - 79),100|False"
Check '79px visible on the left' (OnSingle (-1 * ($W - 79)) 100) '0,100|True'
Check 'exactly 80px visible R'   (OnSingle (1280 - 80) 100)    '1200,100|False'
Check 'one pixel past on the R'  (OnSingle (1280 - 79) 100)    '887,100|True'

Write-Host "`n-- multi-monitor arrangements --"
# A left-hand second monitor: -440 is legitimate here and must NOT be moved.
Check 'left monitor present'  (Resolve-OnScreenPosition -440 77 $W $H -1280 0 2560 800) '-440,77|False'
# ...and the same coordinates once it is unplugged.
Check 'left monitor unplugged'(Resolve-OnScreenPosition -440 77 $W $H 0 0 1280 800)     '0,77|True'
# A desktop whose origin is negative (a second screen up and to the left). A card at
# -2000 still shows 313px here, so it is NOT stranded - the rescue must leave it alone.
# My first expectation for this case was wrong, not the code: it is easy to read a
# negative coordinate as "off-screen" when the desktop itself starts at -1920.
Check 'negative origin, still visible' (Resolve-OnScreenPosition -2000 -900 $W $H -1920 -1080 3840 1080) '-2000,-900|False'
# ...and one that really is past the left edge of that same desktop.
Check 'negative origin, truly off'     (Resolve-OnScreenPosition -2500 -900 $W $H -1920 -1080 3840 1080) '-1920,-900|True'

Write-Host "`n-- degenerate input is never trusted --"
# A zero-size desktop means the query failed; moving the window on that basis would be
# guessing, and the guess would strand it.
Check 'zero-width desktop'    (Resolve-OnScreenPosition -440 77 $W $H 0 0 0 800)  '-440,77|False'
Check 'zero-height desktop'   (Resolve-OnScreenPosition -440 77 $W $H 0 0 1280 0) '-440,77|False'
# A desktop SMALLER than the card: clamp to the origin rather than off the far edge.
Check 'desktop smaller than card' (Resolve-OnScreenPosition -900 -900 $W $H 0 0 200 150) '0,0|True'

Write-Host "`n-- whatever it returns is actually on screen --"
# The property that matters, asserted directly rather than inferred from coordinates.
$cases = @(@(-440,77), @(-900,-900), @(2400,100), @(300,1400), @(-2000,-2000), @(5000,5000))
$bad = @()
foreach ($c in $cases) {
    $f = OnSingle $c[0] $c[1]
    $overlapX = ($f.left + $W) -gt 0 -and $f.left -lt 1280
    $overlapY = ($f.top + $H) -gt 0 -and $f.top -lt 800
    if (-not ($overlapX -and $overlapY)) { $bad += ("{0},{1} -> {2},{3}" -f $c[0], $c[1], $f.left, $f.top) }
}
if ($bad.Count) { Write-Host "  FAIL  every rescued position lands on screen -> $($bad -join '; ')" -ForegroundColor Red; $script:fail++ }
else { Write-Host "  PASS  every rescued position lands on screen ($($cases.Count) cases)" -ForegroundColor Green; $script:pass++ }

Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail) { exit 1 }
