#requires -Version 7.6
param([Parameter(Mandatory)][string]$BaseImage,[string]$Connection='podman-frenchexdev-root')
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($BaseImage,$Connection)
    $proof=Join-Path $script:MutatorRoot ('test/Artifacts/development/generated-node-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $source=Join-Path $proof 'source';$parent=Split-Path $script:MutatorRoot
    $names=@('FrenchExDev.Mutator.PoSh')+@(Get-MutatorContainerDependency (Join-Path $parent 'FrenchExDev.Tools.Npm.PoSh'))
    $identities=@(foreach($name in $names){
        $original=Join-Path $parent $name;$destination=Join-Path $source $name
        $before=Get-MutatorSourceSnapshot $original
        Copy-MutatorTree $original $destination
        $after=Get-MutatorSourceSnapshot $original;$copy=Get-MutatorSourceSnapshot $destination
        if($before.Sha256 -cne $after.Sha256 -or $after.Sha256 -cne $copy.Sha256){throw 'Node qualification sources changed while freezing.'}
        @{Module=$name;Sha256=$copy.Sha256}
    })
    Write-MutatorJson (Join-Path $proof 'provenance.json') $identities
    $build=New-MutatorContainerImage -ModulePath (Join-Path $source 'FrenchExDev.Tools.Npm.PoSh') -OutputDirectory (Join-Path $proof 'build') -BaseImage $BaseImage -Connection $Connection -Reuse
    $validation=Join-Path $proof 'validation';[void][IO.Directory]::CreateDirectory($validation)
    $fixture=Join-Path $source 'FrenchExDev.Mutator.PoSh/test/Fixtures'
    $testSupport=Join-Path $source 'FrenchExDev.Mutator.PoSh'
    $container='mutator-node-qualification-'+[guid]::NewGuid().ToString('N')
    $arguments=@('run','--rm','--name',$container,'--pull=never','--network=none','--memory','2048m','--memory-swap','2048m','--cpus','2',
        '--mount',('type=bind,source='+$validation+',target=/proof'),'--mount',('type=bind,source='+$fixture+',target=/validation,ro=true'),
        '--mount',('type=bind,source='+$testSupport+',target=/opt/mutator/modules/FrenchExDev.Mutator.PoSh,ro=true'),
        '--entrypoint','pwsh',$build.ImageId,'-NoProfile','-File','/validation/Test-GeneratedNodeImage.ps1')
    Write-MutatorJson (Join-Path $proof 'container.json') @{Name=$container;ImageId=$build.ImageId;Connection=$Connection;Arguments=$arguments;MemoryMiB=2048;Cpus=2}
    $run=Invoke-MutatorContainerCommand -Arguments $arguments -Directory $proof -Connection $Connection -TimeoutSeconds 600
    [IO.File]::WriteAllText((Join-Path $proof 'stdout.log'),$run.Stdout)
    [IO.File]::WriteAllText((Join-Path $proof 'stderr.log'),$run.Stderr)
    $result=@{Outcome=$run.Outcome;Proof=$proof;ImageId=$build.ImageId;Reused=$build.Reused;Network='None';MemoryMiB=2048;Cpus=2}
    if(Test-Path (Join-Path $validation 'qualification.json')){$result.Qualification=Read-MutatorJson (Join-Path $validation 'qualification.json')}
    else{$result.Failure=$run.Failure}
    Write-MutatorJson (Join-Path $proof 'result.json') $result
    $result|ConvertTo-Json -Depth 7 -Compress
    if($run.Outcome -ne 'Success'){exit 1}
} $BaseImage $Connection
