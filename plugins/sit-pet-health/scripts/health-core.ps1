Set-StrictMode -Version Latest

function Get-SitPetLevel {
    param(
        [double]$SedentarySeconds,
        [psobject]$Config
    )

    if ($SedentarySeconds -lt [double]$Config.graceSeconds) { return 0 }
    if ($SedentarySeconds -lt [double]$Config.lazySeconds) { return 1 }
    if ($SedentarySeconds -lt [double]$Config.wiltedSeconds) { return 2 }
    if ($SedentarySeconds -lt [double]$Config.sickSeconds) { return 3 }
    return 4
}

function Get-SitPetVitality {
    param(
        [double]$SedentarySeconds,
        [psobject]$Config
    )

    $anchors = @(
        @{ Start = 0.0; End = [double]$Config.graceSeconds; From = 100.0; To = 100.0 },
        @{ Start = [double]$Config.graceSeconds; End = [double]$Config.lazySeconds; From = 100.0; To = 80.0 },
        @{ Start = [double]$Config.lazySeconds; End = [double]$Config.wiltedSeconds; From = 80.0; To = 55.0 },
        @{ Start = [double]$Config.wiltedSeconds; End = [double]$Config.sickSeconds; From = 55.0; To = 25.0 },
        @{ Start = [double]$Config.sickSeconds; End = [double]$Config.sickSeconds + 1800.0; From = 25.0; To = 0.0 }
    )

    foreach ($anchor in $anchors) {
        if ($SedentarySeconds -le $anchor.End) {
            if ($anchor.End -le $anchor.Start) { return [math]::Round($anchor.To, 1) }
            $ratio = [math]::Max(0.0, [math]::Min(1.0, ($SedentarySeconds - $anchor.Start) / ($anchor.End - $anchor.Start)))
            return [math]::Round($anchor.From + (($anchor.To - $anchor.From) * $ratio), 1)
        }
    }
    return 0.0
}

function Step-SitPetHealth {
    param(
        [psobject]$State,
        [double]$DeltaSeconds,
        [double]$IdleSeconds,
        [bool]$IsPaused,
        [psobject]$Config
    )

    $previousSedentary = [double]$State.sedentarySeconds
    $previousLevel = [int]$State.level
    $fullBreak = $false
    $partialBreak = $false
    $fullBreakDurationSeconds = 0.0

    if (-not $IsPaused -and $DeltaSeconds -gt 0 -and $DeltaSeconds -le 30) {
        if ($IdleSeconds -ge [double]$Config.fullBreakSeconds) {
            $State.pendingFullBreak = $true
            $State.idleEpisodePeakSeconds = [math]::Max([double]$State.idleEpisodePeakSeconds, $IdleSeconds)
        }
        elseif ($IdleSeconds -ge [double]$Config.partialBreakStartSeconds) {
            $State.idleEpisodePeakSeconds = [math]::Max([double]$State.idleEpisodePeakSeconds, $IdleSeconds)
            $State.sedentarySeconds = [math]::Max(0.0, [double]$State.sedentarySeconds - ($DeltaSeconds * [double]$Config.partialRecoveryRate))
            $partialBreak = $true
        }
        elseif ($IdleSeconds -lt [double]$Config.activeIdleCutoffSeconds) {
            if ([bool]$State.pendingFullBreak) {
                $State.sedentarySeconds = 0.0
                $State.pendingFullBreak = $false
                $State.fullBreakCreditedForIdleEpisode = $true
                $State.fullBreaks = [int]$State.fullBreaks + 1
                $fullBreakDurationSeconds = [double]$State.idleEpisodePeakSeconds
                $State.lastBreakDurationSeconds = $fullBreakDurationSeconds
                $State.idleEpisodePeakSeconds = 0.0
                $fullBreak = $true
            }
            else {
                $State.sedentarySeconds = [double]$State.sedentarySeconds + $DeltaSeconds
                $State.fullBreakCreditedForIdleEpisode = $false
                $State.idleEpisodePeakSeconds = 0.0
            }
        }
    }

    $State.level = Get-SitPetLevel -SedentarySeconds ([double]$State.sedentarySeconds) -Config $Config
    $State.vitality = Get-SitPetVitality -SedentarySeconds ([double]$State.sedentarySeconds) -Config $Config

    [pscustomobject]@{
        State = $State
        PreviousSedentarySeconds = $previousSedentary
        PreviousLevel = $previousLevel
        LevelChanged = ([int]$State.level -ne $previousLevel)
        FullBreak = $fullBreak
        FullBreakDurationSeconds = $fullBreakDurationSeconds
        PartialBreak = $partialBreak
    }
}

function New-SitPetState {
    [pscustomobject]@{
        version = 2
        sedentarySeconds = 0.0
        vitality = 100.0
        level = 0
        fullBreakCreditedForIdleEpisode = $false
        pendingFullBreak = $false
        idleEpisodePeakSeconds = 0.0
        lastBreakDurationSeconds = 0.0
        fullBreaks = 0
        listenedBreaks = 0
        listenedStreak = 0
        ignoredOpportunities = 0
        codexStatus = 'idle'
        activeCodexSessions = @()
        opportunityUntilUtc = $null
        opportunityPrompted = $false
        reminderHistoryUtc = @()
        healthReminderHistoryUtc = @()
        codexReminderHistoryUtc = @()
        lastLevelReminder = -1
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Update-SitPetCodexSessions {
    param(
        [psobject]$State,
        [string]$EventName,
        [string]$SessionHash,
        [DateTime]$NowUtc = [DateTime]::UtcNow,
        [double]$StaleSeconds = 21600
    )

    $now = $NowUtc.ToUniversalTime()
    $cutoff = $now.AddSeconds(-[math]::Max(300, $StaleSeconds))
    $sessions = @()
    foreach ($entry in @($State.activeCodexSessions)) {
        try {
            $lastEvent = [DateTime]::Parse([string]$entry.lastEventUtc).ToUniversalTime()
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.sessionHash) -and $lastEvent -gt $cutoff) {
                $sessions += [pscustomobject]@{ sessionHash = [string]$entry.sessionHash; lastEventUtc = $lastEvent.ToString('o') }
            }
        }
        catch { }
    }

    $wasRunning = $sessions.Count -gt 0
    $key = if ([string]::IsNullOrWhiteSpace($SessionHash)) { 'sessionless' } else { $SessionHash }
    if ($EventName -in @('UserPromptSubmit', 'PermissionRequest')) {
        $sessions = @($sessions | Where-Object { [string]$_.sessionHash -ne $key })
        $sessions += [pscustomobject]@{ sessionHash = $key; lastEventUtc = $now.ToString('o') }
    }
    elseif ($EventName -eq 'Stop') {
        $sessions = @($sessions | Where-Object { [string]$_.sessionHash -ne $key })
    }

    $State.activeCodexSessions = @($sessions)
    $isRunning = $sessions.Count -gt 0
    $State.codexStatus = if ($isRunning) { 'running' } else { 'idle' }
    [pscustomobject]@{
        WasRunning = $wasRunning
        IsRunning = $isRunning
        BecameRunning = (-not $wasRunning -and $isRunning)
        BecameIdle = ($wasRunning -and -not $isRunning)
        ActiveCount = $sessions.Count
    }
}

function Get-SitPetDialogue {
    param(
        [ValidateSet('level', 'task-start', 'task-done', 'recovery', 'listened')]
        [string]$Kind,
        [psobject]$State,
        [string]$PetName,
        [int]$Seed = 0
    )

    $minutes = [math]::Floor([double]$State.sedentarySeconds / 60)
    $templates = switch ($Kind) {
        'level' {
            switch ([int]$State.level) {
                1 { @('{0} is getting sleepy after {1} minutes.', 'A small break would wake {0} up.', '{1} minutes seated. Stretch before the next task.') }
                2 { @('{0} is wilting after {1} minutes.', 'You have been active for {1} minutes. Walk a little?', '{0} can hold the task while you move.') }
                3 { @('{0} is worn out after {1} minutes.', 'The task can wait for a short movement break.', '{1} minutes seated. Time to stand up.') }
                default { @('{0} is on strike until you leave the keyboard for a while.', '{1} minutes seated. Five minutes away will restore {0} when you return.', 'The chair won this round. Walk around and revive {0}.') }
            }
        }
        'task-start' {
            if ([int]$State.listenedStreak -gt 0) {
                @('I have this task. Take the same good break as last time.', 'I am on duty. Go for a quick walk.', 'Leave the task with me and come back in five minutes.')
            }
            elseif ([int]$State.ignoredOpportunities -gt 1) {
                @('I have the task again. Surprise the chair this time.', 'The work is mine and the legs are yours. Use this gap.', 'You are not needed for five minutes. I will keep watch.')
            }
            else {
                @('I have this part. Move around and come back to review.', 'Codex is running, so you can walk for a moment.', 'A free gap appeared. I will watch the task while you move.')
            }
        }
        'task-done' { @('The task moved, but you did not. Stand up next.', 'I finished my part. Your next action is a short walk.', 'Task done. The chair still has you in review.') }
        'recovery' { @('Welcome back. {0} is fully restored.', 'Five minutes away counted. The strike is over.', 'You returned after time away. Vitality restored.') }
        'listened' { @('You actually took the break. Good trade.', 'Gap used successfully. {0} noticed.', 'You moved while I worked. Keep that arrangement.') }
    }

    if ($null -eq $templates -or $templates.Count -eq 0) { return '' }
    $index = [math]::Abs($Seed + [int]$State.fullBreaks + ([int]$State.level * 7)) % $templates.Count
    return [string]::Format($templates[$index], $PetName, $minutes)
}
