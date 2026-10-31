function Get-MutatorRetentionPlan {
    <#
    .SYNOPSIS
    Plan old successful native runs without deleting evidence.

    .DESCRIPTION
    Protects recent, active, incomplete, imported and linked runs. Bounds items while retaining exact
    eligible counts.
    #>

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunRoot,[ValidateRange(0,10000)][int]$KeepLast=20,
        [datetimeoffset]$BeforeUtc=[datetimeoffset]::UtcNow.AddDays(-30),[ValidateRange(0,1000)][int]$MaxItems=20)
    $root=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunRoot)
    if(!(Test-Path -LiteralPath $root -PathType Container)){return [pscustomobject]@{ReadOnly=$true;TotalCount=0;EligibleCount=0;Items=@();Omitted=0}}
    if((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Retention planning refuses a linked run root.'}
    $rows=@(foreach($directory in Get-ChildItem -LiteralPath $root -Directory -Force){
        $record=Join-Path $directory.FullName 'run.json'
        if(!(Test-Path -LiteralPath $record -PathType Leaf)){continue}
        $row=@{Path=$directory.FullName;Id=$directory.Name;Eligible=$false;Reason='InvalidMetadata';CompletedUtc=$null;Run=$null}
        if(($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ((Get-Item -LiteralPath $record -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){$row.Reason='LinkedEvidence';$row;continue}
        try{$run=Read-MutatorJson $record}catch{$row.Reason='UnreadableMetadata';$row;continue}
        if(!$run -or $run['Id'] -cne $directory.Name){$row;continue}
        $row.Run=$run
        if($run['Outcome'] -cne 'Success' -or $run['ReadOnly'] -or $run['Origin'] -eq 'Imported'){$row.Reason='RetainIncompleteOrImported';$row;continue}
        $completed=[datetimeoffset]::MinValue
        if(![datetimeoffset]::TryParse([string]$run['CompletedUtc'],[ref]$completed)){$row;continue}
        $row.CompletedUtc=$completed;$row.Reason='SuccessfulRun';$row
    })
    $successful=@($rows|Where-Object Reason -EQ SuccessfulRun|Sort-Object CompletedUtc -Descending)
    $newest=@($successful|Select-Object -First $KeepLast|ForEach-Object Id)
    foreach($row in $successful){
        if($row.Id -in $newest){$row.Reason='KeepNewest';continue}
        if($row.CompletedUtc -ge $BeforeUtc){$row.Reason='TooRecent';continue}
        $identities=@($row.Run['Process'])
        foreach($entry in @($row.Run['Packages'])){$state=Read-MutatorJson (Join-Path $row.Path ('packages/'+$entry.Id+'/state.json'));if($state){$identities+=@($state['Process'])}}
        if(@($identities|Where-Object {$_ -and (Test-MutatorProcess $_)}).Count){$row.Reason='LiveProcess';continue}
        $row.Eligible=$true;$row.Reason='OldSuccessfulRun'
    }
    [pscustomobject]@{ReadOnly=$true;RunRoot=$root;KeepLast=$KeepLast;BeforeUtc=$BeforeUtc.ToUniversalTime().ToString('O');TotalCount=$rows.Count
        EligibleCount=@($rows|Where-Object Eligible).Count;Omitted=[math]::Max(0,$rows.Count-$MaxItems)
        Items=@($rows|Select-Object -First $MaxItems|ForEach-Object {[pscustomobject]@{Path=$_.Path;Id=$_.Id;Eligible=$_.Eligible;Reason=$_.Reason;CompletedUtc=$_.CompletedUtc}})}
}
