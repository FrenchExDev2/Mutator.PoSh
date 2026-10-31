function Stop-MutatorMemoryWatchdog {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)
    if(!$Path){$Path=Join-Path $script:MutatorRoot 'test/Artifacts/memory-watchdog'}
    $state=Get-MutatorMemoryWatchdog $Path
    if($PSCmdlet.ShouldProcess($state.Path,'Stop the memory watchdog without stopping any watched process')){Write-MutatorJson (Join-Path $state.Path 'stop.json') @{Utc=[datetime]::UtcNow.ToString('O')}}
    Get-MutatorMemoryWatchdog $state.Path
}
