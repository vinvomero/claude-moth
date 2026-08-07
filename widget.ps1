param([string]$SelfTest, [string]$Screenshot)
# widget.ps1
# Frameless, always-on-top desktop widget that shows real Claude Code usage
# (5-hour + weekly) read from usage-cache.json. Native WPF via Windows PowerShell 5.1.
# Launch hidden with:  powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File widget.ps1
# Dev flags (headless, no window shown):
#   -SelfTest <cache.json> | empty   render against a sample cache (or the no-cache
#                                    state) and print a one-line state dump
#   -Screenshot <out.png>            render the card to a PNG (uses the live cache)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$root      = $PSScriptRoot
$cacheFile = Join-Path $root 'usage-cache.json'
$cfgFile   = Join-Path $root 'config.json'
$stateFile = Join-Path $root 'window-state.json'   # per-user runtime state (gitignored)
$logFile   = Join-Path $root 'widget-error.log'

function Write-Utf8NoBom($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}
function Write-ErrorLog($msg) {
    try { Add-Content -Path $logFile -Value ("[{0}] {1}" -f ([DateTime]::UtcNow.ToString('u')), $msg) } catch { }
}

# ---- config (shipped defaults; user-editable) + window state (runtime; gitignored) ----
$defaults = @{ poll_seconds = 20; stale_minutes = 30; window_left = 60; window_top = 60; track_width = 220 }
$cfg = @{}; foreach ($k in @($defaults.Keys)) { $cfg[$k] = $defaults[$k] }
if (Test-Path $cfgFile) {
    try { (Get-Content $cfgFile -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } } catch { }
}
# Saved window position (written on close) overrides config defaults.
if (Test-Path $stateFile) {
    try {
        $st = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($null -ne $st.window_left) { $cfg.window_left = $st.window_left }
        if ($null -ne $st.window_top)  { $cfg.window_top  = $st.window_top }
    } catch { }
}
# Coerce every numeric setting back to a real number (the README invites hand-edits),
# then clamp the ones where a bad range breaks the widget: a 0/negative timer interval
# is a busy loop, and a non-positive track width kills the XAML parse.
foreach ($k in @($defaults.Keys)) {
    $n = $cfg[$k] -as [double]
    $cfg[$k] = if ($null -eq $n -or [double]::IsNaN($n) -or [double]::IsInfinity($n)) { $defaults[$k] } else { $n }
}
$cfg.poll_seconds  = [math]::Max(1, $cfg.poll_seconds)
$cfg.stale_minutes = [math]::Max(1, $cfg.stale_minutes)
$cfg.track_width   = [math]::Min(2000, [math]::Max(50, $cfg.track_width))
$TRACK = [double]$cfg.track_width

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ResizeMode="NoResize" ShowInTaskbar="False"
        SizeToContent="WidthAndHeight" Title="Claude Usage">
  <Border x:Name="Card" CornerRadius="14" Background="#F0121826" Padding="16,12,16,12">
    <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="0" Opacity="0.5" Color="#000000"/></Border.Effect>
    <StackPanel>
      <Grid x:Name="TitleBar" Margin="0,0,0,10">
        <TextBlock Text="Claude usage" Foreground="#9FB2C8" FontFamily="Segoe UI" FontSize="11" FontWeight="SemiBold"
                   HorizontalAlignment="Left" VerticalAlignment="Center"/>
        <TextBlock x:Name="CloseBtn" Text="&#215;" Foreground="#5A6B82" FontFamily="Segoe UI" FontSize="15"
                   HorizontalAlignment="Right" VerticalAlignment="Center" Cursor="Hand"/>
      </Grid>

      <!-- 5-hour -->
      <Grid Margin="0,0,0,2">
        <TextBlock Text="5-hour" Foreground="#C7D3E3" FontFamily="Segoe UI" FontSize="12" HorizontalAlignment="Left"/>
        <TextBlock x:Name="Pct5" Text="--%" Foreground="#FFFFFF" FontFamily="Segoe UI" FontSize="12" FontWeight="SemiBold" HorizontalAlignment="Right"/>
      </Grid>
      <Border Width="$TRACK" Height="8" CornerRadius="4" Background="#22314A" HorizontalAlignment="Left" Margin="0,0,0,2">
        <Border x:Name="Fill5" Width="0" Height="8" CornerRadius="4" Background="#4CC2FF" HorizontalAlignment="Left"/>
      </Border>
      <TextBlock x:Name="Reset5" Text="" Foreground="#7C8CA3" FontFamily="Segoe UI" FontSize="10" Margin="0,0,0,10"/>

      <!-- Weekly -->
      <Grid Margin="0,0,0,2">
        <TextBlock Text="Weekly" Foreground="#C7D3E3" FontFamily="Segoe UI" FontSize="12" HorizontalAlignment="Left"/>
        <TextBlock x:Name="Pct7" Text="--%" Foreground="#FFFFFF" FontFamily="Segoe UI" FontSize="12" FontWeight="SemiBold" HorizontalAlignment="Right"/>
      </Grid>
      <Border Width="$TRACK" Height="8" CornerRadius="4" Background="#22314A" HorizontalAlignment="Left" Margin="0,0,0,2">
        <Border x:Name="Fill7" Width="0" Height="8" CornerRadius="4" Background="#4CC2FF" HorizontalAlignment="Left"/>
      </Border>
      <TextBlock x:Name="Reset7" Text="" Foreground="#7C8CA3" FontFamily="Segoe UI" FontSize="10" Margin="0,0,0,8"/>

      <TextBlock x:Name="Updated" Text="waiting for first Claude session..." Foreground="#5A6B82"
                 FontFamily="Segoe UI" FontSize="10" HorizontalAlignment="Left"/>
    </StackPanel>
  </Border>
</Window>
"@

# Everything from the XAML parse to the message loop runs inside one try so that
# ANY startup fault reaches widget-error.log - the widget launches hidden, so an
# unlogged exception would just look like "the widget never appeared".
try {

$win = [Windows.Markup.XamlReader]::Parse($xaml)

$Card    = $win.FindName('Card')
$CloseBtn= $win.FindName('CloseBtn')
$Pct5    = $win.FindName('Pct5');  $Fill5 = $win.FindName('Fill5');  $Reset5 = $win.FindName('Reset5')
$Pct7    = $win.FindName('Pct7');  $Fill7 = $win.FindName('Fill7');  $Reset7 = $win.FindName('Reset7')
$Updated = $win.FindName('Updated')

$win.Left = [double]$cfg.window_left
$win.Top  = [double]$cfg.window_top

# ---- helpers ----
function Get-BarColor([double]$pct) {
    if ($pct -ge 90) { return '#FF5C6E' }      # red
    elseif ($pct -ge 70) { return '#FFC24C' }  # amber
    else { return '#4CC2FF' }                  # blue
}
function Format-Remaining([long]$resetAt) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $s = [long]$resetAt - $now
    if ($s -le 0) { return 'resetting...' }
    $d = [math]::Floor($s / 86400); $s -= $d*86400
    $h = [math]::Floor($s / 3600);  $s -= $h*3600
    $m = [math]::Floor($s / 60)
    if ($d -gt 0) { return ("resets in {0}d {1}h" -f $d, $h) }
    if ($h -gt 0) { return ("resets in {0}h {1}m" -f $h, $m) }
    return ("resets in {0}m" -f $m)
}

$script:cache = $null

function Read-Cache {
    if (-not (Test-Path $cacheFile)) { return $null }
    try { return (Get-Content $cacheFile -Raw | ConvertFrom-Json) } catch { return $null }
}

function Update-Display {
    $c = $script:cache
    if (-not $c) {
        $Updated.Text = 'waiting for first Claude session...'
        return
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $ageMin = [math]::Floor(($now - [long]$c.captured_at) / 60)
    $stale  = $ageMin -ge [int]$cfg.stale_minutes
    $dim    = if ($stale) { 0.45 } else { 1.0 }

    $p5 = [math]::Max(0, [math]::Min(100, ([double]$c.five_hour.used_percentage)))
    $p7 = [math]::Max(0, [math]::Min(100, ([double]$c.seven_day.used_percentage)))
    $Pct5.Text = ('{0}%' -f [math]::Round($p5))
    $Pct7.Text = ('{0}%' -f [math]::Round($p7))
    $Fill5.Width = $p5 / 100 * $TRACK
    $Fill7.Width = $p7 / 100 * $TRACK
    $Fill5.Background = [Windows.Media.BrushConverter]::new().ConvertFromString((Get-BarColor $p5))
    $Fill7.Background = [Windows.Media.BrushConverter]::new().ConvertFromString((Get-BarColor $p7))
    $Reset5.Text = Format-Remaining ([long]$c.five_hour.resets_at)
    $Reset7.Text = Format-Remaining ([long]$c.seven_day.resets_at)

    $Card.Opacity = $dim
    if ($ageMin -le 0) { $Updated.Text = 'updated just now' }
    else { $Updated.Text = ('updated {0}m ago' -f $ageMin) }
}

# ---- timers ----
$poll = New-Object Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromSeconds([double]$cfg.poll_seconds)
$poll.Add_Tick({ $script:cache = Read-Cache; Update-Display })

$tick = New-Object Windows.Threading.DispatcherTimer
$tick.Interval = [TimeSpan]::FromSeconds(1)
$tick.Add_Tick({ if ($script:cache) { Update-Display } })

# ---- interaction ----
# Close on button-DOWN and mark it handled: a DragMove started by a bubbled press
# would swallow the mouse-up, so an Up-based close handler would never fire.
$CloseBtn.Add_MouseLeftButtonDown({ $_.Handled = $true; $win.Close() })
# One window-level drag handler (CloseBtn's Handled press never reaches it).
# DragMove throws if the button was already released - ignore that.
$win.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })

$win.Add_Closing({
    # Persist position to the gitignored state file - never rewrite config.json,
    # which is a tracked file (rewriting it would dirty every user's clone).
    try {
        $st = [ordered]@{ window_left = [int]$win.Left; window_top = [int]$win.Top }
        Write-Utf8NoBom $stateFile ($st | ConvertTo-Json)
    } catch { }
})

if ($SelfTest -or $Screenshot) {
    if ($SelfTest -and $SelfTest -ne 'empty') { $script:cache = (Get-Content $SelfTest -Raw | ConvertFrom-Json) }
    elseif ($Screenshot -and (Test-Path $cacheFile)) { $script:cache = (Get-Content $cacheFile -Raw | ConvertFrom-Json) }
    Update-Display
    if ($SelfTest) {
        Write-Output ("SELFTEST OK | Pct5={0} Fill5W={1} Reset5='{2}' | Pct7={3} Fill7W={4} Reset7='{5}' | {6} | Opacity={7}" -f `
            $Pct5.Text, [math]::Round($Fill5.Width,1), $Reset5.Text, $Pct7.Text, [math]::Round($Fill7.Width,1), $Reset7.Text, $Updated.Text, $Card.Opacity)
    }
    if ($Screenshot) {
        $Card.Opacity = 1.0
        $win.Content = $null   # un-parent so we can render the card standalone
        $Card.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        $Card.Arrange([Windows.Rect]::new(0, 0, $Card.DesiredSize.Width, $Card.DesiredSize.Height))
        $Card.UpdateLayout()
        $w = [int][math]::Ceiling($Card.ActualWidth); $h = [int][math]::Ceiling($Card.ActualHeight)
        $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($Card)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create($Screenshot); $enc.Save($fs); $fs.Close()
        Write-Output "SCREENSHOT saved: $Screenshot ($w x $h)"
    }
    return
}

$win.Add_SourceInitialized({
    $script:cache = Read-Cache
    Update-Display
    $poll.Start(); $tick.Start()
})

[void]$win.ShowDialog()

} catch {
    Write-ErrorLog $_.Exception.Message
    throw
}
