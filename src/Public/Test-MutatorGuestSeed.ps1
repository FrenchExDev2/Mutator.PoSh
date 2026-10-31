function Test-MutatorGuestSeed {
    <#
    .SYNOPSIS
    Verify independent qcow2 overlays against one immutable seed.

    .DESCRIPTION
    Uses controlled writes without booting Windows. Rejects stale proof or a foreign backing chain.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Image,[Parameter(Mandatory)][string]$OutputDirectory,[string]$Connection)
    $output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    if(Test-Path (Join-Path $output 'seed-test.json')){throw 'Select a new seed test directory to preserve prior evidence.'}
    if(!$PSCmdlet.ShouldProcess($Image,'Verify two isolated qcow2 overlays with a controlled test write, without booting Windows')){return}
    [void][IO.Directory]::CreateDirectory($output)
    $receipt=@{Outcome='Running';Image=$Image;Connection=$Connection;WindowsBooted=$false;Clones=@();StartedUtc=[datetime]::UtcNow.ToString('O')}
    try {
        $inspect=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$Image) -Directory $script:MutatorRoot -Connection $Connection
        if($inspect.Outcome -ne 'Success'){throw 'The prepared seed image cannot be inspected.'}
        $built=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
        if($built.Os -ne 'linux' -or $built.Id -notmatch '^(sha256:)?[a-f0-9]{64}$' -or $built.Config.Labels['org.frenchexdev.mutator.base'] -cne 'windows-seed'){throw 'An immutable Linux dockurr Windows seed image is required.'}
        $receipt.ImageId=$built.Id
        $probe=Join-Path $script:MutatorRoot 'resources/containers/probes/Test-GuestOverlay.sh'
        foreach($mode in @('writer','reader')){
            $id=[guid]::NewGuid().ToString('N')
            $volume='mutator-overlay-probe-'+$id.Substring(0,12)
            $share=Join-Path $output $mode;[void][IO.Directory]::CreateDirectory($share)
            $create=Invoke-MutatorContainerCommand -Arguments @('volume','create','--label',('org.frenchexdev.mutator.overlay-probe='+$id),$volume) -Directory $script:MutatorRoot -Connection $Connection
            if($create.Outcome -ne 'Success'){throw 'The isolated overlay test volume could not be created.'}
            $clone=@{Mode=$mode;Volume=$volume;RunId=$id;Share=$share;Outcome='Running'}
            $receipt.Clones+=@($clone)
            Write-MutatorJson (Join-Path $output 'seed-test.json') $receipt
            $run=Invoke-MutatorContainerCommand -Arguments @('run','--rm','--memory','512m','--memory-swap','512m','--cpus','2',
                '--env',('MUTATOR_OVERLAY_PROBE='+$mode),'--env',('MUTATOR_OVERLAY_RUN='+$id),'--volume',($volume+':/storage'),'--volume',($share+':/shared'),
                '--volume',($probe+':/run/entry.sh:ro'),$built.Id) -Directory $script:MutatorRoot -Connection $Connection -TimeoutSeconds 1800
            [IO.File]::WriteAllText((Join-Path $share 'container.stdout.log'),$run.Stdout)
            [IO.File]::WriteAllText((Join-Path $share 'container.stderr.log'),$run.Stderr)
            if($run.Outcome -ne 'Success'){throw ('The '+$mode+' overlay isolation probe failed; see retained logs.')}
            $proof=Read-MutatorJson (Join-Path $share 'overlay-proof.json')
            $disk=Read-MutatorJson (Join-Path $share 'disk-info.json')
            if(!$proof -or $proof.Outcome -ne 'Success' -or $proof.RunId -cne $id -or $proof.Mode -cne $mode -or
                $disk['format'] -cne 'qcow2' -or $disk['backing-filename'] -cne '/seed/storage/data.qcow2'){throw 'The expected isolated backing chain was not proven.'}
            $clone.Outcome='Success';$clone.OverlayBytes=$proof.OverlayBytes;$clone.Backing=$disk['backing-filename']
        }
        $receipt.Outcome='Success'
    } catch {$receipt.Outcome='Failed';$receipt.Error=$_.Exception.Message;throw}
    finally {$receipt.CompletedUtc=[datetime]::UtcNow.ToString('O');Write-MutatorJson (Join-Path $output 'seed-test.json') $receipt}
    [pscustomobject]$receipt
}
