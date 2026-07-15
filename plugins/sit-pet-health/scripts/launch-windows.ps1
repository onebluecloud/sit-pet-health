param(
    [string]$PluginRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$PluginData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PluginRoot = [System.IO.Path]::GetFullPath($PluginRoot)
if ([string]::IsNullOrWhiteSpace($PluginData)) {
    $versionDirectory = Get-Item -LiteralPath $PluginRoot
    $pluginDirectory = $versionDirectory.Parent
    $marketplaceDirectory = $pluginDirectory.Parent
    $cacheDirectory = $marketplaceDirectory.Parent
    if ($cacheDirectory.Name -ne 'cache' -or $cacheDirectory.Parent.Name -ne 'plugins') {
        throw 'PluginData is required when launching outside an installed Codex plugin cache.'
    }
    $PluginData = Join-Path $cacheDirectory.Parent.FullName ("data\{0}-{1}" -f $pluginDirectory.Name, $marketplaceDirectory.Name)
    if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME = $cacheDirectory.Parent.Parent.FullName }
}

$PluginData = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($PluginData))
$env:CLAUDE_PLUGIN_ROOT = $PluginRoot
$env:CLAUDE_PLUGIN_DATA = $PluginData
$hookOutput = '{"hook_event_name":"SessionStart","session_id":""}' |
    PowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\hook-windows.ps1')
$hookMessage = $null
if (-not [string]::IsNullOrWhiteSpace(($hookOutput | Out-String))) {
    try { $hookMessage = [string](($hookOutput | Out-String) | ConvertFrom-Json).systemMessage }
    catch { $hookMessage = ($hookOutput | Out-String).Trim() }
}

for ($attempt = 0; $attempt -lt 50; $attempt++) {
    if ((Test-Path -LiteralPath (Join-Path $PluginData 'runtime.pid') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $PluginData 'current-pet.json') -PathType Leaf)) { break }
    Start-Sleep -Milliseconds 100
}
[ordered]@{
    ok = Test-Path -LiteralPath (Join-Path $PluginData 'runtime.pid') -PathType Leaf
    pluginData = $PluginData
    currentPet = Test-Path -LiteralPath (Join-Path $PluginData 'current-pet.json') -PathType Leaf
    enhancementRequired = -not [string]::IsNullOrWhiteSpace($hookMessage) -and $hookMessage -match 'health animation extension|missing tired, sick, and rest'
    systemMessage = $hookMessage
} | ConvertTo-Json -Compress
