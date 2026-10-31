function New-MutatorSchedule {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Pure resource-plan factory; no process or resource is allocated by this function.')]
    [CmdletBinding()]
    param([string[]]$Packages, [Nullable[int]]$Workers, [int]$WorkerBudget = 4, [int]$ThrottleLimit = 2,
        [int]$MemoryBudgetMiB = 4096, [int]$MemoryPerWorkerMiB = 1024, [hashtable]$Durations = @{}, [switch]$Serial)
    if (!$Packages.Count -or $WorkerBudget -lt 1 -or $ThrottleLimit -lt 1 -or $MemoryPerWorkerMiB -lt 1 -or $MemoryBudgetMiB -lt $MemoryPerWorkerMiB) { throw 'Invalid or empty mutation resource plan.' }
    $budget = [math]::Min($WorkerBudget, [math]::Floor($MemoryBudgetMiB / $MemoryPerWorkerMiB))
    if ($Workers -gt $budget) { throw 'Requested mutation workers exceed the CPU/memory reservation budget.' }
    $slots = [math]::Min($Packages.Count, [math]::Min($ThrottleLimit, $budget))
    if ($Serial) { $slots = 1 }
    if ($Workers -gt 0) { $slots = [math]::Min($slots, [math]::Floor($budget / $Workers)); $effective = $Workers }
    else { $effective = [math]::Max(1, [math]::Floor($budget / $slots)) }
    $weighted=foreach($name in $Packages){[pscustomobject]@{Name=$name;Cost=$(if($Durations.ContainsKey($name)){-[double]$Durations[$name]}else{0})}}
    $ordered=@($weighted|Sort-Object Cost,Name|ForEach-Object Name)
    @{ Packages = $ordered; Slots = [int]$slots; Workers = [int]$effective; WorkerBudget = [int]$budget
        ReservedMemoryMiB = [int]($slots * $effective * $MemoryPerWorkerMiB); MemoryBudgetMiB = $MemoryBudgetMiB }
}
