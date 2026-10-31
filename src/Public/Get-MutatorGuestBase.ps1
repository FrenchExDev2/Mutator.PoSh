function Get-MutatorGuestBase {
    <#
    .SYNOPSIS
    Inspect owned guest state and readiness.

    .DESCRIPTION
    Combines retained proof with actual container state. Late readiness cannot override cancellation,
    failure or abnormal termination.
    #>

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $stored=Read-MutatorGuestRun $Path;$run=$stored.Run
    $run.Ready=$false
    $run.ElapsedSeconds=[math]::Round(([datetimeoffset]::UtcNow-[datetimeoffset]::Parse($run.StartedUtc)).TotalSeconds)
    if(!$run['ContainerId']){$run.Running=$false;return [pscustomobject]$run}
    $identity=Get-MutatorOwnedGuest $run
    $run.Running=[bool]$identity.State.Running
    if($run.Outcome -in @('Cancelled','TimedOut')){return [pscustomobject]$run}
    $logs=Invoke-MutatorContainerCommand -Arguments @('logs','--tail','20',$run.ContainerId) -Directory $script:MutatorRoot -Connection $run.Connection
    if($logs.Outcome -eq 'Success'){
        [IO.File]::WriteAllText((Join-Path $run.Path 'container-tail.log'),$logs.Stdout+$logs.Stderr)
        foreach($line in ($logs.Stdout+$logs.Stderr) -split "`n"){
            if($line -match '(?i)Downloading'){$run.Phase='DownloadingWindows'}
            elseif($line -match '(?i)Extracting'){$run.Phase='ExtractingWindows'}
            elseif($line -match '(?i)Booting|Booting Windows'){$run.Phase='InstallingWindows'}
        }
    }
    $moduleGuest=$run.Kind -eq 'WindowsModule'
    $proofRoot=if($moduleGuest){Join-Path $run.Share 'mutator'}else{$run.Share}
    $files=if($moduleGuest){@('module-failed.json','module-ready.json')}else{@('base-progress.json','guest-failed.json','base-ready.json')}
    foreach($name in $files){
        $file=Join-Path $proofRoot $name
        if(!(Test-Path -LiteralPath $file)){continue}
        # SMB publication may be in progress; a partial JSON file is not readiness.
        try {$proof=Read-MutatorJson $file}catch{continue}
        if($proof -isnot [Collections.IDictionary]){continue}
        if($name -eq 'base-progress.json'){$run.Phase=$proof.Stage}
        elseif($name -in @('guest-failed.json','module-failed.json')){$run.Outcome='Failed';$run.Phase='RuntimeFailed';$run.Error=$proof.Error}
        elseif($run.Outcome -eq 'Failed'){continue}
        elseif($moduleGuest){
            if($proof['Outcome'] -ceq 'Success' -and $proof['Module'] -ceq $run.Module -and $proof['Identity'] -ceq $run.PayloadIdentity -and $proof['BaseFingerprint'] -ceq $run.Fingerprint){$run.Ready=$true;$run.Phase='Ready'}
            else{$run.Outcome='Failed';$run.Phase='ReadinessRejected';$run.Error='The module readiness proof does not match the staged payload.'}
        }
        elseif(Test-MutatorGuestReadiness $run $proof){
            $run.Ready=$true;$run.Phase='Ready'
        }else{$run.Outcome='Failed';$run.Phase='ReadinessRejected';$run.Error='The guest readiness proof does not match the prepared base.'}
    }
    if(!$run.Running){
        $run.ExitCode=$identity.State.ExitCode
        if($run.Ready -and $run.Outcome -ne 'Failed' -and $identity.State.ExitCode -eq 0 -and !$identity.State['OOMKilled']){$run.Outcome='Success';$run.Phase='Stopped'}
        elseif($run.Ready){$run.Outcome='Failed';$run.Phase='ShutdownUnverified';$run.Error='The prepared guest stopped without a verified clean exit.'}
        elseif($run['CancelRequested'] -and $run.Outcome -ne 'Failed' -and !$identity.State['OOMKilled']){$run.Outcome='Cancelled';$run.Phase='Stopped'}
        elseif($run.Outcome -ne 'Failed'){$run.Outcome='Failed';$run.Phase='ExitedBeforeReady';$run.Error='The guest exited before clean verified readiness (exit '+$identity.State.ExitCode+').'}
    }
    if($identity.Contains('NetworkSettings') -and $identity.NetworkSettings['Ports'] -and $identity.NetworkSettings.Ports['8006/tcp']){
        $port=@($identity.NetworkSettings.Ports['8006/tcp'])[0]['HostPort'];$run.WebUrl='http://127.0.0.1:'+$port
    }
    [pscustomobject]$run
}
