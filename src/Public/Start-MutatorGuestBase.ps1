function Start-MutatorGuestBase {
    <#
    .SYNOPSIS
    Prepare an owned guest after host/image checks.

    .DESCRIPTION
    Retains identity and isolated storage, with explicit resume of stopped preparation. Keeps failure
    evidence and disks.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$ModuleRoot,[Parameter(Mandatory)][string]$Image,[Parameter(Mandatory)][string]$OutputDirectory,[string]$Connection,[string]$ResumeFrom,
        [ValidateRange(2048,65536)][int]$MemoryMiB=6144,[ValidateRange(2048,64512)][int]$GuestMemoryMiB=4096,
        [ValidateRange(1,64)][int]$Cpus=2,[ValidateRange(32,1024)][int]$DiskGiB=64)
    if($MemoryMiB -lt $GuestMemoryMiB+1024){throw 'Reserve at least 1024 MiB above guest RAM for QEMU and container services.'}
    $root=(Resolve-Path -LiteralPath $ModuleRoot -ErrorAction Stop).ProviderPath
    $definition=Get-MutatorContainerRuntime $root
    $output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    if(Test-Path (Join-Path $output 'guest.json')){throw 'Select a new guest output directory; existing storage is never reused implicitly.'}
    if(!$PSCmdlet.ShouldProcess($Image,'Create isolated Windows base storage and start one dockurr guest')){return}
    [void][IO.Directory]::CreateDirectory($output)
    $id=[guid]::NewGuid().ToString('N')
    $run=@{SchemaVersion=1;Kind='WindowsBase';RunId=$id;Path=$output;Image=$Image;ModuleRoot=$root;Connection=$Connection;Fingerprint=$definition.Fingerprint
        Container=('mutator-windows-base-'+$id.Substring(0,12));Volume=('mutator-windows-storage-'+$id.Substring(0,12));ContainerId=$null
        Share=(Join-Path $output 'share');Outcome='Running';Phase='Preflight';StartedUtc=[datetime]::UtcNow.ToString('O')
        ExpectedPowerShell=$definition.Runtime.Version;ExpectedDotnetSdk=$definition.Versions.Windows['dotnet-sdk']
        MemoryMiB=$MemoryMiB;GuestMemoryMiB=$GuestMemoryMiB;Cpus=$Cpus;DiskGiB=$DiskGiB}
    $file=Join-Path $output 'guest.json';Write-MutatorJson $file $run
    $run.ContainerEngine=$script:MutatorContainerEngine
    $run.ContainerSetting=if($script:MutatorContainerSetting){@{}+$script:MutatorContainerSetting}else{Get-MutatorEngineSetting $script:MutatorContainerEngine}
    if(!$Connection){$Connection=$script:MutatorContainerConnection;$run.Connection=$Connection}
    try {
        $inspect=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$Image) -Directory $root -Connection $Connection
        if($inspect.Outcome -ne 'Success'){throw 'The Windows bootstrap image is not available locally.'}
        $built=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
        if($built.Os -ne 'linux' -or $built.Id -notmatch '^(sha256:)?[a-f0-9]{64}$' -or $built.Config.Labels['org.frenchexdev.mutator.base'] -cne 'windows' -or
            $built.Config.Labels['org.frenchexdev.mutator.fingerprint'] -cne $definition.Fingerprint){throw 'The image does not match the current Windows bootstrap definition.'}
        $run.ImageId=$built.Id
        $null=Test-MutatorGuestHost -Image $built.Id -OutputDirectory (Join-Path $output 'preflight') -Connection $Connection -MemoryMiB $MemoryMiB -DiskGiB $DiskGiB
        $active=Invoke-MutatorContainerCommand -Arguments @('ps','--filter','label=org.frenchexdev.mutator.guest=windows-base','--format','json') -Directory $root -Connection $Connection
        if($active.Outcome -ne 'Success' -or @($active.Stdout|ConvertFrom-Json -AsHashtable).Count){throw 'Another managed Windows base is active, or its state could not be checked.'}
        [void][IO.Directory]::CreateDirectory($run.Share)
        $label='org.frenchexdev.mutator.guest-run='+$id
        if($ResumeFrom){
            $previous=(Read-MutatorGuestRun $ResumeFrom).Run
            $previousEngine=if($previous['ContainerEngine']){$previous.ContainerEngine}else{'Podman'}
            if($previousEngine -cne $run.ContainerEngine){throw 'Resume requires the same container engine as the retained guest.'}
            $old=Get-MutatorOwnedGuest $previous
            if($old.State.Running -or $previous.Fingerprint -cne $definition.Fingerprint -or $previous.Connection -cne $Connection){throw 'Resume requires a stopped guest with the same connection and base fingerprint.'}
            if(Test-Path (Join-Path $previous.Share 'base-ready.json')){throw 'A prepared base must be exported; do not resume its installation.'}
            $volume=Invoke-MutatorContainerCommand -Arguments @('volume','inspect',$previous.Volume) -Directory $root -Connection $Connection
            if($volume.Outcome -ne 'Success'){throw 'The retained guest storage cannot be inspected.'}
            $owned=@($volume.Stdout|ConvertFrom-Json -AsHashtable)[0]
            $owner=if($previous['VolumeOwnerRunId']){$previous.VolumeOwnerRunId}else{$previous.RunId}
            if($owned.Labels['org.frenchexdev.mutator.guest-run'] -cne $owner){throw 'The retained storage does not belong to this guest run.'}
            $run.Volume=$previous.Volume;$run.VolumeOwnerRunId=$owner;$run.ResumeFrom=$previous.Path
        }else{
            $volume=Invoke-MutatorContainerCommand -Arguments @('volume','create','--label',$label,$run.Volume) -Directory $root -Connection $Connection
            if($volume.Outcome -ne 'Success'){throw 'The isolated guest storage volume could not be created.'}
        }
        $create=Invoke-MutatorContainerCommand -Arguments @('create','--name',$run.Container,'--label',$label,'--label','org.frenchexdev.mutator.guest=windows-base',
            '--device','/dev/kvm','--device','/dev/net/tun','--cap-add','NET_ADMIN','--memory',($MemoryMiB.ToString()+'m'),'--memory-swap',($MemoryMiB.ToString()+'m'),
            '--cpus',$Cpus.ToString(),'--stop-timeout','120','--publish','127.0.0.1::8006',
            '--env','VERSION=2025','--env',('RAM_SIZE='+$GuestMemoryMiB+'M'),'--env',('CPU_CORES='+$Cpus),'--env',('DISK_SIZE='+$DiskGiB+'G'),'--env','DISK_FMT=qcow2','--env','RAM_CHECK=N',
            '--volume',($run.Volume+':/storage'),'--volume',($run.Share+':/shared'),$built.Id) -Directory $root -Connection $Connection
        if($create.Outcome -ne 'Success' -or $create.Stdout.Trim() -notmatch '^[a-f0-9]{64}$'){throw 'The owned Windows guest container could not be created.'}
        $run.ContainerId=$create.Stdout.Trim();$run.Phase='Created';Write-MutatorJson $file $run
        $start=Invoke-MutatorContainerCommand -Arguments @('start',$run.ContainerId) -Directory $root -Connection $Connection
        if($start.Outcome -ne 'Success'){throw 'Windows guest startup failed; the owned container and volume are retained.'}
        $run.Phase='InstallingWindows';Write-MutatorJson $file $run
    } catch {$run.Outcome='Failed';$run.Error=$_.Exception.Message;Write-MutatorJson $file $run;throw}
    [pscustomobject]$run
}
