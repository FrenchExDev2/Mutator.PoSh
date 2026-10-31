function Invoke-MutatorGuestValidation {
    <#
    .SYNOPSIS
    Submit the configured Ag job to an owned Windows guest.

    .DESCRIPTION
    Binds owner and fixture hash, validates returned gate evidence and retains a receipt. Does not
    qualify unrelated profiles.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path,[ValidateRange(1,120)][int]$TimeoutMinutes=20)
    $stored=Read-MutatorGuestRun $Path;$run=$stored.Run
    if($run.Kind -ne 'WindowsModule' -or $run.Module -cnotmatch '^FrenchExDev\.[A-Za-z0-9_.-]+\.Ag\.PoSh$'){throw 'Only the Ag Windows module qualification is currently configured.'}
    if(!$PSCmdlet.ShouldProcess($run.ContainerId,'Submit the staged Windows Ag qualification and retain its native/Pester reports')){return}
    $deadline=[datetimeoffset]::UtcNow.AddMinutes($TimeoutMinutes)
    do{
        $status=Get-MutatorGuestBase $Path
        if($status.Outcome -eq 'Failed'){throw ('Windows module provisioning failed: '+$status.Error)}
        if($status.Ready){break}
        if(!$status.Running -or [datetimeoffset]::UtcNow -ge $deadline){throw 'Windows module provisioning did not become ready in time.'}
        Start-Sleep -Seconds 3
    }while($true)
    $id=[guid]::NewGuid().ToString('N')
    $directory=Join-Path $run.Share ('jobs/'+$id)
    $fixture=Join-Path $run.Share 'mutator/modules/FrenchExDev.Mutator.PoSh/resources/containers/probes/Test-WindowsAgImage.ps1'
    Write-MutatorJson (Join-Path $directory 'request.json') @{RunId=$run.RunId;JobId=$id;Type='AgQualification';FixtureSha256=(Get-FileHash $fixture).Hash}
    $receipt=@{RunId=$run.RunId;JobId=$id;Path=$directory;Outcome='Running';ImageId=$run.ImageId}
    try{
        do{
            $result=Read-MutatorJson (Join-Path $directory 'result.json')
            if($result){break}
            $identity=Get-MutatorOwnedGuest $run
            if(!$identity.State.Running){throw 'The guest exited while the qualification was running.'}
            if([datetimeoffset]::UtcNow -ge $deadline){throw 'The Windows guest qualification timed out.'}
            Start-Sleep -Seconds 3
        }while($true)
        if($result.RunId -cne $run.RunId -or $result.JobId -cne $id -or $result.Outcome -cne 'Success' -or $result.ExitCode -ne 0){throw 'The Windows guest job failed or returned a foreign result; see retained guest logs.'}
        $report=Read-MutatorJson (Join-Path $directory 'qualification.json')
        if($report -isnot [Collections.IDictionary]){throw 'The Windows guest test gate was empty, skipped or failed.'}
        $counts=@{}
        foreach($field in @('Passed','Failed','Skipped','DiscoveryErrors')){
            [long]$count=0
            if(![long]::TryParse([string]$report[$field],[ref]$count) -or $count -lt 0){throw 'The Windows guest test gate contains an invalid counter.'}
            $counts[$field]=$count
        }
        if($counts.Passed -le 0 -or $counts.Failed -ne 0 -or $counts.Skipped -ne 0 -or $counts.DiscoveryErrors -ne 0){throw 'The Windows guest test gate was empty, skipped or failed.'}
        $receipt.Outcome='Success';$receipt.Passed=$counts.Passed;$receipt.AgVersion=$report.AgVersion;$receipt.Measurement=$report.Measurement
    }catch{$receipt.Outcome='Failed';$receipt.Error=$_.Exception.Message;throw}
    finally{Write-MutatorJson (Join-Path $directory 'validation-run.json') $receipt}
    [pscustomobject]$receipt
}
