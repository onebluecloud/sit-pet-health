param(
    [string]$TestRoot = $(if (-not [string]::IsNullOrWhiteSpace($env:SIT_PET_TEST_ROOT)) { Join-Path $env:SIT_PET_TEST_ROOT 'sit-pet-health-lifecycle' } elseif (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { Join-Path $env:RUNNER_TEMP 'sit-pet-health-lifecycle' } else { Join-Path ([System.IO.Path]::GetTempPath()) 'sit-pet-tests\sit-pet-health-lifecycle' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pluginRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$launch = Join-Path $pluginRoot 'scripts\launch-windows.ps1'
$hook = Join-Path $pluginRoot 'scripts\hook-windows.ps1'
$uninstall = Join-Path $pluginRoot 'scripts\uninstall-windows.ps1'
$resolved = [System.IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [System.IO.Path]::GetFullPath($(if (-not [string]::IsNullOrWhiteSpace($env:SIT_PET_TEST_ROOT)) { $env:SIT_PET_TEST_ROOT } elseif (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { Join-Path ([System.IO.Path]::GetTempPath()) 'sit-pet-tests' })).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $resolved.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test root.' }
if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
$fixtureRoot = Join-Path (Split-Path -Parent $resolved) 'sit-pet-lifecycle-codex-home'
if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }

try {
    $rejected = $false
    try { $null = & $uninstall -PluginData (Join-Path (Split-Path -Parent $resolved) 'unsafe') }
    catch { $rejected = $_.Exception.Message -match 'Refusing to remove' }
    if (-not $rejected) { throw 'Unsafe uninstall target was accepted.' }

    $emptyCodexHome = Join-Path (Split-Path -Parent $resolved) 'sit-pet-empty-codex-home'
    $emptyPluginData = Join-Path (Split-Path -Parent $resolved) 'sit-pet-empty-plugin-data'
    [System.IO.Directory]::CreateDirectory($emptyCodexHome) | Out-Null
    [System.IO.Directory]::CreateDirectory($emptyPluginData) | Out-Null
    $previousRoot = $env:CLAUDE_PLUGIN_ROOT; $previousData = $env:CLAUDE_PLUGIN_DATA; $previousCodex = $env:CODEX_HOME; $previousTest = $env:SIT_PET_TEST_MODE
    try {
        $env:CLAUDE_PLUGIN_ROOT = $pluginRoot
        $env:CLAUDE_PLUGIN_DATA = $emptyPluginData
        $env:CODEX_HOME = $emptyCodexHome
        $env:SIT_PET_TEST_MODE = '1'
        $hookResult = ('{"hook_event_name":"SessionStart","session_id":"empty"}' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook) | ConvertFrom-Json
        if ([string]$hookResult.systemMessage -notmatch 'one-sentence pet description or a reference image') { throw 'No-pet hook did not ask Codex to create a private pet.' }
    }
    finally {
        $env:CLAUDE_PLUGIN_ROOT = $previousRoot; $env:CLAUDE_PLUGIN_DATA = $previousData; $env:CODEX_HOME = $previousCodex; $env:SIT_PET_TEST_MODE = $previousTest
        Remove-Item -LiteralPath $emptyCodexHome,$emptyPluginData -Recurse -Force -ErrorAction SilentlyContinue
    }

    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    $codexHome = $fixtureRoot
    $sourceRoot = Join-Path $codexHome 'pets\fixture-pet'
    [System.IO.Directory]::CreateDirectory($sourceRoot) | Out-Null
    $spritePath = Join-Path $sourceRoot 'spritesheet.png'
    $bitmap = New-Object System.Windows.Media.Imaging.WriteableBitmap(1536,1872,96,96,[System.Windows.Media.PixelFormats]::Bgra32,$null)
    $bitmap.WritePixels((New-Object System.Windows.Int32Rect(0,0,1,1)),[byte[]]@(80,160,255,255),4,0)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Open($spritePath,[System.IO.FileMode]::Create); try { $encoder.Save($stream) } finally { $stream.Dispose() }
    $manifestPath = Join-Path $sourceRoot 'pet.json'
    [System.IO.File]::WriteAllText($manifestPath, '{"id":"fixture-pet","displayName":"Fixture Pet","spritesheetPath":"spritesheet.png"}', (New-Object System.Text.UTF8Encoding($false)))
    $spriteBefore = (Get-FileHash -LiteralPath $spritePath -Algorithm SHA256).Hash
    $manifestBefore = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $env:CODEX_HOME = $codexHome
    $result = (& $launch -PluginRoot $pluginRoot -PluginData $resolved) | ConvertFrom-Json
    if (-not [bool]$result.ok -or -not [bool]$result.currentPet) { throw 'Launch helper did not create and start a private pet clone.' }
    $cleanup = (& $uninstall -PluginData $resolved) | ConvertFrom-Json
    if (-not [bool]$cleanup.ok -or (Test-Path -LiteralPath $resolved)) { throw 'Uninstall helper did not remove private plugin data.' }
    if ((Get-FileHash -LiteralPath $spritePath -Algorithm SHA256).Hash -ne $spriteBefore) { throw 'Launch or uninstall modified the official spritesheet.' }
    if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $manifestBefore) { throw 'Launch or uninstall modified the official manifest.' }

    Write-Host 'lifecycle-windows: ok'
}
finally {
    if (Test-Path -LiteralPath $resolved) { $null = & $uninstall -PluginData $resolved }
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
