function Stop-MutatorGuestBase {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    $stored=Read-MutatorGuestRun $Path;$run=$stored.Run
    $identity=Get-MutatorOwnedGuest $run
    if(!$PSCmdlet.ShouldProcess($run.ContainerId,'Request graceful shutdown of the owned Windows guest and retain its storage')){return}
    $run.CancelRequested=$true;Write-MutatorJson $stored.File $run
    if($identity.State.Running){
        $before=Get-MutatorGuestBase $Path
        if($before.Ready){
            $code=[IO.File]::ReadAllText((Join-Path $script:MutatorRoot 'resources/containers/probes/Poweroff-Guest.py'))
            $stop=Invoke-MutatorContainerCommand -Arguments @('exec',$run.ContainerId,'python3','-c',$code) -Directory $script:MutatorRoot -Connection $run.Connection
            if($stop.Outcome -ne 'Success'){throw 'The guest ACPI shutdown request failed; do not export it.'}
            $deadline=[datetimeoffset]::UtcNow.AddMinutes(3)
            do {
                $identity=Get-MutatorOwnedGuest $run
                if(!$identity.State.Running){break}
                if([datetimeoffset]::UtcNow -ge $deadline){throw 'The guest did not power off after ACPI; storage is retained and export is refused.'}
                Start-Sleep -Seconds 3
            } while($true)
        }else{
            $stop=Invoke-MutatorContainerCommand -Arguments @('stop','--time','120',$run.ContainerId) -Directory $script:MutatorRoot -Connection $run.Connection -TimeoutSeconds 180
            if($stop.Outcome -ne 'Success'){throw 'The owned Windows guest did not stop cleanly; do not export it.'}
        }
    }
    $status=Get-MutatorGuestBase $Path
    if(!$status.Ready -and $status.Outcome -ne 'Failed'){$status.Outcome='Cancelled';$status.Phase='Stopped'}
    Write-MutatorJson $stored.File $status
    $status
}
