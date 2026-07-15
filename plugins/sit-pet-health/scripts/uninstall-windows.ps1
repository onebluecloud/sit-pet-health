param(
    [string]$PluginData = $env:CLAUDE_PLUGIN_DATA
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PluginData)) { throw 'CLAUDE_PLUGIN_DATA or PluginData is required.' }
$PluginData = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($PluginData))
$leaf = Split-Path -Leaf $PluginData
if ($leaf -notmatch '^sit-pet-health(?:-.+)?$' -or [System.IO.Path]::GetPathRoot($PluginData) -eq $PluginData) {
    throw 'Refusing to remove a directory that is not a sit-pet-health plugin data root.'
}

if (Test-Path -LiteralPath $PluginData) {
    $item = Get-Item -LiteralPath $PluginData -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Refusing to remove a reparse-point plugin data directory.'
    }
    $pidPath = Join-Path $PluginData 'runtime.pid'
    if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
        try {
            $record = Get-Content -LiteralPath $pidPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $pidValue = [int]$record.pid
            $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $pidValue" -ErrorAction SilentlyContinue
            if ($null -ne $process -and [string]$process.CommandLine -match 'runtime-windows\.ps1' -and [string]$process.CommandLine -match [regex]::Escape($PluginData)) {
                Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
                $null = Wait-Process -Id $pidValue -Timeout 5 -ErrorAction SilentlyContinue
            }
        }
        catch { }
    }
    Remove-Item -LiteralPath $PluginData -Recurse -Force
}

[ordered]@{ ok = -not (Test-Path -LiteralPath $PluginData); removedPluginData = $PluginData } | ConvertTo-Json -Compress
