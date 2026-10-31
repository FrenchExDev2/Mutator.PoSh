#requires -Version 7.6
param([Parameter(Mandatory)][string]$Image,[Parameter(Mandatory)][string]$Connection)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
$proof=Join-Path $root ('test/Artifacts/development/windows-resume-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
[void][IO.Directory]::CreateDirectory($proof)
$receipt=@{Outcome='Running';StartedUtc=[datetime]::UtcNow.ToString('O');InterruptedRun=$null;ResumedRun=$null;Error=$null}
$active=$null
try{
    $launch=& (Join-Path $PSScriptRoot 'WindowsMutationSmoke.ps1') -Image $Image -Connection $Connection -DelaySeconds 3 -Functions 8 | ConvertFrom-Json -AsHashtable -DateKind String
    $active=$launch.Path;$receipt.InterruptedRun=$active
    $deadline=[datetimeoffset]::UtcNow.AddMinutes(15)
    do{
        $run=Get-MutatorRun $active
        if($run.Outcome -notin @('Running','Starting')){throw ('The interruption fixture finished before its stop point: '+$run.Outcome)}
        if($run.EvaluatedMutants -gt 0 -and $run.PlannedMutants -gt $run.EvaluatedMutants){break}
        if([datetimeoffset]::UtcNow -ge $deadline){throw 'No interruptible mutation progress appeared.'}
        Start-Sleep -Seconds 1
    }while($true)
    $receipt.StopAtEvaluated=$run.EvaluatedMutants;$receipt.Planned=$run.PlannedMutants
    $null=Stop-MutatorRun $active
    do{
        $run=Get-MutatorRun $active
        if($run.Outcome -notin @('Running','Starting')){break}
        if([datetimeoffset]::UtcNow -ge $deadline){throw 'The interrupted Windows run did not stop.'}
        Start-Sleep -Seconds 2
    }while($true)
    if($run.Outcome -cne 'Interrupted'){throw 'A cooperative stop must remain Interrupted.'}
    $partial=Join-Path $active 'packages/p0000/mutation.json'
    $data=Get-Content $partial -Raw|ConvertFrom-Json -AsHashtable -DateKind String
    if($data['mode'] -cne 'Partial' -or $data.ContainsKey('mutationScore')){throw 'The interrupted report must be partial and have no score.'}
    $context=Get-Content ($partial+'.context.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
    $metadata=Get-Content (Join-Path $active 'run.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
    $receipt.PartialReport=$partial;$receipt.PartialSha256=(Get-FileHash $partial).Hash;$receipt.ContextSha256=$context.Sha256
    $receipt.PartialEvaluated=$data.evaluated
    $launch=& (Join-Path $PSScriptRoot 'WindowsMutationSmoke.ps1') -Image $Image -Connection $Connection -ExistingModule $metadata.Packages[0].ModulePath -ResumeFrom $partial | ConvertFrom-Json -AsHashtable -DateKind String
    $active=$launch.Path;$receipt.ResumedRun=$active
    $deadline=[datetimeoffset]::UtcNow.AddMinutes(20)
    do{
        $run=Get-MutatorRun $active
        if($run.Outcome -notin @('Running','Starting')){break}
        if([datetimeoffset]::UtcNow -ge $deadline){throw 'The resumed Windows run timed out.'}
        Start-Sleep -Seconds 2
    }while($true)
    if($run.Outcome -cne 'Success'){throw ('The resumed Windows run failed: '+[string]$run.Packages[0]['Error'])}
    $state=$run.Packages[0]
    if($state.ContextSha256 -cne $context.Sha256 -or $state.PSMutant.Score -ne 100 -or $state.PSMutant.Total -ne $receipt.Planned){throw 'The resumed context, score or complete discovery differs.'}
    $receipt.Outcome='Success';$receipt.Total=$state.PSMutant.Total;$receipt.Score=$state.PSMutant.Score
}catch{$receipt.Outcome='Failed';$receipt.Error=$_.Exception.Message}
finally{
    if($active){
        $view=Get-MutatorRun $active
        if($view.Outcome -in @('Running','Starting')){$null=Stop-MutatorRun $active -Force}
    }
    $receipt.CompletedUtc=[datetime]::UtcNow.ToString('O')
    $receipt|ConvertTo-Json -Depth 8|Set-Content (Join-Path $proof 'receipt.json')
}
@{Outcome=$receipt.Outcome;Error=$receipt.Error;Total=$receipt['Total'];Report=(Join-Path $proof 'receipt.json')}|ConvertTo-Json -Compress
if($receipt.Outcome -ne 'Success'){exit 1}
