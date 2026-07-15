param(
    [string]$PluginRoot = $env:CLAUDE_PLUGIN_ROOT,
    [string]$PluginData = $env:CLAUDE_PLUGIN_DATA,
    [string]$OutputPath,
    [switch]$NoReveal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PluginRoot)) { $PluginRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if ([string]::IsNullOrWhiteSpace($PluginData)) { throw 'PluginData is required.' }
$PluginRoot = [System.IO.Path]::GetFullPath($PluginRoot)
$PluginData = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($PluginData))

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

function Read-JsonRequired {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing file: $Path" }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function New-Brush {
    param([string]$Color)
    return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($Color))
}

function New-Text {
    param([string]$Text, [double]$Size, [string]$Color = '#4C433D', [string]$Weight = 'Normal')
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
    $block.FontSize = $Size
    $block.Foreground = New-Brush $Color
    $block.FontWeight = if ($Weight -eq 'SemiBold') { [System.Windows.FontWeights]::SemiBold } else { [System.Windows.FontWeights]::Normal }
    return $block
}

function Add-Stat {
    param([System.Windows.Controls.Panel]$Parent, [string]$Value, [string]$Label, [string]$Accent)
    $card = New-Object System.Windows.Controls.Border
    $card.Width = 282; $card.Height = 150; $card.Margin = New-Object System.Windows.Thickness(9)
    $card.CornerRadius = New-Object System.Windows.CornerRadius(22)
    $card.Background = New-Brush '#FFFDF9'; $card.BorderBrush = New-Brush '#EADFD5'; $card.BorderThickness = New-Object System.Windows.Thickness(2)
    $stack = New-Object System.Windows.Controls.StackPanel; $stack.Margin = New-Object System.Windows.Thickness(25,20,25,18)
    $valueText = New-Text -Text $Value -Size 42 -Color $Accent -Weight SemiBold
    $labelText = New-Text -Text $Label -Size 20 -Color '#8D8178'; $labelText.Margin = New-Object System.Windows.Thickness(0,7,0,0)
    [void]$stack.Children.Add($valueText); [void]$stack.Children.Add($labelText); $card.Child = $stack; [void]$Parent.Children.Add($card)
}

$current = Read-JsonRequired (Join-Path $PluginData 'current-pet.json')
$state = Read-JsonRequired (Join-Path $PluginData 'health-state.json')
$profile = Read-JsonRequired (Join-Path ([string]$current.cloneDirectory) 'health-profile.json')
$stagePath = Join-Path ([string]$current.cloneDirectory) ([string]$profile.stages.([string][int]$state.level).file -replace '/', '\')

$bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
$bitmap.BeginInit(); $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $bitmap.UriSource = New-Object System.Uri($stagePath); $bitmap.EndInit(); $bitmap.Freeze()
$petFrame = New-Object System.Windows.Media.Imaging.CroppedBitmap($bitmap, (New-Object System.Windows.Int32Rect(0,0,192,208))); $petFrame.Freeze()

$canvas = New-Object System.Windows.Controls.Canvas
$canvas.Width = 1080; $canvas.Height = 1350; $canvas.Background = New-Brush '#FFF8F0'

$topAccent = New-Object System.Windows.Controls.Border; $topAccent.Width = 1080; $topAccent.Height = 18; $topAccent.Background = New-Brush '#E98779'; [void]$canvas.Children.Add($topAccent)
$brand = New-Text -Text 'CODEX PET HEALTH' -Size 20 -Color '#A06F62' -Weight SemiBold; [System.Windows.Controls.Canvas]::SetLeft($brand,80); [System.Windows.Controls.Canvas]::SetTop($brand,72); [void]$canvas.Children.Add($brand)
$title = New-Text -Text ("{0} 的今日状态" -f [string]$current.displayName) -Size 48 -Color '#443C37' -Weight SemiBold; [System.Windows.Controls.Canvas]::SetLeft($title,78); [System.Windows.Controls.Canvas]::SetTop($title,112); [void]$canvas.Children.Add($title)
$subtitle = New-Text -Text '把 Codex 等待时间，换成一次真正离开电脑。' -Size 23 -Color '#8D8178'; [System.Windows.Controls.Canvas]::SetLeft($subtitle,80); [System.Windows.Controls.Canvas]::SetTop($subtitle,188); [void]$canvas.Children.Add($subtitle)

$petHalo = New-Object System.Windows.Controls.Border; $petHalo.Width=520; $petHalo.Height=560; $petHalo.CornerRadius=New-Object System.Windows.CornerRadius(52); $petHalo.Background=New-Brush '#F3E8DE'; [System.Windows.Controls.Canvas]::SetLeft($petHalo,280); [System.Windows.Controls.Canvas]::SetTop($petHalo,270); [void]$canvas.Children.Add($petHalo)
$petImage = New-Object System.Windows.Controls.Image; $petImage.Source=$petFrame; $petImage.Width=480; $petImage.Height=520; $petImage.Stretch=[System.Windows.Media.Stretch]::Fill; [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($petImage,[System.Windows.Media.BitmapScalingMode]::NearestNeighbor); [System.Windows.Controls.Canvas]::SetLeft($petImage,300); [System.Windows.Controls.Canvas]::SetTop($petImage,288); [void]$canvas.Children.Add($petImage)

$levelNames = @('精神','发懒','蔫了','病恹恹','休息中')
$pill = New-Object System.Windows.Controls.Border; $pill.Padding=New-Object System.Windows.Thickness(22,11,22,11); $pill.CornerRadius=New-Object System.Windows.CornerRadius(24); $pill.Background=New-Brush '#FFFFFF'; $pill.BorderBrush=New-Brush '#E3D6CC'; $pill.BorderThickness=New-Object System.Windows.Thickness(2); $pill.Child=New-Text -Text ("{0} · {1} 元气" -f $levelNames[[int]$state.level],[math]::Round([double]$state.vitality)) -Size 21 -Color '#655A53' -Weight SemiBold; [System.Windows.Controls.Canvas]::SetLeft($pill,410); [System.Windows.Controls.Canvas]::SetTop($pill,795); [void]$canvas.Children.Add($pill)

$stats = New-Object System.Windows.Controls.WrapPanel; $stats.Width=930; $stats.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Center; [System.Windows.Controls.Canvas]::SetLeft($stats,75); [System.Windows.Controls.Canvas]::SetTop($stats,900)
Add-Stat -Parent $stats -Value ([string][int]$state.fullBreaks) -Label '离开电脑' -Accent '#5D9A80'
Add-Stat -Parent $stats -Value ([string][int]$state.listenedBreaks) -Label '听劝空窗' -Accent '#E98779'
Add-Stat -Parent $stats -Value ("{0} min" -f [math]::Floor([double]$state.sedentarySeconds/60)) -Label '本轮连续操作' -Accent '#D29B4C'
[void]$canvas.Children.Add($stats)

$note = New-Text -Text '元气是桌宠互动值，不对应寿命或医疗指标。' -Size 18 -Color '#958980'; [System.Windows.Controls.Canvas]::SetLeft($note,80); [System.Windows.Controls.Canvas]::SetTop($note,1165); [void]$canvas.Children.Add($note)
$privacy = New-Text -Text '官方宠物只读  ·  数据仅保存在本机' -Size 18 -Color '#A06F62' -Weight SemiBold; [System.Windows.Controls.Canvas]::SetLeft($privacy,80); [System.Windows.Controls.Canvas]::SetTop($privacy,1210); [void]$canvas.Children.Add($privacy)
$date = New-Text -Text ([DateTime]::Now.ToString('yyyy.MM.dd')) -Size 18 -Color '#A99D94'; [System.Windows.Controls.Canvas]::SetLeft($date,888); [System.Windows.Controls.Canvas]::SetTop($date,1210); [void]$canvas.Children.Add($date)

$canvas.Measure((New-Object System.Windows.Size(1080,1350))); $canvas.Arrange((New-Object System.Windows.Rect(0,0,1080,1350))); $canvas.UpdateLayout()
$render = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(1080,1350,96,96,[System.Windows.Media.PixelFormats]::Pbgra32); $render.Render($canvas)
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputRoot = Join-Path $PluginData 'share'; [System.IO.Directory]::CreateDirectory($outputRoot) | Out-Null
    $OutputPath = Join-Path $outputRoot ("sit-pet-{0}.png" -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss'))
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath); [System.IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath)) | Out-Null
$encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($render))
$stream=[System.IO.File]::Open($OutputPath,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None); try{$encoder.Save($stream)}finally{$stream.Dispose()}
if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf) -or (Get-Item -LiteralPath $OutputPath).Length -le 0) { throw 'Share card was not created.' }
if (-not $NoReveal -and [Environment]::UserInteractive) { Start-Process explorer.exe -ArgumentList ('/select,"' + $OutputPath + '"') | Out-Null }
[pscustomobject]@{ ok=$true; outputPath=$OutputPath; width=1080; height=1350 } | ConvertTo-Json -Compress
