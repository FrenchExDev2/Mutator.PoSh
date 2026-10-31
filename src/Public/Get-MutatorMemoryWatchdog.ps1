function Get-MutatorMemoryWatchdog {
    <#
    .SYNOPSIS
    Read watchdog policy, usage and liveness.

    .DESCRIPTION
    Returns thresholds, last action and masked errors without starting monitoring or recovery.
    #>

    [CmdletBinding()]
    param([string]$Path)
    if(!$Path){$Path=Join-Path $script:MutatorRoot 'test/Artifacts/memory-watchdog'}
    $directory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $configuration=Read-MutatorJson (Join-Path $directory 'watchdog.json')
    if(!$configuration){throw 'No retained memory watchdog exists at this path.'}
    $state=Read-MutatorJson (Join-Path $directory 'state.json')
    [pscustomobject]@{Path=$directory;Running=[bool](Test-MutatorProcess $configuration.Process);LimitGB=$configuration.LimitBytes/1e9;TriggerGB=$configuration.TriggerBytes/1e9
        UsedGB=$(if($state -and $null -ne $state.UsedBytes){$state.UsedBytes/1e9}else{$null});Outcome=$(if($state){$state.Outcome}else{$configuration.Outcome});LastSampleUtc=$(if($state){$state.Utc}else{$null})
        LastAction=$(if($state){$state['LastAction']}else{$null});Error=$(if($state){Protect-MutatorDiagnostic $state['Error']}else{$null});Process=$configuration.Process;PodmanMachine=$configuration['PodmanMachine']}
}
