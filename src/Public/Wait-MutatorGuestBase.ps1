function Wait-MutatorGuestBase {
    <#
    .SYNOPSIS
    Poll preparation until readiness, failure or deadline.

    .DESCRIPTION
    Retains state and optionally stops when ready. Timeout stops the owned guest while preserving
    storage and proof.
    #>

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[ValidateRange(1,240)][int]$TimeoutMinutes=60,[switch]$StopWhenReady,[switch]$UI)
    $deadline=(Get-MutatorUtcNow).AddMinutes($TimeoutMinutes)
    while($true){
        $status=Get-MutatorGuestBase $Path
        $stored=Read-MutatorGuestRun $Path;Write-MutatorJson $stored.File $status
        if($UI){Write-Progress -Activity (Get-MutatorText 'Guest.Preparation') -Status ($status.Phase+' | '+$status.ElapsedSeconds+' s') -PercentComplete -1}
        if($status.Outcome -eq 'Failed'){
            if($StopWhenReady -and $status.Running){$null=Stop-MutatorGuestBase $Path}
            throw ('Windows base preparation failed: '+$status.Error)
        }
        if($status.Outcome -in @('Cancelled','TimedOut')){return $status}
        if($status.Ready){
            if($UI){Write-Progress -Activity (Get-MutatorText 'Guest.Preparation') -Completed}
            if($StopWhenReady){return Stop-MutatorGuestBase $Path}
            return $status
        }
        if((Get-MutatorUtcNow) -ge $deadline){
            $stopped=Stop-MutatorGuestBase $Path
            $stopped.Outcome='TimedOut';$stopped.Phase='TimedOut';Write-MutatorJson $stored.File $stopped
            throw 'Windows base preparation timed out; its stopped storage and reports are retained.'
        }
        Start-Sleep -Seconds 5
    }
}
