param(
    [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$SkipLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-CodexJson {
    param([string[]]$Arguments)

    $output = & codex @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output | Out-String).Trim())
    }
    return (($output | Out-String) | ConvertFrom-Json)
}

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    throw 'Codex Desktop/CLI is required. The RedSkill package does not install a separate executable.'
}

$PackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)
$marketplaceFile = Join-Path $PackageRoot '.agents\plugins\marketplace.json'
if (-not (Test-Path -LiteralPath $marketplaceFile -PathType Leaf)) {
    throw "Invalid RedSkill package: missing $marketplaceFile"
}

$marketplace = Invoke-CodexJson -Arguments @('plugin', 'marketplace', 'add', $PackageRoot, '--json')
$selector = 'sit-pet-health@{0}' -f $marketplace.marketplaceName
$install = Invoke-CodexJson -Arguments @('plugin', 'add', $selector, '--json')
$installedPath = [System.IO.Path]::GetFullPath([string]$install.installedPath)

$launch = $null
if (-not $SkipLaunch) {
    $launcher = Join-Path $installedPath 'scripts\launch-windows.ps1'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "Plugin installed without launcher: $launcher"
    }
    $launch = & PowerShell -NoProfile -ExecutionPolicy Bypass -File $launcher | Out-String | ConvertFrom-Json
}

[ordered]@{
    ok = $true
    marketplace = [string]$marketplace.marketplaceName
    pluginId = [string]$install.pluginId
    version = [string]$install.version
    installedPath = $installedPath
    launched = if ($SkipLaunch) { $false } else { [bool]$launch.ok }
    pluginData = if ($null -eq $launch) { $null } else { [string]$launch.pluginData }
} | ConvertTo-Json -Compress
