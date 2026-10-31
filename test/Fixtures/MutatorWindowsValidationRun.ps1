#requires -Version 7.6
param([switch]$Coverage,[switch]$Branches)
$ErrorActionPreference='Stop'
if(!$IsWindows){throw 'This validation driver requires Windows; use the driver for the target platform.'}
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Coverage,$Branches)
    if($Coverage -and $Branches){throw 'Choose command coverage or branch instrumentation for a validation process.'}
    $proof=Join-Path $script:MutatorRoot ('test/Artifacts/development/mutator-windows-validation-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $source=Join-Path $proof 'source'
    $parent=Split-Path $script:MutatorRoot
    $config=Read-MutatorJson (Join-Path $script:MutatorRoot 'test/psmutant.config.json')
    $subtrees=@(Get-MutatorSubtree $parent $config)
    $before=@{}
    foreach($name in $subtrees){$before[$name]=Get-MutatorSourceSnapshot (Join-Path $parent $name)}
    foreach($name in $subtrees){Copy-MutatorTree (Join-Path $parent $name) (Join-Path $source $name)}
    $identities=@(foreach($name in $subtrees){
        $live=Get-MutatorSourceSnapshot (Join-Path $parent $name)
        $copy=Get-MutatorSourceSnapshot (Join-Path $source $name)
        @{Module=$name;Before=$before[$name].Sha256;After=$live.Sha256;Copy=$copy.Sha256
            Unchanged=($before[$name].Sha256 -ceq $live.Sha256 -and $live.Sha256 -ceq $copy.Sha256)}
    })
    Write-MutatorJson (Join-Path $proof 'provenance.json') $identities
    if(@($identities|Where-Object Unchanged -EQ $false).Count){throw ('Sources changed while freezing validation dependencies; proof: '+$proof)}
    $subject=Join-Path $source 'FrenchExDev.Mutator.PoSh'
    $arguments=if($Branches){@('-NoProfile','-File',(Join-Path $subject 'test/Fixtures/DevPoShBranchCoverage.ps1'),'-Module','FrenchExDev.Mutator.PoSh','-ProofDirectory',(Join-Path $proof 'branches'))}
        else{@('-NoProfile','-File',(Join-Path $subject 'test/Invoke-Tests.ps1'),'-Path',(Join-Path $subject 'test'))}
    if($Coverage){$arguments+=@('-CoverageModulePath',$subject,'-CoverageBreakpoints')}
    $run=Invoke-MutatorNative (Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})) $arguments $source 1200
    $lines=@($run.Stdout -split "`r?`n"|Where-Object {$_ -like '{*'})
    if(!$lines.Count){
        Write-MutatorJson (Join-Path $proof 'native-failure.json') $run.Failure
        throw ('Frozen validation returned no structured result; proof: '+$proof)
    }
    $tests=$lines[-1]|ConvertFrom-Json -AsHashtable
    if($Branches){
        $result=@{Outcome=$(if($run.Outcome -eq 'Success'){'Success'}else{'Failed'});Proof=$proof;Subject=$subject;Dependencies=$subtrees.Count;NativeOutcome=$run.Outcome;Branch=$tests}
        Write-MutatorJson (Join-Path $proof 'result.json') $result
        $result|ConvertTo-Json -Depth 8 -Compress
        if($run.Outcome -ne 'Success'){exit 1}
        return
    }
    $passed=$tests.Passed -gt 0 -and !$tests.Failed -and !$tests.Skipped -and !$tests.DiscoveryErrors -and $tests.SourceUnchanged
    $result=@{Outcome=$(if(!$passed){'Failed'}elseif($Coverage -and !$tests.Coverage.FullGateSatisfied){'CoverageIncomplete'}else{'Success'})
        Proof=$proof;Subject=$subject;Dependencies=$subtrees.Count;NativeOutcome=$run.Outcome;Tests=$tests}
    Write-MutatorJson (Join-Path $proof 'result.json') $result
    $result|ConvertTo-Json -Depth 8 -Compress
    if(!$passed -or ($Coverage -and !$tests.Coverage.FullGateSatisfied)){exit 1}
} ([bool]$Coverage) ([bool]$Branches)
