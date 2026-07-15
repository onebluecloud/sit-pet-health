param(
    [Parameter(Mandatory = $true)]
    [string]$PluginData,
    [string]$CodexHome,
    [string]$SourcePet,
    [string]$SourceDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PluginRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Storage.FileAccessMode, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapPixelFormat, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapAlphaMode, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapTransform, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.ExifOrientationMode, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.ColorManagementMode, Windows.Graphics.Imaging, ContentType = WindowsRuntime]

function Wait-WinRt {
    param($Operation, [type]$ResultType)
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 } |
        Select-Object -First 1
    $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

function Read-ImagePixels {
    param([string]$Path)
    $file = Wait-WinRt -Operation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) -ResultType ([Windows.Storage.StorageFile])
    $stream = Wait-WinRt -Operation ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) -ResultType ([Windows.Storage.Streams.IRandomAccessStream])
    try {
        $decoder = Wait-WinRt -Operation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) -ResultType ([Windows.Graphics.Imaging.BitmapDecoder])
        $transform = New-Object Windows.Graphics.Imaging.BitmapTransform
        $pixelProvider = Wait-WinRt -Operation ($decoder.GetPixelDataAsync(
            [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
            [Windows.Graphics.Imaging.BitmapAlphaMode]::Straight,
            $transform,
            [Windows.Graphics.Imaging.ExifOrientationMode]::IgnoreExifOrientation,
            [Windows.Graphics.Imaging.ColorManagementMode]::DoNotColorManage
        )) -ResultType ([Windows.Graphics.Imaging.PixelDataProvider])
        return [pscustomobject]@{
            Width = [int]$decoder.PixelWidth
            Height = [int]$decoder.PixelHeight
            Pixels = [byte[]]$pixelProvider.DetachPixelData()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-ContainedPath {
    param([string]$Parent, [string]$Child)
    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $childFull = [System.IO.Path]::GetFullPath($Child)
    if (-not $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'spritesheetPath escapes the source pet directory'
    }
    return $childFull
}

function Save-Png {
    param([System.Windows.Media.Imaging.BitmapSource]$Bitmap, [string]$Path)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

function New-BitmapFromPixels {
    param([byte[]]$Pixels, [int]$Width, [int]$Height)
    $bitmap = New-Object System.Windows.Media.Imaging.WriteableBitmap($Width, $Height, 96, 96, [System.Windows.Media.PixelFormats]::Bgra32, $null)
    $bitmap.WritePixels((New-Object System.Windows.Int32Rect(0, 0, $Width, $Height)), $Pixels, $Width * 4, 0)
    $bitmap.Freeze()
    return $bitmap
}

function New-StageStrip {
    param(
        [byte[]]$SourcePixels,
        [int]$SourceWidth,
        [int]$SourceRow,
        [int[]]$SourceColumns
    )
    $frameWidth = 192
    $frameHeight = 208
    $stride = $SourceWidth * 4
    $output = New-Object byte[] ($stride * $frameHeight)
    for ($destinationColumn = 0; $destinationColumn -lt 8; $destinationColumn++) {
        $sourceColumn = $SourceColumns[$destinationColumn % $SourceColumns.Count]
        for ($y = 0; $y -lt $frameHeight; $y++) {
            $sourceOffset = (($SourceRow * $frameHeight + $y) * $stride) + ($sourceColumn * $frameWidth * 4)
            $destinationOffset = ($y * $stride) + ($destinationColumn * $frameWidth * 4)
            [Array]::Copy($SourcePixels, $sourceOffset, $output, $destinationOffset, $frameWidth * 4)
        }
    }
    return New-BitmapFromPixels -Pixels $output -Width $SourceWidth -Height $frameHeight
}

function Test-CloneComplete {
    param(
        [string]$Directory,
        [string]$SourceSpriteSha256,
        [string]$SourceManifestSha256
    )
    try {
        $required = @(
            (Join-Path $Directory 'health-profile.json'),
            (Join-Path $Directory 'pet.json'),
            (Join-Path $Directory 'spritesheet.png')
        )
        foreach ($name in @('stage-0.png', 'stage-1.png', 'stage-2.png', 'stage-3.png', 'stage-4.png', 'celebrate.png', 'held.png')) {
            $required += Join-Path $Directory "atlases\$name"
        }
        foreach ($path in $required) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -le 0) { return $false }
        }
        $profile = Get-Content -LiteralPath (Join-Path $Directory 'health-profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        return [int]$profile.version -ge 2 -and
            -not [string]::IsNullOrWhiteSpace([string]$profile.actionLayoutId) -and
            [string]$profile.sourceSpriteSha256 -eq $SourceSpriteSha256 -and
            [string]$profile.sourceManifestSha256 -eq $SourceManifestSha256
    }
    catch {
        return $false
    }
}

$PluginData = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($PluginData))
[System.IO.Directory]::CreateDirectory($PluginData) | Out-Null
$selectionPath = Join-Path $PluginData 'selected-source.json'

if ([string]::IsNullOrWhiteSpace($SourceDirectory) -and [string]::IsNullOrWhiteSpace($SourcePet) -and (Test-Path -LiteralPath $selectionPath -PathType Leaf)) {
    try {
        $savedSource = Get-Content -LiteralPath $selectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$savedSource.sourceType -eq 'custom' -and -not [string]::IsNullOrWhiteSpace([string]$savedSource.sourceDirectory)) {
            $savedDirectory = [System.IO.Path]::GetFullPath([string]$savedSource.sourceDirectory)
            $customRoot = [System.IO.Path]::GetFullPath((Join-Path $PluginData 'custom-sources')).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
            if ($savedDirectory.StartsWith($customRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $savedDirectory -PathType Container)) {
                $SourceDirectory = $savedDirectory
            }
        }
    }
    catch { }
}

$sourceDirectories = @()
$sourceType = 'official'
if (-not [string]::IsNullOrWhiteSpace($SourceDirectory)) {
    $customDirectory = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($SourceDirectory))
    if (-not (Test-Path -LiteralPath $customDirectory -PathType Container)) { throw "Custom pet directory not found: $customDirectory" }
    $sourceDirectories = @((Get-Item -LiteralPath $customDirectory))
    $sourceType = 'custom'
}
else {
    if ([string]::IsNullOrWhiteSpace($CodexHome)) {
        $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    }
    $petsRoot = Join-Path ([System.IO.Path]::GetFullPath($CodexHome)) 'pets'
    if (-not (Test-Path -LiteralPath $petsRoot -PathType Container)) {
        throw "Codex pets directory not found: $petsRoot"
    }
    $sourceDirectories = @(Get-ChildItem -LiteralPath $petsRoot -Directory -ErrorAction Stop)
}

$candidates = @()
foreach ($directory in $sourceDirectories) {
    $manifestPath = Join-Path $directory.FullName 'pet.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $manifest.PSObject.Properties['sitPetHealthClone']) { continue }
        $relativeSprite = if (-not [string]::IsNullOrWhiteSpace([string]$manifest.spritesheetPath)) { [string]$manifest.spritesheetPath } else { 'spritesheet.webp' }
        $spritePath = Get-ContainedPath -Parent $directory.FullName -Child (Join-Path $directory.FullName $relativeSprite)
        if (-not (Test-Path -LiteralPath $spritePath -PathType Leaf)) { continue }
        $spriteFile = Get-Item -LiteralPath $spritePath
        if ($spriteFile.Length -le 0 -or $spriteFile.Length -gt 20MB) { continue }
        if ($spriteFile.Extension.ToLowerInvariant() -notin @('.webp', '.png')) { continue }
        $candidates += [pscustomobject]@{
            Slug = $directory.Name
            Directory = $directory.FullName
            ManifestPath = $manifestPath
            Manifest = $manifest
            SpritePath = $spritePath
            ModifiedUtc = $spriteFile.LastWriteTimeUtc
            SourceType = $sourceType
        }
    }
    catch {
        continue
    }
}

if ($candidates.Count -eq 0) { throw 'No valid Codex pet was found. Run /hatch first.' }

$selected = $null
if (-not [string]::IsNullOrWhiteSpace($SourcePet)) {
    $selected = $candidates | Where-Object {
        $_.Slug -eq $SourcePet -or [string]$_.Manifest.id -eq $SourcePet -or [string]$_.Manifest.displayName -eq $SourcePet
    } | Select-Object -First 1
    if ($null -eq $selected) { throw "Pet not found: $SourcePet" }
}
else {
    if (Test-Path -LiteralPath $selectionPath) {
        try {
            $saved = Get-Content -LiteralPath $selectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $selected = $candidates | Where-Object { $_.Slug -eq [string]$saved.slug } | Select-Object -First 1
        }
        catch { $selected = $null }
    }
    if ($null -eq $selected) {
        $selected = $candidates | Sort-Object ModifiedUtc -Descending | Select-Object -First 1
    }
}

$sourceHashBefore = (Get-FileHash -LiteralPath $selected.SpritePath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifestHash = (Get-FileHash -LiteralPath $selected.ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$displayName = if (-not [string]::IsNullOrWhiteSpace([string]$selected.Manifest.displayName)) { [string]$selected.Manifest.displayName } elseif (-not [string]::IsNullOrWhiteSpace([string]$selected.Manifest.name)) { [string]$selected.Manifest.name } else { $selected.Slug }
$safeSlug = ($selected.Slug.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
if ([string]::IsNullOrWhiteSpace($safeSlug)) { $safeSlug = 'pet' }
$cloneId = "$safeSlug-health-$($sourceHashBefore.Substring(0, 8))"
$petsDataRoot = Join-Path $PluginData 'pets'
$cloneDirectory = Join-Path $petsDataRoot $cloneId
$stagingRoot = Join-Path $PluginData 'staging'
[System.IO.Directory]::CreateDirectory($petsDataRoot) | Out-Null

if (Test-CloneComplete -Directory $cloneDirectory -SourceSpriteSha256 $sourceHashBefore -SourceManifestSha256 $manifestHash) {
    $sourceHashAfter = (Get-FileHash -LiteralPath $selected.SpritePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestHashAfter = (Get-FileHash -LiteralPath $selected.ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHashAfter -ne $sourceHashBefore -or $manifestHashAfter -ne $manifestHash) {
        throw 'Source pet changed while the read-only clone was being checked.'
    }
    Write-JsonAtomic -Path (Join-Path $PluginData 'selected-source.json') -Value ([ordered]@{
        slug = $selected.Slug
        sourceType = $selected.SourceType
        sourceDirectory = if ($selected.SourceType -eq 'custom') { $selected.Directory } else { $null }
        sourceSpriteSha256 = $sourceHashBefore
    })
    Write-JsonAtomic -Path (Join-Path $PluginData 'current-pet.json') -Value ([ordered]@{
        version = 2
        cloneId = $cloneId
        cloneDirectory = $cloneDirectory
        sourceSlug = $selected.Slug
        sourceType = $selected.SourceType
        sourceSpriteSha256 = $sourceHashBefore
        displayName = $displayName
        candidateCount = $candidates.Count
    })
    [pscustomobject]@{
        ok = $true
        reused = $true
        cloneId = $cloneId
        cloneDirectory = $cloneDirectory
        displayName = $displayName
        sourceSpriteSha256 = $sourceHashBefore
        sourceManifestSha256 = $manifestHash
        sourceUnchanged = $true
        candidateCount = $candidates.Count
    } | ConvertTo-Json -Compress
    return
}

$staging = Join-Path $stagingRoot "$cloneId-$([Guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($staging) | Out-Null

try {
    $decoded = Read-ImagePixels -Path $selected.SpritePath
    $width = $decoded.Width
    $height = $decoded.Height
    $pixels = $decoded.Pixels

    $layoutCatalog = Get-Content -LiteralPath (Join-Path $PluginRoot 'assets\action-layouts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $layout = $layoutCatalog.layouts | Where-Object {
        [int]$_.width -eq $width -and @($_.heights) -contains $height
    } | Select-Object -First 1
    if ($null -eq $layout) {
        throw "No semantic action layout supports spritesheet dimensions ${width}x${height}."
    }
    $actionLayoutId = [string]$layout.id
    $actions = $layout.actions
    $fallbacks = $layout.fallbacks
    if ($null -ne $selected.Manifest.PSObject.Properties['sitPetHealthActions']) {
        $customActions = $selected.Manifest.sitPetHealthActions
        if ([int]$customActions.frameWidth -ne 192 -or [int]$customActions.frameHeight -ne 208) {
            throw 'Custom semantic actions must use 192x208 frames.'
        }
        if ($null -eq $customActions.PSObject.Properties['actions']) { throw 'Custom semantic actions are missing actions.' }
        $actions = $customActions.actions
        $actionLayoutId = if (-not [string]::IsNullOrWhiteSpace([string]$customActions.layoutId)) { [string]$customActions.layoutId } else { 'pet-manifest-custom' }
    }

    $fullClone = New-BitmapFromPixels -Pixels $pixels -Width $width -Height $height
    Save-Png -Bitmap $fullClone -Path (Join-Path $staging 'spritesheet.png')

    $atlasRoot = Join-Path $staging 'atlases'
    [System.IO.Directory]::CreateDirectory($atlasRoot) | Out-Null
    function Resolve-ActionSpec {
        param([string]$Semantic)
        $candidates = @($Semantic)
        if ($null -ne $fallbacks.PSObject.Properties[$Semantic]) { $candidates += @($fallbacks.$Semantic) }
        foreach ($candidate in $candidates) {
            if ($null -ne $actions.PSObject.Properties[[string]$candidate]) {
                return [pscustomobject]@{ Requested = $Semantic; Resolved = [string]$candidate; Action = $actions.([string]$candidate) }
            }
        }
        throw "No semantic action or fallback is available for '$Semantic'."
    }

    $definitions = @(
        @{ Name = 'stage-0.png'; Semantic = 'idle' },
        @{ Name = 'stage-1.png'; Semantic = 'waiting' },
        @{ Name = 'stage-2.png'; Semantic = 'tired' },
        @{ Name = 'stage-3.png'; Semantic = 'sick' },
        @{ Name = 'stage-4.png'; Semantic = 'rest' },
        @{ Name = 'celebrate.png'; Semantic = 'celebrate' },
        @{ Name = 'held.png'; Semantic = 'held' }
    )
    $stageSpecs = @()
    $rowCount = [int]($height / 208)
    $columnCount = [int]($width / 192)
    foreach ($definition in $definitions) {
        $resolved = Resolve-ActionSpec -Semantic $definition.Semantic
        $action = $resolved.Action
        $columns = @($action.columns | ForEach-Object { [int]$_ })
        if ([int]$action.row -lt 0 -or [int]$action.row -ge $rowCount -or $columns.Count -eq 0 -or $columns.Count -gt 8) {
            throw "Semantic action '$($resolved.Resolved)' has invalid row or columns."
        }
        foreach ($column in $columns) {
            if ($column -lt 0 -or $column -ge $columnCount) { throw "Semantic action '$($resolved.Resolved)' references invalid column $column." }
        }
        if ([int]$action.frames -lt 1 -or [int]$action.frames -gt 8) { throw "Semantic action '$($resolved.Resolved)' has invalid frame count." }
        $stageSpecs += [pscustomobject]@{
            Name = $definition.Name
            Semantic = $definition.Semantic
            ResolvedSemantic = $resolved.Resolved
            Row = [int]$action.row
            Columns = $columns
            Frames = [int]$action.frames
            DurationMs = [double]$action.durationMs
        }
    }
    foreach ($spec in $stageSpecs) {
        $strip = New-StageStrip -SourcePixels $pixels -SourceWidth $width -SourceRow $spec.Row -SourceColumns $spec.Columns
        Save-Png -Bitmap $strip -Path (Join-Path $atlasRoot $spec.Name)
    }

    Copy-Item -LiteralPath $selected.ManifestPath -Destination (Join-Path $staging 'source-pet.json')
    $sourceExtension = [System.IO.Path]::GetExtension($selected.SpritePath).ToLowerInvariant()
    Copy-Item -LiteralPath $selected.SpritePath -Destination (Join-Path $staging ("source-spritesheet" + $sourceExtension))

    $cloneManifest = [ordered]@{
        id = $cloneId
        displayName = "$displayName Health"
        description = "A private health clone of $displayName. The source pet remains read-only."
        spriteVersionNumber = if ($height -eq 2288) { 2 } else { 1 }
        spritesheetPath = 'spritesheet.png'
        sitPetHealthClone = [ordered]@{
            version = 1
            sourceSlug = $selected.Slug
            sourceSpriteSha256 = $sourceHashBefore
        }
    }
    Write-JsonAtomic -Path (Join-Path $staging 'pet.json') -Value $cloneManifest

    $profileAtlases = [ordered]@{}
    for ($level = 0; $level -le 4; $level++) {
        $spec = $stageSpecs[$level]
        $profileAtlases[[string]$level] = [ordered]@{
            file = "atlases/$($spec.Name)"
            semanticAction = $spec.ResolvedSemantic
            frames = $spec.Frames
            durationMs = $spec.DurationMs
        }
    }
    $profile = [ordered]@{
        version = 2
        actionLayoutId = $actionLayoutId
        sourceSlug = $selected.Slug
        sourceDisplayName = $displayName
        sourceSpriteSha256 = $sourceHashBefore
        sourceManifestSha256 = $manifestHash
        sourceWidth = $width
        sourceHeight = $height
        frameWidth = 192
        frameHeight = 208
        stages = $profileAtlases
        celebrate = [ordered]@{ file = 'atlases/celebrate.png'; semanticAction = $stageSpecs[5].ResolvedSemantic; frames = $stageSpecs[5].Frames; durationMs = $stageSpecs[5].DurationMs }
        held = [ordered]@{ file = 'atlases/held.png'; semanticAction = $stageSpecs[6].ResolvedSemantic; frames = $stageSpecs[6].Frames; durationMs = $stageSpecs[6].DurationMs }
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonAtomic -Path (Join-Path $staging 'health-profile.json') -Value $profile

    $sourceHashAfter = (Get-FileHash -LiteralPath $selected.SpritePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHashAfter -ne $sourceHashBefore) { throw 'Source pet changed while the read-only clone was being created.' }
    $manifestHashAfter = (Get-FileHash -LiteralPath $selected.ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($manifestHashAfter -ne $manifestHash) { throw 'Source pet manifest changed while the read-only clone was being created.' }

    if (-not (Test-CloneComplete -Directory $cloneDirectory -SourceSpriteSha256 $sourceHashBefore -SourceManifestSha256 $manifestHash)) {
        if (Test-Path -LiteralPath $cloneDirectory) { Remove-Item -LiteralPath $cloneDirectory -Recurse -Force }
        Move-Item -LiteralPath $staging -Destination $cloneDirectory
    }
    else {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }

    Write-JsonAtomic -Path (Join-Path $PluginData 'selected-source.json') -Value ([ordered]@{
        slug = $selected.Slug
        sourceType = $selected.SourceType
        sourceDirectory = if ($selected.SourceType -eq 'custom') { $selected.Directory } else { $null }
        sourceSpriteSha256 = $sourceHashBefore
    })
    Write-JsonAtomic -Path (Join-Path $PluginData 'current-pet.json') -Value ([ordered]@{
        version = 2
        cloneId = $cloneId
        cloneDirectory = $cloneDirectory
        sourceSlug = $selected.Slug
        sourceType = $selected.SourceType
        sourceSpriteSha256 = $sourceHashBefore
        displayName = $displayName
        candidateCount = $candidates.Count
    })

    [pscustomobject]@{
        ok = $true
        reused = $false
        cloneId = $cloneId
        cloneDirectory = $cloneDirectory
        displayName = $displayName
        sourceSpriteSha256 = $sourceHashBefore
        sourceManifestSha256 = $manifestHash
        sourceUnchanged = $true
        candidateCount = $candidates.Count
    } | ConvertTo-Json -Compress
}
catch {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    throw
}
