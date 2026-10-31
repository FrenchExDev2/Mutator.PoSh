function Start-MutatorMemoryWatchdog {
    <#
    .SYNOPSIS
    Arm an independent Windows host-memory watchdog.

    .DESCRIPTION
    Validates thresholds/counters, reuses only identical living policy and retains actual identity.
    Recovery remains limited to owned processes.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([ValidateRange(4,1048576)][double]$LimitGB=50,[ValidateRange(0,100)][double]$HeadroomGB=2,
        [ValidateRange(1,60)][int]$PollSeconds=2,[ValidateRange(0.1,1000)][double]$MinimumProcessGB=1,[string]$Path,[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$PodmanMachine)
    if(!(Test-MutatorWindowsPlatform)){throw 'The host memory watchdog currently requires Windows.'}
    if($HeadroomGB -ge $LimitGB){throw 'Memory headroom must be below the host limit.'}
    if(!$Path){$Path=Join-Path $script:MutatorRoot 'test/Artifacts/memory-watchdog'}
    $directory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $previous=Read-MutatorJson (Join-Path $directory 'watchdog.json')
    if($previous -and (Test-MutatorProcess $previous.Process)){
        if($previous.LimitBytes -eq [long]($LimitGB*1e9) -and $previous.TriggerBytes -eq [long](($LimitGB-$HeadroomGB)*1e9) -and $previous.PollSeconds -eq $PollSeconds -and $previous.MinimumProcessBytes -eq [long]($MinimumProcessGB*1e9) -and $previous['PodmanMachine'] -ceq $PodmanMachine){return Get-MutatorMemoryWatchdog $directory}
        if(!$PSCmdlet.ShouldProcess($directory,'Replace the running watchdog with the requested host RAM policy')){return}
        Write-MutatorJson (Join-Path $directory 'stop.json') @{Reason='PolicyChanged';Utc=[datetime]::UtcNow.ToString('O')}
        $deadline=[datetimeoffset]::UtcNow.AddSeconds(15)
        while(Test-MutatorProcess $previous.Process){
            if([datetimeoffset]::UtcNow -ge $deadline){throw 'The watchdog is finishing a recovery; wait for it before changing its RAM policy.'}
            Start-Sleep -Milliseconds 250
        }
    }
    # Fail before claiming the watchdog is armed when OS counters are inaccessible.
    $null=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if(!$PSCmdlet.ShouldProcess($directory,'Start a host RAM watchdog with process identity checks and controlled PowerShell restart')){return}
    $stop=Join-Path $directory 'stop.json'
    if(Test-Path -LiteralPath $stop){Remove-Item -LiteralPath $stop -Force}
    $settings=@{LimitBytes=[long]($LimitGB*1e9);TriggerBytes=[long](($LimitGB-$HeadroomGB)*1e9);PollSeconds=$PollSeconds;MinimumProcessBytes=[long]($MinimumProcessGB*1e9)
        RunId=[guid]::NewGuid().ToString('N');CreatedUtc=[datetime]::UtcNow.ToString('O');Process=$null;Outcome='Starting';PodmanMachine=$PodmanMachine}
    Write-MutatorJson (Join-Path $directory 'watchdog.json') $settings
    Write-MutatorJson (Join-Path $directory 'state.json') @{Outcome='Starting';Utc=[datetime]::UtcNow.ToString('O');UsedBytes=$null;LastAction=$null;Error=$null}
    $settings.Process=Start-MutatorDetachedWorker -RunDirectory $directory -Kind MemoryWatchdog
    Write-MutatorJson (Join-Path $directory 'watchdog.json') $settings
    Get-MutatorMemoryWatchdog $directory
}
