#requires -Version 7.6
param([Parameter(Mandatory)][string]$Image,[string]$Connection='podman-frenchexdev-root',[switch]$Branches)
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Image,$Connection,$Branches)
    $proof=Join-Path $script:MutatorRoot ('test/Artifacts/development/devposh-linux-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $source=Join-Path $proof 'source'
    $provenance=@(foreach($name in @('FrenchExDev.DevPoSh.PoSh','FrenchExDev.Mutator.PoSh','QuietCliEcosystem/FrenchExDev.QuietCli.PoSh')){
        $from=Join-Path (Split-Path $script:MutatorRoot) $name
        $before=Get-MutatorSourceSnapshot $from
        Copy-MutatorTree $from (Join-Path $source $name)
        $after=Get-MutatorSourceSnapshot (Join-Path $source $name)
        if($before.Sha256 -cne $after.Sha256){throw 'A coverage dependency changed during snapshotting.'}
        @{Module=$name;Sha256=$before.Sha256}
    })
    Write-MutatorJson (Join-Path $proof 'provenance.json') $provenance
    $inspect=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$Image) -Directory $proof -Connection $Connection
    if($inspect.Outcome -ne 'Success'){throw 'The coverage image is unavailable.'}
    $built=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
    if($built.Os -cne 'linux' -or $built.Id -notmatch '^(sha256:)?[a-f0-9]{64}$'){throw 'An immutable Linux image is required.'}
    $name='mutator-devposh-coverage-'+[guid]::NewGuid().ToString('N')
    $containerRoot='/workspace/PoSh/FrenchExDev'
    $arguments=@('run','--rm','--name',$name,'--pull=never','--network=none','--memory','2048m','--memory-swap','2048m','--cpus','2',
        '--mount',('type=bind,source='+$source+',target='+$containerRoot),'--entrypoint','pwsh',$built.Id,'-NoProfile','-File',
        ($containerRoot+'/FrenchExDev.Mutator.PoSh/test/Invoke-Tests.ps1'),'-Path',($containerRoot+'/FrenchExDev.DevPoSh.PoSh/test/Unit'),
        '-CoverageModulePath',($containerRoot+'/FrenchExDev.DevPoSh.PoSh'),'-CoverageBreakpoints')
    if($Branches){
        $index=$arguments.IndexOf('-File')
        $arguments=@($arguments[0..$index])+@($containerRoot+'/FrenchExDev.Mutator.PoSh/test/Fixtures/DevPoShBranchCoverage.ps1')
    }
    $run=$null
    try{
        $run=Invoke-MutatorContainerCommand -Arguments $arguments -Directory $proof -Connection $Connection -TimeoutSeconds 900
        [IO.File]::WriteAllText((Join-Path $proof 'stdout.log'),$run.Stdout)
        [IO.File]::WriteAllText((Join-Path $proof 'stderr.log'),$run.Stderr)
        $lines=@($run.Stdout -split "`r?`n"|Where-Object {$_ -like '{*'})
        if(!$lines.Count){throw 'No structured Linux test summary was returned.'}
        $summary=$lines[-1]|ConvertFrom-Json -AsHashtable -DateKind String
        Write-MutatorJson (Join-Path $proof 'tests.json') $summary
        if($Branches){
            if($run.Outcome -ne 'Success' -or $summary.Metric -cne 'BranchOutcomes' -or !$summary.Passed -or !$summary.Proof.StartsWith(($containerRoot+'/'),[StringComparison]::Ordinal)){throw ('Linux branch validation failed; proof: '+$proof)}
            $report=Join-Path (Join-Path $source $summary.Proof.Substring($containerRoot.Length+1)) 'coverage.json'
            $receipt=@{TestOutcome='Success';NativeOutcome=$run.Outcome;ExitCode=$run.ExitCode;Summary=$summary;ImageId=$built.Id;Report=$report;Proof=$proof}
            Write-MutatorJson (Join-Path $proof 'receipt.json') $receipt
            @{TestOutcome='Success';Metric=$summary.Metric;Total=$summary.Total;Covered=$summary.Covered;Passed=$summary.Passed;Report=$report;Proof=$proof}|ConvertTo-Json -Depth 5 -Compress
            return
        }
        $reports=@(Get-ChildItem (Join-Path $source 'FrenchExDev.Mutator.PoSh/test/Artifacts/development') -Directory|Where-Object {Test-Path (Join-Path $_.FullName 'coverage.json')})
        if($reports.Count -ne 1 -or !$summary.Passed -or $summary.Failed -or $summary.Skipped -or $summary.DiscoveryErrors -or !$summary.SourceUnchanged){throw ('Linux tests or coverage failed; retained proof: '+$proof)}
        $receipt=@{TestOutcome='Success';NativeOutcome=$run.Outcome;ExitCode=$run.ExitCode;Summary=$summary;ImageId=$built.Id;Report=(Join-Path $reports[0].FullName 'coverage.json');Proof=$proof}
        Write-MutatorJson (Join-Path $proof 'receipt.json') $receipt
        @{TestOutcome='Success';Coverage=$summary.Coverage;Passed=$summary.Passed;Report=$receipt.Report;Proof=$proof}|ConvertTo-Json -Depth 6 -Compress
    }finally{
        if(!$run -or $run.Outcome -eq 'Timeout'){$null=Invoke-MutatorContainerCommand -Arguments @('rm','--force',$name) -Directory $proof -Connection $Connection}
    }
} $Image $Connection $Branches
