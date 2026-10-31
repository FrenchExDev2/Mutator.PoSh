#requires -Version 7.6
param([Parameter(Mandatory)][string]$ProofPath)
$ErrorActionPreference='Stop'
Import-Module PSMutant -RequiredVersion 0.6.0
$proof=(Resolve-Path -LiteralPath $ProofPath).ProviderPath
$source=Join-Path $proof 'source'
$configuration=Get-Content -LiteralPath (Join-Path $source 'FrenchExDev.DevPoSh.PoSh/test/psmutant.config.json') -Raw|ConvertFrom-Json -AsHashtable
$events=@(Get-ChildItem -LiteralPath (Join-Path $proof 'runs') -Filter 'mutants.jsonl' -File -Recurse|Get-Content|ForEach-Object {$_|ConvertFrom-Json})
$survivors=@($events|Group-Object { $_.File+'|'+$_.Id }|ForEach-Object {$_.Group[-1]}|Where-Object Status -EQ Survived)
$details=@(foreach($group in $survivors|Group-Object File){
    if($group.Name -cnotin $configuration.mutate){throw 'Progress names a file outside the frozen mutation scope.'}
    $file=Join-Path $source $group.Name
    $candidates=@(& (Get-Module PSMutant) {param($File) Get-PSMutationCandidate -Path $File} $file)
    foreach($event in $group.Group){
        $candidate=@($candidates|Where-Object Id -EQ $event.Id)
        if($candidate.Count -ne 1){throw 'A survivor has no unique candidate in the frozen source.'}
        $content=[IO.File]::ReadAllText($file)
        $start=[math]::Max(0,$candidate[0].StartOffset-65)
        [ordered]@{File=$group.Name;Sha256=(Get-FileHash -LiteralPath $file).Hash;Id=$event.Id;Line=$candidate[0].Line
            Function=$candidate[0].Function;Operator=$candidate[0].Operator;Original=$candidate[0].Original;Mutated=$candidate[0].Mutated;Description=$candidate[0].Description
            Context=$content.Substring($start,[math]::Min(180,$content.Length-$start))}
    }
})
$report=Join-Path $proof 'survivor-details.json'
ConvertTo-Json -InputObject $details -Depth 6|Set-Content -LiteralPath $report
@{Survivors=$details.Count;Report=$report;Evaluated=$events.Count;Final=$false}|ConvertTo-Json -Compress
