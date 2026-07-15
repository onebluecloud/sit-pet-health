param(
    [string]$TestRoot = $(if (-not [string]::IsNullOrWhiteSpace($env:SIT_PET_TEST_ROOT)) { Join-Path $env:SIT_PET_TEST_ROOT 'ui-assets' } elseif (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { Join-Path $env:RUNNER_TEMP 'sit-pet-ui-assets' } else { Join-Path ([System.IO.Path]::GetTempPath()) 'sit-pet-tests\ui-assets' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$resolved = [System.IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [System.IO.Path]::GetFullPath($(if (-not [string]::IsNullOrWhiteSpace($env:SIT_PET_TEST_ROOT)) { $env:SIT_PET_TEST_ROOT } elseif (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { Join-Path ([System.IO.Path]::GetTempPath()) 'sit-pet-tests' })).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $resolved.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test root.' }
if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
[System.IO.Directory]::CreateDirectory($resolved) | Out-Null

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

function Assert-True { param([bool]$Value, [string]$Message); if (-not $Value) { throw $Message } }
function Write-Json { param([string]$Path, [object]$Value); [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false))) }
function Write-TransparentPng {
    param([string]$Path)
    $bitmap = New-Object System.Windows.Media.Imaging.WriteableBitmap(1536,1872,96,96,[System.Windows.Media.PixelFormats]::Bgra32,$null)
    $bitmap.WritePixels((New-Object System.Windows.Int32Rect(0,0,1,1)),[byte[]]@(80,160,255,255),4,0)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[System.IO.File]::Open($Path,[System.IO.FileMode]::Create);try{$encoder.Save($stream)}finally{$stream.Dispose()}
}

try {
    $settingsSource = Get-Content -LiteralPath (Join-Path $pluginRoot 'scripts\settings-windows.ps1') -Raw -Encoding UTF8
    $runtimeSource = Get-Content -LiteralPath (Join-Path $pluginRoot 'scripts\runtime-windows.ps1') -Raw -Encoding UTF8
    Assert-True ($settingsSource -match '<Track x:Name="PART_Track" Height="22" Margin="11,0"') 'The size-slider track no longer reserves room for its thumb.'
    Assert-True ($runtimeSource -match 'TemplateBinding Tag\}" FontFamily="Segoe MDL2 Assets"') 'The status menu is not using the Fluent icon font.'
    Assert-True ($runtimeSource -notmatch 'Tag="&#x2316;"|Tag="&#x2197;"|Tag="&#x00D7;"') 'The status menu still contains mixed-font fallback icons.'

    $source = Join-Path $resolved 'custom-sources\ui-pet'
    [System.IO.Directory]::CreateDirectory($source) | Out-Null
    Write-TransparentPng -Path (Join-Path $source 'spritesheet.png')
    Write-Json -Path (Join-Path $source 'pet.json') -Value ([ordered]@{ id='ui-pet'; displayName='UI Pet'; spritesheetPath='spritesheet.png' })
    $result = (& (Join-Path $pluginRoot 'scripts\prepare-pet-windows.ps1') -PluginData $resolved -SourceDirectory $source) | ConvertFrom-Json
    Assert-True ([bool]$result.ok) 'The private UI test pet was not prepared.'
    Write-Json -Path (Join-Path $resolved 'health-state.json') -Value ([ordered]@{
        version=2; vitality=73; level=2; sedentarySeconds=3720; fullBreaks=4; listenedBreaks=2; listenedStreak=1; lastBreakDurationSeconds=300
    })
    $output = Join-Path $resolved 'share-card.png'
    $share = (& (Join-Path $pluginRoot 'scripts\share-card-windows.ps1') -PluginRoot $pluginRoot -PluginData $resolved -OutputPath $output -NoReveal) | ConvertFrom-Json
    Assert-True ([bool]$share.ok) 'Share card generation failed.'
    $image = New-Object System.Windows.Media.Imaging.BitmapImage
    $image.BeginInit(); $image.CacheOption=[System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $image.UriSource=New-Object System.Uri($output); $image.EndInit()
    Assert-True ($image.PixelWidth -eq 1080 -and $image.PixelHeight -eq 1350) 'Share card dimensions are incorrect.'
    & (Join-Path $pluginRoot 'scripts\settings-windows.ps1') -PluginRoot $pluginRoot -PluginData $resolved -CodexHome (Join-Path $resolved 'missing-codex-home') -TestMode -AutoCloseSeconds 1
    Write-Host 'ui-assets-windows: ok'
}
finally {
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
