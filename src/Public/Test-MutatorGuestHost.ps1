function Test-MutatorGuestHost {
    <#
    .SYNOPSIS
    Probe KVM/resources without booting a guest OS.

    .DESCRIPTION
    Checks capabilities and available memory/disk, retaining measured proof. Exit zero alone is
    insufficient.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Image,[Parameter(Mandatory)][string]$OutputDirectory,[string]$Connection,
        [ValidateRange(2048,65536)][int]$MemoryMiB=6144,[ValidateRange(32,1024)][int]$DiskGiB=64)
    if(!$PSCmdlet.ShouldProcess($Image,'Probe KVM, cgroup limits and available guest resources without booting an operating system')){return}
    $output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    [void][IO.Directory]::CreateDirectory($output)
    $proof=@{Outcome='Running';Image=$Image;Connection=$Connection;Utc=[datetime]::UtcNow.ToString('O');RequiredMemoryMiB=$MemoryMiB;RequiredDiskGiB=$DiskGiB}
    try {
        $info=Invoke-MutatorContainerCommand -Arguments @('info','--format','json') -Directory $script:MutatorRoot -Connection $Connection
        if($info.Outcome -ne 'Success'){throw ($script:MutatorContainerEngine+' host inspection failed.')}
        $hostInfo=($info.Stdout|ConvertFrom-Json -AsHashtable).host
        if($hostInfo.cgroupControllers -notcontains 'memory' -or $hostInfo.cgroupControllers -notcontains 'cpu'){throw 'The selected connection does not provide memory and CPU controls.'}
        $probe=Join-Path $script:MutatorRoot 'resources/containers/probes/Test-Kvm.sh'
        $run=Invoke-MutatorContainerCommand -Arguments @('run','--rm','--read-only','--memory','512m','--memory-swap','512m','--cpus','1',
            '--device','/dev/kvm','--device','/dev/net/tun','--volume',($probe+':/probe.sh:ro'),'--entrypoint','/bin/bash',$Image,'/probe.sh') -Directory $script:MutatorRoot -Connection $Connection
        [IO.File]::WriteAllText((Join-Path $output 'probe.stdout.log'),$run.Stdout)
        [IO.File]::WriteAllText((Join-Path $output 'probe.stderr.log'),$run.Stderr)
        if($run.Outcome -ne 'Success'){throw 'The KVM device/QEMU probe failed; see retained probe logs.'}
        $enabled=$false
        foreach($line in $run.Stdout -split "`n"){
            $line=$line.Trim()
            if($line -match '^(MemoryMaxBytes|DiskFreeKiB|VMAvailableKiB)=(\d+)$'){$proof[$Matches[1]]=[long]$Matches[2]}
            elseif($line.StartsWith('{')){
                $reply=$line|ConvertFrom-Json -AsHashtable
                if($reply['id'] -eq 'mutator-kvm'){$enabled=($reply['return']['enabled'] -eq $true -and $reply['return']['present'] -eq $true)}
            }
        }
        if(!$enabled -or $proof['MemoryMaxBytes'] -ne 512MB){throw 'KVM acceleration or the actual probe memory limit was not proven.'}
        if($proof['DiskFreeKiB'] -lt ([long]$DiskGiB*1MB)){throw ('Insufficient '+$script:MutatorContainerEngine+' storage for the requested guest disk.')}
        if($proof['VMAvailableKiB'] -lt ([long]$MemoryMiB*1024)){throw ('Insufficient available memory in the '+$script:MutatorContainerEngine+' host.')}
        $proof.KvmEnabled=$true;$proof.Outcome='Success'
    } catch {$proof.Outcome='Failed';$proof.Error=$_.Exception.Message;throw}
    finally {Write-MutatorJson (Join-Path $output 'preflight.json') $proof}
    [pscustomobject]$proof
}
