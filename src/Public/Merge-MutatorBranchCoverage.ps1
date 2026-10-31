function Merge-MutatorBranchCoverage {
    <#
    .SYNOPSIS
    Union branch outcomes from compatible source-bound reports.

    .DESCRIPTION
    Requires identical definitions/fingerprints and successful semantic tests. Rejects fabricated or
    incompatible proof before writing.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string[]]$Path,[Parameter(Mandatory)][string]$OutputPath)
    if(!$Path.Count){throw 'Branch merge requires reports.'}
    $expected=$null;$identity=$null;$fingerprints=$null
    $observed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $inputs=[Collections.Generic.List[object]]::new()
    foreach($file in $Path){
        $resolved=(Resolve-Path -LiteralPath $file -ErrorAction Stop).ProviderPath
        $report=Read-MutatorJson $resolved
        if($report.Metric -cne 'BranchOutcomes' -or !$report.Tests.Passed -or $report.Tests.Failed -or $report.Tests.Skipped -or $report.Tests.DiscoveryErrors -or !$report.Tests.SourceUnchanged -or $report.Tests.NativeOutcome -cne 'Success'){throw 'Branch inputs require passing semantic tests and stable sources.'}
        $scope=@($report.SourceFingerprints|Sort-Object Path -CaseSensitive)
        if(!$scope.Count -or @($scope|Where-Object {$_.Sha256 -notmatch '^[a-fA-F0-9]{64}$'}).Count){throw 'Invalid branch source identities.'}
        $sourceIdentity=ConvertTo-MutatorContainerJson $scope
        $definitions=@($report.Branches|Sort-Object Id)
        if(!$definitions.Count){throw 'Branch discovery was empty.'}
        $definitionIdentity=ConvertTo-MutatorContainerJson $definitions
        if($null -eq $identity){$identity=@{Sources=$sourceIdentity;Definitions=$definitionIdentity};$fingerprints=$scope}
        elseif($identity.Sources -cne $sourceIdentity -or $identity.Definitions -cne $definitionIdentity){throw 'Branch source fingerprints or definitions differ.'}
        $local=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($branch in $definitions){
            if($branch.Id -notmatch '^[a-f0-9]{64}$' -or !@($branch.Outcomes).Count){throw 'Invalid branch definition.'}
            foreach($outcome in $branch.Outcomes){if(!$local.Add($branch.Id+'|'+$outcome)){throw 'Duplicate branch outcome identity.'}}
        }
        if($local.Count -ne $report.Total){throw 'Branch scope counters differ.'}
        $hits=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($entry in $report.Observed){
            if(!$local.Contains($entry) -or !$hits.Add($entry)){throw 'An observed branch is foreign or duplicated.'}
            [void]$observed.Add($entry)
        }
        if($hits.Count -ne $report.Covered -or ($report.Total-$report.Covered) -ne @($report.Missed).Count){throw 'Branch observation counters differ.'}
        $expected=$local
        $inputs.Add(@{Path=$resolved;Sha256=(Get-FileHash -LiteralPath $resolved).Hash;Platform=$report.Platform;Passed=$report.Tests.Passed})
    }
    $missed=@($expected|Where-Object {!$observed.Contains($_)}|Sort-Object)
    $result=@{SchemaVersion=1;Metric='BranchOutcomes';Total=$expected.Count;Covered=$observed.Count;Missed=$missed;Percent=(100.0*$observed.Count/$expected.Count)
        BranchGateSatisfied=($missed.Count -eq 0);SourceFingerprints=$fingerprints;Branches=$definitions;Observed=@($observed);Inputs=$inputs.ToArray()}
    if($PSCmdlet.ShouldProcess($OutputPath,'Write the branch outcome union from identical sources and semantic test passes')){Write-MutatorJson $OutputPath $result}
    [pscustomobject]@{Total=$result.Total;Covered=$result.Covered;Missed=$missed.Count;Percent=$result.Percent;BranchGateSatisfied=$result.BranchGateSatisfied;OutputPath=$OutputPath}
}
