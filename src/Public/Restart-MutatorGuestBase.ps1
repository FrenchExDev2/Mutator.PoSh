function Restart-MutatorGuestBase {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    $stored=Read-MutatorGuestRun $Path;$run=$stored.Run
    $identity=Get-MutatorOwnedGuest $run
    if($identity.State.Running){throw 'The prepared guest is already running.'}
    if($run.Kind -eq 'WindowsModule'){
        $proof=Read-MutatorJson (Join-Path $run.Share 'mutator/module-ready.json')
        $valid=$proof -and $proof['Outcome'] -ceq 'Success' -and $proof['Module'] -ceq $run.Module -and $proof['Identity'] -ceq $run.PayloadIdentity -and $proof['BaseFingerprint'] -ceq $run.Fingerprint
    }else{
        $proof=Read-MutatorJson (Join-Path $run.Share 'base-ready.json')
        $valid=$proof -and (Test-MutatorGuestReadiness $run $proof)
    }
    if(!$valid){throw 'Only a verified prepared base or module can be restarted without reinstalling.'}
    if(!$PSCmdlet.ShouldProcess($run.ContainerId,'Restart the owned prepared Windows base using its retained storage')){return}
    $probe=Join-Path $run.Path ('restart-preflight-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    $null=Test-MutatorGuestHost -Image $run.ImageId -OutputDirectory $probe -Connection $run.Connection -MemoryMiB $run.MemoryMiB -DiskGiB $run.DiskGiB
    $active=Invoke-MutatorContainerCommand -Arguments @('ps','--filter','label=org.frenchexdev.mutator.guest=windows-base','--format','json') -Directory $script:MutatorRoot -Connection $run.Connection
    if($active.Outcome -ne 'Success' -or @($active.Stdout|ConvertFrom-Json -AsHashtable).Count){throw 'Another managed base is active or cannot be checked.'}
    Copy-Item -LiteralPath $stored.File -Destination (Join-Path $run.Path ('guest-before-restart-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'.json'))
    $run.Remove('CancelRequested');$run.Remove('Error')
    $run.Outcome='Running';$run.Phase='BootingPreparedBase';$run.RestartedUtc=[datetime]::UtcNow.ToString('O')
    Write-MutatorJson $stored.File $run
    $start=Invoke-MutatorContainerCommand -Arguments @('start',$run.ContainerId) -Directory $script:MutatorRoot -Connection $run.Connection
    if($start.Outcome -ne 'Success'){$run.Outcome='Failed';Write-MutatorJson $stored.File $run;throw 'The prepared guest could not be restarted.'}
    [pscustomobject]$run
}
