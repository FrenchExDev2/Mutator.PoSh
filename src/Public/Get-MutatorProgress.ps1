function Get-MutatorProgress {
    <#
    .SYNOPSIS
    Project retained state into an agent-friendly snapshot.

    .DESCRIPTION
    Includes mutation/recheck observations and runtime requirements. Reading progress starts or resumes
    no work.
    #>

    [CmdletBinding()]
    param([string]$Path,[string]$RunRoot)
    Get-MutatorRun @PSBoundParameters | Select-Object Id,Outcome,Mode,Platform,TargetOS,Isolation,ProcessedPackages,CompletedPackages,TotalPackages,CompletionPercent,FailedPackages,ErrorPercent,InterruptedPackages,EvaluatedMutants,PlannedMutants,SurvivedMutants,RecheckedMutants,RecheckKilledMutants,RecheckSurvivedMutants,RecheckScopeComplete,ActivePackages,Schedule,HostMemory,
        @{n='Active';e={@($_.Packages|Where-Object Outcome -EQ Running|Select-Object Name,Phase,ExecutionRuntime,RequiredRuntime,EvaluatedMutants,PlannedMutants)}},Error,Path
}
