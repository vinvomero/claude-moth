# make-demo-gif.ps1 - regenerate the README GIFs:
#   assets/moth-demo.gif        the hero: Claude only, exactly as a first-run install looks
#   assets/moth-codex-demo.gif  the Codex opt-in: the tab, the switch, the hidden-provider halo
#
# Renders the REAL widget: for each frame it writes a usage fixture and calls
#   widget.ps1 -SelfTest <fixture> -CodexFixture <fixture|empty> -Provider <p> -StatePath <temp> -Screenshot <png>
# so every frame is the actual widget.ps1 render (real card, real inset + reactive halo,
# real bars/layout/fonts). No hand-maintained copy to drift. The transparent-margin PNGs
# are composited onto a dark "desktop" and encoded into a looping GIF (WPF compresses each
# frame; we byte-patch in the loop + frame delays GifBitmapEncoder omits).
#
# EVERY input is a throwaway file. The author's window-state.json is never opened, and the
# hero passes -CodexFixture empty so it can never fall through to the author's live Codex
# cache - a demo that shipped someone's real usage numbers would be a leak, and one that
# shipped their window size and provider tab would not be a demo of the default install.
# Run:  powershell.exe -ExecutionPolicy Bypass -File tools\make-demo-gif.ps1
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

$root   = Split-Path $PSScriptRoot -Parent
$widget = Join-Path $root 'widget.ps1'
$work   = Join-Path $env:TEMP ("moth-gif-" + $PID)
$BG     = '#0B0D14'
New-Item -ItemType Directory -Force -Path $work | Out-Null
function W8($p, $t) { [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false))) }

# Throwaway window-state files. Neither carries win_w/win_h, so both GIFs render at the
# widget's DEFAULT size no matter what the author has dragged their own window to.
$stateHero  = Join-Path $work 'state-hero.json';  W8 $stateHero  '{}'
$stateCodex = Join-Path $work 'state-codex.json'; W8 $stateCodex '{ "codex": true }'

$now  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$rWk  = $now + 4*86400 + 15*3600   # weekly + Fable reset ~4d 15h out
$r5   = $now + 175*60              # 5-hour resets in ~2h 55m (stable clock)
$r5b  = $now + 299*60              # after the window resets, ~4h 59m out
$rCx  = $now + 132*60              # Codex 5-hour reset, a different time than Claude's
$rCxW = $now + 5*86400 + 2*3600

# --- byte-patch: GifBitmapEncoder writes all frames but no loop + no frame delays.
#     Patch each existing GCE's delay in place + insert a Netscape 2.0 loop block. ---
Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
public static class GifAnim {
  public static byte[] Patch(byte[] d, int[] delays, int loop) {
    int pos = 13;
    byte packedLSD = d[10];
    if ((packedLSD & 0x80) != 0) pos += 3 * (1 << ((packedLSD & 7) + 1));
    int gctEnd = pos;
    var gceDelayAt = new List<int>();
    bool hasNetscape = false;
    int p = pos;
    while (p < d.Length && d[p] != 0x3B) {
      if (d[p] == 0x21) {
        byte label = d[p + 1];
        if (label == 0xF9) gceDelayAt.Add(p + 4);
        if (label == 0xFF) hasNetscape = true;
        p += 2;
        while (true) { int sz = d[p++]; if (sz == 0) break; p += sz; }
      } else if (d[p] == 0x2C) {
        byte packedImg = d[p + 9];
        p += 10;
        if ((packedImg & 0x80) != 0) p += 3 * (1 << ((packedImg & 7) + 1));
        p++;
        while (true) { int sz = d[p++]; if (sz == 0) break; p += sz; }
      } else break;
    }
    for (int i = 0; i < gceDelayAt.Count; i++) {
      int delay = i < delays.Length ? delays[i] : delays[delays.Length - 1];
      d[gceDelayAt[i]]     = (byte)(delay & 0xFF);
      d[gceDelayAt[i] + 1] = (byte)((delay >> 8) & 0xFF);
    }
    if (hasNetscape) return d;
    var o = new List<byte>();
    for (int i = 0; i < gctEnd; i++) o.Add(d[i]);
    o.AddRange(new byte[] { 0x21, 0xFF, 0x0B });
    o.AddRange(Encoding.ASCII.GetBytes("NETSCAPE2.0"));
    o.AddRange(new byte[] { 0x03, 0x01, (byte)(loop & 0xFF), (byte)((loop >> 8) & 0xFF), 0x00 });
    for (int i = gctEnd; i < d.Length; i++) o.Add(d[i]);
    return o.ToArray();
  }
}
'@

# Render one frame list through the real widget and encode it to $out.
# A frame is: p5/p7/pf/r5 (Claude), cx (a Codex bucket hashtable or $null), provider,
# state (a throwaway state-file path), delay (hundredths of a second).
function Build-Gif($frames, $out, $tag) {
    $pngs = @()
    for ($i = 0; $i -lt $frames.Count; $i++) {
        $f = $frames[$i]
        $fix = [ordered]@{
            five_hour = [ordered]@{ used_percentage = [math]::Round([double]$f.p5, 1); resets_at = [long]$f.r5 }
            seven_day = [ordered]@{ used_percentage = [math]::Round([double]$f.p7, 1); resets_at = [long]$rWk }
            fable     = [ordered]@{ used_percentage = [math]::Round([double]$f.pf, 1); resets_at = [long]$rWk; label = 'Fable'; captured_at = [long]$now }
            captured_at = [long]$now
        } | ConvertTo-Json
        $fixPath = Join-Path $work "$tag-fix$i.json"; $pngPath = Join-Path $work "$tag-frame$i.png"
        W8 $fixPath $fix
        # 'empty' is a real answer, not a missing argument: it tells the widget to render
        # with no Codex snapshot rather than reaching for the live cache on this machine.
        $cxArg = 'empty'
        if ($f.cx) {
            $cxArg = Join-Path $work "$tag-cx$i.json"
            W8 $cxArg (@{
                five_hour = [ordered]@{ used_percentage = [double]$f.cx.p5; resets_at = [long]$f.cx.r5; window_mins = 300 }
                seven_day = [ordered]@{ used_percentage = [double]$f.cx.p7; resets_at = [long]$f.cx.r7; window_mins = 10080 }
                captured_at = [long]$now
            } | ConvertTo-Json)
        }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget `
            -SelfTest $fixPath -CodexFixture $cxArg -Provider $f.provider -StatePath $f.state -Screenshot $pngPath | Out-Null
        if (-not (Test-Path $pngPath)) { throw "frame $i of $tag did not render ($pngPath)" }
        $pngs += $pngPath
    }

    # Composite each transparent-margin PNG onto the dark desktop (GIF has no soft alpha), uniform size.
    $firstImg = [System.Drawing.Image]::FromFile($pngs[0]); $fw = $firstImg.Width; $fh = $firstImg.Height; $firstImg.Dispose()
    $bgBrush = [Windows.Media.BrushConverter]::new().ConvertFromString($BG)
    $enc = New-Object Windows.Media.Imaging.GifBitmapEncoder
    foreach ($p in $pngs) {
        $src = New-Object Windows.Media.Imaging.BitmapImage
        $src.BeginInit(); $src.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $src.UriSource = [Uri]$p; $src.EndInit()
        $dv = New-Object Windows.Media.DrawingVisual; $dc = $dv.RenderOpen()
        $dc.DrawRectangle($bgBrush, $null, [Windows.Rect]::new(0, 0, $fw, $fh))
        $dc.DrawImage($src, [Windows.Rect]::new(0, 0, $fw, $fh))
        $dc.Close()
        $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($fw, $fh, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($dv)
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    }
    $ms = New-Object System.IO.MemoryStream
    $enc.Save($ms); $raw = $ms.ToArray(); $ms.Close()

    $delays = $frames | ForEach-Object { [int]$_.delay }
    $anim = [GifAnim]::Patch($raw, $delays, 0)
    New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
    [System.IO.File]::WriteAllBytes($out, $anim)
    Write-Host ("wrote {0}  ({1} real-widget frames, {2}x{3}, {4:N0} bytes)" -f $out, $frames.Count, $fw, $fh, $anim.Length)
}

# --- hero: Claude only. climb -> peak hold -> reset (loops) -------------------------
$hero = @()
$steps = 22
for ($i = 0; $i -lt $steps; $i++) {
    $t = $i / ($steps - 1)
    $hero += @{ p5 = (6 + $t*89); p7 = (19 + $t*8); pf = (55 + $t*10); r5 = $r5; cx = $null; provider = 'claude'; state = $stateHero; delay = 16 }
}
$hero += @{ p5 = 96; p7 = 27; pf = 65; r5 = $r5;  cx = $null; provider = 'claude'; state = $stateHero; delay = 90 }  # peak hold (red)
$hero += @{ p5 = 96; p7 = 27; pf = 65; r5 = $r5;  cx = $null; provider = 'claude'; state = $stateHero; delay = 90 }
$hero += @{ p5 = 5;  p7 = 27; pf = 65; r5 = $r5b; cx = $null; provider = 'claude'; state = $stateHero; delay = 70 }  # 5-hour window resets
$hero += @{ p5 = 5;  p7 = 27; pf = 65; r5 = $r5b; cx = $null; provider = 'claude'; state = $stateHero; delay = 70 }

# --- codex: same climb with the tab up, then switch, then Claude resets behind you ---
# The story the second GIF tells is the one the first cannot: the halo is the OTHER
# provider. Frames 17-18 sit on Codex at a calm 17% with the card still red, because the
# Claude you just switched away from is at 96%. Then Claude's window resets and the halo
# cools to amber while the Codex bars have not moved at all.
$cxCalm = @{ p5 = 17; p7 = 9; r5 = $rCx; r7 = $rCxW }
$codex = @()
$steps = 16
for ($i = 0; $i -lt $steps; $i++) {
    $t = $i / ($steps - 1)
    $codex += @{ p5 = (6 + $t*90); p7 = (19 + $t*8); pf = (55 + $t*10); r5 = $r5; cx = $cxCalm; provider = 'claude'; state = $stateCodex; delay = 16 }
}
$codex += @{ p5 = 96; p7 = 27; pf = 65; r5 = $r5;  cx = $cxCalm; provider = 'claude'; state = $stateCodex; delay = 90 }   # peak hold, tab visible
$codex += @{ p5 = 96; p7 = 27; pf = 65; r5 = $r5;  cx = $cxCalm; provider = 'codex';  state = $stateCodex; delay = 120 }  # switch: Codex bars, red halo
$codex += @{ p5 = 96; p7 = 27; pf = 65; r5 = $r5;  cx = $cxCalm; provider = 'codex';  state = $stateCodex; delay = 120 }
$codex += @{ p5 = 5;  p7 = 27; pf = 65; r5 = $r5b; cx = $cxCalm; provider = 'codex';  state = $stateCodex; delay = 90 }   # Claude resets behind you: halo cools
$codex += @{ p5 = 5;  p7 = 27; pf = 65; r5 = $r5b; cx = $cxCalm; provider = 'codex';  state = $stateCodex; delay = 90 }

# try/finally: a frame that throws must not leave a half-written temp state (or 40 PNGs)
# behind. There is nothing to restore - no real file was ever touched.
try {
    Build-Gif $hero  (Join-Path $root 'assets\moth-demo.gif')       'hero'
    Build-Gif $codex (Join-Path $root 'assets\moth-codex-demo.gif') 'codex'
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
