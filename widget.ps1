param([string]$SelfTest, [string]$Screenshot, [string]$CodexFixture, [string]$Provider, [string]$StatePath)
# widget.ps1
# Frameless, always-on-top desktop widget that shows real Claude Code usage
# (5-hour + weekly) read from usage-cache.json. Native WPF via Windows PowerShell 5.1.
# Launch hidden with:  powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File widget.ps1
# Dev flags (headless, no window shown):
#   -SelfTest <cache.json> | empty   render against a sample cache (or the no-cache
#                                    state) and print a one-line state dump
#   -Screenshot <out.png>            render the card to a PNG (uses the live cache)
#   -CodexFixture <cache.json>       supply a Codex snapshot without polling Codex
#                                    ('empty' = no Codex snapshot, and do NOT fall back
#                                    to the live cache)
#   -Provider claude|codex           force which provider the dev render paints
#   -StatePath <state.json>          read/write window state here instead of the real
#                                    window-state.json, so a demo render can set its own
#                                    flags without touching the author's settings
# Dev flags never start the timers (those live in SourceInitialized), so a headless
# run can never spawn the Codex helper.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms   # Cursor::Position (absolute screen px) for drag-resize

$root      = $PSScriptRoot
$cacheFile = Join-Path $root 'usage-cache.json'
$cfgFile   = Join-Path $root 'config.json'
# Per-user runtime state (gitignored). -StatePath redirects every read AND write of it,
# so a demo render can hand itself a throwaway state file instead of borrowing - and
# rewriting - the author's real one.
$stateFile = if ($StatePath) { $StatePath } else { Join-Path $root 'window-state.json' }
$logFile   = Join-Path $root 'widget-error.log'
$hiddenFlag = Join-Path $root 'widget-hidden.flag' # written when the user clicks x, so
                                                   # mid-session relaunch respects the close;
                                                   # a new session (or /moth) clears it.

function Write-Utf8NoBom($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}
function Write-ErrorLog($msg) {
    try { Add-Content -Path $logFile -Value ("[{0}] {1}" -f ([DateTime]::UtcNow.ToString('u')), $msg) } catch { }
}

# ---- config (shipped defaults; user-editable) + window state (runtime; gitignored) ----
$defaults = @{ poll_seconds = 20; stale_minutes = 30; window_left = 60; window_top = 60; win_w = 294; win_h = 270 }
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
        if ($null -ne $st.win_w)       { $cfg.win_w       = $st.win_w }
        if ($null -ne $st.win_h)       { $cfg.win_h       = $st.win_h }
        # live_sync is the current name; fable_bar is the old one, still honored.
        if ($null -ne $st.live_sync)   { $cfg.live_sync   = $st.live_sync }
        elseif ($null -ne $st.fable_bar) { $cfg.live_sync = $st.fable_bar }
        # Codex as a second provider - opt-in, same shape as live_sync. Keys read here
        # or they are invisible to the widget: this merge is an explicit allow-list, not
        # a wholesale copy.
        if ($null -ne $st.codex)     { $cfg.codex     = $st.codex }
        if ($null -ne $st.codex_exe) { $cfg.codex_exe = $st.codex_exe }
        # Manual provider pick and when it was made. Both are needed: the pick holds only
        # until the OTHER provider shows activity newer than the pick.
        if ($null -ne $st.provider)          { $cfg.provider          = $st.provider }
        if ($null -ne $st.provider_picked_at) { $cfg.provider_picked_at = $st.provider_picked_at }
    } catch {
        # A hand-edit with an unescaped backslash (e.g. "codex_exe": "C:\Users\...") makes
        # the whole file unparseable, and every setting in it - position, live_sync, codex -
        # silently reverts to defaults. Say so once instead of leaving the user to guess.
        Write-ErrorLog ("window-state.json could not be parsed; using defaults - " + $_.Exception.Message)
    }
}
# Opt-in live sync via the oauth/usage endpoint (undocumented; see README). This is
# the PRIMARY data source for desktop-app users, who get no statusLine feed. Accept
# either config key: live_sync (current) or fable_bar (legacy).
# live_sync wins whenever it is set at all - so an explicit `live_sync: false` overrides
# a stale legacy `fable_bar: true`. Fall back to the old key only when live_sync is absent.
$LIVE_SYNC_ON = if ($null -ne $cfg.live_sync) { $cfg.live_sync -eq $true } else { $cfg.fable_bar -eq $true }
# Opt-in Codex provider. When off the widget behaves exactly as it always has: Claude
# only, no provider tab, and capture-codex.ps1 is never spawned.
$CODEX_ON = ($cfg.codex -eq $true)
# Both Codex runtime files live outside the repo: the repo is OneDrive-synced, which
# rewrites mtimes (forging the activity signal) and churns on a 3-minute rewrite.
$MOTH_DATA_DIR  = Join-Path $env:LOCALAPPDATA 'Moth'
$codexCacheFile = Join-Path $MOTH_DATA_DIR 'codex-cache.json'
$activityFile   = Join-Path $MOTH_DATA_DIR 'activity.json'
$codexHelper    = Join-Path $root 'capture-codex.ps1'
# Coerce every numeric setting back to a real number (the README invites hand-edits),
# then clamp the ones where a bad range breaks the widget: a 0/negative timer interval
# is a busy loop, and a non-positive track width kills the XAML parse.
foreach ($k in @($defaults.Keys)) {
    $n = $cfg[$k] -as [double]
    $cfg[$k] = if ($null -eq $n -or [double]::IsNaN($n) -or [double]::IsInfinity($n)) { $defaults[$k] } else { $n }
}
$cfg.poll_seconds  = [math]::Max(1, $cfg.poll_seconds)
$cfg.stale_minutes = [math]::Max(1, $cfg.stale_minutes)
# Free-resize bounds (match the window's MinWidth/MinHeight in the XAML). One source of
# truth, used to clamp the saved size at startup AND in the grip drag handlers.
$MIN_W = 230.0; $MIN_H = 190.0; $MAX_W = 1440.0; $MAX_H = 1240.0
$cfg.win_w = [math]::Min($MAX_W, [math]::Max($MIN_W, $cfg.win_w))
$cfg.win_h = [math]::Min($MAX_H, [math]::Max($MIN_H, $cfg.win_h))

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ResizeMode="NoResize" ShowInTaskbar="False"
        Width="294" Height="270" MinWidth="230" MinHeight="190" Title="Moth">
  <Grid>
    <Border x:Name="Card" CornerRadius="14" Background="#FB0B0D14" BorderBrush="#1A1E2E" BorderThickness="1" Padding="16,12,16,12" Margin="20">
    <!-- Card is inset 20px inside the window so the amber glow (blur 18 < 20) fades to
         nothing BEFORE the window edge - no square clip at the rounded corners. -->
    <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="0" Opacity="0.2" Color="#FFB65C"/></Border.Effect>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Grid x:Name="TitleBar" Grid.Row="0" Margin="0,0,0,10">
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
          <!-- Provider switch. Collapsed entirely until a second provider has data, so
               the Claude-only card is untouched. Sits in the drag area, so the handlers
               mark the event Handled on BUTTON-DOWN like MinBtn/CloseBtn - an Up-based
               click never fires because DragMove swallows the mouse-up. -->
          <StackPanel x:Name="TabGroup" Orientation="Horizontal" VerticalAlignment="Center"
                      Margin="8,0,0,0" Visibility="Collapsed">
            <TextBlock x:Name="TabClaude" Text="Claude" FontFamily="Segoe UI" FontSize="11"
                       Foreground="#6E6552" Cursor="Hand" VerticalAlignment="Center"/>
            <TextBlock Text="/" FontFamily="Segoe UI" FontSize="11" Foreground="#3A362C"
                       Margin="4,0,4,0" VerticalAlignment="Center"/>
            <TextBlock x:Name="TabCodex" Text="Codex" FontFamily="Segoe UI" FontSize="11"
                       Foreground="#6E6552" Cursor="Hand" VerticalAlignment="Center"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <TextBlock x:Name="MinBtn" Text="&#8211;" Foreground="#5A5240" FontFamily="Segoe UI" FontSize="16"
                     Cursor="Hand" Margin="0,0,10,0" ToolTip="Minimize to taskbar"/>
          <TextBlock x:Name="CloseBtn" Text="&#215;" Foreground="#5A5240" FontFamily="Segoe UI" FontSize="16"
                     Cursor="Hand" ToolTip="Close"/>
        </StackPanel>
      </Grid>

      <!-- bars: fill the middle row; tracks stretch to card width; thickness set in code -->
      <StackPanel x:Name="BarsPanel" Grid.Row="1" VerticalAlignment="Center">
      <!-- 5-hour -->
      <Grid Margin="0,0,0,2">
        <TextBlock Text="5-hour" Foreground="#C9BFA9" FontFamily="Segoe UI" FontSize="13" HorizontalAlignment="Left"/>
        <TextBlock x:Name="Pct5" Text="--%" Foreground="#FFD9A0" FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right"/>
      </Grid>
      <Border x:Name="Track5" Height="8" CornerRadius="4" Background="#181A24" HorizontalAlignment="Stretch" Margin="0,0,0,2">
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
      <Border x:Name="Track7" Height="8" CornerRadius="4" Background="#181A24" HorizontalAlignment="Stretch" Margin="0,0,0,2">
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
        <Border x:Name="TrackF" Height="8" CornerRadius="4" Background="#181A24" HorizontalAlignment="Stretch" Margin="0,0,0,2">
          <Border x:Name="FillF" Width="0" Height="8" CornerRadius="4" Background="#E8A34C" HorizontalAlignment="Left"/>
        </Border>
        <TextBlock x:Name="ResetF" Text="" Foreground="#6E6552" FontFamily="Segoe UI" FontSize="11" Margin="0,0,0,8"/>
      </StackPanel>
      </StackPanel>

      <TextBlock x:Name="Updated" Grid.Row="2" Text="waiting for Claude usage data..." Foreground="#6E6552"
                 FontFamily="Segoe UI" FontSize="11" HorizontalAlignment="Left"/>
    </Grid>
    </Border>
    <!-- Free-resize grips: thin transparent edge strips + corner squares over the card
         edges. NoResize window + manual drag so it works on a transparent window. Only the
         bottom-right corner shows a visible hint; the rest are invisible hit zones. -->
    <!-- Grips are inset by the 20px card margin so you grab the VISIBLE card edge, not the halo. -->
    <Border x:Name="GripL"  HorizontalAlignment="Left"   VerticalAlignment="Stretch"   Width="6"  Margin="20,20,0,20" Background="Transparent" Cursor="SizeWE" Tag="L"/>
    <Border x:Name="GripR"  HorizontalAlignment="Right"  VerticalAlignment="Stretch"   Width="6"  Margin="0,20,20,20" Background="Transparent" Cursor="SizeWE" Tag="R"/>
    <Border x:Name="GripT"  VerticalAlignment="Top"      HorizontalAlignment="Stretch" Height="6" Margin="20,20,20,0" Background="Transparent" Cursor="SizeNS" Tag="T"/>
    <Border x:Name="GripB"  VerticalAlignment="Bottom"   HorizontalAlignment="Stretch" Height="6" Margin="20,0,20,20" Background="Transparent" Cursor="SizeNS" Tag="B"/>
    <Border x:Name="GripTL" HorizontalAlignment="Left"   VerticalAlignment="Top"    Width="12" Height="12" Margin="20,20,0,0" Background="Transparent" Cursor="SizeNWSE" Tag="TL"/>
    <Border x:Name="GripTR" HorizontalAlignment="Right"  VerticalAlignment="Top"    Width="12" Height="12" Margin="0,20,20,0" Background="Transparent" Cursor="SizeNESW" Tag="TR"/>
    <Border x:Name="GripBL" HorizontalAlignment="Left"   VerticalAlignment="Bottom" Width="12" Height="12" Margin="20,0,0,20" Background="Transparent" Cursor="SizeNESW" Tag="BL"/>
    <Border x:Name="GripBR" HorizontalAlignment="Right"  VerticalAlignment="Bottom" Width="15" Height="15" Margin="0,0,22,22" Background="Transparent" Cursor="SizeNWSE" Tag="BR">
      <Path Stroke="#7A6E55" StrokeThickness="1.4" SnapsToDevicePixels="True" Data="M 12,4 L 4,12 M 12,8 L 8,12"/>
    </Border>
  </Grid>
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
$TabGroup = $win.FindName('TabGroup'); $TabClaude = $win.FindName('TabClaude'); $TabCodex = $win.FindName('TabCodex')
$PctF    = $win.FindName('PctF');  $FillF = $win.FindName('FillF');  $ResetF = $win.FindName('ResetF')
$Updated = $win.FindName('Updated')
$BarsPanel = $win.FindName('BarsPanel')
$Track5 = $win.FindName('Track5'); $Track7 = $win.FindName('Track7'); $TrackF = $win.FindName('TrackF')
$Grips = @('GripL','GripR','GripT','GripB','GripTL','GripTR','GripBL','GripBR') | ForEach-Object { $win.FindName($_) }
# Apply the saved/default window size before the window is shown.
$win.Width  = [double]$cfg.win_w
$win.Height = [double]$cfg.win_h

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
    $countdown = if ($d -gt 0) { "in {0}d {1}h" -f $d, $h }
                 elseif ($h -gt 0) { "in {0}h {1}m" -f $h, $m }
                 else { "in {0}m" -f $m }
    # Wall-clock reset time in the user's local zone, locale-aware short time (12h/24h
    # follows the OS setting). '·' via [char] so PS 5.1 file-encoding can't mangle it.
    # FromUnixTimeSeconds THROWS for out-of-range epochs (e.g. a ms-sized value) - guard
    # it so a bad cache value degrades to the countdown instead of crash-looping the widget.
    $clock = $null
    try { $clock = [DateTimeOffset]::FromUnixTimeSeconds([long]$resetAt).ToLocalTime().ToString('t') } catch { }
    if ($clock) { return ("resets {0} {1} {2}" -f $clock, ([char]0x00B7), $countdown) }
    return ("resets {0}" -f $countdown)
}

$script:cache = $null

function Test-Numeric($x) {
    # PS 5.1 gotcha: `$null -as [double]` is 0, not $null - so guard null/blank FIRST.
    if ($null -eq $x) { return $false }
    if ($x -is [string] -and [string]::IsNullOrWhiteSpace($x)) { return $false }
    $d = $x -as [double]
    return (($null -ne $d) -and (-not [double]::IsNaN($d)))
}

function Read-Cache {
    if (-not (Test-Path $cacheFile)) { return $null }
    try { $c = Get-Content $cacheFile -Raw | ConvertFrom-Json } catch { return $null }
    # Shape-guard the cache. It is normally written by our own code, but the README
    # invites hand-edits and a malformed cache must degrade to "waiting for data",
    # never crash the widget (a thrown [long] cast on ISO/garbage would kill the
    # dialog and the statusLine ensure-check would relaunch it into the same crash).
    # Require both core buckets with numeric percent + epoch resets_at, and a numeric
    # captured_at (writers always convert ISO to epoch before storing).
    foreach ($b in 'five_hour','seven_day') {
        if (-not $c.$b) { return $null }
        if (-not (Test-Numeric $c.$b.used_percentage)) { return $null }
        if (-not (Test-Numeric $c.$b.resets_at)) { return $null }
    }
    if (-not (Test-Numeric $c.captured_at)) { return $null }
    # The per-model (fable) bucket is OPTIONAL - so a bad one drops just that bar rather
    # than sinking the whole cache. Without this, a non-numeric hand-edit crashes the
    # render path (the one place that bypasses the numeric guard above).
    if ($c.fable -and (-not (Test-Numeric $c.fable.used_percentage) -or -not (Test-Numeric $c.fable.resets_at))) {
        $c.PSObject.Properties.Remove('fable')
    }
    return $c
}

# The Codex cache is written by capture-codex.ps1 and has a DIFFERENT contract to the
# Claude one, even though it borrows the same field names so the helper can reuse the
# shared parsers: only five_hour is required (some plans report no weekly bucket at
# all), and a null resets_at is legitimate rather than corrupt - at 0% used there is no
# open window to reset. Only Read-CodexCache knows this file's fields; everything
# downstream consumes the provider view built from it.
function Read-CodexCache {
    if (-not (Test-Path $codexCacheFile)) { return $null }
    try { $c = Get-Content $codexCacheFile -Raw | ConvertFrom-Json } catch { return $null }
    # An ERROR-ONLY cache (last_error, no buckets) is a valid shape, not a broken one: the
    # helper writes it whenever a poll fails, and it is the whole mechanism by which the
    # card explains itself. Rejecting it here is what made "turn the flag on and nothing
    # happens" the experience for anyone whose Codex was missing or signed out.
    $hasBuckets = ($c.five_hour -and (Test-Numeric $c.five_hour.used_percentage) -and (Test-Numeric $c.captured_at))
    if (-not $hasBuckets -and -not $c.last_error) { return $null }
    # Weekly is optional; drop just that bucket when it is malformed.
    if ($hasBuckets -and $c.seven_day -and -not (Test-Numeric $c.seven_day.used_percentage)) {
        $c.PSObject.Properties.Remove('seven_day')
    }
    return $c
}

# Per-provider "the user actually did something" stamps, written by touch-activity.ps1.
# Deliberately NOT derived from either usage cache: the statusLine rewrites captured_at
# every ~15s while a Claude session is merely open, and the live_sync poll rewrites it
# every 3 minutes with no session at all - auto-following that would yank the card back
# to Claude seconds after every Codex turn.
#
# Codex has no hook entry installed (whether the desktop app fires them is unconfirmed),
# so its stamp comes from the newest sessions rollout file, which only grows on real
# turns. logs_2.sqlite-wal is deliberately NOT used: it advances on its own roughly
# every 12 seconds, so it is a heartbeat, not activity.
$script:codexRolloutDir = Join-Path $env:USERPROFILE '.codex\sessions'
function Read-Activity {
    $claude = $null; $codex = $null
    if (Test-Path $activityFile) {
        try {
            $a = Get-Content $activityFile -Raw | ConvertFrom-Json
            if (Test-Numeric $a.claude) { $claude = [long]$a.claude }
            if (Test-Numeric $a.codex)  { $codex  = [long]$a.codex }
        } catch { }
    }
    if ($null -eq $codex -and (Test-Path $script:codexRolloutDir)) {
        try {
            $newest = Get-ChildItem $script:codexRolloutDir -Recurse -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if ($newest) { $codex = [long][DateTimeOffset]::new($newest.LastWriteTimeUtc, [TimeSpan]::Zero).ToUnixTimeSeconds() }
        } catch { }
    }
    # A stamp from the future (clock step, hand edit) would pin the pick forever.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($null -ne $claude -and $claude -gt $now) { $claude = $now }
    if ($null -ne $codex  -and $codex  -gt $now) { $codex  = $now }
    return [pscustomobject]@{ claude = $claude; codex = $codex }
}

# Flatten either cache into ONE shape the paint path and the halo consume, so neither
# has to know which provider it is looking at or which file the numbers came from.
# Each bucket carries its own freshness (the pattern the per-model bar already used),
# because the two providers go stale independently.
function ConvertTo-ProviderView($provider, $c) {
    if ($null -eq $c) { return $null }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $staleSecs = [int]$cfg.stale_minutes * 60

    # capturedAt stays $null when the cache has none (the error-only shape): casting an
    # absent stamp to [long] yields 0, which renders as "last synced 496000h ago".
    $capturedAt = $null
    $baseStale = $false
    if (Test-Numeric $c.captured_at) {
        $capturedAt = [long]$c.captured_at
        $baseStale = (($now - $capturedAt) -ge $staleSecs)
    }
    $p5 = $null
    if ($c.five_hour -and (Test-Numeric $c.five_hour.used_percentage)) {
        $p5 = [math]::Max(0, [math]::Min(100, [double]$c.five_hour.used_percentage))
    }

    $v = [pscustomobject]@{
        provider    = $provider
        p5          = $p5
        r5          = $null
        p7          = $null
        r7          = $null
        stale5      = $baseStale
        stale7      = $baseStale
        window5Secs = 18000.0
        fable       = $null
        fableStale  = $baseStale
        capturedAt  = $capturedAt
        lastError   = $null
    }
    # Attach the reason BEFORE the early return - an error-only view is precisely the one
    # that has nothing but a reason to show.
    if ($c.last_error) { $v.lastError = $c.last_error }
    if ($null -eq $p5) { return $v }   # error-only view: no bars, no countdowns to build
    if (Test-Numeric $c.five_hour.resets_at) { $v.r5 = [long]$c.five_hour.resets_at }
    if (Test-Numeric $c.five_hour.window_mins) {
        $w = [double]$c.five_hour.window_mins * 60.0
        if ($w -gt 0) { $v.window5Secs = $w }
    }
    if ($c.seven_day -and (Test-Numeric $c.seven_day.used_percentage)) {
        $v.p7 = [math]::Max(0, [math]::Min(100, [double]$c.seven_day.used_percentage))
        if (Test-Numeric $c.seven_day.resets_at) { $v.r7 = [long]$c.seven_day.resets_at }
    }
    # Per-model bar is a Claude-only concept and carries its own timestamp, because the
    # statusLine writer carries the bucket forward untouched while refreshing the
    # top-level captured_at - a frozen value must not render as live.
    if ($c.fable -and (Test-Numeric $c.fable.used_percentage)) {
        $v.fable = $c.fable
        if (Test-Numeric $c.fable.captured_at) {
            $v.fableStale = ((($now - [long]$c.fable.captured_at)) -ge $staleSecs)
        }
    }
    if ($c.last_error) { $v.lastError = $c.last_error }
    return $v
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
        $w = [int][math]::Round([double]$win.ActualWidth); $h = [int][math]::Round([double]$win.ActualHeight)
        if ($w -le 0) { $w = [int]$win.Width }; if ($h -le 0) { $h = [int]$win.Height }
        # Key includes size so a pure resize (no move) still triggers a write.
        $key = '{0},{1},{2},{3}' -f [int]$win.Left, [int]$win.Top, $w, $h
        if ($key -eq $script:lastSavedPos) { return }
        $st = @{}
        if (Test-Path $stateFile) {
            try { (Get-Content $stateFile -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $st[$_.Name] = $_.Value } } catch { }
        }
        $st.window_left = [int]$win.Left
        $st.window_top  = [int]$win.Top
        $st.win_w       = $w
        $st.win_h       = $h
        [void]$st.Remove('scale')   # drop the legacy uniform-scale key if present
        Write-Utf8NoBom $stateFile ([pscustomobject]$st | ConvertTo-Json)
        $script:lastSavedPos = $key
    } catch { }
}

$script:p5 = 0; $script:p7 = 0; $script:pf = 0
function Update-Layout {
    # Fluid, distortion-free resize: the bars FILL the current width (fill = pct of the
    # stretched track's actual width) and THICKEN with window height; text is untouched.
    # Runs on every data update and on window SizeChanged.
    try {
        if ($null -eq $win) { return }
        $h = [double]$win.ActualHeight; if ($h -le 0) { $h = [double]$win.Height }
        $barH = [math]::Max(6.0, [math]::Min(46.0, 8.0 + ($h - 270.0) * 0.06))
        $rad  = New-Object Windows.CornerRadius(($barH / 2.0))
        # All three tracks stretch to the SAME card width, so take the widest laid-out one
        # (a collapsed/not-yet-measured track reports 0 and would otherwise NaN the fill).
        $tw = 0.0
        foreach ($t in @($Track5,$Track7,$TrackF)) { if ($t -and [double]$t.ActualWidth -gt $tw) { $tw = [double]$t.ActualWidth } }
        foreach ($p in @(@($Track5,$Fill5,$script:p5), @($Track7,$Fill7,$script:p7), @($TrackF,$FillF,$script:pf))) {
            $track = $p[0]; $fill = $p[1]; $pct = [double]$p[2]
            if ($null -eq $track) { continue }
            $track.Height = $barH; $track.CornerRadius = $rad
            $fill.Height = $barH;  $fill.CornerRadius = $rad
            $fill.Width = [math]::Max(0.0, $pct / 100.0 * $tw)
        }
    } catch { }
}

# STALE TREATMENT IS A SOLID-CARD TREATMENT, NEVER OPACITY. A dimmed card reads as
# "the widget is broken/transparent". Stale => bars desaturate to a muted grey-amber
# and the glow turns off; the card stays fully opaque and the label explains.
$STALE_BAR = '#8A7B5E'

# Paint ONE provider view into the bars. Knows nothing about which provider it is or
# which file the numbers came from - that is the whole point of the view.
function Show-ProviderView($v) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # A provider can have no reading at all (a failed poll with no prior snapshot). Show
    # the bar as unknown rather than as a confident 0%.
    if ($null -eq $v.p5) {
        $Pct5.Text = '--%'
        $script:p5 = 0
        $col5 = $STALE_BAR
    } else {
        $Pct5.Text = ('{0}%' -f [math]::Round($v.p5))
        $script:p5 = $v.p5   # Update-Layout turns these into fill widths (fluid)
        $col5 = if ($v.stale5) { $STALE_BAR } else { Get-BarColor $v.p5 }
    }
    $Fill5.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($col5)

    # A provider can report no weekly bucket at all (some Codex plans). Show the bar as
    # unknown rather than as a fresh 0%, which would read as "you have used nothing".
    if ($null -eq $v.p7) {
        $Pct7.Text = '--%'
        $script:p7 = 0
        $col7 = $STALE_BAR
    } else {
        $Pct7.Text = ('{0}%' -f [math]::Round($v.p7))
        $script:p7 = $v.p7
        $col7 = if ($v.stale7) { $STALE_BAR } else { Get-BarColor $v.p7 }
    }
    $Fill7.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($col7)

    # Bar glow: match the bar when fresh, off (transparent) when stale.
    try {
        if ($Fill5.Effect) { $Fill5.Effect.Opacity = if ($v.stale5 -or $null -eq $v.p5) { 0.0 } else { 0.55 }; $Fill5.Effect.Color = [Windows.Media.ColorConverter]::ConvertFromString($col5) }
        if ($Fill7.Effect) { $Fill7.Effect.Opacity = if ($v.stale7 -or $null -eq $v.p7) { 0.0 } else { 0.55 }; $Fill7.Effect.Color = [Windows.Media.ColorConverter]::ConvertFromString($col7) }
    } catch { }

    # A null reset is legitimate (no window open yet at 0% used), so blank the countdown
    # and park the hourglass rather than rendering an epoch-0 "resetting..." forever.
    $Reset5.Text = if ($null -eq $v.r5) { '' } else { Format-Remaining ([long]$v.r5) }
    $Reset7.Text = if ($null -eq $v.r7) { '' } else { Format-Remaining ([long]$v.r7) }

    # Hourglass: rotate 0deg -> 180deg across the 5-hour window, recomputed on every 1s
    # tick so it turns continuously. Muted (not hidden) when stale, matching the bars.
    if ($null -eq $v.r5) {
        $Hourglass5.Visibility = [Windows.Visibility]::Collapsed
    } else {
        $secsLeft5 = [long]$v.r5 - $now
        $frac5 = [math]::Max(0.0, [math]::Min(1.0, 1.0 - ([double]$secsLeft5 / [double]$v.window5Secs)))
        $Hourglass5Rot.Angle = 180.0 * $frac5
        $Hourglass5.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($(if ($v.stale5) { $STALE_BAR } else { '#B08D53' }))
        $Hourglass5.Visibility = [Windows.Visibility]::Visible
    }

    # Per-model weekly bar - Claude-only, and only when that cache carries the bucket.
    # It has its OWN timestamp: the statusLine capture carries it forward unchanged while
    # refreshing the top-level captured_at, so a frozen value must never show in amber.
    if ($v.fable) {
        $pf = [math]::Max(0, [math]::Min(100, ([double]$v.fable.used_percentage)))
        $PctF.Text = ('{0}%' -f [math]::Round($pf))
        $script:pf = $pf
        $FillF.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($(if ($v.fableStale) { $STALE_BAR } else { '#E8A34C' }))
        if ($v.fable.label) { $FableLabel.Text = ('{0} (weekly)' -f $v.fable.label) }
        if ($v.fable.resets_at) { $ResetF.Text = Format-Remaining ([long]$v.fable.resets_at) }
        $FableGroup.Visibility = [Windows.Visibility]::Visible
    } else {
        $script:pf = 0
        $FableGroup.Visibility = [Windows.Visibility]::Collapsed
    }
    Update-Layout   # size the (stretchable) bars to the current width + height
}

# Pure reducer for "which provider should the card show". No I/O, no side effects: the
# CALLER persists when it reports changed, which keeps this fixture-testable and keeps
# selection out of the once-a-second paint path.
#
# Activity here means a turn/session event (see Read-Activity), never a data refresh.
# Ties and missing stamps resolve to Claude, the incumbent - a card that flips on a
# coin-toss at startup is worse than one that is predictably wrong.
function Resolve-ProviderState($codexOn, $codexPresent, $tClaude, $tCodex, $pick, $pickedAt) {
    if (-not $codexOn -or -not $codexPresent) {
        return [pscustomobject]@{ provider = 'claude'; tabVisible = $false; pick = $pick; pickedAt = $pickedAt; changed = $false }
    }
    $changed = $false
    if ($pick -eq 'claude' -or $pick -eq 'codex') {
        $otherStamp = if ($pick -eq 'claude') { $tCodex } else { $tClaude }
        $since = if ($null -eq $pickedAt) { 0 } else { [long]$pickedAt }
        if ($null -ne $otherStamp -and [long]$otherStamp -gt $since) {
            # The other tool has been used since the pick was made: auto-follow resumes.
            $changed = $true
        } else {
            return [pscustomobject]@{ provider = $pick; tabVisible = $true; pick = $pick; pickedAt = $pickedAt; changed = $false }
        }
    }
    # Auto-follow needs a comparable PAIR of stamps. Codex always has one (its rollout
    # files), but Claude's only exists once its hook is installed - and a missing stamp
    # would lose every comparison, pinning the card to Codex forever and silently turning
    # a Claude widget into a Codex-only one. With one side unknown, keep the incumbent and
    # let the tab be the mechanism; auto-follow starts working when both signals exist.
    $provider = 'claude'
    if ($null -ne $tClaude -and $null -ne $tCodex -and [long]$tCodex -gt [long]$tClaude) { $provider = 'codex' }
    return [pscustomobject]@{ provider = $provider; tabVisible = $true; pick = $null; pickedAt = $null; changed = $changed }
}

# Persist the manual pick without touching the size/position keys. Save-WindowState only
# writes when the POSITION changed, so the pick needs its own read-merge-write.
function Save-ProviderPick($pick, $pickedAt) {
    try {
        $obj = @{}
        if (Test-Path $stateFile) {
            try { (Get-Content $stateFile -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $obj[$_.Name] = $_.Value } } catch { }
        }
        if ($null -eq $pick) {
            $obj.Remove('provider') | Out-Null
            $obj.Remove('provider_picked_at') | Out-Null
        } else {
            $obj['provider'] = $pick
            $obj['provider_picked_at'] = [long]$pickedAt
        }
        Write-Utf8NoBom $stateFile (([pscustomobject]$obj) | ConvertTo-Json -Depth 10)
    } catch { Write-ErrorLog ("could not persist provider pick - " + $_.Exception.Message) }
}

# Which provider the card is currently painting, and whether the switch tab is shown.
# Set by Update-Display; read by the dev dump and (from U4) the tab handlers.
$script:activeProvider = 'claude'
$script:tabVisible = $false
$script:forcedProvider = $null
$script:codexCache = $null
$script:tabColClaude = $null
$script:tabColCodex = $null
# Manual pick, seeded from the gitignored per-user state and mutated by the tab.
$script:pick = $(if ($cfg.provider -eq 'claude' -or $cfg.provider -eq 'codex') { [string]$cfg.provider } else { $null })
$script:pickedAt = $(if (Test-Numeric $cfg.provider_picked_at) { [long]$cfg.provider_picked_at } else { $null })
# Activity stamps, refreshed by the poll tick - never read from disk in the 1s paint path.
$script:activity = [pscustomobject]@{ claude = $null; codex = $null }

function Update-Display {
    # Views are rebuilt every tick, not every poll: staleness and the countdowns have to
    # advance once a second. This is pure in-memory transformation - the caches
    # themselves are read on the poll tick.
    $views = @{}
    $cv = ConvertTo-ProviderView 'claude' $script:cache
    if ($cv) { $views['claude'] = $cv }
    if ($CODEX_ON -or $script:forcedProvider) {
        $xv = ConvertTo-ProviderView 'codex' $script:codexCache
        # No cache file at all yet. Say so, rather than showing a Claude-only card that
        # looks exactly like the flag having done nothing: "checking" until the first
        # poll has had its chance, then the launch failure it must be if nothing landed
        # (blocked execution policy, an uncreatable data dir, a helper that died early).
        if (-not $xv -and $CODEX_ON) {
            $waited = if ($null -eq $script:cxStartedAt) { 0 } else { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $script:cxStartedAt }
            $pendingClass = if ($script:cxStartedAt -and $waited -gt 30) { 'spawn-failed' } else { 'pending' }
            $xv = [pscustomobject]@{
                provider = 'codex'; p5 = $null; r5 = $null; p7 = $null; r7 = $null
                stale5 = $false; stale7 = $false; window5Secs = 18000.0
                fable = $null; fableStale = $false; capturedAt = $null
                lastError = $(if ($pendingClass -eq 'pending') { $null } else { [pscustomobject]@{ class = 'spawn-failed'; code = $null; message = '' } })
            }
        }
        if ($xv) { $views['codex'] = $xv }
    }
    $script:views = $views

    # Selection is a pure reducer over values already in memory. When it clears a pick,
    # THIS caller persists the clear - the reducer itself stays side-effect free.
    $r = Resolve-ProviderState $CODEX_ON ($null -ne $views['codex']) `
            $script:activity.claude $script:activity.codex $script:pick $script:pickedAt
    if ($r.changed) {
        $script:pick = $r.pick; $script:pickedAt = $r.pickedAt
        Save-ProviderPick $r.pick $r.pickedAt
    }
    $active = $r.provider
    if ($script:forcedProvider) { $active = $script:forcedProvider }  # dev render override
    $script:activeProvider = $active
    $script:tabVisible = $r.tabVisible

    # The data gate is "does ANY provider have a view", not "is the Claude cache loaded" -
    # otherwise a Codex-only card would never advance its countdown.
    $v = $views[$active]
    if (-not $v -and $views['claude']) { $v = $views['claude']; $active = 'claude'; $script:activeProvider = 'claude' }
    if (-not $v) {
        $Updated.Text = 'waiting for Claude usage data...'
        $TabGroup.Visibility = [Windows.Visibility]::Collapsed
        return
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    # No timestamp means no snapshot has ever landed, so there is no age to report - the
    # status text says what is happening instead of inventing an elapsed time.
    $ageMin = $null
    if ($null -ne $v.capturedAt) { $ageMin = [math]::Floor(($now - $v.capturedAt) / 60) }
    $stale  = $v.stale5

    Show-ProviderView $v

    # Tab: only once a second provider actually has data, so the Claude-only card is
    # untouched. Brushes are set on change only - this runs once a second.
    $tabVis = if ($script:tabVisible) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    if ($TabGroup.Visibility -ne $tabVis) { $TabGroup.Visibility = $tabVis }
    if ($script:tabVisible) {
        # "Claude" and "Codex" both start with C, so a single-letter abbreviation would
        # render two identical tabs at exactly the width where it kicks in.
        $narrow = ([double]$win.Width -lt 260.0)
        $lblC = if ($narrow) { 'Cl' } else { 'Claude' }
        $lblX = if ($narrow) { 'Co' } else { 'Codex' }
        if ($TabClaude.Text -ne $lblC) { $TabClaude.Text = $lblC }
        if ($TabCodex.Text  -ne $lblX) { $TabCodex.Text  = $lblX }
        $cCol = if ($active -eq 'claude') { '#F5E9D5' } else { '#6E6552' }
        $xCol = if ($active -eq 'codex')  { '#F5E9D5' } else { '#6E6552' }
        if ($script:tabColClaude -ne $cCol) {
            $TabClaude.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($cCol); $script:tabColClaude = $cCol
        }
        if ($script:tabColCodex -ne $xCol) {
            $TabCodex.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($xCol); $script:tabColCodex = $xCol
        }
    }

    # Card is ALWAYS fully opaque - staleness lives in the bars + label, never opacity.
    $Card.Opacity = 1.0
    # Card halo reacts to usage: it tracks the HOTTEST limit (5h / weekly / per-model) -
    # soft amber when you're fine, warming to orange/red and brightening as you near a
    # limit ("the flame rising"). Blur stays fixed (<= inset margin) so corners never clip;
    # only colour + opacity change. Muted grey + dim when stale, matching the bars.
    # It tracks the hottest limit across BOTH providers, so it can warn about the one you
    # are not looking at - the tab is how you find out which. Only FRESH buckets count: a
    # frozen snapshot must not hold the card red for days (the per-model bar used to).
    try {
        if ($Card.Effect) {
            $heat = $null
            foreach ($pv in $views.Values) {
                if (-not $pv.stale5) { if ($null -eq $heat -or $pv.p5 -gt $heat) { $heat = $pv.p5 } }
                if ($null -ne $pv.p7 -and -not $pv.stale7) { if ($null -eq $heat -or $pv.p7 -gt $heat) { $heat = $pv.p7 } }
                if ($pv.fable -and -not $pv.fableStale) {
                    $pfv = [double]$pv.fable.used_percentage
                    if ($null -eq $heat -or $pfv -gt $heat) { $heat = $pfv }
                }
            }
            if ($null -eq $heat) {
                $Card.Effect.Color   = [Windows.Media.ColorConverter]::ConvertFromString($STALE_BAR)
                $Card.Effect.Opacity = 0.12
            } else {
                $Card.Effect.Color   = [Windows.Media.ColorConverter]::ConvertFromString((Get-BarColor $heat))
                $Card.Effect.Opacity = [math]::Max(0.12, [math]::Min(0.55, 0.12 + $heat / 100.0 * 0.45))
            }
        }
    } catch { }
    # Status text belongs to the VISIBLE provider. A Claude token hint printed under
    # Codex bars would tell the user to fix something unrelated to what they can see.
    if ($active -eq 'codex') {
        $cls  = if ($v.lastError) { [string]$v.lastError.class } else { '' }
        $code = if ($v.lastError -and (Test-Numeric $v.lastError.code)) { [int]$v.lastError.code } else { $null }
        $msg  = if ($v.lastError) { [string]$v.lastError.message } else { '' }
        if ($cls -eq 'binary-missing')  { $Updated.Text = 'Codex app-server not found' }
        elseif ($cls -eq 'spawn-failed'){ $Updated.Text = "couldn't start Codex" }
        elseif ($cls -eq 'parse-fail')  { $Updated.Text = 'Codex reply had no usable limits' }
        elseif ($cls -eq 'rpc-error') {
            # -32600 is JSON-RPC's generic "invalid request" - the server returns it for
            # rejected params too, so only the message makes it a sign-in problem.
            if     ($code -eq -32600 -and $msg -match '(?i)auth') { $Updated.Text = 'sign in to Codex to sync' }
            elseif ($code -eq -32601) { $Updated.Text = 'Codex too old for rateLimits/read' }
            elseif ($code -eq -32603) { $Updated.Text = 'Codex sync failed' }
            elseif ($code -eq -32001) { $Updated.Text = 'Codex overloaded, retrying' }
            elseif ($null -ne $code)  { $Updated.Text = ('Codex error {0}' -f $code) }
            else                      { $Updated.Text = 'Codex sync failed' }
        }
        elseif ($cls -eq 'timeout')     { $Updated.Text = 'codex: poll timed out' }
        elseif ($null -eq $ageMin)      { $Updated.Text = 'Codex: checking...' }
        elseif ($stale) {
            $Updated.Text = if ($ageMin -ge 60) { ('codex: last synced {0}h ago' -f [math]::Floor($ageMin/60)) } else { ('codex: last synced {0}m ago' -f $ageMin) }
        } else {
            $Updated.Text = if ($ageMin -le 0) { 'codex: updated just now' } else { ('codex: updated {0}m ago' -f $ageMin) }
        }
    } elseif ($script:epExpired -and $stale) {
        # Expired token is NOT a login problem - the user IS logged in; the file just
        # aged out. Say what's actually happening (nudge in flight) or what actually
        # fixes it (any fresh Claude session rewrites the file).
        $Updated.Text = if ($script:epNudgeOk) { 'refreshing sync...' } else { 'open a Claude session to re-sync' }
    } elseif ($script:epAuthHint -and $stale) {
        # Only surface the login hint when the missing token is ACTUALLY causing
        # staleness. If the statusLine feed is keeping the bars fresh, live_sync's
        # absent token is irrelevant - don't nag a logged-in user to "log in", and
        # don't let a hint that can never clear (token in protected storage) shadow
        # good data forever.
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
# The poll tick owns ALL file reads for the render path; Update-Display and the 1s tick
# are pure in-memory work so a provider switch can never cost disk I/O once a second.
$poll.Add_Tick({
    $script:cache = Read-Cache
    if ($CODEX_ON) {
        $script:codexCache = Read-CodexCache
        $script:activity = Read-Activity
        # A Codex turn just landed: refresh now instead of waiting out the Codex interval,
        # so the bars lag a turn by one poll tick rather than by up to three minutes.
        if ($null -ne $script:activity.codex -and $null -ne $script:cxLastActivity -and
            $script:activity.codex -gt $script:cxLastActivity) { Invoke-CodexPoll }
        $script:cxLastActivity = $script:activity.codex
        # A poll deferred by the spacing floor is honoured on the first tick that clears
        # it, so a turn's refresh is delayed rather than lost.
        if ($script:cxWanted) { Invoke-CodexPoll }
    }
    Update-Display
    Save-WindowState
})

$tick = New-Object Windows.Threading.DispatcherTimer
$tick.Interval = [TimeSpan]::FromSeconds(1)
$tick.Add_Tick({ if ($script:cache -or $script:codexCache) { Update-Display } })

# ---- Codex poll (opt-in): fire-and-forget the helper, never talk to Codex from here ----
# Every timer here runs on the WPF dispatcher thread, so anything that blocks freezes the
# card. Talking to `codex app-server` means a process spawn plus a live backend call - so
# the widget only LAUNCHES capture-codex.ps1 and reads the cache it publishes. The helper
# owns the exchange, its own 8s deadline, and killing its child.
$CX_BASE_SECONDS = 180
# Floor between spawns. The rollout file advances on every streamed Codex turn and the
# poll tick fires an immediate helper whenever it does, so without this an agentic run
# spawns an app-server - plus a backend call and a possible auth.json refresh - on every
# poll tick, roughly every 15 seconds. A deferred poll is remembered, not dropped.
$CX_MIN_SPACING = 60
$script:cxBackoff = $CX_BASE_SECONDS
$script:cxProc = $null
$script:cxStartedAt = $null
$script:cxLastActivity = $null
$script:cxWanted = $false

function Invoke-CodexPoll {
    try {
        # Still running from last time? Skip rather than stack helpers. The helper also
        # holds a named mutex, which covers the case where a widget restart forgot the
        # in-flight child.
        if ($script:cxProc -and -not $script:cxProc.HasExited) {
            $ageSec = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $script:cxStartedAt)
            # The helper's own deadline is the real bound; this is the anomaly path for a
            # helper that somehow outlived it. .NET Framework has no process-tree kill, so
            # use taskkill /T to make sure its codex.exe child goes too.
            if ($ageSec -gt 30) {
                Write-ErrorLog ("codex: helper still running after {0}s - terminating tree" -f $ageSec)
                try { Start-Process 'taskkill.exe' -ArgumentList '/PID', $script:cxProc.Id, '/T', '/F' -WindowStyle Hidden -ErrorAction SilentlyContinue } catch { }
                $script:cxProc = $null
            }
            return
        }
        if (-not (Test-Path $codexHelper)) { return }
        $sinceLast = if ($null -eq $script:cxStartedAt) { [int]::MaxValue }
                     else { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $script:cxStartedAt }
        if ($sinceLast -lt $CX_MIN_SPACING) { $script:cxWanted = $true; return }
        $script:cxWanted = $false
        # Hidden via ShellExecute (SW_HIDE), the same idiom as the token nudge: the console
        # is created already hidden rather than flashing and then hiding. No -Wait (that
        # would block the dispatcher) and no output redirection.
        # QUOTE THE PATH. Start-Process joins -ArgumentList with spaces and does NOT quote,
        # so an unquoted path containing a space (this repo lives under "Claude Projects")
        # splits into two arguments and powershell.exe dies with 0xFFFD0000 before running
        # anything - a launch that "succeeds" from here and silently never polls.
        $script:cxProc = Start-Process 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $codexHelper + '"'))
        $script:cxStartedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        # Success resets the interval, not just the variable - restoring only the variable
        # once pinned polling at the backoff ceiling forever (the live_sync bug).
        $script:cxBackoff = $CX_BASE_SECONDS
        $cx.Interval = [TimeSpan]::FromSeconds($CX_BASE_SECONDS)
    } catch {
        Write-ErrorLog ("codex: could not launch helper - " + $_.Exception.Message)
        # Back off, but never past the point where a HEALTHY provider would look stale.
        $ceiling = [math]::Max($CX_BASE_SECONDS, ([int]$cfg.stale_minutes * 60) - 60)
        $script:cxBackoff = [math]::Min($ceiling, $script:cxBackoff * 2)
        $cx.Interval = [TimeSpan]::FromSeconds($script:cxBackoff)
    }
}

$cx = New-Object Windows.Threading.DispatcherTimer
$cx.Interval = [TimeSpan]::FromSeconds($CX_BASE_SECONDS)
$cx.Add_Tick({ Invoke-CodexPoll })

# ---- live sync: oauth/usage endpoint poll (PRIMARY source for desktop-app users) ----
# The desktop app never runs the statusLine feed, so this endpoint is the only way to
# keep the widget fresh there. Polls with the token Claude Code already maintains in
# .credentials.json. UNDOCUMENTED endpoint: see the README's honesty section. Never
# performs its own login; never logs the token. 180s base interval + User-Agent header
# are REQUIRED endpoint etiquette (without the UA you get aggressively rate-limited).
$EP_BASE_SECONDS = 180
$script:epBackoff = $EP_BASE_SECONDS

function ConvertTo-PctScale($v) {
    # The endpoint reports utilization on a 0-100 scale (verified live: 79.0, 24.0).
    # Guard null/empty FIRST: in PS 5.1 `$null -as [double]` is 0, NOT $null - so a
    # `utilization: null` payload would coerce to a fresh, wrong 0% and silently
    # overwrite good data. Return $null instead so the write-guard skips it. (The Mac
    # plugin guards this same case.) No 0-1 rescale: it would turn a real 1% into 100%.
    if ($null -eq $v -or ($v -is [string] -and [string]::IsNullOrWhiteSpace($v))) { return $null }
    $d = $v -as [double]
    if ($null -eq $d -or [double]::IsNaN($d)) { return $null }
    return [math]::Max(0.0, [math]::Min(100.0, $d))
}
function ConvertTo-Epoch($v) {
    # The endpoint has returned BOTH epoch integers and ISO 8601 strings over time
    # ("2026-08-08T06:00:00.013303+00:00") - accept either. ISO parse must use
    # InvariantCulture (locale-proof, same reason as the statusLine parser).
    $l = [long]0
    if ([long]::TryParse([string]$v, [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$l)) {
        # Normalize epoch-MILLIS to seconds: anything past ~year 5138 (1e11 s) is almost
        # certainly milliseconds, and FromUnixTimeSeconds would throw on it downstream.
        if ($l -gt 100000000000) { $l = [long]($l / 1000) }
        return $l
    }
    $dto = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$v, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$dto)) { return [long]$dto.ToUnixTimeSeconds() }
    return $null
}

function Select-ScopedWeekly($limits) {
    # Pure, fixture-testable pick of the per-model weekly-scoped limit from limits[].
    # DETERMINISTIC tie-break (active, then highest percent, then model name) so Windows,
    # Mac, and repeated calls all pick the same model even if several are active - PS 5.1
    # Sort-Object isn't a stable sort, so we can't lean on input order.
    if (-not $limits) { return $null }
    $cands = @($limits | Where-Object {
        $_.group -eq 'weekly' -and $_.scope -and $_.scope.model -and $_.scope.model.display_name })
    if (-not $cands.Count) { return $null }
    $cands | Sort-Object `
        @{ Expression = { [int][bool]$_.is_active };            Descending = $true }, `
        @{ Expression = { [double]($_.percent -as [double]) };  Descending = $true }, `
        @{ Expression = { [string]$_.scope.model.display_name }; Descending = $false } |
        Select-Object -First 1
}

function Invoke-TokenNudge {
    # The login token in .credentials.json expires every ~8h, and a LONG-RUNNING Claude
    # app refreshes it in memory without writing the file back - so the file (our only
    # token source) goes permanently stale mid-session. Verified fix: a FRESH Claude
    # Code process refreshes the token via its own official path and writes the file.
    # So: wake a minimal headless `claude -p` (one tiny Haiku request, disclosed in the
    # README, disable with "token_nudge": false). Throttled to once per 15 min.
    # We deliberately do NOT call the OAuth refresh endpoint ourselves - Claude Code
    # owns the token lifecycle; Moth just gives it a reason to run.
    if ($cfg.token_nudge -eq $false) { return $false }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($script:lastNudge -and (($now - $script:lastNudge) -lt 900)) { return $true }
    $cli = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $cli) { return $false }
    $script:lastNudge = $now
    try {
        Start-Process -WindowStyle Hidden -FilePath $cli.Source -ArgumentList '-p','ok','--model','claude-haiku-4-5'
        Write-ErrorLog "live_sync: login token expired; woke a minimal Claude Code process to refresh it (token nudge)."
        return $true
    } catch { return $false }
}

function Invoke-EndpointPoll {
    try {
        $credFile = Join-Path $env:USERPROFILE '.claude\.credentials.json'
        $token = $null; $expMs = $null
        if (Test-Path $credFile) {
            $oauth = (Get-Content $credFile -Raw | ConvertFrom-Json).claudeAiOauth
            $token = $oauth.accessToken
            $expMs = $oauth.expiresAt -as [long]
        }
        # Expired-token check BEFORE burning a doomed request: expiresAt is epoch ms.
        $expired = $false
        if ($token -and $expMs -and ($expMs -lt ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 60000))) { $expired = $true }
        if (-not $token -or $expired) {
            if ($expired) {
                # Not a login problem - the file's token aged out while the app holds a
                # fresh one in memory. Nudge Claude Code to rewrite the file, then retry
                # SOON (fixed short interval, not the doubling backoff - the nudge
                # usually lands within seconds).
                $script:epNudgeOk = Invoke-TokenNudge
                $script:epExpired = $true
                $ep.Interval = [TimeSpan]::FromSeconds(45)
                return
            }
            # Token entirely absent: can be TRANSIENT (Claude Code rewrites the file on
            # refresh). NEVER stop polling - hint, back off, recover automatically.
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
        $script:epBackoff = $EP_BASE_SECONDS   # success resets backoff...
        $ep.Interval = [TimeSpan]::FromSeconds($EP_BASE_SECONDS)  # ...and the LIVE timer, not just the variable - else one blip pins polling at up to 30 min forever
        $script:epAuthHint = $false
        $script:epExpired = $false

        $p5 = ConvertTo-PctScale $resp.five_hour.utilization
        $r5 = ConvertTo-Epoch    $resp.five_hour.resets_at
        $p7 = ConvertTo-PctScale $resp.seven_day.utilization
        $r7 = ConvertTo-Epoch    $resp.seven_day.resets_at

        # Per-model weekly usage lives in limits[] as a `weekly_scoped` entry
        # (scope.model.display_name), NOT in a top-level seven_day_<model> field - those
        # are null on Max plans. The `fable` cache key is a legacy name; it now holds
        # whichever model the scoped weekly limit currently tracks (Fable, Opus, ...).
        $scoped = Select-ScopedWeekly $resp.limits

        if ($null -ne $p5 -and $null -ne $r5 -and $null -ne $p7 -and $null -ne $r7) {
            $obj = [ordered]@{
                five_hour   = [ordered]@{ used_percentage = $p5; resets_at = $r5 }
                seven_day   = [ordered]@{ used_percentage = $p7; resets_at = $r7 }
            }
            # Populate the per-model bar in its OWN try - a shape surprise from this
            # undocumented array must drop just this bar, never discard the good
            # five_hour/seven_day data for the whole tick.
            try {
              if ($scoped) {
                $rawPct = if ($null -ne $scoped.percent) { $scoped.percent } else { $scoped.utilization }
                $pm = ConvertTo-PctScale $rawPct
                if ($null -ne $pm) {
                    $obj.fable = [ordered]@{
                        used_percentage = $pm
                        resets_at       = ConvertTo-Epoch $scoped.resets_at
                        label           = [string]$scoped.scope.model.display_name
                        captured_at     = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    }
                }
              }
            } catch { Write-ErrorLog ("live_sync: per-model bar skipped - " + $_.Exception.Message) }
            $obj.captured_at = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $json = [pscustomobject]$obj | ConvertTo-Json -Depth 5
            $tmp = "$cacheFile.$PID.tmp"   # per-writer name so it never collides with the statusLine capture's temp
            Write-Utf8NoBom $tmp $json
            if (Test-Path $cacheFile) { [System.IO.File]::Replace($tmp, $cacheFile, [NullString]::Value) }
            else { Move-Item -Path $tmp -Destination $cacheFile -Force }
            $script:cache = Read-Cache
            Update-Display
        }
    } catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 401) {
            # 401 with a token that LOOKED valid = the file is stale anyway (e.g. clock
            # skew, or expiresAt lied). Same cure: nudge Claude Code to rewrite it.
            $script:epExpired = $true
            $script:epNudgeOk = Invoke-TokenNudge
            Write-ErrorLog ("endpoint poll failed: HTTP 401 - token stale; nudged={0}" -f $script:epNudgeOk)
            $ep.Interval = [TimeSpan]::FromSeconds(45)
            return
        }
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
$CloseBtn.Add_MouseLeftButtonDown({ $_.Handled = $true; $script:userClosed = $true; $win.Close() })
# One window-level drag handler (CloseBtn's Handled press never reaches it).
# DragMove throws if the button was already released - ignore that.
$win.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })

# ---- free resize (8 edge/corner grips) ----
# NoResize transparent window, so resize is manual. Each grip's Tag names the active edges
# (L/R/T/B; corners combine them). Cursor is tracked in absolute SCREEN pixels and converted
# to DIPs via the window's DPI so the drag is 1:1 at any display scale. The grip press is
# Handled so the window's DragMove never competes. Every handler is wrapped - an exception
# in a WPF event handler propagates to the dispatcher and would take the whole widget down.
# ($this is the grip that fired; one shared handler serves all 8.)
$script:rz = $null
$rzDown = {
    try {
        $_.Handled = $true
        $p = [System.Windows.Forms.Cursor]::Position
        $dip = 1.0
        try { $src = [System.Windows.PresentationSource]::FromVisual($win); if ($src) { $dip = [double]$src.CompositionTarget.TransformFromDevice.M11 } } catch { }
        $script:rz = @{ mode = [string]$this.Tag; px = $p.X; py = $p.Y
                        L = [double]$win.Left; T = [double]$win.Top; W = [double]$win.ActualWidth; H = [double]$win.ActualHeight; dip = $dip }
        if (-not $this.CaptureMouse()) { $script:rz = $null }
    } catch { $script:rz = $null }
}
$rzMove = {
    try {
        if ($null -eq $script:rz) { return }
        if ($_.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { $script:rz = $null; return }
        $p = [System.Windows.Forms.Cursor]::Position
        $dx = ($p.X - $script:rz.px) * $script:rz.dip
        $dy = ($p.Y - $script:rz.py) * $script:rz.dip
        $m = $script:rz.mode; $W = $script:rz.W; $H = $script:rz.H; $L = $script:rz.L; $T = $script:rz.T
        $newW = $W; $newH = $H; $newL = $L; $newT = $T
        if ($m -like '*R*') { $newW = $W + $dx }
        if ($m -like '*L*') { $newW = $W - $dx }
        if ($m -like '*B*') { $newH = $H + $dy }
        if ($m -like '*T*') { $newH = $H - $dy }
        $newW = [math]::Max($MIN_W, [math]::Min($MAX_W, $newW))
        $newH = [math]::Max($MIN_H, [math]::Min($MAX_H, $newH))
        if ($m -like '*L*') { $newL = $L + ($W - $newW) }   # left/top edges move the origin
        if ($m -like '*T*') { $newT = $T + ($H - $newH) }
        $win.Left = $newL; $win.Top = $newT; $win.Width = $newW; $win.Height = $newH
    } catch { $script:rz = $null }
}
$rzUp = {
    try {
        if ($null -eq $script:rz) { return }
        $_.Handled = $true; $script:rz = $null
        $this.ReleaseMouseCapture(); Save-WindowState
    } catch { }
}
# App-scoped capture: clicking another window mid-drag fires LostMouseCapture with no
# MouseUp. Clear state (and persist) so the widget can never get stuck resizing.
$rzLost = { if ($script:rz) { $script:rz = $null; try { Save-WindowState } catch { } } }
foreach ($g in $Grips) {
    if ($null -eq $g) { continue }
    $g.Add_MouseLeftButtonDown($rzDown); $g.Add_MouseMove($rzMove)
    $g.Add_MouseLeftButtonUp($rzUp);      $g.Add_LostMouseCapture($rzLost)
}
# Reflow the bars whenever the window size changes (drag, or programmatic).
$win.Add_SizeChanged({ Update-Layout })

$win.Add_Closing({
    Save-WindowState
    # Only the x button sets $userClosed, so a forceful kill (/moth, install restart)
    # or an OS shutdown never leaves a stray "stay hidden" marker behind.
    if ($script:userClosed) { try { New-Item -ItemType File -Path $hiddenFlag -Force | Out-Null } catch { } }
})

# ---- minimize / restore ----
# The window is normally taskbar-less (ShowInTaskbar=False); a minimized window with
# no taskbar entry would be unrecoverable. So: enable the taskbar entry just for the
# minimized period, and hide it again when the user restores from the taskbar.
# Provider tabs. Act on BUTTON-DOWN and mark the event Handled, exactly like MinBtn and
# CloseBtn: the window-level Down handler starts DragMove, which swallows the mouse-up,
# so an Up-based click would never fire. Consequence: the tab is not a drag handle - the
# "Moth" wordmark beside it still is.
function Set-ProviderPick($provider) {
    $script:pick = $provider
    $script:pickedAt = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Save-ProviderPick $script:pick $script:pickedAt
    Update-Display
}
$TabClaude.Add_MouseLeftButtonDown({
    $_.Handled = $true
    try { Set-ProviderPick 'claude' } catch { Write-ErrorLog ("tab claude - " + $_.Exception.Message) }
})
$TabCodex.Add_MouseLeftButtonDown({
    $_.Handled = $true
    try { Set-ProviderPick 'codex' } catch { Write-ErrorLog ("tab codex - " + $_.Exception.Message) }
})

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
    # Codex side: an explicit fixture, else the live Codex cache for -Screenshot. Loaded
    # raw the same way the Claude cache is, so a fixture can exercise shapes Read-CodexCache
    # would reject.
    # 'empty' is an ANSWER, not a missing argument: it means "render with no Codex
    # snapshot" and must not fall through to the live cache, or a hero frame rendered on
    # the author's machine would quietly carry the author's real Codex percentages.
    if ($CodexFixture -eq 'empty') { }
    elseif ($CodexFixture) { $script:codexCache = (Get-Content $CodexFixture -Raw | ConvertFrom-Json) }
    elseif ($Screenshot -and (Test-Path $codexCacheFile)) { $script:codexCache = (Get-Content $codexCacheFile -Raw | ConvertFrom-Json) }
    if ($Provider) { $script:forcedProvider = $Provider }
    # The window is never shown here, so nothing lays it out. Detach the content and force a
    # layout pass at the window size so the fluid bars (and ActualWidth) are real.
    $ww = [double]$win.Width; $wh = [double]$win.Height
    $rootEl = $win.Content; $win.Content = $null
    $rootEl.Measure([Windows.Size]::new($ww, $wh))
    $rootEl.Arrange([Windows.Rect]::new(0, 0, $ww, $wh))
    $rootEl.UpdateLayout()
    Update-Display   # sets text/visibility/percentages, then Update-Layout fills the bars
    if ($SelfTest) {
        $fableDump = if ($FableGroup.Visibility -eq [Windows.Visibility]::Visible) {
            "Fable[vis {0}='{1}' {2} reset='{3}']" -f $PctF.Text, $FableLabel.Text, [math]::Round($FillF.Width,1), $ResetF.Text
        } else { "Fable[collapsed]" }
        $provDump = "Provider={0} Tab={1}" -f $script:activeProvider, $(if ($script:tabVisible) { 'visible' } else { 'hidden' })
        # Halo is the cross-provider signal, so it has to be assertable without eyeballing
        # a screenshot: it can be driven by a provider that is not even on screen.
        $haloDump = if ($Card.Effect) {
            "Halo={0}/{1:N2}" -f $Card.Effect.Color, $Card.Effect.Opacity
        } else { "Halo=none" }
        $provDump = "$provDump $haloDump"
        Write-Output ("SELFTEST OK | Pct5={0} Fill5W={1} Reset5='{2}' | Pct7={3} Fill7W={4} Reset7='{5}' | {6} | Win={7}x{8} | Opacity={9} | {10} | {11}" -f `
            $Pct5.Text, [math]::Round($Fill5.Width,1), $Reset5.Text, $Pct7.Text, [math]::Round($Fill7.Width,1), $Reset7.Text, $Updated.Text, [int]$ww, [int]$wh, $Card.Opacity, $fableDump, $provDump)
    }
    if ($Screenshot) {
        $Card.Opacity = 1.0
        foreach ($g in $Grips) { if ($g) { $g.Visibility = [Windows.Visibility]::Collapsed } }  # hide grips in the shot
        $rootEl.Measure([Windows.Size]::new($ww, $wh))
        $rootEl.Arrange([Windows.Rect]::new(0, 0, $ww, $wh))
        $rootEl.UpdateLayout()
        $w = [int][math]::Ceiling($ww); $h = [int][math]::Ceiling($wh)
        $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($rootEl)
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
    # Read the Codex side once before first paint so the card OPENS on the right provider
    # rather than flipping to it up to a poll interval later.
    if ($CODEX_ON) {
        $script:codexCache = Read-CodexCache
        $script:activity = Read-Activity
        # Seed from the file so the first poll tick does not read an "advance" that is
        # really just the first read and fire a spurious immediate poll.
        $script:cxLastActivity = $script:activity.codex
    }
    Update-Display
    $poll.Start(); $tick.Start()
    # Codex polling starts BEFORE the endpoint poll. Invoke-EndpointPoll runs
    # synchronously here and can take up to its 15s timeout; anything after it is at the
    # mercy of it returning cleanly, and a start that never happens is invisible.
    # Starting a timer is instant, so it goes first.
    # This is also the ONLY place polling starts, so a headless -SelfTest / -Screenshot
    # run (which returns long before this) can never spawn a helper. The first poll is
    # left to the timer rather than fired now: first paint must not wait on a spawn.
    if ($CODEX_ON) {
        $cx.Start(); Write-ErrorLog 'codex: polling enabled'
        # First snapshot seconds after first paint, not three minutes later. A one-shot
        # timer, not an inline call: first paint must not wait on a process spawn. It
        # cannot fire until this handler returns, so with live sync on it lands after
        # the synchronous endpoint fetch below.
        $cxFirst = New-Object Windows.Threading.DispatcherTimer
        $cxFirst.Interval = [TimeSpan]::FromSeconds(3)
        $cxFirst.Add_Tick({ $cxFirst.Stop(); Invoke-CodexPoll }.GetNewClosure())
        $cxFirst.Start()
    }
    if ($LIVE_SYNC_ON) { $ep.Start(); Invoke-EndpointPoll }   # immediate first fetch
})

[void]$win.ShowDialog()

} catch {
    Write-ErrorLog $_.Exception.Message
    throw
}
