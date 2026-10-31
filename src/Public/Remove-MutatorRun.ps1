function Remove-MutatorRun {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param([Parameter(Mandatory)][string]$RunRoot,[ValidateRange(0,10000)][int]$KeepLast=20,
        [datetimeoffset]$BeforeUtc=[datetimeoffset]::UtcNow.AddDays(-30))
    $plan=Get-MutatorRetentionPlan -RunRoot $RunRoot -KeepLast $KeepLast -BeforeUtc $BeforeUtc -MaxItems 1000
    if($plan.Omitted){throw 'Retention refuses an incomplete plan; select a narrower run root.'}
    $root=[IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunRoot))
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    $prefix=$root.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $candidates=@($plan.Items|Where-Object Eligible)
    foreach($candidate in $candidates){
        $path=[IO.Path]::GetFullPath($candidate.Path)
        if(!$path.StartsWith($prefix,$comparison) -or ![string]::Equals((Split-Path $path),$root.TrimEnd([IO.Path]::DirectorySeparatorChar),$comparison)){throw 'Retention target is outside the named run root.'}
        $run=Read-MutatorJson (Join-Path $path 'run.json')
        if($run['SchemaVersion'] -ne 1 -or $run['Id'] -cne (Split-Path $path -Leaf) -or $run.Id -cnotmatch '^\d{8}-\d{6}-[a-f0-9]{8}$' -or $run['Outcome'] -cne 'Success'){throw 'Retention requires an identified native successful run.'}
        if(!$run['SourceRoot']){throw 'Retention requires the original source root.'}
        $source=[IO.Path]::GetFullPath($run.SourceRoot)
        if([string]::Equals($source,$path,$comparison) -or $source.StartsWith($path+[IO.Path]::DirectorySeparatorChar,$comparison)){throw 'Retention refuses to remove the original source tree.'}
    }
    $removed=0;$retained=0
    foreach($candidate in $candidates){
        $path=[IO.Path]::GetFullPath($candidate.Path)
        if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Retention refuses linked evidence.'}
        if(@(Get-ChildItem -LiteralPath $path -Force -Recurse|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){$retained++;continue}
        if($PSCmdlet.ShouldProcess($path,'Remove an old successful run; incomplete, imported and active evidence is retained')){
            # Refresh after any interactive confirmation, not before its delay.
            $fresh=Get-MutatorRetentionPlan -RunRoot $root -KeepLast $KeepLast -BeforeUtc $BeforeUtc -MaxItems 1000
            if(!@($fresh.Items|Where-Object {$_.Id -ceq $candidate.Id -and $_.Eligible}).Count){$retained++;continue}
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            $removed++
        }else{$retained++}
    }
    [pscustomobject]@{Removed=$removed;Retained=$retained;Eligible=$candidates.Count;KeepLast=$KeepLast;BeforeUtc=$BeforeUtc.ToUniversalTime().ToString('O')}
}
