#requires -Version 7.6
param([string]$BaseImage,[Parameter(Mandatory)][string]$Connection)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
$modules=Split-Path $root
$proof=Join-Path $root ('test/Artifacts/development/linux-ag-mutation-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
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
$module=Join-Path $source 'FrenchExDev.Tools.Ag.PoSh'
# Force the validation platform only; mutation sources and complete test associations stay intact.
$recipe=Join-Path $module 'test/mutator.container.psd1'
[void][IO.Directory]::CreateDirectory((Split-Path $recipe))
Set-Content $recipe "@{Binary='ag';UseWhen='Always';PackageManager='apk';Packages=@('the_silver_searcher=2.2.0-r1')}"
$parameters=@{ModulePath=$module;SourceRoot=$source;RunRoot=(Join-Path $proof 'runs');ContainerConnection=$Connection;WorkerBudget=1;ThrottleLimit=1;Workers=1;MemoryBudgetMiB=2048;SkipStryker=$true;Background=$true}
if($BaseImage){$parameters.ContainerBaseImage=$BaseImage}
$run=Invoke-MutatorRun @parameters
@{Path=$run.Path;Proof=$proof;Outcome=$run.Outcome;Module='FrenchExDev.Tools.Ag.PoSh';Platform='Linux'}|ConvertTo-Json -Compress
