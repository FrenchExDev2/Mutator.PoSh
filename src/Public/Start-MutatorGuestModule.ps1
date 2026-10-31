function Start-MutatorGuestModule {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Image,[Parameter(Mandatory)][string]$OutputDirectory,[string]$Connection,[string]$ShareDirectory,
        [ValidateRange(2048,65536)][int]$MemoryMiB=6144,[ValidateRange(2048,64512)][int]$GuestMemoryMiB=4096,[ValidateRange(1,64)][int]$Cpus=2)
    if($MemoryMiB -lt $GuestMemoryMiB+1024){throw 'Reserve at least 1024 MiB above guest RAM.'}
    $output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    if(Test-Path (Join-Path $output 'guest.json')){throw 'Select a new module guest directory.'}
    $share=if($ShareDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ShareDirectory)}else{Join-Path $output 'share'}
    if(Test-Path $share){if(@(Get-ChildItem -LiteralPath $share -Force).Count){throw 'Select an empty guest share directory.'}}
    if(!$PSCmdlet.ShouldProcess($Image,'Stage an immutable module payload and start an isolated Windows overlay')){return}
    [void][IO.Directory]::CreateDirectory($output)
    $id=[guid]::NewGuid().ToString('N')
    $run=@{Kind='WindowsModule';SchemaVersion=1;RunId=$id;Path=$output;Image=$Image;Connection=$Connection;Outcome='Running';Phase='Staging';ContainerId=$null
        Container=('mutator-windows-module-'+$id.Substring(0,12));Volume=('mutator-module-storage-'+$id.Substring(0,12));Share=$share
        StartedUtc=[datetime]::UtcNow.ToString('O');MemoryMiB=$MemoryMiB;GuestMemoryMiB=$GuestMemoryMiB;Cpus=$Cpus;DiskGiB=64}
    $file=Join-Path $output 'guest.json';Write-MutatorJson $file $run
    $run.ContainerEngine=$script:MutatorContainerEngine
    $run.ContainerSetting=if($script:MutatorContainerSetting){@{}+$script:MutatorContainerSetting}else{Get-MutatorEngineSetting $script:MutatorContainerEngine}
    if(!$Connection){$Connection=$script:MutatorContainerConnection;$run.Connection=$Connection}
    try{
        $inspect=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$Image) -Directory $script:MutatorRoot -Connection $Connection
        if($inspect.Outcome -ne 'Success'){throw 'The module image is unavailable.'}
        $built=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
        $module=$built.Config.Labels['org.frenchexdev.mutator.module']
    if($built.Os -ne 'linux' -or $built.Id -notmatch '^(sha256:)?[a-f0-9]{64}$' -or $built.Config.Labels['org.frenchexdev.mutator.guest-os'] -cne 'windows' -or $module -cnotmatch '^FrenchExDev\.[A-Za-z0-9_.-]+\.PoSh$'){throw 'A dockurr FrenchExDev module image is required.'}
        $run.ImageId=$built.Id;$run.Module=$module;$run.Fingerprint=$built.Config.Labels['org.frenchexdev.mutator.fingerprint']
        $null=Test-MutatorGuestHost -Image $built.Id -OutputDirectory (Join-Path $output 'preflight') -Connection $Connection -MemoryMiB $MemoryMiB
        [void][IO.Directory]::CreateDirectory($run.Share)
        [void][IO.Directory]::CreateDirectory((Join-Path $run.Share 'jobs'))
        $copy=Invoke-MutatorContainerCommand -Arguments @('run','--rm','--memory','512m','--entrypoint','/bin/bash','--volume',($run.Share+':/out'),$built.Id,'-c','cp -r /shared/mutator /out/') -Directory $script:MutatorRoot -Connection $Connection -TimeoutSeconds 300
        if($copy.Outcome -ne 'Success'){throw 'The baked module payload could not be staged.'}
        $payload=Join-Path $run.Share 'mutator'
        $metadata=Read-MutatorJson (Join-Path $payload 'image.json')
        if($metadata.Module -cne $module -or $metadata.BaseFingerprint -cne $run.Fingerprint){throw 'The staged module metadata differs from the image.'}
        $run.PayloadIdentity=(Get-FileHash (Join-Path $payload 'image.json')).Hash+'-'+(Get-FileHash (Join-Path $payload 'tool-inputs.txt')).Hash
        Copy-MutatorTree $script:MutatorRoot (Join-Path $payload 'modules/FrenchExDev.Mutator.PoSh')
        $bootstrap=Join-Path $payload 'bootstrap'
        Move-Item -LiteralPath (Join-Path $bootstrap 'Install-ImageTool.ps1') -Destination (Join-Path $bootstrap 'Install-ImageTool.Original.ps1')
        Copy-Item (Join-Path $script:MutatorRoot 'resources/containers/jobs/Install-GuestModule.ps1') (Join-Path $bootstrap 'Install-ImageTool.ps1')
        Copy-Item (Join-Path $script:MutatorRoot 'resources/containers/jobs/Invoke-GuestJobs.ps1') $bootstrap
        foreach($name in @('Serve-GuestControl.ps1','Watch-GuestControl.ps1','Test-GuestControl.ps1','Invoke-GuestJobProcess.ps1')){Copy-Item (Join-Path $script:MutatorRoot ('resources/containers/jobs/'+$name)) $bootstrap}
        Write-MutatorJson (Join-Path $bootstrap 'guest-context.json') @{RunId=$id}
        $run.PayloadSha256=(Get-MutatorSourceSnapshot $payload).Sha256
        $label='org.frenchexdev.mutator.guest-run='+$id
        $volume=Invoke-MutatorContainerCommand -Arguments @('volume','create','--label',$label,$run.Volume) -Directory $script:MutatorRoot -Connection $Connection
        if($volume.Outcome -ne 'Success'){throw 'The module overlay volume could not be created.'}
        $create=Invoke-MutatorContainerCommand -Arguments @('create','--name',$run.Container,'--label',$label,'--label','org.frenchexdev.mutator.guest=windows-module',
            '--device','/dev/kvm','--device','/dev/net/tun','--cap-add','NET_ADMIN','--memory',($MemoryMiB.ToString()+'m'),'--memory-swap',($MemoryMiB.ToString()+'m'),'--cpus',$Cpus.ToString(),
            '--stop-timeout','120','--publish','127.0.0.1::8006','--env',('RAM_SIZE='+$GuestMemoryMiB+'M'),'--env',('CPU_CORES='+$Cpus),'--env','RAM_CHECK=N',
            '--volume',($run.Volume+':/storage'),'--volume',($run.Share+':/shared'),$built.Id) -Directory $script:MutatorRoot -Connection $Connection
        if($create.Outcome -ne 'Success' -or $create.Stdout.Trim() -notmatch '^[a-f0-9]{64}$'){throw 'The module guest could not be created.'}
        $run.ContainerId=$create.Stdout.Trim();Write-MutatorJson $file $run
        $start=Invoke-MutatorContainerCommand -Arguments @('start',$run.ContainerId) -Directory $script:MutatorRoot -Connection $Connection
        if($start.Outcome -ne 'Success'){throw 'The module guest could not start.'}
        $control=Invoke-MutatorContainerCommand -Arguments @('exec','--detach',$run.ContainerId,'pwsh','-NoLogo','-NoProfile','-File','/shared/mutator/bootstrap/Serve-GuestControl.ps1','-Root','/shared/jobs','-Owner',$id) -Directory $script:MutatorRoot -Connection $Connection
        if($control.Outcome -ne 'Success'){throw 'The owned guest cancellation endpoint could not start.'}
        $health=Invoke-MutatorContainerCommand -Arguments @('exec',$run.ContainerId,'pwsh','-NoLogo','-NoProfile','-File','/shared/mutator/bootstrap/Test-GuestControl.ps1','-Owner',$id) -Directory $script:MutatorRoot -Connection $Connection -TimeoutSeconds 60
        if($health.Outcome -ne 'Success'){throw 'The PowerShell guest cancellation endpoint failed its owner/runtime health check.'}
        $run.ControlTransport='ContainerHttp'
        $run.Phase='ProvisioningModule';Write-MutatorJson $file $run
    }catch{$run.Outcome='Failed';$run.Error=$_.Exception.Message;Write-MutatorJson $file $run;throw}
    [pscustomobject]$run
}
