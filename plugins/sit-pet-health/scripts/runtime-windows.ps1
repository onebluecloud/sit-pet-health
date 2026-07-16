param(
    [string]$PluginRoot = $env:CLAUDE_PLUGIN_ROOT,
    [string]$PluginData = $env:CLAUDE_PLUGIN_DATA,
    [switch]$TestMode,
    [int]$AutoExitSeconds = 0,
    [double]$TimeScale = 1.0,
    [double]$InitialSedentarySeconds = -1,
    [double]$SimulatedIdleSeconds = -1,
    [string]$SimulatedIdleFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PluginRoot)) {
    $PluginRoot = if (-not [string]::IsNullOrWhiteSpace($env:PLUGIN_ROOT)) { $env:PLUGIN_ROOT } else { Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
}
if ([string]::IsNullOrWhiteSpace($PluginData) -and -not [string]::IsNullOrWhiteSpace($env:PLUGIN_DATA)) { $PluginData = $env:PLUGIN_DATA }
if ([string]::IsNullOrWhiteSpace($PluginData)) {
    throw 'CLAUDE_PLUGIN_DATA is required.'
}
$PluginRoot = [System.IO.Path]::GetFullPath($PluginRoot)
$PluginData = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($PluginData))
[System.IO.Directory]::CreateDirectory($PluginData) | Out-Null

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms

if (-not ('SitPet.NativeActivity' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace SitPet {
    public static class NativeActivity {
        [StructLayout(LayoutKind.Sequential)]
        private struct LASTINPUTINFO {
            public uint cbSize;
            public uint dwTime;
        }

        [DllImport("user32.dll")]
        private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint desiredAccess);

        [DllImport("user32.dll")]
        private static extern bool SwitchDesktop(IntPtr desktop);

        [DllImport("user32.dll")]
        private static extern bool CloseDesktop(IntPtr desktop);

        [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
        private static extern int GetWindowLong32(IntPtr window, int index);

        [DllImport("user32.dll", EntryPoint = "SetWindowLong")]
        private static extern int SetWindowLong32(IntPtr window, int index, int value);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
        private static extern IntPtr GetWindowLongPtr64(IntPtr window, int index);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")]
        private static extern IntPtr SetWindowLongPtr64(IntPtr window, int index, IntPtr value);

        public static bool IsPaused { get; private set; }

        static NativeActivity() {
            SystemEvents.SessionSwitch += OnSessionSwitch;
            SystemEvents.PowerModeChanged += OnPowerModeChanged;
        }

        private static void OnSessionSwitch(object sender, SessionSwitchEventArgs e) {
            if (e.Reason == SessionSwitchReason.SessionLock ||
                e.Reason == SessionSwitchReason.RemoteDisconnect ||
                e.Reason == SessionSwitchReason.ConsoleDisconnect) {
                IsPaused = true;
            } else if (e.Reason == SessionSwitchReason.SessionUnlock ||
                       e.Reason == SessionSwitchReason.RemoteConnect ||
                       e.Reason == SessionSwitchReason.ConsoleConnect) {
                IsPaused = false;
            }
        }

        private static void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e) {
            if (e.Mode == PowerModes.Suspend) IsPaused = true;
            if (e.Mode == PowerModes.Resume) IsPaused = false;
        }

        public static double GetIdleSeconds() {
            LASTINPUTINFO info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(info);
            if (!GetLastInputInfo(ref info)) return 0;
            uint elapsed = unchecked((uint)Environment.TickCount - info.dwTime);
            return elapsed / 1000.0;
        }

        public static bool IsWorkstationLocked() {
            const uint DESKTOP_SWITCHDESKTOP = 0x0100;
            IntPtr desktop = OpenInputDesktop(0, false, DESKTOP_SWITCHDESKTOP);
            if (desktop == IntPtr.Zero) return true;
            try { return !SwitchDesktop(desktop); }
            finally { CloseDesktop(desktop); }
        }

        public static void MakeClickThrough(IntPtr window) {
            const int GWL_EXSTYLE = -20;
            const long WS_EX_TRANSPARENT = 0x20L;
            const long WS_EX_NOACTIVATE = 0x08000000L;
            long style = IntPtr.Size == 8 ? GetWindowLongPtr64(window, GWL_EXSTYLE).ToInt64() : GetWindowLong32(window, GWL_EXSTYLE);
            long updated = style | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE;
            if (IntPtr.Size == 8) SetWindowLongPtr64(window, GWL_EXSTYLE, new IntPtr(updated));
            else SetWindowLong32(window, GWL_EXSTYLE, (int)updated);
        }
    }
}
'@
}

. (Join-Path $PluginRoot 'scripts\health-core.ps1')

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-Log {
    param([string]$Message)
    try {
        $logRoot = Join-Path $PluginData 'logs'
        [System.IO.Directory]::CreateDirectory($logRoot) | Out-Null
        $line = "[$([DateTime]::UtcNow.ToString('o'))] $Message$([Environment]::NewLine)"
        [System.IO.File]::AppendAllText((Join-Path $logRoot 'runtime.log'), $line, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

function Merge-Config {
    param([psobject]$Base, [psobject]$Override)
    if ($null -eq $Override) { return $Base }
    foreach ($property in $Override.PSObject.Properties) {
        if ($null -ne $Base.PSObject.Properties[$property.Name]) {
            $Base.($property.Name) = $property.Value
        }
    }
    return $Base
}

function Import-Bitmap {
    param([string]$Path)
    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.UriSource = New-Object System.Uri($Path)
    $bitmap.EndInit()
    $bitmap.Freeze()
    return $bitmap
}

function Get-CroppedFrame {
    param([System.Windows.Media.Imaging.BitmapSource]$Atlas, [int]$Frame)
    $frameIndex = [math]::Max(0, [math]::Min(7, $Frame))
    $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap($Atlas, (New-Object System.Windows.Int32Rect(($frameIndex * 192), 0, 192, 208)))
    $crop.Freeze()
    return $crop
}

function Test-CodexDesktopRunning {
    try {
        foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
            if ($process.ProcessName -in @('codex', 'codex-code-mode-host')) { return $true }
            if ($process.ProcessName -eq 'ChatGPT') {
                try {
                    if ($process.Path -match 'OpenAI\.Codex') { return $true }
                }
                catch { return $true }
            }
        }
    }
    catch { return $true }
    return $false
}

$mutexHashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($PluginData.ToLowerInvariant()))
$mutexHash = ([BitConverter]::ToString($mutexHashBytes)).Replace('-', '').Substring(0, 20)
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\SitPetHealth-$mutexHash", [ref]$createdNew)
if (-not $createdNew) { exit 0 }

$statePath = Join-Path $PluginData 'health-state.json'
$configPath = Join-Path $PluginData 'config.json'
$currentPetPath = Join-Path $PluginData 'current-pet.json'
$eventsRoot = Join-Path $PluginData 'events'
$pausePath = Join-Path $PluginData 'pause.flag'
$pauseStatePath = Join-Path $PluginData 'pause.json'
$restartRequestPath = Join-Path $PluginData 'restart.request.json'
[System.IO.Directory]::CreateDirectory($eventsRoot) | Out-Null
$restartRequested = $false

function Get-PauseUntilUtc {
    if (Test-Path -LiteralPath $pausePath -PathType Leaf) { return [DateTime]::MaxValue }
    if (-not (Test-Path -LiteralPath $pauseStatePath -PathType Leaf)) { return $null }
    try {
        $record = Get-Content -LiteralPath $pauseStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $until = [DateTime]::Parse([string]$record.untilUtc).ToUniversalTime()
        if ($until -gt [DateTime]::UtcNow) { return $until }
    } catch { }
    Remove-Item -LiteralPath $pauseStatePath -Force -ErrorAction SilentlyContinue
    return $null
}

function Test-SitPetPaused { return $null -ne (Get-PauseUntilUtc) }

function Set-SitPetPause {
    param([DateTime]$UntilUtc)
    Remove-Item -LiteralPath $pausePath -Force -ErrorAction SilentlyContinue
    Write-JsonAtomic -Path $pauseStatePath -Value ([ordered]@{ version = 1; untilUtc = $UntilUtc.ToUniversalTime().ToString('o') })
}

function Clear-SitPetPause {
    Remove-Item -LiteralPath $pausePath, $pauseStatePath -Force -ErrorAction SilentlyContinue
}

function Test-QuietHours {
    if (-not [bool]$config.quietHoursEnabled) { return $false }
    try {
        $now = [DateTime]::Now.TimeOfDay
        $start = [TimeSpan]::ParseExact([string]$config.quietHoursStart, 'hh\:mm', $null)
        $end = [TimeSpan]::ParseExact([string]$config.quietHoursEnd, 'hh\:mm', $null)
        if ($start -eq $end) { return $true }
        if ($start -lt $end) { return $now -ge $start -and $now -lt $end }
        return $now -ge $start -or $now -lt $end
    } catch { return $false }
}

try {
    if (-not (Test-Path -LiteralPath $currentPetPath -PathType Leaf)) {
        throw 'No prepared pet clone was found.'
    }
    $currentPet = Get-Content -LiteralPath $currentPetPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $cloneDirectory = [System.IO.Path]::GetFullPath([string]$currentPet.cloneDirectory)
    $profilePath = Join-Path $cloneDirectory 'health-profile.json'
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { throw 'health-profile.json is missing.' }
    $profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $config = Get-Content -LiteralPath (Join-Path $PluginRoot 'assets\default-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try { $config = Merge-Config -Base $config -Override (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { Write-Log "Ignored malformed config.json: $($_.Exception.Message)" }
    }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { Write-JsonAtomic -Path $configPath -Value $config }

    $dialogues = Get-Content -LiteralPath (Join-Path $PluginRoot 'assets\dialogues.zh-CN.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $state = New-SitPetState
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $savedState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($property in $savedState.PSObject.Properties) {
                if ($null -ne $state.PSObject.Properties[$property.Name]) { $state.($property.Name) = $property.Value }
            }
        }
        catch { Write-Log "Ignored malformed health-state.json: $($_.Exception.Message)" }
    }
    $state.version = 2
    if ($InitialSedentarySeconds -ge 0) {
        $state.sedentarySeconds = $InitialSedentarySeconds
        $state.level = Get-SitPetLevel -SedentarySeconds $InitialSedentarySeconds -Config $config
        $state.vitality = Get-SitPetVitality -SedentarySeconds $InitialSedentarySeconds -Config $config
    }

    $atlasByName = @{}
    function Register-AtlasEntry {
        param([psobject]$Entry, [string]$Name)
        $path = Join-Path $cloneDirectory ([string]$Entry.file -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing atlas: $path" }
        $atlasByName[$Name] = [pscustomobject]@{
            Path = $path
            Bitmap = $null
            FrameCache = @{}
            Frames = [int]$Entry.frames
            DurationMs = [double]$Entry.durationMs
            LastUsedUtc = [DateTime]::MinValue
        }
    }
    function Get-AtlasEntry {
        param([string]$Name)
        if (-not $atlasByName.ContainsKey($Name)) { return $null }
        $entry = $atlasByName[$Name]
        if ($null -eq $entry.Bitmap) {
            $entry.Bitmap = Import-Bitmap -Path $entry.Path
            $entry.FrameCache = @{}
        }
        $entry.LastUsedUtc = [DateTime]::UtcNow
        $loaded = @($atlasByName.GetEnumerator() | Where-Object { $null -ne $_.Value.Bitmap } | Sort-Object { $_.Value.LastUsedUtc })
        while ($loaded.Count -gt 2) {
            $oldest = $loaded[0]
            if ([string]$oldest.Key -ne $Name) {
                $oldest.Value.Bitmap = $null
                $oldest.Value.FrameCache = @{}
            }
            $loaded = @($atlasByName.GetEnumerator() | Where-Object { $null -ne $_.Value.Bitmap } | Sort-Object { $_.Value.LastUsedUtc })
        }
        return $entry
    }
    function Get-AtlasFrame {
        param([psobject]$Entry, [int]$Frame)
        $frameIndex = [math]::Max(0, [math]::Min(7, $Frame))
        if (-not $Entry.FrameCache.ContainsKey($frameIndex)) {
            $Entry.FrameCache[$frameIndex] = Get-CroppedFrame -Atlas $Entry.Bitmap -Frame $frameIndex
        }
        return $Entry.FrameCache[$frameIndex]
    }
    for ($level = 0; $level -le 4; $level++) { Register-AtlasEntry -Entry $profile.stages.([string]$level) -Name "stage-$level" }
    Register-AtlasEntry -Entry $profile.celebrate -Name 'celebrate'
    Register-AtlasEntry -Entry $profile.held -Name 'held'

    $window = New-Object System.Windows.Window
    $window.Title = 'RousePet'
    $window.WindowStyle = [System.Windows.WindowStyle]::None
    $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $window.AllowsTransparency = $true
    $window.Background = [System.Windows.Media.Brushes]::Transparent
    $window.Topmost = $true
    $window.ShowInTaskbar = $false
    $window.SizeToContent = [System.Windows.SizeToContent]::Manual
    $window.SnapsToDevicePixels = $true

    $grid = New-Object System.Windows.Controls.Grid
    $window.Content = $grid

    $petImage = New-Object System.Windows.Controls.Image
    $petImage.Stretch = [System.Windows.Media.Stretch]::Fill
    $petImage.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $petImage.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
    $petImage.Cursor = [System.Windows.Input.Cursors]::Hand
    [System.Windows.Automation.AutomationProperties]::SetName($petImage, "$($currentPet.displayName) 桌宠")
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($petImage, [System.Windows.Media.BitmapScalingMode]::NearestNeighbor)
    $grid.Children.Add($petImage) | Out-Null

    $resizeHandle = New-Object System.Windows.Controls.Primitives.Thumb
    $resizeHandle.Width = 28
    $resizeHandle.Height = 28
    $resizeHandle.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $resizeHandle.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
    $resizeHandle.Margin = New-Object System.Windows.Thickness(0)
    $resizeHandle.Cursor = [System.Windows.Input.Cursors]::SizeNWSE
    $resizeHandle.Background = [System.Windows.Media.Brushes]::Transparent
    $resizeHandle.Opacity = 1
    $resizeHandle.Template = [System.Windows.Markup.XamlReader]::Parse(@'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                 TargetType="{x:Type Thumb}">
  <Border Background="#01000000"/>
</ControlTemplate>
'@)
    [System.Windows.Automation.AutomationProperties]::SetName($resizeHandle, 'Resize pet')
    [System.Windows.Controls.Panel]::SetZIndex($resizeHandle, 22)
    $grid.Children.Add($resizeHandle) | Out-Null

    $resizeGlyph = New-Object System.Windows.Controls.Canvas
    $resizeGlyph.Width = 28
    $resizeGlyph.Height = 28
    $resizeGlyph.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $resizeGlyph.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
    $resizeGlyph.IsHitTestVisible = $false
    $resizeGlyph.Opacity = 0
    foreach ($coordinates in @(@(11, 24, 24, 11), @(18, 24, 24, 18))) {
        $line = New-Object System.Windows.Shapes.Line
        $line.X1 = $coordinates[0]
        $line.Y1 = $coordinates[1]
        $line.X2 = $coordinates[2]
        $line.Y2 = $coordinates[3]
        $line.Stroke = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(205, 91, 82, 76))
        $line.StrokeThickness = 1.35
        $line.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
        $line.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
        $resizeGlyph.Children.Add($line) | Out-Null
    }
    [System.Windows.Controls.Panel]::SetZIndex($resizeGlyph, 21)
    $grid.Children.Add($resizeGlyph) | Out-Null

    $bubbleText = New-Object System.Windows.Controls.TextBlock
    $bubbleText.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(78, 70, 65))
    $bubbleText.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
    $bubbleText.FontSize = 14
    $bubbleText.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $bubbleText.MaxWidth = 286
    $bubbleText.LineHeight = 21

    $bubbleBorder = New-Object System.Windows.Controls.Border
    $bubbleBorder.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(246, 255, 250, 244))
    $bubbleBorder.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(220, 229, 162, 115))
    $bubbleBorder.BorderThickness = New-Object System.Windows.Thickness(1)
    $bubbleBorder.CornerRadius = New-Object System.Windows.CornerRadius(14)
    $bubbleBorder.Padding = New-Object System.Windows.Thickness(14, 10, 14, 10)
    $bubbleBorder.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius = 12; ShadowDepth = 3; Opacity = 0.22; Color = [System.Windows.Media.Color]::FromRgb(73, 62, 55) }
    $bubbleBorder.Child = $bubbleText

    $bubbleTail = New-Object System.Windows.Shapes.Polygon
    $bubbleTail.Width = 18
    $bubbleTail.Height = 9
    $bubbleTail.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $bubbleTail.Fill = $bubbleBorder.Background
    $bubbleTail.Stroke = $bubbleBorder.BorderBrush
    $bubbleTail.StrokeThickness = 1
    $bubbleTail.Margin = New-Object System.Windows.Thickness(0, -1, 0, 0)
    $tailPoints = New-Object System.Windows.Media.PointCollection
    $tailPoints.Add((New-Object System.Windows.Point(0, 0)))
    $tailPoints.Add((New-Object System.Windows.Point(18, 0)))
    $tailPoints.Add((New-Object System.Windows.Point(9, 9)))
    $bubbleTail.Points = $tailPoints

    $bubblePanel = New-Object System.Windows.Controls.StackPanel
    $bubblePanel.Orientation = [System.Windows.Controls.Orientation]::Vertical
    $bubblePanel.Children.Add($bubbleBorder) | Out-Null
    $bubblePanel.Children.Add($bubbleTail) | Out-Null

    $bubbleWindow = New-Object System.Windows.Window
    $bubbleWindow.Title = 'RousePet Message'
    $bubbleWindow.WindowStyle = [System.Windows.WindowStyle]::None
    $bubbleWindow.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $bubbleWindow.AllowsTransparency = $true
    $bubbleWindow.Background = [System.Windows.Media.Brushes]::Transparent
    $bubbleWindow.Topmost = $true
    $bubbleWindow.ShowInTaskbar = $false
    $bubbleWindow.ShowActivated = $false
    $bubbleWindow.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
    $bubbleWindow.IsHitTestVisible = $false
    $bubbleWindow.Content = $bubblePanel
    $bubbleWindow.Add_SourceInitialized({
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($bubbleWindow)
        [SitPet.NativeActivity]::MakeClickThrough($helper.Handle)
    })
    $bubbleVisible = $false

    $bubbleTimer = New-Object System.Windows.Threading.DispatcherTimer
    $bubbleTimer.Interval = [TimeSpan]::FromSeconds(7)
    $bubbleTimer.Add_Tick({
        $bubbleWindow.Hide()
        $script:bubbleVisible = $false
        $bubbleTimer.Stop()
    })

    $scale = [math]::Max(0.30, [math]::Min(2.5, [double]$config.petScale))
    function Update-BubblePosition {
        if (-not $script:bubbleVisible) { return }
        $bubbleWindow.UpdateLayout()
        $bubbleWidth = [math]::Max(1, $bubbleWindow.ActualWidth)
        $bubbleHeight = [math]::Max(1, $bubbleWindow.ActualHeight)
        $gap = 3 + [math]::Min(7, 3 * $script:scale)
        $workArea = [System.Windows.SystemParameters]::WorkArea
        $left = $window.Left + (($window.Width - $bubbleWidth) / 2)
        $left = [math]::Max($workArea.Left + 4, [math]::Min($workArea.Right - $bubbleWidth - 4, $left))
        $top = $window.Top - $bubbleHeight - $gap
        if ($top -lt $workArea.Top + 4) { $top = $workArea.Top + 4 }
        $bubbleWindow.Left = $left
        $bubbleWindow.Top = $top
    }

    function Apply-Scale {
        param([double]$NewScale, [bool]$Persist)
        $script:scale = [math]::Max(0.30, [math]::Min(2.5, $NewScale))
        $petImage.Width = 192 * $script:scale
        $petImage.Height = 208 * $script:scale
        $window.Width = (192 * $script:scale) + 16
        $window.Height = (208 * $script:scale) + 16
        $compactRatio = [math]::Max(0.58, [math]::Min(1.0, $script:scale))
        $bubbleText.MaxWidth = [math]::Round(205 + (81 * $compactRatio))
        $bubbleText.FontSize = [math]::Round(11.5 + (2.5 * $compactRatio), 1)
        $bubbleText.LineHeight = [math]::Round(17 + (4 * $compactRatio), 1)
        $handleSize = [math]::Round([math]::Max(14, [math]::Min(28, 22 * $script:scale)))
        $resizeHandle.Width = $handleSize
        $resizeHandle.Height = $handleSize
        $resizeGlyph.Width = [math]::Max(12, $handleSize - 4)
        $resizeGlyph.Height = [math]::Max(12, $handleSize - 4)
        Update-BubblePosition
        if ($Persist) {
            $config.petScale = [math]::Round($script:scale, 3)
            Write-JsonAtomic -Path $configPath -Value $config
        }
    }

    function Move-ToDefaultPosition {
        $workArea = [System.Windows.SystemParameters]::WorkArea
        $window.Left = $workArea.Right - $window.Width - 22
        $window.Top = $workArea.Bottom - $window.Height - 22
    }

    function Clamp-WindowToWorkArea {
        $workArea = [System.Windows.SystemParameters]::WorkArea
        $margin = 6
        $window.Left = [math]::Max($workArea.Left + $margin, [math]::Min($workArea.Right - $window.Width - $margin, $window.Left))
        $window.Top = [math]::Max($workArea.Top + $margin, [math]::Min($workArea.Bottom - $window.Height - $margin, $window.Top))
    }

    Apply-Scale -NewScale $scale -Persist $false
    if ($null -ne $config.windowX -and $null -ne $config.windowY) {
        $window.Left = [double]$config.windowX
        $window.Top = [double]$config.windowY
    }
    else { Move-ToDefaultPosition }
    Clamp-WindowToWorkArea

    $currentAtlasName = "stage-$([int]$state.level)"
    $frameIndex = 0
    $animationStarted = [DateTime]::UtcNow
    $temporaryAtlasUntil = [DateTime]::MinValue

    function Set-Atlas {
        param([string]$Name, [double]$ForMilliseconds = 0)
        if (-not $atlasByName.ContainsKey($Name)) { return }
        $null = Get-AtlasEntry -Name $Name
        if ($script:currentAtlasName -ne $Name) {
            $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0.45, 1.0, [TimeSpan]::FromMilliseconds(260))
            $petImage.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
        }
        $script:currentAtlasName = $Name
        $script:frameIndex = 0
        $script:animationStarted = [DateTime]::UtcNow
        if ($ForMilliseconds -gt 0) { $script:temporaryAtlasUntil = [DateTime]::UtcNow.AddMilliseconds($ForMilliseconds) }
        else { $script:temporaryAtlasUntil = [DateTime]::MinValue }
    }

    function Show-Bubble {
        param([string]$Text, [int]$Seconds = 7)
        if ([string]::IsNullOrWhiteSpace($Text)) { return }
        $bubbleText.Text = $Text
        $bubbleTimer.Stop()
        $bubbleTimer.Interval = [TimeSpan]::FromSeconds([math]::Max(3, $Seconds))
        if (-not $script:bubbleVisible) {
            if ($null -eq $bubbleWindow.Owner) { $bubbleWindow.Owner = $window }
            $script:bubbleVisible = $true
            $bubbleWindow.Opacity = 0
            $bubbleWindow.Show()
        }
        $bubbleWindow.UpdateLayout()
        Update-BubblePosition
        $bubbleTimer.Start()
        $enter = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [TimeSpan]::FromMilliseconds(180))
        $bubbleWindow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $enter)
    }

    $window.Add_LocationChanged({ Update-BubblePosition })
    $window.Add_SizeChanged({ Update-BubblePosition })

    $lastDialogueIndexByKey = @{}
    function Format-Dialogue {
        param([string]$Key)
        $tone = [string]$config.dialogueTone
        $toneValues = $null
        if ($null -ne $dialogues.PSObject.Properties['tones'] -and $null -ne $dialogues.tones.PSObject.Properties[$tone] -and $null -ne $dialogues.tones.$tone.PSObject.Properties[$Key]) {
            $toneValues = $dialogues.tones.$tone.$Key
        }
        $values = if ($null -ne $toneValues) { @($toneValues) } else { @($dialogues.$Key) }
        if ($values.Count -eq 0) { return '' }
        $identity = if ($null -ne $currentPet.PSObject.Properties['sourceSpriteSha256']) { [string]$currentPet.sourceSpriteSha256 } else { [string]$currentPet.cloneId }
        $seedText = "$identity|$tone|$Key|$([int]$state.level)|$([int]$state.fullBreaks)|$([int]$state.listenedBreaks)|$([DateTime]::UtcNow.Ticks)"
        $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seedText))
        $index = [int]$hash[0] % $values.Count
        if ($values.Count -gt 1 -and $lastDialogueIndexByKey.ContainsKey($Key) -and [int]$lastDialogueIndexByKey[$Key] -eq $index) { $index = ($index + 1) % $values.Count }
        $lastDialogueIndexByKey[$Key] = $index
        $breakMinutes = [math]::Max(1, [math]::Round([double]$state.lastBreakDurationSeconds / 60))
        return ([string]$values[$index]).Replace('{pet}', [string]$currentPet.displayName).
            Replace('{minutes}', [string][math]::Floor([double]$state.sedentarySeconds / 60)).
            Replace('{breakMinutes}', [string]$breakMinutes).
            Replace('{breaks}', [string][int]$state.fullBreaks).
            Replace('{listened}', [string][int]$state.listenedBreaks).
            Replace('{streak}', [string][int]$state.listenedStreak)
    }

    function Get-LevelName {
        $keys = @('healthy', 'lazy', 'wilted', 'sick', 'strike')
        return [string]$dialogues.ui.($keys[[int]$state.level])
    }

    function Can-Remind {
        param([ValidateSet('health', 'codex')][string]$Kind)
        return Test-SitPetCanRemind -State $state -Kind $Kind -Config $config
    }

    function Record-Reminder {
        param([ValidateSet('health', 'codex')][string]$Kind)
        Add-SitPetReminder -State $state -Kind $Kind
    }

    function Show-Reminder {
        param(
            [string]$Key,
            [int]$Seconds = 7,
            [ValidateSet('health', 'codex')][string]$Kind = 'health'
        )
        if ((Test-SitPetPaused) -or (Test-QuietHours) -or -not (Can-Remind -Kind $Kind)) { return $false }
        Show-Bubble -Text (Format-Dialogue -Key $Key) -Seconds $Seconds
        Record-Reminder -Kind $Kind
        return $true
    }

    function Save-State {
        $state.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Write-JsonAtomic -Path $statePath -Value $state
        try {
            $config.windowX = [math]::Round($window.Left, 1)
            $config.windowY = [math]::Round($window.Top, 1)
            Write-JsonAtomic -Path $configPath -Value $config
        }
        catch { }
    }

    $menuXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="258" Background="Transparent">
  <Border Margin="6" Padding="12,11,12,10" CornerRadius="8" Background="#FCFAF7"
          BorderBrush="#E8DDD3" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect Color="#4A372B" BlurRadius="18" ShadowDepth="4" Opacity="0.20"/>
    </Border.Effect>
    <Border.Resources>
      <Style TargetType="Button">
        <Setter Property="Height" Value="32"/>
        <Setter Property="Margin" Value="0"/>
        <Setter Property="Padding" Value="8,0"/>
        <Setter Property="Foreground" Value="#514943"/>
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="BorderThickness" Value="0"/>
        <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
        <Setter Property="FontSize" Value="11.5"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="Button">
              <Border x:Name="Chrome" Background="{TemplateBinding Background}" CornerRadius="6">
                <Grid Margin="8,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="24"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                   <TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="14"
                             Foreground="{TemplateBinding Foreground}" VerticalAlignment="Center"/>
                  <ContentPresenter Grid.Column="1" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                </Grid>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Chrome" Property="Background" Value="#F5EDE6"/></Trigger>
                <Trigger Property="IsPressed" Value="True"><Setter TargetName="Chrome" Property="Background" Value="#F2D9D4"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
    </Border.Resources>
    <StackPanel>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Border x:Name="StatusDot" Width="8" Height="8" Margin="0,3,8,0" CornerRadius="4" Background="#77B69E" VerticalAlignment="Top"/>
        <StackPanel Grid.Column="1">
          <TextBlock x:Name="MenuTitle" FontFamily="Microsoft YaHei UI" FontSize="13" FontWeight="SemiBold"
                     Foreground="#443D38" TextTrimming="CharacterEllipsis" MaxWidth="142"/>
          <TextBlock x:Name="MenuSubtitle" Margin="0,2,0,0" FontFamily="Microsoft YaHei UI" FontSize="9.5" Foreground="#968A81"/>
        </StackPanel>
        <TextBlock x:Name="VitalityText" Grid.Column="2" FontFamily="Microsoft YaHei UI" FontSize="10"
                   FontWeight="SemiBold" Foreground="#6B625C" VerticalAlignment="Top"/>
      </Grid>
      <Border Margin="0,8,0,0" Height="5" CornerRadius="3" Background="#EDE7E1">
        <Border x:Name="VitalityFill" Width="222" HorizontalAlignment="Left" CornerRadius="3" Background="#77B69E"/>
      </Border>
      <TextBlock x:Name="StatsText" Margin="0,8,0,8" FontFamily="Microsoft YaHei UI" FontSize="9.5" Foreground="#897D75"/>
      <Border Height="1" Margin="0,0,0,4" Background="#E9E0D8"/>
      <Button x:Name="PauseButton" Tag="&#xE769;"/>
      <Button x:Name="PauseTodayButton" Tag="&#xE787;"/>
      <Button x:Name="SettingsButton" Tag="&#xE713;"/>
      <Button x:Name="ShareButton" Tag="&#xE72D;"/>
      <Button x:Name="ResetPositionButton" Tag="&#xE707;"/>
      <Button x:Name="ResetScaleButton" Tag="&#xE73F;"/>
      <Border Height="1" Margin="0,4" Background="#E9E0D8"/>
      <Button x:Name="ExitButton" Tag="&#xE8BB;" Foreground="#A95F58"/>
    </StackPanel>
  </Border>
</Grid>
'@
    $menuCard = [System.Windows.Markup.XamlReader]::Parse($menuXaml)
    $menuWindow = New-Object System.Windows.Window
    $menuWindow.Title = 'RousePet Menu'
    $menuWindow.WindowStyle = [System.Windows.WindowStyle]::None
    $menuWindow.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $menuWindow.AllowsTransparency = $true
    $menuWindow.Background = [System.Windows.Media.Brushes]::Transparent
    $menuWindow.Topmost = $true
    $menuWindow.ShowInTaskbar = $false
    $menuWindow.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
    $menuWindow.Content = $menuCard
    $menuVisible = $false
    $menuTimer = New-Object System.Windows.Threading.DispatcherTimer
    $menuTimer.Interval = [TimeSpan]::FromSeconds(8)

    $menuTitle = $menuCard.FindName('MenuTitle')
    $menuSubtitle = $menuCard.FindName('MenuSubtitle')
    $statusDot = $menuCard.FindName('StatusDot')
    $vitalityText = $menuCard.FindName('VitalityText')
    $vitalityFill = $menuCard.FindName('VitalityFill')
    $statsText = $menuCard.FindName('StatsText')
    $pauseButton = $menuCard.FindName('PauseButton')
    $pauseTodayButton = $menuCard.FindName('PauseTodayButton')
    $settingsButton = $menuCard.FindName('SettingsButton')
    $shareButton = $menuCard.FindName('ShareButton')
    $resetPositionButton = $menuCard.FindName('ResetPositionButton')
    $resetScaleButton = $menuCard.FindName('ResetScaleButton')
    $exitButton = $menuCard.FindName('ExitButton')

    $resetPositionButton.Content = [string]$dialogues.ui.resetPosition
    $resetScaleButton.Content = [string]$dialogues.ui.resetScale
    $exitButton.Content = [string]$dialogues.ui.exit
    $pauseTodayButton.Content = [string]$dialogues.ui.pauseToday
    $settingsButton.Content = [string]$dialogues.ui.settings
    $shareButton.Content = [string]$dialogues.ui.shareCard

    function Get-LevelBrush {
        $colors = @('#77B69E', '#E5AD58', '#7FA8B8', '#D9897E', '#929793')
        return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($colors[[int]$state.level]))
    }

    function Update-StatusMenu {
        $menuTitle.Text = "$($currentPet.displayName)  $([char]0x00B7)  $(Get-LevelName)"
        $minutes = [math]::Floor([double]$state.sedentarySeconds / 60)
        $menuSubtitle.Text = if ($minutes -lt 1) {
            [string]$dialogues.ui.menuJustStarted
        }
        else {
            ([string]$dialogues.ui.menuSeatedFormat).Replace('{minutes}', [string]$minutes)
        }
        $vitalityText.Text = ([string]$dialogues.ui.menuVitalityFormat).Replace('{vitality}', [string][math]::Round([double]$state.vitality))
        $vitalityFill.Width = 222 * ([math]::Max(0, [math]::Min(100, [double]$state.vitality)) / 100)
        $brush = Get-LevelBrush
        $vitalityFill.Background = $brush
        $statusDot.Background = $brush
        $statsText.Text = "久坐 $minutes 分  $([char]0x00B7)  离开 $([int]$state.fullBreaks)  $([char]0x00B7)  听劝 $([int]$state.listenedBreaks)"
        $isPaused = Test-SitPetPaused
        $pauseButton.Content = if ($isPaused) { [string]$dialogues.ui.resume } else { [string]$dialogues.ui.pause }
        $pauseButton.Tag = if ($isPaused) { [string][char]0xE768 } else { [string][char]0xE769 }
        $pauseTodayButton.Visibility = if ($isPaused) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
    }

    function Update-MenuPosition {
        if (-not $script:menuVisible) { return }
        $menuWindow.UpdateLayout()
        $workArea = [System.Windows.SystemParameters]::WorkArea
        $gap = 9
        $left = $window.Left - $menuWindow.ActualWidth - $gap
        if ($left -lt $workArea.Left + 4) { $left = $window.Left + $window.Width + $gap }
        $left = [math]::Max($workArea.Left + 4, [math]::Min($workArea.Right - $menuWindow.ActualWidth - 4, $left))
        $top = $window.Top + (($window.Height - $menuWindow.ActualHeight) / 2)
        $menuWindow.Left = $left
        $menuWindow.Top = [math]::Max($workArea.Top + 4, [math]::Min($workArea.Bottom - $menuWindow.ActualHeight - 4, $top))
    }

    function Hide-StatusMenu {
        $menuTimer.Stop()
        if ($script:menuVisible) { $menuWindow.Hide() }
        $script:menuVisible = $false
    }

    function Show-StatusMenu {
        Update-StatusMenu
        $menuTimer.Stop()
        if (-not $script:menuVisible) {
            if ($null -eq $menuWindow.Owner) { $menuWindow.Owner = $window }
            $script:menuVisible = $true
            $menuWindow.Opacity = 0
            $menuWindow.Show()
        }
        Update-MenuPosition
        $menuWindow.Activate() | Out-Null
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [TimeSpan]::FromMilliseconds(160))
        $menuWindow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
        $menuTimer.Start()
    }

    $menuTimer.Add_Tick({ Hide-StatusMenu })
    $menuWindow.Add_Deactivated({ Hide-StatusMenu })
    $window.Add_LocationChanged({ Update-MenuPosition })
    $window.Add_SizeChanged({ Update-MenuPosition })

    $window.Add_PreviewMouseDown({
        param($sender, $eventArgs)
        if ([bool]$config.debug) {
            Write-Log "Mouse down on $($eventArgs.OriginalSource.GetType().FullName) at $($eventArgs.GetPosition($window))."
        }
    })

    $pauseButton.Add_Click({
        Hide-StatusMenu
        if (Test-SitPetPaused) {
            Clear-SitPetPause
            Show-Bubble -Text ([string]$dialogues.ui.resumed)
        }
        else {
            Set-SitPetPause -UntilUtc ([DateTime]::UtcNow.AddHours(1))
            Show-Bubble -Text ([string]$dialogues.ui.paused)
        }
    })
    $pauseTodayButton.Add_Click({
        Hide-StatusMenu
        Set-SitPetPause -UntilUtc ([DateTime]::Today.AddDays(1).ToUniversalTime())
        Show-Bubble -Text ([string]$dialogues.ui.pausedToday)
    })
    $settingsButton.Add_Click({
        Hide-StatusMenu
        $settingsScript = Join-Path $PluginRoot 'scripts\settings-windows.ps1'
        $arguments = "-NoProfile -STA -File `"$settingsScript`" -PluginRoot `"$PluginRoot`" -PluginData `"$PluginData`""
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    })
    $shareButton.Add_Click({
        Hide-StatusMenu
        Save-State
        Show-Bubble -Text ([string]$dialogues.ui.shareGenerating) -Seconds 5
        $shareScript = Join-Path $PluginRoot 'scripts\share-card-windows.ps1'
        $arguments = "-NoProfile -STA -File `"$shareScript`" -PluginRoot `"$PluginRoot`" -PluginData `"$PluginData`""
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    })
    $resetPositionButton.Add_Click({ Hide-StatusMenu; Move-ToDefaultPosition; Save-State })
    $resetScaleButton.Add_Click({ Hide-StatusMenu; Apply-Scale -NewScale 1.0 -Persist $true; Clamp-WindowToWorkArea; Save-State })
    $exitButton.Add_Click({ Hide-StatusMenu; $window.Close() })
    $petImage.Add_MouseRightButtonUp({
        param($sender, $eventArgs)
        if ($script:menuVisible) { Hide-StatusMenu } else { Show-StatusMenu }
        $eventArgs.Handled = $true
    })

    $petImage.Add_MouseLeftButtonDown({
        param($sender, $eventArgs)
        if ($eventArgs.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }
        $beforeLeft = $window.Left
        $beforeTop = $window.Top
        Set-Atlas -Name 'held'
        try { $window.DragMove() } catch { }
        $distance = [math]::Abs($window.Left - $beforeLeft) + [math]::Abs($window.Top - $beforeTop)
        if ($distance -lt 3) {
            Set-Atlas -Name 'celebrate' -ForMilliseconds ([double]$profile.celebrate.durationMs)
            Show-Bubble -Text (Format-Dialogue -Key 'click') -Seconds 4
        }
        else {
            Clamp-WindowToWorkArea
            Set-Atlas -Name "stage-$([int]$state.level)"
            Save-State
        }
        $eventArgs.Handled = $true
    })
    $petImage.Add_MouseWheel({
        param($sender, $eventArgs)
        Apply-Scale -NewScale ($script:scale + (($eventArgs.Delta / 120.0) * 0.08)) -Persist $true
        Clamp-WindowToWorkArea
        Save-State
        $eventArgs.Handled = $true
    })

    $window.Add_MouseEnter({
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation($resizeGlyph.Opacity, 0.78, [TimeSpan]::FromMilliseconds(140))
        $resizeGlyph.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    })
    $window.Add_MouseLeave({
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation($resizeGlyph.Opacity, 0.0, [TimeSpan]::FromMilliseconds(180))
        $resizeGlyph.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    })
    $resizeStartScale = $scale
    $resizeStartCursorX = 0.0
    $resizeStartCursorY = 0.0
    $resizeDpiX = 1.0
    $resizeDpiY = 1.0
    $resizeHandle.Add_DragStarted({
        $script:resizeStartScale = $script:scale
        $cursor = [System.Windows.Forms.Cursor]::Position
        $script:resizeStartCursorX = [double]$cursor.X
        $script:resizeStartCursorY = [double]$cursor.Y
        $source = [System.Windows.PresentationSource]::FromVisual($window)
        if ($null -ne $source -and $null -ne $source.CompositionTarget) {
            $script:resizeDpiX = [math]::Max(0.1, [double]$source.CompositionTarget.TransformToDevice.M11)
            $script:resizeDpiY = [math]::Max(0.1, [double]$source.CompositionTarget.TransformToDevice.M22)
        }
        Write-Log "Resize started at scale $script:resizeStartScale."
    })
    $resizeHandle.Add_DragDelta({
        param($sender, $eventArgs)
        $cursor = [System.Windows.Forms.Cursor]::Position
        $horizontalScaleDelta = (([double]$cursor.X - $script:resizeStartCursorX) / $script:resizeDpiX) / 192.0
        $verticalScaleDelta = (([double]$cursor.Y - $script:resizeStartCursorY) / $script:resizeDpiY) / 208.0
        $scaleDelta = if ([math]::Abs($horizontalScaleDelta) -ge [math]::Abs($verticalScaleDelta)) {
            $horizontalScaleDelta
        }
        else {
            $verticalScaleDelta
        }
        Apply-Scale -NewScale ($script:resizeStartScale + $scaleDelta) -Persist $false
        Clamp-WindowToWorkArea
        $eventArgs.Handled = $true
    })
    $resizeHandle.Add_DragCompleted({
        Clamp-WindowToWorkArea
        Apply-Scale -NewScale $script:scale -Persist $true
        Save-State
        Write-Log "Resize completed at scale $script:scale."
    })

    $animationTimer = New-Object System.Windows.Threading.DispatcherTimer
    $animationTimer.Interval = [TimeSpan]::FromMilliseconds(90)
    $animationTimer.Add_Tick({
        if ($temporaryAtlasUntil -ne [DateTime]::MinValue -and [DateTime]::UtcNow -ge $temporaryAtlasUntil) {
            Set-Atlas -Name "stage-$([int]$state.level)"
        }
        $entry = Get-AtlasEntry -Name $currentAtlasName
        $elapsed = ([DateTime]::UtcNow - $animationStarted).TotalMilliseconds
        $perFrame = [math]::Max(100, $entry.DurationMs / [math]::Max(1, $entry.Frames))
        $nextFrame = [int][math]::Floor($elapsed / $perFrame) % [math]::Max(1, $entry.Frames)
        if ($nextFrame -ne $frameIndex -or $null -eq $petImage.Source) {
            $script:frameIndex = $nextFrame
            $petImage.Source = Get-AtlasFrame -Entry $entry -Frame $nextFrame
        }
    })

    function Process-HookEvent {
        param([psobject]$Event)
        $eventName = [string]$Event.eventName
        $sessionHash = if ($null -ne $Event.PSObject.Properties['sessionHash']) { [string]$Event.sessionHash } else { '' }
        $transition = Update-SitPetCodexSessions -State $state -EventName $eventName -SessionHash $sessionHash -StaleSeconds ([double]$config.codexSessionStaleSeconds)
        if ($eventName -in @('UserPromptSubmit', 'PermissionRequest')) {
            if ($transition.BecameRunning -and [double]$state.sedentarySeconds -ge [double]$config.codexOpportunitySeconds -and $script:lastIdleSeconds -lt [double]$config.activeIdleCutoffSeconds) {
                $key = if ([int]$state.listenedStreak -gt 0) { 'taskStartListened' } elseif ([int]$state.ignoredOpportunities -gt 1) { 'taskStartIgnored' } else { 'taskStartFirst' }
                if (Show-Reminder -Key $key -Seconds 9 -Kind 'codex') {
                    $state.opportunityUntilUtc = [DateTime]::UtcNow.AddSeconds([double]$config.codexOpportunityWindowSeconds).ToString('o')
                    $state.opportunityPrompted = $true
                }
            }
        }
        elseif ($eventName -eq 'Stop' -and $transition.BecameIdle) {
            if ([bool]$state.opportunityPrompted) {
                $opportunityValid = $false
                try { $opportunityValid = [DateTime]::Parse([string]$state.opportunityUntilUtc).ToUniversalTime() -gt [DateTime]::UtcNow }
                catch { }
                if ($opportunityValid) {
                    $state.ignoredOpportunities = [int]$state.ignoredOpportunities + 1
                    $state.listenedStreak = 0
                    [void](Show-Reminder -Key 'taskDone' -Seconds 9 -Kind 'codex')
                }
                $state.opportunityPrompted = $false
                $state.opportunityUntilUtc = $null
            }
        }
    }

    $lastTick = [DateTime]::UtcNow
    $lastSave = [DateTime]::UtcNow
    $lastCodexSeen = [DateTime]::UtcNow
    $lastCodexCheck = [DateTime]::MinValue
    function Get-CurrentIdleSeconds {
        if ($TestMode -and -not [string]::IsNullOrWhiteSpace($SimulatedIdleFile) -and (Test-Path -LiteralPath $SimulatedIdleFile -PathType Leaf)) {
            try { return [double]([System.IO.File]::ReadAllText($SimulatedIdleFile).Trim()) } catch { }
        }
        if ($SimulatedIdleSeconds -ge 0) { return $SimulatedIdleSeconds }
        return [SitPet.NativeActivity]::GetIdleSeconds()
    }

    $lastIdleSeconds = Get-CurrentIdleSeconds
    $startedAt = [DateTime]::UtcNow
    $healthTimer = New-Object System.Windows.Threading.DispatcherTimer
    $healthTimer.Interval = [TimeSpan]::FromMilliseconds([math]::Max(250, [int]$config.pollMilliseconds))
    $healthTimer.Add_Tick({
        try {
            $now = [DateTime]::UtcNow
            $realDelta = ($now - $lastTick).TotalSeconds
            $delta = [math]::Min(30, $realDelta) * [math]::Max(0.1, $TimeScale)
            $script:lastTick = $now
            $script:lastIdleSeconds = Get-CurrentIdleSeconds
            $paused = [SitPet.NativeActivity]::IsPaused -or [SitPet.NativeActivity]::IsWorkstationLocked() -or ($realDelta -gt 5) -or (Test-SitPetPaused)

            if (Test-Path -LiteralPath $restartRequestPath -PathType Leaf) {
                Remove-Item -LiteralPath $restartRequestPath -Force -ErrorAction SilentlyContinue
                $script:restartRequested = $true
                $window.Close()
                return
            }

            foreach ($eventFile in @(Get-ChildItem -LiteralPath $eventsRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
                try {
                    $hookEvent = Get-Content -LiteralPath $eventFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    Process-HookEvent -Event $hookEvent
                }
                catch { Write-Log "Ignored event $($eventFile.Name): $($_.Exception.Message)" }
                finally { Remove-Item -LiteralPath $eventFile.FullName -Force -ErrorAction SilentlyContinue }
            }

            $effectiveConfig = $config | Select-Object *
            if ([bool]$state.opportunityPrompted) { $effectiveConfig.partialRecoveryRate = [double]$config.partialRecoveryRate * 2 }
            $step = Step-SitPetHealth -State $state -DeltaSeconds $delta -IdleSeconds $lastIdleSeconds -IsPaused $paused -Config $effectiveConfig
            $script:state = $step.State

            if ($step.FullBreak) {
                $wasOpportunity = [bool]$state.opportunityPrompted
                if ($wasOpportunity) {
                    $state.listenedBreaks = [int]$state.listenedBreaks + 1
                    $state.listenedStreak = [int]$state.listenedStreak + 1
                    $state.opportunityPrompted = $false
                    $state.opportunityUntilUtc = $null
                }
                Set-Atlas -Name 'celebrate' -ForMilliseconds ([double]$profile.celebrate.durationMs * 1.8)
                Show-Bubble -Text (Format-Dialogue -Key $(if ($wasOpportunity) { 'listened' } else { 'recovery' })) -Seconds 8
            }
            elseif ($step.LevelChanged) {
                Set-Atlas -Name "stage-$([int]$state.level)"
                if ([int]$state.level -gt [int]$step.PreviousLevel) {
                    $state.lastLevelReminder = [int]$state.level
                    [void](Show-Reminder -Key "level$([int]$state.level)" -Seconds $(if ([int]$state.level -ge 3) { 9 } else { 7 }) -Kind 'health')
                }
            }

            if (($now - $lastSave).TotalSeconds -ge 15) {
                Save-State
                $script:lastSave = $now
            }

            if (-not $TestMode) {
                if (($now - $lastCodexCheck).TotalSeconds -ge 10) {
                    $script:lastCodexCheck = $now
                    if (Test-CodexDesktopRunning) { $script:lastCodexSeen = $now }
                    elseif (($now - $lastCodexSeen).TotalSeconds -ge 30) { $window.Close(); return }
                }
            }
            if ($AutoExitSeconds -gt 0 -and ($now - $startedAt).TotalSeconds -ge $AutoExitSeconds) { $window.Close() }
        }
        catch { Write-Log "Tick error: $($_.Exception.Message)" }
    })

    $window.Add_Loaded({
        $pidRecord = [ordered]@{ pid = $PID; startedAtUtc = [DateTime]::UtcNow.ToString('o'); pluginData = $PluginData }
        Write-JsonAtomic -Path (Join-Path $PluginData 'runtime.pid') -Value $pidRecord
        Set-Atlas -Name "stage-$([int]$state.level)"
        $animationTimer.Start()
        $healthTimer.Start()
        if (-not (Test-Path -LiteralPath (Join-Path $PluginData 'welcome-shown.flag'))) {
            Show-Bubble -Text (Format-Dialogue -Key 'welcome') -Seconds 8
            [System.IO.File]::WriteAllText((Join-Path $PluginData 'welcome-shown.flag'), [DateTime]::UtcNow.ToString('o'))
        }
        $candidateCount = if ($null -ne $currentPet.PSObject.Properties['candidateCount']) { [int]$currentPet.candidateCount } else { 1 }
        if ($candidateCount -gt 1 -and -not (Test-Path -LiteralPath (Join-Path $PluginData 'picker-completed.flag'))) {
            $settingsScript = Join-Path $PluginRoot 'scripts\settings-windows.ps1'
            $arguments = "-NoProfile -STA -File `"$settingsScript`" -PluginRoot `"$PluginRoot`" -PluginData `"$PluginData`" -FirstRun"
            Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
        }
    })
    $window.Add_Closed({
        $animationTimer.Stop()
        $healthTimer.Stop()
        $bubbleTimer.Stop()
        $menuTimer.Stop()
        $script:menuVisible = $false
        try { $menuWindow.Close() } catch { }
        $script:bubbleVisible = $false
        try { $bubbleWindow.Close() } catch { }
        Save-State
        Remove-Item -LiteralPath (Join-Path $PluginData 'runtime.pid') -Force -ErrorAction SilentlyContinue
    })

    Write-Log "Runtime starting for clone $($currentPet.cloneId)."
    $null = $window.ShowDialog()
    Write-Log 'Runtime stopped.'
}
catch {
    Write-Log "Fatal: $($_.Exception.ToString())"
    try { Write-JsonAtomic -Path (Join-Path $PluginData 'last-error.json') -Value ([ordered]@{ occurredAtUtc = [DateTime]::UtcNow.ToString('o'); component = 'runtime'; message = $_.Exception.Message }) } catch { }
    if (-not $TestMode) { try { [void][System.Windows.MessageBox]::Show("RousePet 启动失败。`n`n$($_.Exception.Message)`n`n可从设置里的运行诊断查看详情。", 'RousePet') } catch { } }
    throw
}
finally {
    if ($createdNew) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    $mutex.Dispose()
}

if ($restartRequested) {
    $runtimeScript = Join-Path $PluginRoot 'scripts\runtime-windows.ps1'
    $arguments = "-NoProfile -STA -File `"$runtimeScript`" -PluginRoot `"$PluginRoot`" -PluginData `"$PluginData`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}
