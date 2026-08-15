# make-demo-gif.ps1 - regenerate the README hero GIF (assets/moth-demo.gif).
#
# Renders the REAL widget: for each frame it writes a usage fixture and calls
#   widget.ps1 -SelfTest <fixture> -Screenshot <png>
# so every frame is the actual widget.ps1 render (real card, real inset + reactive halo,
# real bars/layout/fonts). No hand-maintained copy to drift. The transparent-margin PNGs
# are composited onto a dark "desktop" and encoded into a looping GIF (WPF compresses each
# frame; we byte-patch in the loop + frame delays GifBitmapEncoder omits).
# Run:  powershell.exe -ExecutionPolicy Bypass -File tools\make-demo-gif.ps1
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

$root   = Split-Path $PSScriptRoot -Parent
$widget = Join-Path $root 'widget.ps1'
$out    = Join-Path $root 'assets\moth-demo.gif'
$state  = Join-Path $root 'window-state.json'
$work   = Join-Path $env:TEMP ("moth-gif-" + $PID)
$BG     = '#0B0D14'
New-Item -ItemType Directory -Force -Path $work | Out-Null
function W8($p, $t) { [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false))) }

# Render at the widget's DEFAULT size: back up the user's saved window-state, strip its
# saved size for the render, then restore it afterwards.
$stateBak = if (Test-Path $state) { Get-Content $state -Raw } else { $null }
if ($stateBak) {
    try { $s = $stateBak | ConvertFrom-Json; $s.PSObject.Properties.Remove('win_w'); $s.PSObject.Properties.Remove('win_h'); W8 $state ($s | ConvertTo-Json) } catch { }
}

$now  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$rWk  = $now + 4*86400 + 15*3600   # weekly + Fable reset ~4d 15h out
$r5   = $now + 175*60              # 5-hour resets in ~2h 55m (stable clock)
$r5b  = $now + 299*60              # after the window resets, ~4h 59m out

# frame usage sequence: climb -> peak hold -> reset (loops)
$frames = @()
$steps = 22
for ($i = 0; $i -lt $steps; $i++) {
    $t = $i / ($steps - 1)
    $frames += @{ p5 = (6 + $t*89); p7 = (19 + $t*8); pf = (55 + $t*10); r5 = $r5; delay = 16 }
}
$frames += @{ p5 = 96; p7 = 27; pf = 65; r5 = $r5;  delay = 90 }   # peak hold (red)
$frames += @{ p5 = 96; p7 = 27; pf = 65; r5 = $r5;  delay = 90 }
$frames += @{ p5 = 5;  p7 = 27; pf = 65; r5 = $r5b; delay = 70 }   # 5-hour window resets
$frames += @{ p5 = 5;  p7 = 27; pf = 65; r5 = $r5b; delay = 70 }

# Render each frame through the real widget.
$pngs = @()
for ($i = 0; $i -lt $frames.Count; $i++) {
    $f = $frames[$i]
    $fix = [ordered]@{
        five_hour = [ordered]@{ used_percentage = [math]::Round([double]$f.p5, 1); resets_at = [long]$f.r5 }
        seven_day = [ordered]@{ used_percentage = [math]::Round([double]$f.p7, 1); resets_at = [long]$rWk }
        fable     = [ordered]@{ used_percentage = [math]::Round([double]$f.pf, 1); resets_at = [long]$rWk; label = 'Fable'; captured_at = [long]$now }
        captured_at = [long]$now
    } | ConvertTo-Json
    $fixPath = Join-Path $work "fix$i.json"; $pngPath = Join-Path $work "frame$i.png"
    W8 $fixPath $fix
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget -SelfTest $fixPath -Screenshot $pngPath | Out-Null
    if (-not (Test-Path $pngPath)) { throw "frame $i did not render ($pngPath)" }
    $pngs += $pngPath
}

# Restore the user's real window-state.
if ($stateBak) { W8 $state $stateBak }

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
$delays = $frames | ForEach-Object { [int]$_.delay }
$anim = [GifAnim]::Patch($raw, $delays, 0)
New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
[System.IO.File]::WriteAllBytes($out, $anim)
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("wrote {0}  ({1} real-widget frames, {2}x{3}, {4:N0} bytes)" -f $out, $frames.Count, $fw, $fh, $anim.Length)
