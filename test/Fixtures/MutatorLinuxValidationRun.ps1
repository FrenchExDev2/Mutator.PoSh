#requires -Version 7.6
param([Parameter(Mandatory)][string]$Image,[string]$Connection='podman-frenchexdev-root',[switch]$Branches)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Image,$Connection,$Branches)
    $proof=Join-Path $script:MutatorRoot ('test/Artifacts/development/mutator-linux-validation-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $source=Join-Path $proof 'source'
    $parent=Split-Path $script:MutatorRoot
    $configuration=Read-MutatorJson (Join-Path $script:MutatorRoot 'test/psmutant.config.json')
    $modules=@(Get-MutatorSubtree $parent $configuration)
    $before=@{}
    foreach($module in $modules){$before[$module]=Get-MutatorSourceSnapshot (Join-Path $parent $module)}
    foreach($module in $modules){Copy-MutatorTree (Join-Path $parent $module) (Join-Path $source $module)}
    $identities=@(foreach($module in $modules){
        $live=Get-MutatorSourceSnapshot (Join-Path $parent $module)
        $frozen=Get-MutatorSourceSnapshot (Join-Path $source $module)
        @{Module=$module;Before=$before[$module].Sha256;After=$live.Sha256;Copy=$frozen.Sha256
            Unchanged=($before[$module].Sha256 -ceq $live.Sha256 -and $live.Sha256 -ceq $frozen.Sha256)}
    })
    Write-MutatorJson (Join-Path $proof 'provenance.json') $identities
    if(@($identities|Where-Object Unchanged -EQ $false).Count){throw ('Linux validation sources changed while freezing; proof: '+$proof)}
    $inspect=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$Image) -Directory $proof -Connection $Connection
    if($inspect.Outcome -cne 'Success'){throw 'The pinned Linux validation image is unavailable.'}
    $built=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
    if($built.Os -cne 'linux' -or $built.Id -notmatch '^(sha256:)?[a-f0-9]{64}$'){throw 'An immutable Linux image is required.'}
    $container='mutator-linux-validation-'+[guid]::NewGuid().ToString('N')
    $mount='/workspace/PoSh/FrenchExDev'
    $subject=$mount+'/FrenchExDev.Mutator.PoSh'
    $arguments=@('run','--rm','--name',$container,'--pull=never','--network=none','--memory','2048m','--memory-swap','2048m','--cpus','2',
        '--mount',('type=bind,source='+$source+',target='+$mount),'--entrypoint','pwsh',$built.Id,'-NoProfile','-File')
    if($Branches){$arguments+=@(($subject+'/test/Fixtures/DevPoShBranchCoverage.ps1'),'-Module','FrenchExDev.Mutator.PoSh','-ProofDirectory',($mount+'/FrenchExDev.Mutator.PoSh/test/Artifacts/branches'))}
    else{$arguments+=@(($subject+'/test/Invoke-Tests.ps1'),'-Path',($subject+'/test'),'-CoverageModulePath',$subject,'-CoverageBreakpoints')}
    Write-MutatorJson (Join-Path $proof 'container.json') @{Name=$container;ImageId=$built.Id;Connection=$Connection;MemoryMiB=2048;Cpus=2;Arguments=$arguments}
    $run=$null
    try {
        $run=Invoke-MutatorContainerCommand -Arguments $arguments -Directory $proof -Connection $Connection -TimeoutSeconds 1500
        [IO.File]::WriteAllText((Join-Path $proof 'stdout.log'),$run.Stdout)
        [IO.File]::WriteAllText((Join-Path $proof 'stderr.log'),$run.Stderr)
        $lines=@($run.Stdout -split "`r?`n"|Where-Object {$_ -like '{*'})
        if(!$lines.Count){Write-MutatorJson (Join-Path $proof 'native-failure.json') $run.Failure;throw ('Linux validation returned no structured result; proof: '+$proof)}
        $summary=$lines[-1]|ConvertFrom-Json -AsHashtable -DateKind String
        $passed=if($Branches){$run.Outcome -ceq 'Success' -and $summary.Metric -ceq 'BranchOutcomes' -and $summary.Passed -gt 0}
            else{$summary.Passed -gt 0 -and !$summary.Failed -and !$summary.Skipped -and !$summary.DiscoveryErrors -and $summary.SourceUnchanged}
        $result=@{Outcome=$(if(!$passed){'Failed'}elseif(!$Branches -and !$summary.Coverage.FullGateSatisfied){'CoverageIncomplete'}else{'Success'})
            Proof=$proof;Source=$source;Dependencies=$modules.Count;ImageId=$built.Id;NativeOutcome=$run.Outcome;Summary=$summary;Branches=[bool]$Branches}
        Write-MutatorJson (Join-Path $proof 'result.json') $result
        $result|ConvertTo-Json -Depth 8 -Compress
        if(!$passed -or (!$Branches -and !$summary.Coverage.FullGateSatisfied)){exit 1}
    } finally {
        if(!$run -or $run.Outcome -ceq 'Timeout'){$null=Invoke-MutatorContainerCommand -Arguments @('rm','--force',$container) -Directory $proof -Connection $Connection}
    }
} $Image $Connection ([bool]$Branches)
