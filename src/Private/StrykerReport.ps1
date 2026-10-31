function Get-MutatorStrykerSummary {
    <#
    .SYNOPSIS
    Count Stryker verdicts without excluding ignored or noncompiling mutants.

    .DESCRIPTION
    Separates detected/undetected statuses and rejects invalid reports. Unknown verdicts remain
    undetected; empty scores remain unknown.
    #>

    param([Collections.IDictionary]$Report)
    $counts=@{Killed=0L;Timeout=0L;Survived=0L;NoCoverage=0L;Ignored=0L;CompileError=0L;Unknown=0L}
    if(!$Report -or $Report['files'] -isnot [Collections.IDictionary]){throw 'Stryker discovery was empty or its report was invalid.'}
    foreach($file in $Report.files.Values){foreach($mutant in @($file.mutants)){
        $status=[string]$mutant.status
        if($counts.ContainsKey($status)){$counts[$status]++}else{$counts.Unknown++}
    }}
    $detected=$counts.Killed+$counts.Timeout
    $undetected=$counts.Survived+$counts.NoCoverage+$counts.Unknown+$counts.Ignored+$counts.CompileError
    $total=$detected+$undetected
    @{Score=$(if($total){100*$detected/$total}else{$null});Detected=$detected;Undetected=$undetected
        Total=$total;Survived=$counts.Survived;Ignored=$counts.Ignored;CompileErrors=$counts.CompileError;Statuses=$counts}
}
