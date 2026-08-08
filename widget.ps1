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
# Saved window position and per-user overrides (window-state.json is gitignored,
# so personal settings like live_sync can live here without dirtying the repo).
if (Test-Path $stateFile) {
    try {
        $st = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($null -ne $st.window_left) { $cfg.window_left = $st.window_left }
        if ($null -ne $st.window_top)  { $cfg.window_top  = $st.window_top }
        # live_sync is the current name; fable_bar is the old one, still honored.
        if ($null -ne $st.live_sync)   { $cfg.live_sync   = $st.live_sync }
        elseif ($null -ne $st.fable_bar) { $cfg.live_sync = $st.fable_bar }
    } catch { }
}
# Opt-in live sync via the oauth/usage endpoint (undocumented; see README). This is
# the PRIMARY data source for desktop-app users, who get no statusLine feed. Accept
# either config key: live_sync (current) or fable_bar (legacy).
$LIVE_SYNC_ON = ($cfg.live_sync -eq $true) -or ($cfg.fable_bar -eq $true)
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
        SizeToContent="WidthAndHeight" Title="Moth">
  <Border x:Name="Card" CornerRadius="14" Background="#FB0B0D14" BorderBrush="#1A1E2E" BorderThickness="1" Padding="16,12,16,12">
    <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.18" Color="#FFB65C"/></Border.Effect>
    <StackPanel>
      <Grid x:Name="TitleBar" Margin="0,0,0,10">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
          <!-- Moth logo: spark above, wings swept up toward it, tail below (the A mark) -->
          <Canvas Width="16" Height="14" Margin="0,1,7,0">
            <Ellipse Canvas.Left="7.4" Canvas.Top="0.2" Width="1.4" Height="1.4" Fill="#FFF3DF"/>
            <Path Data="M8,5.6 L2.4,2.4 C0.8,1.6 0,3.2 0.8,4.8 L5.6,8.8 Z" Fill="#FFB65C"/>
            <Path Data="M8,5.6 L13.6,2.4 C15.2,1.6 16,3.2 15.2,4.8 L10.4,8.8 Z" Fill="#FFB65C"/>
            <Path Data="M8,5.4 L4.4,10.4 C3.6,11.8 4.4,12.8 5.4,12.1 L8,9.9 L10.6,12.1 C11.6,12.8 12.4,11.8 11.6,10.4 Z" Fill="#E8A34C"/>
            <Ellipse Canvas.Left="6.9" Canvas.Top="5.6" Width="2.2" Height="2.2" Fill="#FFF3DF"/>
          </Canvas>
          <TextBlock Text="Moth" Foreground="#F5E9D5" FontFamily="Segoe UI" FontSize="12" FontWeight="SemiBold"
                     VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <TextBlock x:Name="MinBtn" Text="&#8211;" Foreground="#5A5240" FontFamily="Segoe UI" FontSize="16"
                     Cursor="Hand" Margin="0,0,10,0" ToolTip="Minimize to taskbar"/>
          <TextBlock x:Name="CloseBtn" Text="&#215;" Foreground="#5A5240" FontFamily="Segoe UI" FontSize="16"
                     Cursor="Hand" ToolTip="Close"/>
        </StackPanel>
      </Grid>

      <!-- 5-hour -->
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
        <TextBlock x:Name="Hourglass5" Text="&#x231B;" Foreground="#B08D53" FontFamily="Segoe UI Symbol" FontSize="11"
                   Margin="0,0,4,0" VerticalAlignment="Center" Visibility="Collapsed" RenderTransformOrigin="0.5,0.5">
          <TextBlock.RenderTransform><RotateTransform x:Name="Hourglass5Rot" Angle="0"/></TextBlock.RenderTransform>
        </TextBlock>
        <TextBlock x:Name="Reset5" Text="" Foreground="#6E6552" FontFamily="Segoe UI" FontSize="11" VerticalAlignment="Center"/>
      </StackPanel>

      <!-- Weekly -->
      <Grid Margin="0,0,0,2">
        <TextBlock Text="Weekly" Foreground="#C9BFA9" FontFamily="Segoe UI" FontSize="13" HorizontalAlignment="Left"/>
        <TextBlock x:Name="Pct7" Text="--%" Foreground="#FFD9A0" FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right"/>
      </Grid>
      <Border Width="$TRACK" Height="8" CornerRadius="4" Background="#181A24" HorizontalAlignment="Left" Margin="0,0,0,2">
        <Border x:Name="Fill7" Width="0" Height="8" CornerRadius="4" Background="#FFB65C" HorizontalAlignment="Left">
          <Border.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="0" Opacity="0.55" Color="#FFB65C"/></Border.Effect>
        </Border>
      </Border>
      <TextBlock x:Name="Reset7" Text="" Foreground="#6E6552" FontFamily="Segoe UI" FontSize="11" Margin="0,0,0,8"/>

      <!-- Per-model weekly (endpoint mode only; hidden until data arrives) -->
      <StackPanel x:Name="FableGroup" Visibility="Collapsed">
        <Grid Margin="0,0,0,2">
          <TextBlock x:Name="FableLabel" Text="Fable (weekly)" Foreground="#C9BFA9" FontFamily="Segoe UI" FontSize="13" HorizontalAlignment="Left"/>
          <TextBlock x:Name="PctF" Text="--%" Foreground="#FFD9A0" FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right"/>
        </Grid>
        <Border Width="$TRACK" Height="8" CornerRadius="4" Background="#181A24" HorizontalAlignment="Left" Margin="0,0,0,2">
          <Border x:Name="FillF" Width="0" Height="8" CornerRadius="4" Background="#E8A34C" HorizontalAlignment="Left"/>
        </Border>
        <TextBlock x:Name="ResetF" Text="" Foreground="#6E6552" FontFamily="Segoe UI" FontSize="11" Margin="0,0,0,8"/>
      </StackPanel>

      <TextBlock x:Name="Updated" Text="waiting for Claude usage data..." Foreground="#6E6552"
                 FontFamily="Segoe UI" FontSize="11" HorizontalAlignment="Left"/>
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
$MinBtn  = $win.FindName('MinBtn')
$Pct5    = $win.FindName('Pct5');  $Fill5 = $win.FindName('Fill5');  $Reset5 = $win.FindName('Reset5')
$Hourglass5 = $win.FindName('Hourglass5'); $Hourglass5Rot = $win.FindName('Hourglass5Rot')
$Pct7    = $win.FindName('Pct7');  $Fill7 = $win.FindName('Fill7');  $Reset7 = $win.FindName('Reset7')
$FableGroup = $win.FindName('FableGroup'); $FableLabel = $win.FindName('FableLabel')
$PctF    = $win.FindName('PctF');  $FillF = $win.FindName('FillF');  $ResetF = $win.FindName('ResetF')
$Updated = $win.FindName('Updated')

$win.Left = [double]$cfg.window_left
$win.Top  = [double]$cfg.window_top

# ---- helpers ----
function Get-BarColor([double]$pct) {
    # "Drawn to the light" palette: the lamp burns warmer as you use more.
    if ($pct -ge 90) { return '#FF5C6E' }      # red - about to burn out
    elseif ($pct -ge 70) { return '#FF9D42' }  # deep orange - flame rising
    else { return '#FFB65C' }                  # warm amber - steady glow
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

$script:lastSavedPos = $null
function Save-WindowState {
    # Persist position to the gitignored state file - never rewrite config.json (tracked).
    # Runs on the poll tick AND on close, so a forceful /moth restart (which bypasses the
    # Closing handler) still reloads the most recent position, not a stale one.
    # Only writes when the position actually changed and the window is in Normal state
    # (a minimized window reports a bogus off-screen position we must not persist).
    try {
        if ($null -eq $win -or $win.WindowState -ne [Windows.WindowState]::Normal) { return }
        $key = '{0},{1}' -f [int]$win.Left, [int]$win.Top
        if ($key -eq $script:lastSavedPos) { return }
        $st = @{}
        if (Test-Path $stateFile) {
            try { (Get-Content $stateFile -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $st[$_.Name] = $_.Value } } catch { }
        }
        $st.window_left = [int]$win.Left
        $st.window_top  = [int]$win.Top
        Write-Utf8NoBom $stateFile ([pscustomobject]$st | ConvertTo-Json)
        $script:lastSavedPos = $key
    } catch { }
}

function Update-Display {
    $c = $script:cache
    if (-not $c) {
        $Updated.Text = 'waiting for Claude usage data...'
        return
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $ageMin = [math]::Floor(($now - [long]$c.captured_at) / 60)
    $stale  = $ageMin -ge [int]$cfg.stale_minutes
    # STALE TREATMENT IS A SOLID-CARD TREATMENT, NEVER OPACITY. A dimmed card reads as
    # "the widget is broken/transparent". Stale => bars desaturate to a muted grey-amber
    # and the glow turns off; the card stays fully opaque and the label explains.
    $STALE_BAR = '#8A7B5E'

    $p5 = [math]::Max(0, [math]::Min(100, ([double]$c.five_hour.used_percentage)))
    $p7 = [math]::Max(0, [math]::Min(100, ([double]$c.seven_day.used_percentage)))
    $Pct5.Text = ('{0}%' -f [math]::Round($p5))
    $Pct7.Text = ('{0}%' -f [math]::Round($p7))
    $Fill5.Width = $p5 / 100 * $TRACK
    $Fill7.Width = $p7 / 100 * $TRACK
    $col5 = if ($stale) { $STALE_BAR } else { Get-BarColor $p5 }
    $col7 = if ($stale) { $STALE_BAR } else { Get-BarColor $p7 }
    $Fill5.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($col5)
    $Fill7.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($col7)
    # Bar glow: match the bar when fresh, off (transparent) when stale.
    try {
        if ($Fill5.Effect) { $Fill5.Effect.Opacity = if ($stale) { 0.0 } else { 0.55 }; $Fill5.Effect.Color = [Windows.Media.ColorConverter]::ConvertFromString($col5) }
        if ($Fill7.Effect) { $Fill7.Effect.Opacity = if ($stale) { 0.0 } else { 0.55 }; $Fill7.Effect.Color = [Windows.Media.ColorConverter]::ConvertFromString($col7) }
    } catch { }
    $Reset5.Text = Format-Remaining ([long]$c.five_hour.resets_at)
    $Reset7.Text = Format-Remaining ([long]$c.seven_day.resets_at)

    # Hourglass: rotate 0deg -> 180deg across the 5-hour window (18000s), recomputed on
    # every 1s tick so it turns continuously. Hidden until real data exists (the no-cache
    # branch above returns early). Muted (not hidden) when stale, matching the bars.
    $secsLeft5 = [long]$c.five_hour.resets_at - $now
    $frac5 = [math]::Max(0.0, [math]::Min(1.0, 1.0 - ([double]$secsLeft5 / 18000.0)))
    $Hourglass5Rot.Angle = 180.0 * $frac5
    $Hourglass5.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($(if ($stale) { $STALE_BAR } else { '#B08D53' }))
    $Hourglass5.Visibility = [Windows.Visibility]::Visible

    # Per-model weekly bar - rendered only when the cache carries a fable bucket
    if ($c.fable -and $null -ne $c.fable.used_percentage) {
        $pf = [math]::Max(0, [math]::Min(100, ([double]$c.fable.used_percentage)))
        $PctF.Text = ('{0}%' -f [math]::Round($pf))
        $FillF.Width = $pf / 100 * $TRACK
        if ($c.fable.label) { $FableLabel.Text = ('{0} (weekly)' -f $c.fable.label) }
        if ($c.fable.resets_at) { $ResetF.Text = Format-Remaining ([long]$c.fable.resets_at) }
        $FableGroup.Visibility = [Windows.Visibility]::Visible
    } else {
        $FableGroup.Visibility = [Windows.Visibility]::Collapsed
    }

    # Card is ALWAYS fully opaque - staleness lives in the bars + label, never opacity.
    $Card.Opacity = 1.0
    if ($script:epAuthHint) {
        $Updated.Text = 'log in to Claude Code to sync'
    } elseif ($stale) {
        $Updated.Text = if ($ageMin -ge 60) { ('last synced {0}h ago' -f [math]::Floor($ageMin/60)) } else { ('last synced {0}m ago' -f $ageMin) }
    } else {
        $Updated.Text = if ($ageMin -le 0) { 'updated just now' } else { ('updated {0}m ago' -f $ageMin) }
    }
}

# ---- timers ----
$poll = New-Object Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromSeconds([double]$cfg.poll_seconds)
$poll.Add_Tick({ $script:cache = Read-Cache; Update-Display; Save-WindowState })

$tick = New-Object Windows.Threading.DispatcherTimer
$tick.Interval = [TimeSpan]::FromSeconds(1)
$tick.Add_Tick({ if ($script:cache) { Update-Display } })

# ---- live sync: oauth/usage endpoint poll (PRIMARY source for desktop-app users) ----
# The desktop app never runs the statusLine feed, so this endpoint is the only way to
# keep the widget fresh there. Polls with the token Claude Code already maintains in
# .credentials.json. UNDOCUMENTED endpoint: see the README's honesty section. Never
# performs its own login; never logs the token. 180s base interval + User-Agent header
# are REQUIRED endpoint etiquette (without the UA you get aggressively rate-limited).
$EP_BASE_SECONDS = 180
$script:epBackoff = $EP_BASE_SECONDS

function ConvertTo-PctScale($v) {
    # Endpoint utilization may be 0-1 fraction or 0-100 percent; normalize to 0-100.
    $d = $v -as [double]
    if ($null -eq $d -or [double]::IsNaN($d)) { return $null }
    if ($d -le 1.0) { $d = $d * 100 }
    return [math]::Max(0.0, [math]::Min(100.0, $d))
}
function ConvertTo-Epoch($v) {
    # The endpoint has returned BOTH epoch integers and ISO 8601 strings over time
    # ("2026-08-08T06:00:00.013303+00:00") - accept either. ISO parse must use
    # InvariantCulture (locale-proof, same reason as the statusLine parser).
    $l = [long]0
    if ([long]::TryParse([string]$v, [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$l)) { return $l }
    $dto = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$v, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$dto)) { return [long]$dto.ToUnixTimeSeconds() }
    return $null
}

function Invoke-EndpointPoll {
    try {
        $credFile = Join-Path $env:USERPROFILE '.claude\.credentials.json'
        $token = $null
        if (Test-Path $credFile) { $token = (Get-Content $credFile -Raw | ConvertFrom-Json).claudeAiOauth.accessToken }
        if (-not $token) {
            # Token can be TRANSIENTLY absent (Claude Code rewrites the file on refresh;
            # observed empty-then-repopulated the same evening). NEVER stop polling -
            # show the login hint, back off, and recover automatically when it returns.
            if (-not $script:epNoTokenLogged) {
                Write-ErrorLog "live_sync: no login token in .credentials.json yet - will keep checking (backoff). Log in to Claude Code if this persists."
                $script:epNoTokenLogged = $true
            }
            $script:epAuthHint = $true
            $script:epBackoff = [math]::Min(1800, $script:epBackoff * 2)
            $ep.Interval = [TimeSpan]::FromSeconds($script:epBackoff)
            return
        }
        $script:epNoTokenLogged = $false
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 15 -Headers @{
            'Authorization'  = "Bearer $token"
            'anthropic-beta' = 'oauth-2025-04-20'
            'User-Agent'     = 'claude-code/2.1.224'
        }
        $script:epBackoff = $EP_BASE_SECONDS   # success resets backoff
        $script:epAuthHint = $false

        $p5 = ConvertTo-PctScale $resp.five_hour.utilization
        $r5 = ConvertTo-Epoch    $resp.five_hour.resets_at
        $p7 = ConvertTo-PctScale $resp.seven_day.utilization
        $r7 = ConvertTo-Epoch    $resp.seven_day.resets_at

        # Discover the per-model weekly bucket at runtime (seven_day_fable /
        # seven_day_opus / ...) rather than hardcoding a model name.
        $modelKey = $null
        foreach ($pref in @('seven_day_fable','seven_day_opus','seven_day_sonnet')) {
            if ($resp.PSObject.Properties.Name -contains $pref -and $resp.$pref) { $modelKey = $pref; break }
        }

        if ($null -ne $p5 -and $null -ne $r5 -and $null -ne $p7 -and $null -ne $r7) {
            $obj = [ordered]@{
                five_hour   = [ordered]@{ used_percentage = $p5; resets_at = $r5 }
                seven_day   = [ordered]@{ used_percentage = $p7; resets_at = $r7 }
            }
            if ($modelKey) {
                $pm = ConvertTo-PctScale $resp.$modelKey.utilization
                if ($null -ne $pm) {
                    $label = (Get-Culture).TextInfo.ToTitleCase(($modelKey -replace '^seven_day_',''))
                    $obj.fable = [ordered]@{
                        used_percentage = $pm
                        resets_at       = ConvertTo-Epoch $resp.$modelKey.resets_at
                        label           = $label
                    }
                }
            }
            $obj.captured_at = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $json = [pscustomobject]$obj | ConvertTo-Json -Depth 5
            $tmp = "$cacheFile.tmp"
            Write-Utf8NoBom $tmp $json
            if (Test-Path $cacheFile) { [System.IO.File]::Replace($tmp, $cacheFile, [NullString]::Value) }
            else { Move-Item -Path $tmp -Destination $cacheFile -Force }
            $script:cache = Read-Cache
            Update-Display
        }
    } catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 401) { $script:epAuthHint = $true }
        # diagnostic only - status + exception text, never the token or response body
        Write-ErrorLog ("endpoint poll failed: HTTP {0} - {1}" -f $code, $_.Exception.Message)
        # back off on any failure (429, network, schema change): double up to 30 min
        $script:epBackoff = [math]::Min(1800, $script:epBackoff * 2)
        $ep.Interval = [TimeSpan]::FromSeconds($script:epBackoff)
    }
}

$ep = New-Object Windows.Threading.DispatcherTimer
$ep.Interval = [TimeSpan]::FromSeconds($EP_BASE_SECONDS)
$ep.Add_Tick({ Invoke-EndpointPoll })

# ---- interaction ----
# Close on button-DOWN and mark it handled: a DragMove started by a bubbled press
# would swallow the mouse-up, so an Up-based close handler would never fire.
$CloseBtn.Add_MouseLeftButtonDown({ $_.Handled = $true; $win.Close() })
# One window-level drag handler (CloseBtn's Handled press never reaches it).
# DragMove throws if the button was already released - ignore that.
$win.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })

$win.Add_Closing({ Save-WindowState })

# ---- minimize / restore ----
# The window is normally taskbar-less (ShowInTaskbar=False); a minimized window with
# no taskbar entry would be unrecoverable. So: enable the taskbar entry just for the
# minimized period, and hide it again when the user restores from the taskbar.
$MinBtn.Add_MouseLeftButtonDown({
    $_.Handled = $true
    $win.ShowInTaskbar = $true
    $win.WindowState = [Windows.WindowState]::Minimized
})
$win.Add_StateChanged({
    if ($win.WindowState -eq [Windows.WindowState]::Normal) { $win.ShowInTaskbar = $false }
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
    # Force-exit: WPF spins up non-background threads during render, so a plain `return`
    # leaves the process alive (an orphan). These are headless dev modes - kill it outright.
    [Environment]::Exit(0)
}

# ---- single-instance guard ----
# The SessionStart hook and the statusLine ensure-check can both fire a launch within
# the same moment at cold start; the launch chain takes long enough that both see zero
# running widgets and both spawn, stacking two windows. First instance creates+owns the
# named mutex; a second sees createdNew=$false and exits quietly. (Headless -SelfTest /
# -Screenshot runs returned above and never reach here, so they don't contend.)
$script:mutexNew = $false
$script:mothMutex = New-Object System.Threading.Mutex($true, 'Global\MothWidget', [ref]$script:mutexNew)
if (-not $script:mutexNew) {
    Write-ErrorLog "another Moth instance already holds the single-instance mutex; this launch exits."
    return
}

$win.Add_SourceInitialized({
    $script:cache = Read-Cache
    Update-Display
    $poll.Start(); $tick.Start()
    if ($LIVE_SYNC_ON) { $ep.Start(); Invoke-EndpointPoll }   # immediate first fetch
})

[void]$win.ShowDialog()

} catch {
    Write-ErrorLog $_.Exception.Message
    throw
}
