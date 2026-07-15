param([string]$PluginRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\health-core.ps1')
$config = Get-Content -LiteralPath (Join-Path $PluginRoot 'assets\default-config.json') -Raw | ConvertFrom-Json

function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -ne $Expected) {
        throw "$Label expected '$Expected' but got '$Actual'"
    }
}

$points = @(0, 1799, 1800, 3599, 3600, 5399, 5400, 7199, 7200)
$levels = @(0, 0, 1, 1, 2, 2, 3, 3, 4)
for ($i = 0; $i -lt $points.Count; $i++) {
    Assert-Equal (Get-SitPetLevel -SedentarySeconds $points[$i] -Config $config) $levels[$i] "level $($points[$i])"
}

Assert-Equal (Get-SitPetVitality -SedentarySeconds 3600 -Config $config) 80 'vitality 60m'
Assert-Equal (Get-SitPetVitality -SedentarySeconds 7200 -Config $config) 25 'vitality 120m'
Assert-Equal (Get-SitPetVitality -SedentarySeconds 9000 -Config $config) 0 'vitality floor'

$state = New-SitPetState
$state.sedentarySeconds = 5000
$result = Step-SitPetHealth -State $state -DeltaSeconds 1 -IdleSeconds 300 -IsPaused $false -Config $config
Assert-Equal $result.State.pendingFullBreak $true 'full break waits for return'
Assert-Equal $result.State.fullBreaks 0 'full break not credited while away'
Assert-Equal $result.FullBreak $false 'no celebration while away'
$result = Step-SitPetHealth -State $state -DeltaSeconds 1 -IdleSeconds 0 -IsPaused $false -Config $config
Assert-Equal $result.State.sedentarySeconds 0 'full break reset on return'
Assert-Equal $result.State.fullBreaks 1 'full break count on return'
Assert-Equal $result.FullBreak $true 'full break return event'
Assert-Equal $result.FullBreakDurationSeconds 300 'full break duration'
$result = Step-SitPetHealth -State $state -DeltaSeconds 1 -IdleSeconds 0 -IsPaused $false -Config $config
Assert-Equal $result.State.fullBreaks 1 'single credit per idle episode'

$state = New-SitPetState
$state.sedentarySeconds = 2400
$result = Step-SitPetHealth -State $state -DeltaSeconds 10 -IdleSeconds 90 -IsPaused $false -Config $config
Assert-Equal $result.State.sedentarySeconds 2380 'partial recovery'

$state = New-SitPetState
$result = Step-SitPetHealth -State $state -DeltaSeconds 10 -IdleSeconds 300 -IsPaused $true -Config $config
Assert-Equal $result.State.pendingFullBreak $false 'locked or sleeping idle does not arm break credit'

$state = New-SitPetState
$transition = Update-SitPetCodexSessions -State $state -EventName 'UserPromptSubmit' -SessionHash 'a' -NowUtc ([DateTime]'2026-07-14T00:00:01Z')
Assert-Equal $transition.BecameRunning $true 'first session starts runtime opportunity'
Assert-Equal $transition.ActiveCount 1 'one active session'
$transition = Update-SitPetCodexSessions -State $state -EventName 'PermissionRequest' -SessionHash 'a' -NowUtc ([DateTime]'2026-07-14T00:00:02Z')
Assert-Equal $transition.BecameRunning $false 'same session does not restart opportunity'
Assert-Equal $transition.ActiveCount 1 'same session remains unique'
$transition = Update-SitPetCodexSessions -State $state -EventName 'UserPromptSubmit' -SessionHash 'b' -NowUtc ([DateTime]'2026-07-14T00:00:03Z')
Assert-Equal $transition.ActiveCount 2 'two concurrent sessions'
$transition = Update-SitPetCodexSessions -State $state -EventName 'Stop' -SessionHash 'a' -NowUtc ([DateTime]'2026-07-14T00:00:04Z')
Assert-Equal $transition.BecameIdle $false 'one concurrent stop keeps runtime busy'
Assert-Equal $transition.ActiveCount 1 'second session remains active'
$transition = Update-SitPetCodexSessions -State $state -EventName 'Stop' -SessionHash 'b' -NowUtc ([DateTime]'2026-07-14T00:00:05Z')
Assert-Equal $transition.BecameIdle $true 'last concurrent stop becomes idle'
Assert-Equal $transition.ActiveCount 0 'all sessions stopped'

$state = New-SitPetState
$start = [DateTime]'2026-07-14T00:00:00Z'
Assert-Equal (Test-SitPetCanRemind -State $state -Kind health -Config $config -NowUtc $start) $true 'first reminder allowed'
Add-SitPetReminder -State $state -Kind health -NowUtc $start
Assert-Equal (Test-SitPetCanRemind -State $state -Kind codex -Config $config -NowUtc $start.AddMinutes(5)) $false 'minimum reminder gap'
Assert-Equal (Test-SitPetCanRemind -State $state -Kind codex -Config $config -NowUtc $start.AddMinutes(10)) $true 'reminder allowed after gap'
Add-SitPetReminder -State $state -Kind codex -NowUtc $start.AddMinutes(10)
Add-SitPetReminder -State $state -Kind health -NowUtc $start.AddMinutes(20)
Assert-Equal (Test-SitPetCanRemind -State $state -Kind codex -Config $config -NowUtc $start.AddMinutes(30)) $false 'global reminder cap'
Assert-Equal (Test-SitPetCanRemind -State $state -Kind codex -Config $config -NowUtc $start.AddHours(2)) $true 'rolling reminder window expires'

Write-Output 'health-core-powershell: ok'
