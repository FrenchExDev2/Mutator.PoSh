#requires -Version 7.6
param([string[]]$Path = @((Join-Path $PSScriptRoot 'Unit')),[string]$CoverageModulePath,[switch]$CoverageBreakpoints)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Import-Module Pester -RequiredVersion 6.2.0 -ErrorAction Stop
$harnessModule=Import-Module (Join-Path (Split-Path $PSScriptRoot) 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking -PassThru
$requiredRoots=@((Split-Path $PSScriptRoot),(Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.DevPoSh.PoSh'),(Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'QuietCliEcosystem/FrenchExDev.QuietCli.PoSh'))
foreach($required in $requiredRoots){if(!(Test-Path -LiteralPath $required -PathType Container)){throw "Required test source root is missing: $required"}}
$sourceRoots=@(@($requiredRoots+$CoverageModulePath)|Where-Object {$_ -and (Test-Path -LiteralPath $_ -PathType Container)}|Sort-Object -Unique)
$before=@{};foreach($source in $sourceRoots){$before[$source]=(& $harnessModule {param($Path) (Get-MutatorSourceSnapshot $Path).Sha256} $source)}
$artifacts=Join-Path $PSScriptRoot ('Artifacts/development/'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($artifacts)
$env:QUIETCLI_CONFIG_PATH=Join-Path $artifacts 'quietcli-config.yaml'
[IO.File]::WriteAllText($env:QUIETCLI_CONFIG_PATH,"history: {enabled: false}`nmeasurement: {enabled: false}`n")
$env:MUTATOR_CONFIG_PATH=Join-Path $artifacts 'mutator-config.yaml'
[IO.File]::WriteAllText($env:MUTATOR_CONFIG_PATH,"docker: {enabled: true, pipe: null}`npodman: {enabled: true, pipe: null}`n")
$configuration=New-PesterConfiguration
$selected=@(foreach($requested in $Path){
    $resolved=(Resolve-Path -LiteralPath $requested -ErrorAction Stop).ProviderPath
    if($resolved.TrimEnd([IO.Path]::DirectorySeparatorChar) -eq $PSScriptRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)){
        Join-Path $PSScriptRoot 'Unit'
        Join-Path $PSScriptRoot 'Integration'
    }else{$resolved}
})
$configuration.Run.Path=$selected;$configuration.Run.PassThru=$true;$configuration.Run.Parallel=$false
$configuration.Run.ExcludePath=@(foreach($selection in $selected){
    $testRoot=if(Test-Path -LiteralPath $selection -PathType Leaf){Split-Path $selection}else{$selection}
    foreach($folder in @('Artifacts','.cache')){Join-Path $testRoot ($folder+'/*');Join-Path $testRoot ('*/'+$folder+'/*')}
})
$configuration.TestRegistry.Enabled=$false;$configuration.Output.Verbosity='None'
$configuration.TestResult.Enabled=$true;$configuration.TestResult.OutputFormat='NUnitXml';$configuration.TestResult.OutputPath=Join-Path $artifacts 'tests.xml'
if($CoverageModulePath){
    $coverageSources=@(& (Get-Module FrenchExDev.Mutator.PoSh) {param($ModulePath) Get-MutatorProductionFile $ModulePath} $CoverageModulePath)
    if(!$coverageSources.Count){throw 'Coverage requires a nonempty complete production scope.'}
    $configuration.CodeCoverage.Enabled=$true;$configuration.CodeCoverage.Path=$coverageSources
    $configuration.CodeCoverage.OutputFormat='Cobertura';$configuration.CodeCoverage.OutputPath=Join-Path $artifacts 'coverage.xml'
    $configuration.CodeCoverage.CoveragePercentTarget=100
    $configuration.CodeCoverage.UseBreakpoints=[bool]$CoverageBreakpoints
}
if($env:MUTATOR_BRANCH_PROBE){. $env:MUTATOR_BRANCH_PROBE}
$result=Invoke-Pester -Configuration $configuration 6>$null
if(!$result -or !$result.PSObject.Properties['PassedCount']){
    @{ToolFailure='PesterResultMissing';ResultTypes=@($result|ForEach-Object {$_.GetType().FullName}|Sort-Object -Unique);ResultCount=@($result).Count
        Errors=@($Error|Select-Object -First 3|ForEach-Object {@{Message=$_.Exception.Message;Id=$_.FullyQualifiedErrorId;Stack=$_.ScriptStackTrace}})}|ConvertTo-Json -Depth 5 -Compress
    exit 1
}
$coverage=$null
if($CoverageModulePath){
    $data=$result.CodeCoverage
    if(!$data -or $data.CommandsAnalyzedCount -le 0){throw 'Coverage discovery was empty or the coverage tool failed.'}
    $coverage=@{ModulePath=(Resolve-Path $CoverageModulePath).ProviderPath;Metric='Commands';Scope='CurrentProcess';Backend=$(if($CoverageBreakpoints){'Breakpoints'}else{'Profiler'});Percent=$data.CoveragePercent
        Platform=$(if($IsWindows){'Windows'}elseif($IsLinux){'Linux'}else{'MacOS'})
        Tests=@{Passed=$result.PassedCount;Failed=$result.FailedCount;Skipped=$result.SkippedCount;DiscoveryErrors=$result.FailedContainersCount}
        Analyzed=$data.CommandsAnalyzedCount;Executed=$data.CommandsExecutedCount;Missed=$data.CommandsMissedCount
        SourceFiles=$coverageSources;FilesAnalyzed=$data.FilesAnalyzed;RequiredPercent=100
        MissingMetrics=@('BranchCoverage');FullGateSatisfied=$false;CommandGateSatisfied=($data.CommandsMissedCount -eq 0)
        Report=(Join-Path $artifacts 'coverage.xml');Runtime=$PSVersionTable.PSVersion.ToString();Pester='6.2.0'
        MissedLocations=@($data.CommandsMissed|Select-Object File,Line,EndLine,StartColumn,EndColumn,Function,Class)
        ExecutedLocations=@($data.CommandsExecuted|Select-Object File,Line,EndLine,StartColumn,EndColumn,Function,Class)
        MissedByFile=@($data.CommandsMissed|Group-Object File|Sort-Object Count -Descending|ForEach-Object {@{File=$_.Name;Missed=$_.Count}})
        SourceFingerprints=@($coverageSources|ForEach-Object {@{Path=$_;Sha256=(Get-FileHash -LiteralPath $_).Hash}})}
}
$identities=@(foreach($source in $sourceRoots){$after=(& $harnessModule {param($Path) (Get-MutatorSourceSnapshot $Path).Sha256} $source);@{Path=$source;Before=$before[$source];After=$after;Unchanged=($before[$source] -ceq $after)}})
$identities|ConvertTo-Json -Depth 5|Set-Content (Join-Path $artifacts 'sources.json')
if($coverage){
    $coverage.SourcesUnchanged=(@($identities|Where-Object Unchanged -EQ $false).Count -eq 0)
    $coverage|ConvertTo-Json -Depth 8|Set-Content (Join-Path $artifacts 'coverage.json')
}
$summary=@{Passed=$result.PassedCount;Failed=$result.FailedCount;Skipped=$result.SkippedCount;DiscoveryErrors=$result.FailedContainersCount;Report=$configuration.TestResult.OutputPath.Value
    Failures=@($result.Failed|Select-Object -First 8|ForEach-Object{@{Name=$_.ExpandedPath;Message=$_.ErrorRecord.Exception.Message}})
    Discovery=@($result.FailedContainers|ForEach-Object{$_.ErrorRecord.Exception.Message});Runtime=$PSVersionTable.PSVersion.ToString();Pester='6.2.0';SourceUnchanged=(@($identities|Where-Object Unchanged -EQ $false).Count -eq 0)
    Coverage=$(if($coverage){[pscustomobject]$coverage|Select-Object Metric,Scope,Percent,Analyzed,Missed,CommandGateSatisfied,FullGateSatisfied,MissingMetrics,Report}else{$null})}
$summary|ConvertTo-Json -Depth 6 -Compress
if(!$result.PassedCount -or $result.FailedCount -or $result.SkippedCount -or $result.FailedContainersCount -or !$summary.SourceUnchanged){exit 1}
if($coverage -and !$coverage.FullGateSatisfied){exit 1}
