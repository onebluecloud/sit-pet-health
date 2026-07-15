param(
    [Parameter(Mandatory = $true)]
    [string]$PluginData,
    [string]$CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

function Test-ContainedPath {
    param([string]$Parent, [string]$Child)
    try {
        $root = [System.IO.Path]::GetFullPath($Parent).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        return [System.IO.Path]::GetFullPath($Child).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

$PluginData = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($PluginData))
$warnings = @()
$current = Read-JsonSafe -Path (Join-Path $PluginData 'current-pet.json')
$selection = Read-JsonSafe -Path (Join-Path $PluginData 'selected-source.json')
$state = Read-JsonSafe -Path (Join-Path $PluginData 'health-state.json')
$configPath = Join-Path $PluginData 'config.json'
$config = Read-JsonSafe -Path $configPath
$pause = Read-JsonSafe -Path (Join-Path $PluginData 'pause.json')
$lastError = Read-JsonSafe -Path (Join-Path $PluginData 'last-error.json')
$pidRecord = Read-JsonSafe -Path (Join-Path $PluginData 'runtime.pid')
if ((Test-Path -LiteralPath $configPath -PathType Leaf) -and $null -eq $config) { $warnings += 'config.json is malformed.' }

$runtimeAlive = $false
$runtimeMemoryMb = $null
if ($null -ne $pidRecord -and $null -ne $pidRecord.PSObject.Properties['pid']) {
    try {
        $runtimeProcess = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$pidRecord.pid)" -ErrorAction Stop
        $runtimeAlive = $null -ne $runtimeProcess -and [string]$runtimeProcess.CommandLine -match 'runtime-windows\.ps1' -and [string]$runtimeProcess.CommandLine -match [regex]::Escape($PluginData)
        if ($runtimeAlive) {
            $processRecord = Get-Process -Id ([int]$pidRecord.pid) -ErrorAction SilentlyContinue
            if ($null -ne $processRecord) { $runtimeMemoryMb = [math]::Round($processRecord.PrivateMemorySize64 / 1MB, 1) }
        }
    }
    catch { $runtimeAlive = $false }
}

$cloneDirectory = if ($null -ne $current) { [string]$current.cloneDirectory } else { '' }
$profile = if (-not [string]::IsNullOrWhiteSpace($cloneDirectory)) { Read-JsonSafe -Path (Join-Path $cloneDirectory 'health-profile.json') } else { $null }
$profileVersion = if ($null -ne $profile -and $null -ne $profile.PSObject.Properties['version']) { [int]$profile.version } else { 0 }
$actionLayoutId = if ($null -ne $profile -and $null -ne $profile.PSObject.Properties['actionLayoutId']) { [string]$profile.actionLayoutId } else { '' }
$extensionStatus = if ($null -ne $profile -and $null -ne $profile.PSObject.Properties['healthExtension']) { [string]$profile.healthExtension.status } else { 'missing' }
$extensionActions = if ($null -ne $profile -and $null -ne $profile.PSObject.Properties['healthExtension'] -and $null -ne $profile.healthExtension.PSObject.Properties['actions']) { @($profile.healthExtension.actions | ForEach-Object { [string]$_.semantic }) } else { @() }
$requiredCloneFiles = @('pet.json', 'spritesheet.png', 'health-profile.json', 'atlases\stage-0.png', 'atlases\stage-1.png', 'atlases\stage-2.png', 'atlases\stage-3.png', 'atlases\stage-4.png', 'atlases\celebrate.png', 'atlases\held.png')
$missingCloneFiles = @()
if ([string]::IsNullOrWhiteSpace($cloneDirectory) -or -not (Test-ContainedPath -Parent $PluginData -Child $cloneDirectory)) {
    $warnings += 'Current clone path is missing or outside plugin data.'
}
else {
    foreach ($relative in $requiredCloneFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $cloneDirectory $relative) -PathType Leaf)) { $missingCloneFiles += $relative }
    }
}

$sourceDirectory = ''
$sourceType = if ($null -ne $selection -and $null -ne $selection.PSObject.Properties['sourceType'] -and -not [string]::IsNullOrWhiteSpace([string]$selection.sourceType)) { [string]$selection.sourceType } else { 'official' }
if ($sourceType -eq 'custom') {
    $sourceDirectory = if ($null -ne $selection -and $null -ne $selection.PSObject.Properties['sourceDirectory']) { [string]$selection.sourceDirectory } else { '' }
    $customRoot = Join-Path $PluginData 'custom-sources'
    if ([string]::IsNullOrWhiteSpace($sourceDirectory) -or -not (Test-ContainedPath -Parent $customRoot -Child $sourceDirectory)) {
        $warnings += 'Custom source path is missing or outside custom-sources.'
        $sourceDirectory = ''
    }
}
else {
    if ([string]::IsNullOrWhiteSpace($CodexHome)) {
        $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    }
    if ($null -ne $current) { $sourceDirectory = Join-Path ([System.IO.Path]::GetFullPath($CodexHome)) ("pets\" + [string]$current.sourceSlug) }
}

$sourceManifestPath = if (-not [string]::IsNullOrWhiteSpace($sourceDirectory)) { Join-Path $sourceDirectory 'pet.json' } else { '' }
$sourceManifest = Read-JsonSafe -Path $sourceManifestPath
$sourceSpritePath = ''
if ($null -ne $sourceManifest) {
    $relativeSprite = if (-not [string]::IsNullOrWhiteSpace([string]$sourceManifest.spritesheetPath)) { [string]$sourceManifest.spritesheetPath } else { 'spritesheet.webp' }
    $candidate = Join-Path $sourceDirectory $relativeSprite
    if (Test-ContainedPath -Parent $sourceDirectory -Child $candidate) { $sourceSpritePath = [System.IO.Path]::GetFullPath($candidate) }
}

$sourceSpriteHash = if (-not [string]::IsNullOrWhiteSpace($sourceSpritePath) -and (Test-Path -LiteralPath $sourceSpritePath -PathType Leaf)) { (Get-FileHash -LiteralPath $sourceSpritePath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
$sourceManifestHash = if (-not [string]::IsNullOrWhiteSpace($sourceManifestPath) -and (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf)) { (Get-FileHash -LiteralPath $sourceManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
$expectedSpriteHash = if ($null -ne $profile) { [string]$profile.sourceSpriteSha256 } else { '' }
$expectedManifestHash = if ($null -ne $profile) { [string]$profile.sourceManifestSha256 } else { '' }
$sourceUnchanged = -not [string]::IsNullOrWhiteSpace($sourceSpriteHash) -and -not [string]::IsNullOrWhiteSpace($sourceManifestHash) -and $sourceSpriteHash -eq $expectedSpriteHash -and $sourceManifestHash -eq $expectedManifestHash
if (-not $sourceUnchanged) { $warnings += 'Source pet hashes do not match the private health profile.' }
if ($missingCloneFiles.Count -gt 0) { $warnings += 'Private clone is incomplete.' }
if ($null -ne $profile -and ($profileVersion -lt 3 -or [string]::IsNullOrWhiteSpace($actionLayoutId))) { $warnings += 'Private clone uses a legacy action profile and should be rebuilt.' }
if ($extensionStatus -notin @('complete', 'missing')) { $warnings += 'Dedicated private health actions are pending; safe fallback actions remain active.' }
if ($extensionStatus -eq 'complete' -and $extensionActions.Count -gt 0) {
    foreach ($stage in 2..4) {
        $relative = [string]$profile.stages.PSObject.Properties[[string]$stage].Value.file
        $candidate = Join-Path $cloneDirectory ($relative -replace '/', '\')
        if (-not (Test-ContainedPath -Parent $cloneDirectory -Child $candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $warnings += "Generated health stage $stage is missing or outside the private clone."
        }
    }
}
if (-not $runtimeAlive) { $warnings += 'Pet runtime is not running.' }

$pendingEvents = @(Get-ChildItem -LiteralPath (Join-Path $PluginData 'events') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count

[ordered]@{
    ok = ($null -ne $current -and $missingCloneFiles.Count -eq 0 -and $sourceUnchanged -and $runtimeAlive)
    pluginData = $PluginData
    sourceType = $sourceType
    sourceDirectory = $sourceDirectory
    sourceUnchanged = $sourceUnchanged
    sourceSpriteSha256 = $sourceSpriteHash
    sourceManifestSha256 = $sourceManifestHash
    cloneId = if ($null -ne $current) { [string]$current.cloneId } else { $null }
    cloneDirectory = $cloneDirectory
    cloneComplete = ($missingCloneFiles.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($cloneDirectory))
    missingCloneFiles = $missingCloneFiles
    runtimeAlive = $runtimeAlive
    runtimePid = if ($null -ne $pidRecord) { $pidRecord.pid } else { $null }
    runtimePrivateMemoryMb = $runtimeMemoryMb
    profileVersion = if ($null -ne $profile) { $profileVersion } else { $null }
    actionLayoutId = if (-not [string]::IsNullOrWhiteSpace($actionLayoutId)) { $actionLayoutId } else { $null }
    healthExtensionStatus = $extensionStatus
    healthExtensionActions = $extensionActions
    candidateCount = if ($null -ne $current -and $null -ne $current.PSObject.Properties['candidateCount']) { $current.candidateCount } else { $null }
    configVersion = if ($null -ne $config -and $null -ne $config.PSObject.Properties['version']) { $config.version } else { $null }
    pausedUntilUtc = if ($null -ne $pause) { $pause.untilUtc } elseif (Test-Path -LiteralPath (Join-Path $PluginData 'pause.flag')) { 'indefinite-legacy' } else { $null }
    lastError = $lastError
    health = if ($null -ne $state) { [ordered]@{ level = $state.level; vitality = $state.vitality; sedentarySeconds = $state.sedentarySeconds; fullBreaks = $state.fullBreaks; listenedBreaks = $state.listenedBreaks } } else { $null }
    pendingSanitizedEvents = $pendingEvents
    warnings = $warnings
} | ConvertTo-Json -Depth 8
