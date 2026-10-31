function Invoke-MutatorPodmanCacheRecovery {
    <#
    .SYNOPSIS
    Reclaim clean cache or compact free pages in a verified Podman VM.

    .DESCRIPTION
    Checks the named running machine and counters first. Retains measured intervention details,
    including actual kernel compaction.
    #>

    param([ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$Machine)
    $inspection=Invoke-MutatorNative podman @('machine','inspect',$Machine) $script:MutatorRoot 30
    if($inspection.Outcome -ne 'Success'){throw 'The configured Podman machine could not be verified.'}
    $instance=@($inspection.Stdout|ConvertFrom-Json -AsHashtable)[0]
    if($instance.Name -cne $Machine -or $instance.State -cne 'running'){throw 'The configured Podman machine is not running.'}
    $memory=Invoke-MutatorNative podman @('machine','ssh',$Machine,'cat','/proc/meminfo') $script:MutatorRoot 30
    if($memory.Outcome -ne 'Success'){throw 'Podman VM memory counters are unavailable.'}
    $cached=0L;$available=0L
    foreach($line in ($memory.Stdout -split "`r?`n")){
        if($line -match '^(Cached|SReclaimable):\s+(\d+)\s+kB'){$cached+=[long]$Matches[2]*1024}
        elseif($line -match '^MemAvailable:\s+(\d+)\s+kB'){$available=[long]$Matches[1]*1024}
    }
    if($cached -lt 1e9 -and $available -lt 1e9){return @{Outcome='InsufficientReclaimableCache';Kind='PodmanCache';Machine=$Machine;CachedBytes=$cached;AvailableBytes=$available}}
    $drop=if($cached -ge 1e9){'sync; printf 3 > /proc/sys/vm/drop_caches; '}else{''}
    # WSL can retain freed but fragmented pages until CPU becomes idle.
    # Compaction lets page reporting return them without restarting the VM.
    $command="sudo -n sh -c '"+$drop+'if test -w /proc/sys/vm/compact_memory; then printf 1 > /proc/sys/vm/compact_memory; printf compacted; fi'+"'"
    $result=Invoke-MutatorNative podman @('machine','ssh',$Machine,$command) $script:MutatorRoot 120
    if($result.Outcome -ne 'Success'){throw 'Podman VM cache recovery failed.'}
    $compacted=$result.Stdout.Trim() -ceq 'compacted'
    $outcome=if($cached -ge 1e9){'CacheReclaimed'}elseif($compacted){'MemoryCompacted'}else{'InsufficientReclaimableCache'}
    @{Outcome=$outcome;Kind='PodmanCache';Machine=$Machine;CachedBytes=$cached;AvailableBytes=$available;Compacted=$compacted;Utc=[datetime]::UtcNow.ToString('O')}
}
