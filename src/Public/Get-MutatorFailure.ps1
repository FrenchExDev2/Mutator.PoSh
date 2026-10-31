function Get-MutatorFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[ValidateRange(1,100)][int]$MaxItems=20,[ValidateRange(1024,1048576)][int]$MaxOutputBytes=8192,[ValidateRange(0,2147483647)][int]$Skip=0)
    $run=Get-MutatorRun -Path $Path
    $items=[Collections.Generic.List[object]]::new()
    if($run.Error){$items.Add(@{Package=$null;Kind='Supervisor';Message=$run.Error;Report=$run.Report})}
    foreach($package in $run.Packages){
        $folder=Join-Path $run.Path ('packages/'+$package.Id)
        if($package['Error']){$items.Add(@{Package=$package.Name;Kind='Execution';Phase=$package['FailedPhase'];Message=$package.Error;Report=(Join-Path $folder 'state.json')})}
        $pathPS=Join-Path $folder 'mutation.json'
        $report=Read-MutatorJson $pathPS
        if($report){foreach($mutant in @($report['mutants']|Where-Object Status -EQ Survived)){
            $items.Add(@{Package=$package.Name;Kind='PSMutant';File=$mutant.File;Line=$mutant.Line;Id=$mutant.Id;Operator=$mutant.Operator;Description=$mutant.Description;Report=$pathPS})
        }}
        $pathRecheck=Join-Path $folder 'mutation.recheck.json'
        $recheck=Read-MutatorJson $pathRecheck
        if($recheck){foreach($mutant in @($recheck['mutants']|Where-Object Status -EQ Survived)){
            $items.Add(@{Package=$package.Name;Kind='PSMutantRecheck';File=$mutant.File;Line=$mutant.Line;Id=$mutant.Id;Operator=$mutant.Operator;Description=$mutant.Description;Report=$pathRecheck})
        }}
        $pathCS=Join-Path $folder 'stryker/reports/mutation-report.json'
        $report=Read-MutatorJson $pathCS
        if($report){foreach($file in $report.files.Keys){foreach($mutant in @($report.files[$file].mutants|Where-Object status -In @('Survived','NoCoverage'))){
            $items.Add(@{Package=$package.Name;Kind='Stryker';File=$file;Line=$mutant.location.start.line;Id=$mutant.id;Operator=$mutant.mutatorName;Status=$mutant.status;Report=$pathCS})
        }}}
    }
    $selected=@($items|Select-Object -Skip $Skip -First $MaxItems)
    $result=[ordered]@{Run=$run.Id;Outcome=$run.Outcome;TotalFailures=$items.Count;Returned=$selected.Count;Skip=$Skip;Items=$selected;Truncated=($items.Count -gt $Skip+$selected.Count);NextSkip=$(if($items.Count -gt $Skip+$selected.Count){$Skip+$selected.Count}else{$null})}
    while([Text.Encoding]::UTF8.GetByteCount(($result|ConvertTo-Json -Depth 12 -Compress)) -gt $MaxOutputBytes -and $result.Returned -gt 0){
        $result.Returned--; $result.Items=@($selected|Select-Object -First $result.Returned);$result.Truncated=$true;$result.NextSkip=$Skip+$result.Returned
    }
    if(!$result.Returned -and $selected.Count){$result['Advice']='Increase MaxOutputBytes to inspect the next complete failure entry.'}
    [pscustomobject]$result
}
