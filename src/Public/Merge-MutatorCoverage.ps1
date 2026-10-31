function Merge-MutatorCoverage {
    <#
    .SYNOPSIS
    Merge exact command spans and optional branch evidence.

    .DESCRIPTION
    Requires identical sources and valid test outcomes before unioning observations. Command, line and
    branch metrics stay separate.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string[]]$Path,[Parameter(Mandatory)][string]$OutputPath,[string]$BranchPath)
    if(!$Path.Count){throw 'Coverage merge requires reports.'}
    $sources=$null;$commands=$null;$inputs=[Collections.Generic.List[object]]::new()
    foreach($file in $Path){
        $resolved=(Resolve-Path -LiteralPath $file -ErrorAction Stop).ProviderPath
        $report=Read-MutatorJson $resolved
        if($report.Metric -cne 'Commands' -or $report.Backend -cne 'Breakpoints' -or !$report.SourcesUnchanged -or
            !$report.Tests.Passed -or $report.Tests.Failed -or $report.Tests.Skipped -or $report.Tests.DiscoveryErrors){throw 'Coverage inputs require passing tests, stable sources and the exact breakpoint collector.'}
        $root=$report.ModulePath.Replace('\','/').TrimEnd('/')+'/'
        $comparison=if($report.Platform -ceq 'Windows'){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
        $fingerprints=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach($entry in $report.SourceFingerprints){
            $name=$entry.Path.Replace('\','/')
            if(!$name.StartsWith($root,$comparison) -or $entry.Sha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid coverage source identity.'}
            $name=$name.Substring($root.Length)
            if($name.Split('/') -contains '..' -or $fingerprints.ContainsKey($name)){throw 'Ambiguous coverage source path.'}
            $fingerprints[$name]=$entry.Sha256.ToUpperInvariant()
        }
        if(!$fingerprints.Count){throw 'Coverage source discovery was empty.'}
        if($null -eq $sources){$sources=$fingerprints}
        elseif((@($sources.Keys|Sort-Object -CaseSensitive) -join "`n") -cne (@($fingerprints.Keys|Sort-Object -CaseSensitive) -join "`n")){throw 'Coverage source scopes differ.'}
        foreach($name in $sources.Keys){if($sources[$name] -cne $fingerprints[$name]){throw 'Coverage source fingerprints differ.'}}
        $rows=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach($state in @(@{Rows=@($report.ExecutedLocations);Hit=$true},@{Rows=@($report.MissedLocations);Hit=$false})){
            foreach($entry in $state.Rows){
                $name=$entry.File.Replace('\','/')
                if(!$name.StartsWith($root,$comparison)){throw 'A command escaped the coverage source root.'}
                $name=$name.Substring($root.Length)
                if(!$sources.ContainsKey($name) -or !$entry.Line -or !$entry.StartColumn -or !$entry.EndColumn -or $entry.EndLine -lt $entry.Line){throw 'A coverage command has no exact source span.'}
                $key=@($name,$entry.Line,$entry.StartColumn,$entry.EndLine,$entry.EndColumn,$entry.Function,$entry.Class) -join '|'
                if($rows.ContainsKey($key)){throw 'Duplicate coverage command identity.'}
                $rows[$key]=@{File=$name;Line=$entry.Line;StartColumn=$entry.StartColumn;EndLine=$entry.EndLine;EndColumn=$entry.EndColumn;Function=$entry.Function;Class=$entry.Class;Hit=$state.Hit}
            }
        }
        if(!$rows.Count -or $rows.Count -ne $report.Analyzed -or @($rows.Values|Where-Object Hit).Count -ne $report.Executed -or @($rows.Values|Where-Object {!$_.Hit}).Count -ne $report.Missed){throw 'Coverage discovery or counters are inconsistent.'}
        if($null -eq $commands){$commands=$rows}
        else{
            if((@($commands.Keys|Sort-Object -CaseSensitive) -join "`n") -cne (@($rows.Keys|Sort-Object -CaseSensitive) -join "`n")){throw 'Coverage command scopes differ.'}
            foreach($key in $commands.Keys){$commands[$key].Hit=$commands[$key].Hit -or $rows[$key].Hit}
        }
        $inputs.Add(@{Path=$resolved;Sha256=(Get-FileHash -LiteralPath $resolved).Hash;Platform=$report.Platform;Runtime=$report.Runtime;Passed=$report.Tests.Passed})
    }
    $missed=@($commands.Values|Where-Object {!$_.Hit}|Sort-Object File,Line,StartColumn)
    $lineGroups=@($commands.Values|Group-Object { $_.File+'|'+$_.Line })
    $missedLines=@($lineGroups|Where-Object {!@($_.Group|Where-Object Hit).Count})
    $result=@{SchemaVersion=1;Metric='Commands';Scope='MergedProcesses';Backend='Breakpoints';Analyzed=$commands.Count
        Executed=($commands.Count-$missed.Count);Missed=$missed.Count;Percent=(100.0*($commands.Count-$missed.Count)/$commands.Count)
        CommandGateSatisfied=($missed.Count -eq 0);FullGateSatisfied=$false;MissingMetrics=@('BranchCoverage');Branches=$null
        SourceFingerprints=@($sources.Keys|Sort-Object|ForEach-Object {@{Path=$_;Sha256=$sources[$_]}});Inputs=$inputs.ToArray();MissedLocations=$missed
        CommandLocations=@($commands.Values|Sort-Object File,Line,StartColumn)
        Lines=@{Metric='CommandStartLines';Total=$lineGroups.Count;Covered=($lineGroups.Count-$missedLines.Count);Missed=$missedLines.Count;Percent=(100.0*($lineGroups.Count-$missedLines.Count)/$lineGroups.Count)}}
    if($BranchPath){
        $branchFile=(Resolve-Path -LiteralPath $BranchPath -ErrorAction Stop).ProviderPath
        $branch=Read-MutatorJson $branchFile
        if($branch.Metric -cne 'BranchOutcomes' -or !@($branch.Inputs).Count){throw 'A merged branch proof is required.'}
        $branchSources=@($branch.SourceFingerprints|Sort-Object Path -CaseSensitive)
        $commandSources=@($result.SourceFingerprints|Sort-Object Path -CaseSensitive)
        if((ConvertTo-MutatorContainerJson $branchSources) -cne (ConvertTo-MutatorContainerJson $commandSources)){throw 'Command and branch source fingerprints differ.'}
        $expected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($definition in $branch.Branches){
            if(!$sources.ContainsKey($definition.File) -or $definition.Id -notmatch '^[a-f0-9]{64}$' -or !@($definition.Outcomes).Count){throw 'Invalid branch definition in coverage gate.'}
            foreach($outcome in $definition.Outcomes){if(!$expected.Add($definition.Id+'|'+$outcome)){throw 'Duplicate branch outcome in coverage gate.'}}
        }
        $observed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($hit in $branch.Observed){if(!$expected.Contains($hit) -or !$observed.Add($hit)){throw 'Invalid branch observation in coverage gate.'}}
        $branchMissed=@($expected|Where-Object {!$observed.Contains($_)}|Sort-Object)
        if(!$expected.Count -or $expected.Count -ne $branch.Total -or $observed.Count -ne $branch.Covered -or
            ($branchMissed -join "`n") -cne (@($branch.Missed|Sort-Object) -join "`n")){throw 'Branch counters are inconsistent in coverage gate.'}
        $result.Branches=@{Total=$expected.Count;Covered=$observed.Count;Missed=$branchMissed.Count;Percent=(100.0*$observed.Count/$expected.Count)
            Path=$branchFile;Sha256=(Get-FileHash -LiteralPath $branchFile).Hash}
        $result.MissingMetrics=@()
        $result.FullGateSatisfied=$result.CommandGateSatisfied -and $result.Lines.Missed -eq 0 -and $branchMissed.Count -eq 0
    }
    if($PSCmdlet.ShouldProcess($OutputPath,'Write coverage merged by exact source fingerprints and command spans')){Write-MutatorJson $OutputPath $result}
    [pscustomobject]@{Analyzed=$result.Analyzed;Executed=$result.Executed;Missed=$result.Missed;Percent=$result.Percent;Lines=$result.Lines;Branches=$result.Branches;CommandGateSatisfied=$result.CommandGateSatisfied;FullGateSatisfied=$result.FullGateSatisfied;OutputPath=$OutputPath}
}
