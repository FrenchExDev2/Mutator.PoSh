#requires -Version 7.6
param([Parameter(Mandatory)][string]$Image,[Parameter(Mandatory)][string]$Connection)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
$modules=Split-Path $root
$proof=Join-Path $root ('test/Artifacts/development/windows-ag-mutation-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
$source=Join-Path $proof 'source'
$configuration=Get-Content (Join-Path $modules 'FrenchExDev.Tools.Ag.PoSh/test/psmutant.config.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$provenance=& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Modules,$Source,$Configuration)
    foreach($subtree in Get-MutatorSubtree $Modules $Configuration){
        $before=Get-MutatorSourceSnapshot (Join-Path $Modules $subtree)
        Copy-MutatorTree (Join-Path $Modules $subtree) (Join-Path $Source $subtree)
        $after=Get-MutatorSourceSnapshot (Join-Path $Source $subtree)
        if($before.Sha256 -cne $after.Sha256){throw 'A declared dependency changed during snapshotting.'}
        @{Module=$subtree;Sha256=$before.Sha256}
    }
} $modules $source $configuration
$provenance|ConvertTo-Json -Depth 5|Set-Content (Join-Path $proof 'source-provenance.json')
$run=Invoke-MutatorRun -ModulePath (Join-Path $source 'FrenchExDev.Tools.Ag.PoSh') -SourceRoot $source -RunRoot (Join-Path $proof 'runs') -WindowsGuestImage $Image -ContainerConnection $Connection -WorkerBudget 1 -ThrottleLimit 1 -Workers 1 -MemoryBudgetMiB 6144 -SkipStryker -Background
@{Path=$run.Path;Proof=$proof;Outcome=$run.Outcome;Module='FrenchExDev.Tools.Ag.PoSh';Platform='Windows'}|ConvertTo-Json -Compress
