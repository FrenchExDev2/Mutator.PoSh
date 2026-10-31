function Test-MutatorValidationStop {
    param([string]$ReportRoot,[string]$RunId)
    $path=Join-Path $ReportRoot 'stop.json'
    if(![IO.File]::Exists($path)){return $false}
    $request=Read-MutatorJson $path
    return [bool]($request -and $request['RunId'] -ceq $RunId)
}

function Stop-MutatorValidationMutation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private cooperative stop is covered by the validation run public ShouldProcess boundary.')]
    [CmdletBinding()]
    param([string]$RunPath,[string]$Destination,[string]$ValidationRunId,[ValidateRange(0,3600)][int]$TimeoutSeconds=60)
    $proof=@{Stopped=$false;ReportsCopied=$false;PartialReportAvailable=$false;Error=$null;RunPath=$RunPath}
    try{
        $null=Stop-MutatorRun -Path $RunPath
        $deadline=(Get-MutatorUtcNow).AddSeconds($TimeoutSeconds)
        do{
            $state=Get-MutatorRun -Path $RunPath
            $identities=@($state.Process)+@($state.Packages|ForEach-Object{$_['Process']})+@(Get-MutatorRunWorkerIdentity $RunPath)
            $active=@($identities|Where-Object{$_ -and (Test-MutatorProcess $_)}).Count -gt 0
            if(!$active -and $state.Outcome -notin @('Starting','Running')){
                $proof.Stopped=$true
                break
            }
            if((Get-MutatorUtcNow) -ge $deadline){throw 'The mutation child did not stop within the cooperative grace period; its sandbox is retained.'}
            Start-Sleep -Milliseconds 250
        }while($true)
        $null=Export-MutatorReport -Path $RunPath -RunId $ValidationRunId
        Copy-MutatorValidationMutationProof -RunPath $RunPath -Destination $Destination
        $proof.ReportsCopied=$true
        $proof.PartialReportAvailable=(Test-Path (Join-Path $Destination 'packages/p0000/mutation.json')) -or (Test-Path (Join-Path $Destination 'mutation.json'))
    }catch{$proof.Error=$_.Exception.Message}
    return $proof
}
function Assert-MutatorValidationActive {
    param([string]$ReportRoot,[string]$RunId)
    if(Test-MutatorValidationStop $ReportRoot $RunId){throw [OperationCanceledException]::new('The validation was stopped by its owner.')}
}