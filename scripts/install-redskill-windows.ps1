param(
    [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$LocalRoot,
    [switch]$AcknowledgePermissions,
    [switch]$SkipLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-CodexJson {
    param([string[]]$Arguments)

    $output = & codex @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($output | Out-String).Trim()) }
    return (($output | Out-String) | ConvertFrom-Json)
}

function Copy-DirectoryContents {
    param([string]$Source, [string]$Destination)

    [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

if (-not $AcknowledgePermissions) {
    throw 'Permission acknowledgement is required. Read SKILL.md "安装前权限确认" to the user and rerun only after explicit consent.'
}
if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    throw 'Codex Desktop/CLI is required. This package does not install a separate executable.'
}

$PackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)
$skillFile = Join-Path $PackageRoot 'SKILL.md'
$pluginSource = Join-Path $PackageRoot 'plugin'
$marketplaceTemplate = Join-Path $PackageRoot 'metadata\marketplace.json'
$pluginTemplate = Join-Path $PackageRoot 'metadata\plugin.json'
foreach ($required in @($skillFile, $marketplaceTemplate, $pluginTemplate)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Invalid RousePet package: missing $required" }
}
if (-not (Test-Path -LiteralPath $pluginSource -PathType Container)) {
    throw "Invalid RousePet package: missing $pluginSource"
}

$localRoot = if ([string]::IsNullOrWhiteSpace($LocalRoot)) {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'RousePet'
} else {
    [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($LocalRoot))
}
$marketplaceRoot = Join-Path $localRoot 'marketplace'
$stagingRoot = Join-Path $localRoot ("marketplace-staging-{0}" -f [Guid]::NewGuid().ToString('N'))
$stagingPlugin = Join-Path $stagingRoot 'plugins\sit-pet-health'
$ownerMarkerName = 'rousepet-owner.json'
$ownerMarker = Join-Path $marketplaceRoot $ownerMarkerName
$installRecordPath = Join-Path $localRoot 'install-record.json'

try {
    [System.IO.Directory]::CreateDirectory((Join-Path $stagingRoot '.agents\plugins')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $stagingPlugin '.codex-plugin')) | Out-Null
    Copy-DirectoryContents -Source $pluginSource -Destination $stagingPlugin
    Copy-Item -LiteralPath $marketplaceTemplate -Destination (Join-Path $stagingRoot '.agents\plugins\marketplace.json') -Force
    Copy-Item -LiteralPath $pluginTemplate -Destination (Join-Path $stagingPlugin '.codex-plugin\plugin.json') -Force
    [System.IO.File]::WriteAllText(
        (Join-Path $stagingRoot $ownerMarkerName),
        ([ordered]@{ owner = 'RousePet'; schema = 1 } | ConvertTo-Json) + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false))
    )

    if (Test-Path -LiteralPath $marketplaceRoot) {
        $existing = Get-Item -LiteralPath $marketplaceRoot -Force
        if (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Refusing to replace a reparse-point marketplace directory.'
        }
        $isOwned = $false
        if (Test-Path -LiteralPath $ownerMarker -PathType Leaf) {
            $owner = Get-Content -LiteralPath $ownerMarker -Raw -Encoding UTF8 | ConvertFrom-Json
            $isOwned = [string]$owner.owner -eq 'RousePet'
        }
        elseif (Test-Path -LiteralPath $installRecordPath -PathType Leaf) {
            $legacyRecord = Get-Content -LiteralPath $installRecordPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $recordedRoot = [System.IO.Path]::GetFullPath([string]$legacyRecord.marketplaceRoot)
            $isOwned = [string]::Equals($recordedRoot, $marketplaceRoot, [System.StringComparison]::OrdinalIgnoreCase)
        }
        if (-not $isOwned) {
            throw 'Refusing to replace an existing marketplace directory without a RousePet ownership record.'
        }
        Remove-Item -LiteralPath $marketplaceRoot -Recurse -Force
    }
    Move-Item -LiteralPath $stagingRoot -Destination $marketplaceRoot
}
catch {
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
    throw
}

$marketplace = Invoke-CodexJson -Arguments @('plugin', 'marketplace', 'add', $marketplaceRoot, '--json')
$selector = 'sit-pet-health@{0}' -f $marketplace.marketplaceName
$install = Invoke-CodexJson -Arguments @('plugin', 'add', $selector, '--json')
$installedPath = [System.IO.Path]::GetFullPath([string]$install.installedPath)

$launch = $null
if (-not $SkipLaunch) {
    $launcher = Join-Path $installedPath 'scripts\launch-windows.ps1'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "Plugin installed without launcher: $launcher" }
    $launch = & $launcher | Out-String | ConvertFrom-Json
}

$record = [ordered]@{
    version = 1
    marketplace = [string]$marketplace.marketplaceName
    pluginId = [string]$install.pluginId
    installedPath = $installedPath
    marketplaceRoot = $marketplaceRoot
    installedAtUtc = [DateTime]::UtcNow.ToString('o')
}
[System.IO.Directory]::CreateDirectory($localRoot) | Out-Null
[System.IO.File]::WriteAllText(
    $installRecordPath,
    ($record | ConvertTo-Json -Depth 4) + [Environment]::NewLine,
    (New-Object System.Text.UTF8Encoding($false))
)

[ordered]@{
    ok = $true
    marketplace = [string]$marketplace.marketplaceName
    pluginId = [string]$install.pluginId
    version = [string]$install.version
    installedPath = $installedPath
    marketplaceRoot = $marketplaceRoot
    launched = if ($SkipLaunch) { $false } else { [bool]$launch.ok }
    pluginData = if ($null -eq $launch) { $null } else { [string]$launch.pluginData }
    enhancementRequired = if ($null -eq $launch) { $false } else { [bool]$launch.enhancementRequired }
    enhancementMessage = if ($null -eq $launch) { $null } else { [string]$launch.systemMessage }
} | ConvertTo-Json -Compress
