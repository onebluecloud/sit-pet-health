param(
    [string]$Version = '1.3.0',
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$stageParent = Join-Path $OutputDirectory 'stage'
$packageRoot = Join-Path $stageParent 'rousepet'
$packageName = "rousepet-redskill-v$Version"
$zipPath = Join-Path $OutputDirectory "$packageName.zip"

if (Test-Path -LiteralPath $stageParent) { Remove-Item -LiteralPath $stageParent -Recurse -Force }
New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot 'scripts') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot 'metadata') | Out-Null

Copy-Item -LiteralPath (Join-Path $repositoryRoot 'SKILL.md') -Destination $packageRoot -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LICENSE') -Destination (Join-Path $packageRoot 'LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'plugins\sit-pet-health\THIRD-PARTY-NOTICES.txt') -Destination $packageRoot -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\install-redskill-windows.ps1') -Destination (Join-Path $packageRoot 'scripts') -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot '.agents\plugins\marketplace.json') -Destination (Join-Path $packageRoot 'metadata\marketplace.json') -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'plugins\sit-pet-health\.codex-plugin\plugin.json') -Destination (Join-Path $packageRoot 'metadata\plugin.json') -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'plugins\sit-pet-health') -Destination (Join-Path $packageRoot 'plugin') -Recurse -Force

$pluginRoot = Join-Path $packageRoot 'plugin'
foreach ($relative in @('.codex-plugin', 'agents', 'scripts\tests', 'skills\upgrade-codex-pet-health\agents', 'vendor\hatch-pet\agents')) {
    $path = Join-Path $pluginRoot $relative
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}

# The RedSkill release is Windows-only. Remove unverified macOS and shell files
# instead of relying on the uploader to filter them.
Get-ChildItem -LiteralPath $pluginRoot -Recurse -File | Where-Object {
    $_.Extension -eq '.sh' -or $_.Name -match 'macos' -or $_.Name -in @('health-core.js', 'generate_pet_images.py')
} | Remove-Item -Force

# Keep the Windows-only hook manifest self-contained. `commandWindows` remains
# the exact reviewed command; the generic command mirrors it instead of pointing
# to macOS files that are intentionally not shipped in this package.
$hooksPath = Join-Path $pluginRoot 'hooks\hooks.json'
$hooksDocument = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($eventProperty in $hooksDocument.hooks.PSObject.Properties) {
    foreach ($group in @($eventProperty.Value)) {
        foreach ($hook in @($group.hooks)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$hook.commandWindows)) {
                $hook.command = [string]$hook.commandWindows
            }
        }
    }
}
[System.IO.File]::WriteAllText(
    $hooksPath,
    ($hooksDocument | ConvertTo-Json -Depth 10) + [Environment]::NewLine,
    (New-Object System.Text.UTF8Encoding($false))
)

$pluginLicense = Join-Path $pluginRoot 'LICENSE'
if (Test-Path -LiteralPath $pluginLicense -PathType Leaf) {
    Move-Item -LiteralPath $pluginLicense -Destination "$pluginLicense.txt" -Force
}
Get-ChildItem -LiteralPath $packageRoot -Recurse -Directory -Filter '__pycache__' |
    Sort-Object { $_.FullName.Length } -Descending |
    Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath $packageRoot -Recurse -File | Where-Object {
    $_.Extension -in @('.pyc', '.pyo') -or $_.Name -eq '.DS_Store'
} | Remove-Item -Force

$allFiles = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File)
$forbidden = @($allFiles | Where-Object {
    $relative = $_.FullName.Substring($packageRoot.Length + 1)
    $hasHiddenSegment = @($relative.Split([IO.Path]::DirectorySeparatorChar) | Where-Object { $_.StartsWith('.') }).Count -gt 0
    $_.Name -match '\.yaml\.txt$' -or $_.Extension -in @('.yaml', '.yml', '.sh') -or $hasHiddenSegment
})
if ($forbidden.Count -gt 0) { throw "RedSkill package contains filtered or hidden files: $($forbidden.FullName -join ', ')" }

$bypassHits = @(Select-String -Path ($allFiles.FullName) -Pattern 'ExecutionPolicy\s*["'']?[, ]+\s*["'']?Bypass|ExecutionPolicy Bypass|yaml\.txt carriers|restore.*yaml' -CaseSensitive:$false)
if ($bypassHits.Count -gt 0) { throw "RedSkill package contains permission bypass or filter-restoration logic: $($bypassHits.Path -join ', ')" }

if ($allFiles.Count -eq 0) { throw 'RedSkill package is empty.' }
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
& tar.exe -a -c -f $zipPath -C $stageParent 'rousepet'
if ($LASTEXITCODE -ne 0) { throw 'Failed to create RedSkill archive.' }

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$zipPath.sha256" -Encoding ascii -Value "$hash  $packageName.zip"

[ordered]@{
    ok = $true
    package = $zipPath
    sha256 = $hash
    topLevel = 'rousepet'
    uploadFileCount = $allFiles.Count
    extensions = @($allFiles | Group-Object Extension | Sort-Object Name | ForEach-Object { [ordered]@{ extension = $_.Name; count = $_.Count } })
} | ConvertTo-Json -Depth 5 -Compress
