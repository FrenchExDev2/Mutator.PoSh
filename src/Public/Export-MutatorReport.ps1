function Export-MutatorReport {
    <#
    .SYNOPSIS
    Copy source-bound package evidence to module artifacts.

    .DESCRIPTION
    Retains reports, summaries and source comparisons. Refuses read-only imports, unsafe run IDs and
    escaping destinations.
    #>

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$RunId)
    $run=Get-MutatorRun -Path $Path
    $plan=Read-MutatorJson (Join-Path $run.Path 'run.json')
    if($plan['ReadOnly']){throw 'A read-only imported run cannot be exported as a new source-bound execution.'}
    foreach($entry in $plan.Packages){
        $state=@($run.Packages|Where-Object Id -CEQ $entry.Id)[0]
        $artifactRoot=[IO.Path]::GetFullPath((Join-Path $entry.ModulePath 'test/Artifacts'))
        $artifacts=[IO.Path]::GetFullPath((Join-Path $artifactRoot ("$($run.Platform)/$($run.Runtime)/$RunId")))
        $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
        if(!$artifacts.StartsWith(($artifactRoot+[IO.Path]::DirectorySeparatorChar),$comparison)){throw 'The export must remain inside the module artifact directory.'}
        [void][IO.Directory]::CreateDirectory($artifacts)
        $packageArtifacts=Join-Path $run.Path ('packages/'+$entry.Id)
        foreach($file in Get-ChildItem $packageArtifacts -File -ErrorAction Ignore){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $artifacts $file.Name) -Force}
        if(Test-Path (Join-Path $packageArtifacts 'stryker')){Copy-MutatorTree (Join-Path $packageArtifacts 'stryker') (Join-Path $artifacts 'stryker')}
        $current=Get-MutatorSourceSnapshot $entry.ModulePath
        $unchanged=$state['SourceSha256'] -and $state.SourceSha256 -ceq $current.Sha256
        $proof=Join-Path $artifacts 'sources.mutation.json'
        Write-MutatorJson $proof @{SourceSha256=$state['SourceSha256'];AfterSha256=$current.Sha256;Unchanged=[bool]$unchanged;Files=$current.Files;Runtime=$run.Runtime;Run=$run.Id}
        $assembly=if($state['Stryker']){
            @{Outcome=$(if($state.Stryker.Detected -gt 0 -and !$state.Stryker.Undetected){'Success'}else{'Failed'});Mutation=$state.Stryker}
        }elseif($entry.Stryker){@{Outcome='Failed'}}else{$null}
        $report=@{Package=$entry.Name -replace '^FrenchExDev\.(?:Tools\.)?|\.PoSh$','';Runtime=$run.Runtime;Platform=$run.Platform;RunId=$RunId;ArtifactPath=$artifacts
            Outcome=$state.Outcome;Mutation=$state['PSMutant'];Assembly=$assembly;Error=$state['Error'];MutatorRun=$run.Path
            Provenance=@{Path=$proof;SourceSha256=$state['SourceSha256'];Sha256=(Get-FileHash $proof).Hash;Unchanged=[bool]$unchanged}}
        if($entry.Name -ceq 'FrenchExDev.Mutator.PoSh'){$report.Package='Mutator'}
        if($entry.Name -ceq 'FrenchExDev.Tools.Utility.Agent.PoSh'){$report.Package='Agent'}
        Write-MutatorJson (Join-Path $artifacts 'summary.mutation.json') $report
        $report
    }
}
