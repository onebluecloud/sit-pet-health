param(
    [string]$TestRoot = $(if (-not [string]::IsNullOrWhiteSpace($env:SIT_PET_TEST_ROOT)) { Join-Path $env:SIT_PET_TEST_ROOT 'automated-prepare' } elseif (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { Join-Path $env:RUNNER_TEMP 'sit-pet-automated-prepare' } else { Join-Path ([System.IO.Path]::GetTempPath()) 'sit-pet-tests\automated-prepare' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pluginRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$prepare = Join-Path $pluginRoot 'scripts\prepare-pet-windows.ps1'
$diagnose = Join-Path $pluginRoot 'scripts\diagnose-windows.ps1'
$resolved = [System.IO.Path]::GetFullPath($TestRoot)
if ($resolved.Length -lt 8 -or [System.IO.Path]::GetPathRoot($resolved) -eq $resolved) { throw 'Unsafe test root.' }
if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
[System.IO.Directory]::CreateDirectory($resolved) | Out-Null

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

function Assert-True {
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw $Message }
}

function Write-TransparentPng {
    param([string]$Path, [int]$Width, [int]$Height, [switch]$Marker)
    $bitmap = New-Object System.Windows.Media.Imaging.WriteableBitmap($Width, $Height, 96, 96, [System.Windows.Media.PixelFormats]::Bgra32, $null)
    if ($Marker) {
        $bitmap.WritePixels((New-Object System.Windows.Int32Rect(0, 0, 1, 1)), [byte[]]@(255, 160, 80, 255), 4, 0)
    }
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

function Write-Utf8Json {
    param([string]$Path, [object]$Value)
    $json = $Value | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

try {
    $codexHome = Join-Path $resolved 'codex-home'
    $petRoot = Join-Path $codexHome 'pets\v2pet'
    [System.IO.Directory]::CreateDirectory($petRoot) | Out-Null
    $source = Join-Path $petRoot 'spritesheet.png'
    Write-TransparentPng -Path $source -Width 1536 -Height 2288
    Write-Utf8Json -Path (Join-Path $petRoot 'pet.json') -Value ([ordered]@{
        id = 'v2pet'
        displayName = 'V2 Test Pet'
        spritesheetPath = 'spritesheet.png'
        spriteVersionNumber = 2
    })

    $hashBefore = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $manifestPath = Join-Path $petRoot 'pet.json'
    $manifestHashBefore = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $pluginData = Join-Path $resolved 'plugin-data'
    $result = (& $prepare -PluginData $pluginData -CodexHome $codexHome -SourcePet 'v2pet') | ConvertFrom-Json
    $hashAfter = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $manifestHashAfter = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    Assert-True ($result.ok -eq $true) 'Preparation did not report success.'
    Assert-True ($hashBefore -eq $hashAfter) 'The source spritesheet changed.'
    Assert-True ($manifestHashBefore -eq $manifestHashAfter) 'The source pet manifest changed.'
    Assert-True ($result.sourceUnchanged -eq $true) 'The sourceUnchanged invariant was not reported.'

    $profile = Get-Content -LiteralPath (Join-Path $result.cloneDirectory 'health-profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([int]$profile.version -eq 3) 'The semantic health profile version was not generated.'
    Assert-True ([string]$profile.actionLayoutId -eq 'codex-standard-192x208-v1') 'The standard Codex semantic action layout was not selected.'
    Assert-True ([int]$profile.sourceHeight -eq 2288) 'V2 height was not preserved.'
    $expectedSemantics = @('idle', 'waiting', 'tired', 'sick', 'rest')
    for ($level = 0; $level -le 4; $level++) {
        Assert-True ([string]$profile.stages.PSObject.Properties[[string]$level].Value.semanticAction -eq $expectedSemantics[$level]) "Stage $level did not use the expected semantic action."
    }
    Assert-True ([string]$profile.celebrate.semanticAction -eq 'celebrate') 'The celebration semantic action was not preserved.'
    Assert-True ([string]$profile.held.semanticAction -eq 'held') 'The held semantic action was not preserved.'
    Assert-True ([bool]$result.enhancementRequired) 'A standard pet without explicit health actions did not request a private extension.'
    Assert-True ((@($result.enhancementActions) -join ',') -eq 'tired,sick,rest') 'The standard pet requested the wrong private health actions.'
    Assert-True ([string]$profile.healthExtension.status -eq 'required') 'The private health extension request was not recorded.'
    foreach ($file in @('stage-0.png', 'stage-1.png', 'stage-2.png', 'stage-3.png', 'stage-4.png', 'celebrate.png', 'held.png')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $result.cloneDirectory "atlases\$file") -PathType Leaf) "Missing generated atlas $file."
    }

    $reused = (& $prepare -PluginData $pluginData -CodexHome $codexHome -SourcePet 'v2pet') | ConvertFrom-Json
    Assert-True ([bool]$reused.reused) 'An unchanged clone was decoded and rebuilt instead of reused.'

    Write-Utf8Json -Path $manifestPath -Value ([ordered]@{
        id = 'v2pet'
        displayName = 'V2 Test Pet Renamed'
        spritesheetPath = 'spritesheet.png'
        spriteVersionNumber = 2
    })
    $renamedManifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $renamed = (& $prepare -PluginData $pluginData -CodexHome $codexHome -SourcePet 'v2pet') | ConvertFrom-Json
    $renamedProfile = Get-Content -LiteralPath (Join-Path $renamed.cloneDirectory 'health-profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (-not [bool]$renamed.reused) 'A changed source manifest incorrectly reused stale clone metadata.'
    Assert-True ([string]$renamedProfile.sourceManifestSha256 -eq $renamedManifestHash) 'The clone did not refresh after a source manifest update.'
    Assert-True ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $renamedManifestHash) 'The source manifest was modified during refresh.'

    $previousCloneId = [string]$renamed.cloneId
    Write-TransparentPng -Path $source -Width 1536 -Height 2288 -Marker
    $updatedSpriteHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    $updated = (& $prepare -PluginData $pluginData -CodexHome $codexHome -SourcePet 'v2pet') | ConvertFrom-Json
    Assert-True ([string]$updated.cloneId -ne $previousCloneId) 'A changed source spritesheet did not create a new private clone identity.'
    Assert-True ([string]$updated.sourceSpriteSha256 -eq $updatedSpriteHash) 'The refreshed clone does not match the updated source spritesheet.'
    Assert-True ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -eq $updatedSpriteHash) 'The updated source spritesheet was modified during refresh.'

    Remove-Item -LiteralPath (Join-Path $updated.cloneDirectory 'atlases\stage-3.png') -Force
    $rebuilt = (& $prepare -PluginData $pluginData -CodexHome $codexHome -SourcePet 'v2pet') | ConvertFrom-Json
    Assert-True (Test-Path -LiteralPath (Join-Path $rebuilt.cloneDirectory 'atlases\stage-3.png') -PathType Leaf) 'A damaged clone was not rebuilt.'

    $evilHome = Join-Path $resolved 'evil-home'
    $evilRoot = Join-Path $evilHome 'pets\evil'
    [System.IO.Directory]::CreateDirectory($evilRoot) | Out-Null
    Write-TransparentPng -Path (Join-Path $evilHome 'pets\outside.png') -Width 1536 -Height 1872
    Write-Utf8Json -Path (Join-Path $evilRoot 'pet.json') -Value ([ordered]@{
        id = 'evil'
        displayName = 'Escape Test'
        spritesheetPath = '..\outside.png'
    })
    $escapeRejected = $false
    try { $null = & $prepare -PluginData (Join-Path $resolved 'evil-data') -CodexHome $evilHome -SourcePet 'evil' }
    catch { $escapeRejected = $_.Exception.Message -match 'No valid Codex pet' }
    Assert-True $escapeRejected 'A spritesheet path escaping its pet directory was accepted.'

    $customRoot = Join-Path $resolved 'plugin-custom\custom-sources\prompt-pet'
    [System.IO.Directory]::CreateDirectory($customRoot) | Out-Null
    Write-TransparentPng -Path (Join-Path $customRoot 'spritesheet.png') -Width 1536 -Height 1872
    Write-Utf8Json -Path (Join-Path $customRoot 'pet.json') -Value ([ordered]@{
        id = 'prompt-pet'
        displayName = 'Prompt Pet'
        spritesheetPath = 'spritesheet.png'
    })
    $customData = Join-Path $resolved 'plugin-custom'
    $customResult = (& $prepare -PluginData $customData -CodexHome (Join-Path $resolved 'does-not-exist') -SourceDirectory $customRoot) | ConvertFrom-Json
    Assert-True ($customResult.ok -eq $true) 'A plugin-private custom source could not be prepared.'
    $customCurrent = Get-Content -LiteralPath (Join-Path $customData 'current-pet.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$customCurrent.sourceType -eq 'custom') 'The custom source type was not preserved.'
    $customDiagnosis = (& $diagnose -PluginData $customData -CodexHome (Join-Path $resolved 'does-not-exist')) | ConvertFrom-Json
    Assert-True ([string]$customDiagnosis.sourceType -eq 'custom') 'Diagnosis lost the custom source type.'
    Assert-True ([bool]$customDiagnosis.sourceUnchanged) 'Diagnosis could not verify the custom source hashes.'

    $fallbackRoot = Join-Path $resolved 'plugin-fallback\custom-sources\fallback-pet'
    [System.IO.Directory]::CreateDirectory($fallbackRoot) | Out-Null
    Write-TransparentPng -Path (Join-Path $fallbackRoot 'spritesheet.png') -Width 1536 -Height 1872
    Write-Utf8Json -Path (Join-Path $fallbackRoot 'pet.json') -Value ([ordered]@{
        id = 'fallback-pet'
        displayName = 'Fallback Pet'
        spritesheetPath = 'spritesheet.png'
        sitPetHealthActions = [ordered]@{
            layoutId = 'fallback-only-idle'
            frameWidth = 192
            frameHeight = 208
            actions = [ordered]@{
                idle = [ordered]@{ row = 0; columns = @(0, 1, 2, 3, 4, 5, 0, 1); frames = 6; durationMs = 1680 }
            }
        }
    })
    $fallbackData = Join-Path $resolved 'plugin-fallback'
    $fallbackResult = (& $prepare -PluginData $fallbackData -SourceDirectory $fallbackRoot) | ConvertFrom-Json
    $fallbackProfile = Get-Content -LiteralPath (Join-Path $fallbackResult.cloneDirectory 'health-profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$fallbackProfile.actionLayoutId -eq 'fallback-only-idle') 'A custom semantic layout id was not preserved.'
    foreach ($level in 0..4) {
        Assert-True ([string]$fallbackProfile.stages.PSObject.Properties[[string]$level].Value.semanticAction -eq 'idle') "Stage $level did not fall back to the available idle action."
    }
    Assert-True ([bool]$fallbackResult.enhancementRequired) 'A fallback-only pet did not request dedicated health actions.'
    Assert-True ((@($fallbackResult.enhancementActions) -join ',') -eq 'tired,sick,rest') 'The fallback-only pet requested the wrong health actions.'
    Assert-True ([string]$fallbackProfile.celebrate.semanticAction -eq 'idle') 'Celebration did not fall back to idle.'
    Assert-True ([string]$fallbackProfile.held.semanticAction -eq 'idle') 'Held did not fall back to idle.'

    $explicitRoot = Join-Path $resolved 'plugin-explicit\custom-sources\explicit-pet'
    [System.IO.Directory]::CreateDirectory($explicitRoot) | Out-Null
    Write-TransparentPng -Path (Join-Path $explicitRoot 'spritesheet.png') -Width 1536 -Height 1872
    Write-Utf8Json -Path (Join-Path $explicitRoot 'pet.json') -Value ([ordered]@{
        id = 'explicit-pet'
        displayName = 'Explicit Pet'
        spritesheetPath = 'spritesheet.png'
        sitPetHealthActions = [ordered]@{
            layoutId = 'explicit-health-actions'
            frameWidth = 192
            frameHeight = 208
            actions = [ordered]@{
                idle = [ordered]@{ row = 0; columns = @(0, 1, 2, 3, 4, 5); frames = 6; durationMs = 1680 }
                tired = [ordered]@{ row = 5; columns = @(0, 1, 2); frames = 3; durationMs = 3600 }
                sick = [ordered]@{ row = 5; columns = @(3, 4, 5); frames = 3; durationMs = 4500 }
                rest = [ordered]@{ row = 5; columns = @(6, 7); frames = 2; durationMs = 6000 }
            }
        }
    })
    $explicitResult = (& $prepare -PluginData (Join-Path $resolved 'plugin-explicit') -SourceDirectory $explicitRoot) | ConvertFrom-Json
    Assert-True (-not [bool]$explicitResult.enhancementRequired) 'A pet with explicit health actions incorrectly requested image generation.'
    $explicitProfile = Get-Content -LiteralPath (Join-Path $explicitResult.cloneDirectory 'health-profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$explicitProfile.healthExtension.status -eq 'complete') 'Explicit health actions were not marked complete.'

    Write-Host 'prepare-pet-windows: ok'
}
finally {
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
