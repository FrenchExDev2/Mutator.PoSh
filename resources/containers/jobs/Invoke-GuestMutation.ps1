#requires -Version 7.6
param([Parameter(Mandatory)][string]$JobDirectory,[string]$Root='C:\mutator',[string]$JobsDirectory='\\host.lan\Data\jobs')
$ErrorActionPreference='Stop'
$id=Split-Path $JobDirectory -Leaf
if($id -notmatch '^[a-f0-9]{32}$' -or $JobDirectory -cne (Join-Path $JobsDirectory $id)){throw 'Invalid Windows mutation job directory.'}
$moduleRoot=Join-Path $Root 'modules/FrenchExDev.Mutator.PoSh'
Import-Module (Join-Path $moduleRoot 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Directory,$Id,$Root)
    $descriptor=Read-MutatorJson (Join-Path $Directory 'mutation.json')
    $local=Join-Path $Root ('mutation-jobs/'+$Id)
    $source=Join-Path $local 'source'
    if(Test-Path $local){throw 'A Windows mutation job cannot reuse an existing local sandbox.'}
    Copy-MutatorTree (Join-Path $Directory 'source') $source
    if((Get-MutatorSourceSnapshot $source).Sha256 -cne $descriptor.SourceSha256){throw 'The Windows mutation source fingerprint differs.'}
    foreach($key in @('Module','Configuration')){
        $relative=[string]$descriptor[$key]
        $full=[IO.Path]::GetFullPath((Join-Path $source $relative))
        $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
        if([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or !$full.StartsWith($source+[IO.Path]::DirectorySeparatorChar,$comparison)){throw 'The Windows mutation descriptor escapes its source root.'}
    }
    $configuration=Join-Path $source $descriptor.Configuration
    $config=Read-MutatorJson $configuration
    if(!$config -or $config.coveredLinesOnly -ne $false){throw 'Complete Windows mutation discovery is required.'}
    [void](Get-MutatorSubtree $source $config)
    if($descriptor['Stryker'] -isnot [bool]){throw 'The Windows Stryker selection must be explicit.'}
    $resume=$null
    if($descriptor['ResumeReportSha256']){
        $resume=Join-Path $local 'resume/mutation.json'
        [void][IO.Directory]::CreateDirectory((Split-Path $resume))
        foreach($suffix in @('','.context.json')){[IO.File]::Copy((Join-Path $Directory ('resume/mutation.json'+$suffix)),($resume+$suffix))}
        if((Get-FileHash $resume).Hash -cne $descriptor.ResumeReportSha256 -or (Get-FileHash ($resume+'.context.json')).Hash -cne $descriptor.ResumeContextSha256){throw 'The Windows resume artifact fingerprint differs.'}
    }
    $entry=@{Id='p0000';Name=$descriptor.Name;ModulePath=(Join-Path $source $descriptor.Module);Configuration=$configuration;ResumeFrom=$resume;ContainerRecipe=$null;Stryker=$descriptor.Stryker}
    $runPath=Join-Path $local 'run'
    Write-MutatorJson (Join-Path $runPath 'run.json') @{SourceRoot=$source;Packages=@($entry);Schedule=@{Workers=1};TestOrder=$descriptor.TestOrder
        ContainerImageId=$descriptor.ImageId;StrykerRuntime='Host';StopPath=(Join-Path $local 'stop.json');ToolCacheRoot=(Join-Path $Root 'mutation-tools')}
    Invoke-MutatorPackage $runPath p0000
} $JobDirectory $id $Root
