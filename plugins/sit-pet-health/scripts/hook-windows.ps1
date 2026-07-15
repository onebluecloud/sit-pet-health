param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-ShortHash {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $bytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
    return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant().Substring(0, 16)
}

try {
    $rootValue = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PLUGIN_ROOT)) { $env:CLAUDE_PLUGIN_ROOT } else { $env:PLUGIN_ROOT }
    $dataValue = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PLUGIN_DATA)) { $env:CLAUDE_PLUGIN_DATA } else { $env:PLUGIN_DATA }
    if ([string]::IsNullOrWhiteSpace($rootValue) -or [string]::IsNullOrWhiteSpace($dataValue)) {
        throw 'Codex plugin root or data directory is missing.'
    }
    $pluginRoot = [System.IO.Path]::GetFullPath($rootValue)
    $pluginData = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($dataValue))
    [System.IO.Directory]::CreateDirectory($pluginData) | Out-Null

    $raw = [Console]::In.ReadToEnd()
    $payload = if ([string]::IsNullOrWhiteSpace($raw)) { [pscustomobject]@{} } else { $raw | ConvertFrom-Json }
    $eventName = ''
    foreach ($field in @('hook_event_name', 'hookEventName', 'event_name', 'eventName')) {
        if ($null -ne $payload.PSObject.Properties[$field] -and -not [string]::IsNullOrWhiteSpace([string]$payload.$field)) {
            $eventName = [string]$payload.$field
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }

    $previousCloneId = ''
    $currentPetPath = Join-Path $pluginData 'current-pet.json'
    if (Test-Path -LiteralPath $currentPetPath -PathType Leaf) {
        try { $previousCloneId = [string](Get-Content -LiteralPath $currentPetPath -Raw -Encoding UTF8 | ConvertFrom-Json).cloneId }
        catch { $previousCloneId = '' }
    }
    if ($eventName -eq 'SessionStart' -or -not (Test-Path -LiteralPath (Join-Path $pluginData 'current-pet.json') -PathType Leaf)) {
        $null = & (Join-Path $pluginRoot 'scripts\prepare-pet-windows.ps1') -PluginData $pluginData
        if (-not (Test-Path -LiteralPath (Join-Path $pluginData 'current-pet.json') -PathType Leaf)) {
            throw 'Pet clone preparation did not produce current-pet.json.'
        }
    }
    $currentCloneId = [string](Get-Content -LiteralPath $currentPetPath -Raw -Encoding UTF8 | ConvertFrom-Json).cloneId
    $petCloneChanged = -not [string]::IsNullOrWhiteSpace($previousCloneId) -and $previousCloneId -ne $currentCloneId

    $sessionValue = ''
    foreach ($field in @('session_id', 'sessionId', 'thread_id', 'threadId')) {
        if ($null -ne $payload.PSObject.Properties[$field]) { $sessionValue = [string]$payload.$field; break }
    }
    $eventRoot = Join-Path $pluginData 'events'
    [System.IO.Directory]::CreateDirectory($eventRoot) | Out-Null
    $eventPath = Join-Path $eventRoot ("$([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfffffff'))-$([Guid]::NewGuid().ToString('N')).json")
    Write-JsonAtomic -Path $eventPath -Value ([ordered]@{
        version = 1
        eventName = $eventName
        occurredAtUtc = [DateTime]::UtcNow.ToString('o')
        sessionHash = Get-ShortHash -Value $sessionValue
    })

    $runtimePidPath = Join-Path $pluginData 'runtime.pid'
    $runtimeAlive = $false
    if (Test-Path -LiteralPath $runtimePidPath -PathType Leaf) {
        try {
            $pidRecord = Get-Content -LiteralPath $runtimePidPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $process = Get-Process -Id ([int]$pidRecord.pid) -ErrorAction SilentlyContinue
            if ($null -ne $process) {
                try {
                    $cim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$pidRecord.pid)" -ErrorAction Stop
                    $runtimeAlive = $null -ne $cim -and [string]$cim.CommandLine -match 'runtime-windows\.ps1' -and [string]$cim.CommandLine -match [regex]::Escape($pluginData)
                }
                catch { $runtimeAlive = $false }
            }
        }
        catch { $runtimeAlive = $false }
    }
    if ($runtimeAlive -and $petCloneChanged) {
        Stop-Process -Id ([int]$pidRecord.pid) -Force -ErrorAction SilentlyContinue
        $null = Wait-Process -Id ([int]$pidRecord.pid) -Timeout 3 -ErrorAction SilentlyContinue
        $runtimeAlive = $false
    }
    if (-not $runtimeAlive) {
        Remove-Item -LiteralPath $runtimePidPath -Force -ErrorAction SilentlyContinue
        $arguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-STA',
            '-File', ('"' + (Join-Path $pluginRoot 'scripts\runtime-windows.ps1') + '"'),
            '-PluginRoot', ('"' + $pluginRoot + '"'),
            '-PluginData', ('"' + $pluginData + '"')
        )
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    }
}
catch {
    $message = $_.Exception.Message.Replace('"', '\"')
    [Console]::Out.WriteLine("{`"systemMessage`":`"Codex pet health could not start: $message`"}")
    exit 0
}
