function Start-MutatorLeasedWorker {
    <#
    .SYNOPSIS
    Reserve shared workers and memory before starting a package.

    .DESCRIPTION
    Locks pool updates, drops dead leases and refreshes idle policy. Returns no worker when the lock or
    capacity is unavailable.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private launcher runs only after Invoke-MutatorRun has approved its single ShouldProcess boundary.')]
    [CmdletBinding()]
    param([string]$RunDirectory,[string]$Package,[Collections.IDictionary]$Schedule)
    $root=Split-Path $RunDirectory
    $lockPath=Join-Path $root 'resources.lock'
    $lock=$null
    try {
        try {$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{return $null}
        $path=Join-Path $root 'resources.json'
        $pool=Read-MutatorJson $path
        if(!$pool){$pool=@{WorkerBudget=$Schedule.WorkerBudget;MemoryBudgetMiB=$Schedule.MemoryBudgetMiB;Leases=@()}}
        $live=@($pool.Leases|Where-Object{Test-MutatorProcess $_.Process})
        # An idle pool must not retain a previous run's smaller policy forever.
        if(!$live.Count){$pool.WorkerBudget=$Schedule.WorkerBudget;$pool.MemoryBudgetMiB=$Schedule.MemoryBudgetMiB}
        $workers=0; $memory=0
        foreach($lease in $live){$workers+=$lease.Workers;$memory+=$lease.ReservedMemoryMiB}
        $reservation=[int]($Schedule.ReservedMemoryMiB/$Schedule.Slots)
        if($Schedule.Workers -gt $Schedule.WorkerBudget -or $reservation -gt $Schedule.MemoryBudgetMiB){throw 'The package reservation exceeds its own worker or memory budget.'}
        if($workers+$Schedule.Workers -gt $pool.WorkerBudget -or $memory+$reservation -gt $pool.MemoryBudgetMiB){return $null}
        $process=Start-MutatorWorker $RunDirectory $Package
        $pool.Leases=$live+@(@{Run=$RunDirectory;Package=$Package;Process=$process;Workers=$Schedule.Workers;ReservedMemoryMiB=$reservation})
        Write-MutatorJson $path $pool
        $process
    } finally {if($lock){$lock.Dispose()}}
}
