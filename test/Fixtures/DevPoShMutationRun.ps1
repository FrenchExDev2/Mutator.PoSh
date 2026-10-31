#requires -Version 7.6
param([ValidateRange(1,4)][int]$Workers=1,[switch]$Foreground)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
$proof=Join-Path $root ('test/Artifacts/development/devposh-mutation-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
$source=Join-Path $proof 'source'
$provenance=@(& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Destination)
    foreach($name in @('FrenchExDev.DevPoSh.PoSh','FrenchExDev.Mutator.PoSh','QuietCliEcosystem/FrenchExDev.QuietCli.PoSh')){
        $original=Join-Path (Split-Path $script:MutatorRoot) $name
        $before=Get-MutatorSourceSnapshot $original
        Copy-MutatorTree $original (Join-Path $Destination $name)
        $after=Get-MutatorSourceSnapshot (Join-Path $Destination $name)
        if($before.Sha256 -cne $after.Sha256){throw 'A mutation dependency changed during snapshotting.'}
        @{Module=$name;Sha256=$before.Sha256}
    }
} $source)
$provenance|ConvertTo-Json -Depth 4|Set-Content (Join-Path $proof 'provenance.json')
$run=Invoke-MutatorRun -ModulePath (Join-Path $source 'FrenchExDev.DevPoSh.PoSh') -SourceRoot $source -RunRoot (Join-Path $proof 'runs') `
    -Workers $Workers -WorkerBudget $Workers -ThrottleLimit 1 -MemoryBudgetMiB 4096 -SkipStryker -Background:(!$Foreground)
@{Outcome=$run.Outcome;Path=$run.Path;Proof=$proof;Workers=$Workers}|ConvertTo-Json -Compress
if($Foreground -and $run.Outcome -ne 'Success'){exit 1}
