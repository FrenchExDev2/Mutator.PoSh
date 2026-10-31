function Test-MutatorPowerShellQualityGate {
    <#
    .SYNOPSIS
    Validate complete coverage and mutation for identical sources.

    .DESCRIPTION
    Requires exact inventories, full command/line/branch coverage and strict raw mutation proof before
    writing success.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$ModulePath,[Parameter(Mandatory)][string]$CoveragePath,
        [Parameter(Mandatory)][string[]]$MutationRunPath,[string]$OutputPath)
    $root=(Resolve-Path -LiteralPath $ModulePath -ErrorAction Stop).ProviderPath
    $name=Split-Path $root -Leaf
    $productionHashes=[ordered]@{}
    $productionFiles=@(Get-MutatorProductionFile -ModulePath $root)
    foreach($file in $productionFiles){$productionHashes[[IO.Path]::GetRelativePath($root,$file).Replace('\','/')]=(Get-FileHash -LiteralPath $file).Hash}
    if(!$productionHashes.Count){throw 'Quality gate source discovery was empty.'}
    $configuration=Read-MutatorJson (Join-Path $root 'test/psmutant.config.json')
    Confirm-MutatorEquivalence $root $configuration
    $equivalents=Get-MutatorEquivalence $root $configuration.mutate
    $coverage=Read-MutatorJson $CoveragePath
    if(!$coverage.FullGateSatisfied -or !$coverage.CommandGateSatisfied -or $coverage.Missed -ne 0 -or
        $coverage.Analyzed -le 0 -or $coverage.Executed -ne $coverage.Analyzed -or $coverage.Lines.Missed -ne 0 -or
        $coverage.Branches.Missed -ne 0 -or $coverage.Branches.Total -le 0 -or $coverage.Branches.Covered -ne $coverage.Branches.Total){throw 'Complete command, executable-line and branch coverage is required.'}
    if(@($coverage.SourceFingerprints).Count -ne $productionHashes.Count){throw "Coverage source scope differs from the complete module (proof: $(@($coverage.SourceFingerprints).Count), module: $($productionHashes.Count), keys: $($productionHashes.Keys -join ', '))."}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($entry in $coverage.SourceFingerprints){
        if(!$productionHashes.Contains($entry.Path) -or !$seen.Add($entry.Path) -or $productionHashes[$entry.Path] -cne $entry.Sha256){throw 'Coverage source identity differs from the current production source.'}
    }
    if(!$MutationRunPath.Count){throw 'At least one complete mutation run is required.'}
    $proofs=[Collections.Generic.List[object]]::new()
    foreach($path in $MutationRunPath){
        $runRoot=(Resolve-Path -LiteralPath $path -ErrorAction Stop).ProviderPath
        $plan=Read-MutatorJson (Join-Path $runRoot 'run.json')
        if($plan.Outcome -cne 'Success' -or @($plan.Packages).Count -ne 1 -or $plan.Packages[0].Name -cne $name){throw 'A successful complete run of this one module is required.'}
        $packageRoot=Join-Path $runRoot ('packages/'+$plan.Packages[0].Id)
        $state=Read-MutatorJson (Join-Path $packageRoot 'state.json')
        $reportPath=Join-Path $packageRoot 'mutation.json'
        $report=Read-MutatorJson $reportPath
        if($state.Outcome -cne 'Success' -or !(Test-MutatorPowerShellGate $report @{Total=$state.PSMutant.Total;Killed=$state.PSMutant.Killed;Score=$state.PSMutant.Score;ExitCode=0})){throw 'The complete PowerShell mutation gate is not satisfied.'}
        if(@($report.sourceHashes.Keys).Count -ne $productionHashes.Count){throw 'Mutation source scope differs from the complete module.'}
        foreach($file in $productionHashes.Keys){
            $key=$name+'/'+$file
            if(!$report.sourceHashes.Contains($key) -or $report.sourceHashes[$key].ToUpperInvariant() -cne $productionHashes[$file]){throw 'Mutation source identity differs from the current production source.'}
        }
        $identities=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $detected=0;$reviewed=0
        foreach($mutant in $report.mutants){
            $key=$mutant.File+':'+$mutant.Line+':'+$mutant.Description
            if(!$report.sourceHashes.Contains($mutant.File) -or !$identities.Add($mutant.File+'|'+$mutant.Id)){throw 'A mutation candidate is foreign or duplicated.'}
            if($equivalents.Contains($key)){
                if($mutant.Status -cne 'Survived'){throw 'A declared equivalence was detected and must be reviewed.'}
                $reviewed++
            }elseif($mutant.Status -cin @('Killed','TimedOut')){$detected++}
            else{throw 'An unjustified survivor or unknown mutation verdict remains.'}
        }
        if($detected -ne $report.killed -or $reviewed -ne $report.declaredEquivalent -or $reviewed -ne $equivalents.Count -or
            $identities.Count -ne $report.total+$report.declaredEquivalent){throw 'Mutation discovery and equivalence counters are inconsistent.'}
        if($state.PSMutant.TimedOut -ne $report.timedOut){throw 'Mutation timeout counters are inconsistent.'}
        if($state.Stryker -and ($state.Stryker.Undetected -or !$state.Stryker.Detected)){throw 'The configured C# mutation gate is not satisfied.'}
        $proofs.Add(@{Platform=$plan.Platform;Runtime=$plan.Runtime;Discovered=$identities.Count;Detected=$detected;Equivalent=$reviewed;TimedOut=$report.timedOut
            Report=$reportPath;Sha256=(Get-FileHash -LiteralPath $reportPath).Hash;Tool=$state.PSMutant.Tool})
    }
    $result=@{SchemaVersion=1;Scope='PowerShell';Outcome='Success';FullGateSatisfied=$true;Module=$name;SourceFiles=$productionHashes.Count
        SourceFingerprints=@(foreach($file in $productionHashes.Keys){@{Path=$file;Sha256=$productionHashes[$file]}})
        Coverage=@{Path=$CoveragePath;Sha256=(Get-FileHash -LiteralPath $CoveragePath).Hash;Commands=$coverage.Analyzed;Branches=$coverage.Branches.Total}
        Mutation=$proofs.ToArray()}
    if($OutputPath -and $PSCmdlet.ShouldProcess($OutputPath,'Write the complete coverage and mutation proof for identical production sources')){Write-MutatorJson $OutputPath $result}
    [pscustomobject]$result
}
