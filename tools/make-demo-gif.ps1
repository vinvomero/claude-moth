# make-demo-gif.ps1 - regenerate the README hero GIF (assets/moth-demo.gif).
# Renders the REAL Moth card (same XAML/palette as widget.ps1) through a short
# "flame rising" loop - 5-hour usage climbing amber -> orange -> red, the hourglass
# turning, then the window resetting - and encodes a looping animated GIF with no
# external tools (WPF compresses each frame; we byte-patch in the loop + frame delays
# that GifBitmapEncoder omits). Run:  powershell.exe -ExecutionPolicy Bypass -File tools\make-demo-gif.ps1
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$root = Split-Path $PSScriptRoot -Parent
$out  = Join-Path $root 'assets\moth-demo.gif'
$TRACK = 220.0
$PAD = 26      # dark "desktop" margin around the card (GIF has no alpha - avoid ragged corners)
$BG  = '#0B0D14'

# --- the card, copied from widget.ps1 (5-hour + Weekly - the default two-bar view) ---
$xaml = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="Card" CornerRadius="14" Background="#FB0B0D14" BorderBrush="#1A1E2E" BorderThickness="1" Padding="16,12,16,12">
  <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.18" Color="#FFB65C"/></Border.Effect>
  <StackPanel>
    <Grid Margin="0,0,0,10">
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
        <Canvas Width="16" Height="14" Margin="0,1,7,0">
          <Ellipse Canvas.Left="7.4" Canvas.Top="0.2" Width="1.4" Height="1.4" Fill="#FFF3DF"/>
          <Path Data="M8,5.6 L2.4,2.4 C0.8,1.6 0,3.2 0.8,4.8 L5.6,8.8 Z" Fill="#FFB65C"/>
          <Path Data="M8,5.6 L13.6,2.4 C15.2,1.6 16,3.2 15.2,4.8 L10.4,8.8 Z" Fill="#FFB65C"/>
          <Path Data="M8,5.4 L4.4,10.4 C3.6,11.8 4.4,12.8 5.4,12.1 L8,9.9 L10.6,12.1 C11.6,12.8 12.4,11.8 11.6,10.4 Z" Fill="#E8A34C"/>
          <Ellipse Canvas.Left="6.9" Canvas.Top="5.6" Width="2.2" Height="2.2" Fill="#FFF3DF"/>
        </Canvas>
        <TextBlock Text="Moth" Foreground="#F5E9D5" FontFamily="Segoe UI" FontSize="12" FontWeight="SemiBold" VerticalAlignment="Center"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
        <TextBlock Text="&#8211;" Foreground="#5A5240" FontFamily="Segoe UI" FontSize="16" Margin="0,0,10,0"/>
        <TextBlock Text="&#215;" Foreground="#5A5240" FontFamily="Segoe UI" FontSize="16"/>
      </StackPanel>
    </Grid>

    <Grid Margin="0,0,0,2">
      <TextBlock Text="5-hour" Foreground="#C9BFA9" FontFamily="Segoe UI" FontSize="13" HorizontalAlignment="Left"/>
      <TextBlock x:Name="Pct5" Text="--%" Foreground="#FFD9A0" FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right"/>
    </Grid>
    <Border Width="$TRACK" Height="8" CornerRadius="4" Background="#181A24" HorizontalAlignment="Left" Margin="0,0,0,2">
      <Border x:Name="Fill5" Width="0" Height="8" CornerRadius="4" Background="#FFB65C" HorizontalAlignment="Left">
        <Border.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="0" Opacity="0.55" Color="#FFB65C"/></Border.Effect>
      </Border>
    </Border>
    <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
      <TextBlock x:Name="Hourglass5" Text="&#x231B;" Foreground="#B08D53" FontFamily="Segoe UI Symbol" FontSize="11" Margin="0,0,4,0" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
        <TextBlock.RenderTransform><RotateTransform x:Name="Hourglass5Rot" Angle="0"/></TextBlock.RenderTransform>
      </TextBlock>
      <TextBlock x:Name="Reset5" Text="" Foreground="#6E6552" FontFamily="Segoe UI" FontSize="11" VerticalAlignment="Center"/>
    </StackPanel>

    <Grid Margin="0,0,0,2">
      <TextBlock Text="Weekly" Foreground="#C9BFA9" FontFamily="Segoe UI" FontSize="13" HorizontalAlignment="Left"/>
      <TextBlock x:Name="Pct7" Text="--%" Foreground="#FFD9A0" FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right"/>
    </Grid>
    <Border Width="$TRACK" Height="8" CornerRadius="4" Background="#181A24" HorizontalAlignment="Left" Margin="0,0,0,2">
      <Border x:Name="Fill7" Width="0" Height="8" CornerRadius="4" Background="#FFB65C" HorizontalAlignment="Left">
        <Border.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="0" Opacity="0.55" Color="#FFB65C"/></Border.Effect>
      </Border>
    </Border>
    <TextBlock x:Name="Reset7" Text="resets in 4d 15h" Foreground="#6E6552" FontFamily="Segoe UI" FontSize="11" Margin="0,0,0,8"/>

    <TextBlock x:Name="Updated" Text="updated just now" Foreground="#6E6552" FontFamily="Segoe UI" FontSize="11" HorizontalAlignment="Left"/>
  </StackPanel>
</Border>
"@

$card = [Windows.Markup.XamlReader]::Parse($xaml)
$Pct5 = $card.FindName('Pct5'); $Fill5 = $card.FindName('Fill5'); $Reset5 = $card.FindName('Reset5')
$Hg = $card.FindName('Hourglass5'); $HgRot = $card.FindName('Hourglass5Rot')
$Pct7 = $card.FindName('Pct7'); $Fill7 = $card.FindName('Fill7')
$Updated = $card.FindName('Updated')

function Get-BarColor([double]$pct) {
    if ($pct -ge 90) { return '#FF5C6E' } elseif ($pct -ge 70) { return '#FF9D42' } else { return '#FFB65C' }
}
function Format-Mins([int]$mins) {
    $h = [math]::Floor($mins / 60); $m = $mins % 60
    if ($h -gt 0) { return ("resets in {0}h {1}m" -f $h, $m) } else { return ("resets in {0}m" -f $m) }
}
$brush = { param($hex) [Windows.Media.BrushConverter]::new().ConvertFromString($hex) }
$colr  = { param($hex) [Windows.Media.ColorConverter]::ConvertFromString($hex) }

# --- animation sequence: climb -> peak hold -> reset (loops) ---
$frames = @()
$steps = 22
for ($i = 0; $i -lt $steps; $i++) {
    $t = $i / ($steps - 1)
    $frames += @{ p5 = (6 + $t*89); p7 = (19 + $t*8); mins5 = [int](283 - $t*235); delay = 7 }
}
$frames += @{ p5 = 96; p7 = 27; mins5 = 44; delay = 45 }   # peak hold (red)
$frames += @{ p5 = 96; p7 = 27; mins5 = 43; delay = 50 }
$frames += @{ p5 = 5;  p7 = 27; mins5 = 299; delay = 32 }   # the 5-hour window resets
$frames += @{ p5 = 5;  p7 = 27; mins5 = 299; delay = 32 }

# Lock a fixed frame size (measure the widest state once) so every GIF frame matches.
function Set-State($f) {
    $p5 = [double]$f.p5; $p7 = [double]$f.p7
    $c5 = Get-BarColor $p5; $c7 = Get-BarColor $p7
    $Pct5.Text = ('{0}%' -f [math]::Round($p5)); $Fill5.Width = $p5/100*$TRACK
    $Fill5.Background = (& $brush $c5); $Fill5.Effect.Color = (& $colr $c5)
    $Pct7.Text = ('{0}%' -f [math]::Round($p7)); $Fill7.Width = $p7/100*$TRACK
    $Fill7.Background = (& $brush $c7); $Fill7.Effect.Color = (& $colr $c7)
    $Reset5.Text = Format-Mins $f.mins5
    $HgRot.Angle = 180.0 * [math]::Max(0.0, [math]::Min(1.0, 1.0 - (($f.mins5*60.0)/18000.0)))
}
Set-State $frames[0]
$card.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
$card.Arrange([Windows.Rect]::new(0,0,$card.DesiredSize.Width,$card.DesiredSize.Height)); $card.UpdateLayout()
$cw = [int][math]::Ceiling($card.ActualWidth); $ch = [int][math]::Ceiling($card.ActualHeight)
$fw = $cw + 2*$PAD; $fh = $ch + 2*$PAD

$enc = New-Object Windows.Media.Imaging.GifBitmapEncoder
foreach ($f in $frames) {
    Set-State $f
    $card.Measure([Windows.Size]::new($cw, $ch))
    $card.Arrange([Windows.Rect]::new(0,0,$cw,$ch)); $card.UpdateLayout()
    $cardRtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($cw, $ch, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $cardRtb.Render($card)
    # Composite onto the padded dark "desktop" background.
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawRectangle((& $brush $BG), $null, [Windows.Rect]::new(0,0,$fw,$fh))
    $dc.DrawImage($cardRtb, [Windows.Rect]::new($PAD,$PAD,$cw,$ch))
    $dc.Close()
    $frameRtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($fw, $fh, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $frameRtb.Render($dv)
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($frameRtb))
}
$ms = New-Object System.IO.MemoryStream
$enc.Save($ms); $raw = $ms.ToArray(); $ms.Close()

# --- byte-patch: GifBitmapEncoder writes all frames but no loop + no frame delays.
#     Insert the Netscape 2.0 loop block after the screen descriptor/global color
#     table, and a Graphic Control Extension (delay) before each image descriptor. ---
Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
public static class GifAnim {
  // GifBitmapEncoder already writes one Graphic Control Extension per frame (delay 0)
  // and no loop block. So: patch each existing GCE's delay in place, and insert a
  // single Netscape 2.0 loop block after the global color table if none exists.
  public static byte[] Patch(byte[] d, int[] delays, int loop) {
    int pos = 13;                       // after header(6) + logical screen descriptor(7)
    byte packedLSD = d[10];
    if ((packedLSD & 0x80) != 0) pos += 3 * (1 << ((packedLSD & 7) + 1));
    int gctEnd = pos;
    var gceDelayAt = new List<int>();   // byte offset of each GCE's 2-byte delay field
    bool hasNetscape = false;
    int p = pos;
    while (p < d.Length && d[p] != 0x3B) {
      if (d[p] == 0x21) {               // extension
        byte label = d[p + 1];
        if (label == 0xF9) gceDelayAt.Add(p + 4);                 // graphic control ext
        if (label == 0xFF) hasNetscape = true;                    // application ext
        p += 2;
        while (true) { int sz = d[p++]; if (sz == 0) break; p += sz; }
      } else if (d[p] == 0x2C) {        // image descriptor
        byte packedImg = d[p + 9];
        p += 10;
        if ((packedImg & 0x80) != 0) p += 3 * (1 << ((packedImg & 7) + 1));
        p++;                            // LZW minimum code size
        while (true) { int sz = d[p++]; if (sz == 0) break; p += sz; }
      } else break;
    }
    // Patch delays in place (one GCE per frame, in order).
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
Write-Host ("wrote {0}  ({1} frames, {2}x{3}, {4:N0} bytes)" -f $out, $frames.Count, $fw, $fh, $anim.Length)
