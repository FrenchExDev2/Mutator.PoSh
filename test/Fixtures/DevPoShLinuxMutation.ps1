#requires -Version 7.6
param([Parameter(Mandatory)][string]$Image,[string]$Connection='podman-frenchexdev-root',[switch]$Background)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Image,$Connection,$Background)
    $proof=Join-Path $script:MutatorRoot ('test/Artifacts/development/devposh-linux-mutation-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $source=Join-Path $proof 'source'
    foreach($name in @('FrenchExDev.DevPoSh.PoSh','FrenchExDev.Mutator.PoSh','QuietCliEcosystem/FrenchExDev.QuietCli.PoSh')){
        $original=Join-Path (Split-Path $script:MutatorRoot) $name
        $before=Get-MutatorSourceSnapshot $original
        Copy-MutatorTree $original (Join-Path $source $name)
        if($before.Sha256 -cne (Get-MutatorSourceSnapshot (Join-Path $source $name)).Sha256){throw 'A Linux mutation dependency changed during snapshotting.'}
    }
    $inspect=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$Image) -Directory $proof -Connection $Connection
    if($inspect.Outcome -ne 'Success'){throw 'The pinned Linux mutation image is unavailable.'}
    $built=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
    if($built.Os -cne 'linux' -or $built.Id -notmatch '^(sha256:)?[a-f0-9]{64}$'){throw 'A verified immutable Linux image is required.'}
    $name='mutator-devposh-mutation-'+[guid]::NewGuid().ToString('N')
    $containerRoot='/workspace/PoSh/FrenchExDev'
    $arguments=@('run','--rm','--name',$name,'--pull=never','--network=none','--memory','2048m','--memory-swap','2048m','--cpus','2',
        '--mount',('type=bind,source='+$source+',target='+$containerRoot),'--entrypoint','pwsh',$built.Id,'-NoProfile','-File',
        ($containerRoot+'/FrenchExDev.Mutator.PoSh/test/Fixtures/DevPoShMutationRun.ps1'),'-Workers','1','-Foreground')
    if($Background){$arguments=@('run','--detach')+$arguments[1..($arguments.Count-1)]}
    Write-MutatorJson (Join-Path $proof 'container.json') @{Name=$name;ImageId=$built.Id;Connection=$Connection;MemoryMiB=2048;Cpus=2;Arguments=$arguments}
    $run=$null
    try{
        $run=Invoke-MutatorContainerCommand -Arguments $arguments -Directory $proof -Connection $Connection -TimeoutSeconds 10800
        if($Background){
            $containerId=$run.Stdout.Trim()
            if($run.Outcome -ne 'Success' -or $containerId -cnotmatch '^[a-f0-9]{64}$'){
                Write-MutatorJson (Join-Path $proof 'launch-failure.json') $run.Failure
                throw ('Detached Linux mutation did not start; proof: '+$proof)
            }
            $receipt=@{Outcome='Running';NativeOutcome=$run.Outcome;Proof=$proof;ContainerId=$containerId;ContainerName=$name;ImageId=$built.Id;Connection=$Connection;Source=$source}
            Write-MutatorJson (Join-Path $proof 'receipt.json') $receipt
            $receipt|ConvertTo-Json -Depth 5 -Compress
            return
        }
        [IO.File]::WriteAllText((Join-Path $proof 'stdout.log'),$run.Stdout)
        [IO.File]::WriteAllText((Join-Path $proof 'stderr.log'),$run.Stderr)
        $lines=@($run.Stdout -split "`r?`n"|Where-Object {$_ -like '{*'})
        if(!$lines.Count){throw ('No structured Linux mutation result; proof: '+$proof)}
        $summary=$lines[-1]|ConvertFrom-Json -AsHashtable
        if(!$summary.Path.StartsWith(($containerRoot+'/'),[StringComparison]::Ordinal)){throw 'The Linux mutation run escaped its source mount.'}
        $path=Join-Path $source $summary.Path.Substring($containerRoot.Length+1)
        $package=Read-MutatorJson (Join-Path $path 'packages/p0000/state.json')
        $receipt=@{Outcome=$summary.Outcome;NativeOutcome=$run.Outcome;ExitCode=$run.ExitCode;Proof=$proof;Run=$path;ImageId=$built.Id;PSMutant=$package.PSMutant;Failure=$run.Failure}
        Write-MutatorJson (Join-Path $proof 'receipt.json') $receipt
        @{Outcome=$receipt.Outcome;NativeOutcome=$receipt.NativeOutcome;Proof=$proof;Run=$path;PSMutant=$package.PSMutant}|ConvertTo-Json -Depth 6 -Compress
    }finally{
        if(!$run -or $run.Outcome -eq 'Timeout' -or ($run.Failure -and $run.Failure.Error.Code -eq 'ExecutionFailed')){
            $null=Invoke-MutatorContainerCommand -Arguments @('rm','--force',$name) -Directory $proof -Connection $Connection
        }
    }
} $Image $Connection ([bool]$Background)
