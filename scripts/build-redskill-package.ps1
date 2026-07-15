param(
    [string]$Version = '1.1.0',
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$stageParent = Join-Path $OutputDirectory 'stage'
$packageName = "rousepet-redskill-v$Version"
$packageRoot = Join-Path $stageParent $packageName
$zipPath = Join-Path $OutputDirectory "$packageName.zip"

if (Test-Path -LiteralPath $stageParent) { Remove-Item -LiteralPath $stageParent -Recurse -Force }
New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null

$directories = @('agents', '.agents', 'plugins')
foreach ($directory in $directories) {
    Copy-Item -LiteralPath (Join-Path $repositoryRoot $directory) -Destination $packageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot 'scripts') | Out-Null
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\install-redskill-windows.ps1') -Destination (Join-Path $packageRoot 'scripts') -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\install-redskill-macos.sh') -Destination (Join-Path $packageRoot 'scripts') -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'SKILL.md') -Destination $packageRoot -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LICENSE') -Destination $packageRoot -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'plugins\sit-pet-health\THIRD-PARTY-NOTICES.txt') -Destination $packageRoot -Force

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
& tar.exe -a -c -f $zipPath -C $stageParent $packageName
if ($LASTEXITCODE -ne 0) { throw 'Failed to create RedSkill archive.' }

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$zipPath.sha256" -Encoding ascii -Value "$hash  $packageName.zip"

[ordered]@{
    ok = $true
    package = $zipPath
    sha256 = $hash
} | ConvertTo-Json -Compress
