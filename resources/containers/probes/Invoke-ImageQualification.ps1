#requires -Version 7.6
# Objectif : Qualifier un outil natif dans une image Mutator avec QuietCli et des assertions indépendantes.
# Sources: https://github.com/ggreer/the_silver_searcher/blob/master/doc/ag.1.md
# https://www.freedesktop.org/software/systemd/man/latest/journalctl.html
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Ag','Journalctl')][string]$Profile,
    [Parameter(Mandatory)][string]$ModuleRoot,[Parameter(Mandatory)][string]$ProofDirectory,
    [ValidateSet('Linux','Windows')][string]$ExpectedOS='Linux',[string]$ExpectedDotnetVersion)
$ErrorActionPreference='Stop'
[void][IO.Directory]::CreateDirectory($ProofDirectory)
$module=Import-Module (Join-Path $ModuleRoot 'FrenchExDev.Mutator.PoSh/FrenchExDev.Mutator.PoSh.psd1') -PassThru -DisableNameChecking
$summary=@{SchemaVersion=2;Scope='NativeToolAndEngineSmoke';Outcome='Running';Passed=0;Failed=0;Skipped=0;DiscoveryErrors=0;FullGateSatisfied=$false;Checks=@();PowerShell=$PSVersionTable.PSVersion.ToString()}
function Invoke-ImageNative {
    param([string]$File,[string[]]$Arguments,[string]$Directory=$ProofDirectory,[int]$Timeout=60)
    $result=& $module {param($File,$Arguments,$Directory,$Timeout) Invoke-MutatorNative $File $Arguments $Directory $Timeout} $File $Arguments $Directory $Timeout
    if($result.StdoutTruncated -or $result.StderrTruncated){throw 'Qualification output was incomplete.'}
    $result
}
function Confirm-ImageCheck {
    param([string]$Name,[bool]$Condition)
    if(!$Condition){throw ('Image assertion failed: '+$Name)}
    $summary.Checks+=@{Name=$Name;Outcome='Success'};$summary.Passed++
}
try{
    Confirm-ImageCheck Platform $(if($ExpectedOS -eq 'Windows'){$IsWindows}else{$IsLinux})
    $tools=@(foreach($tool in @(@('Pester','6.2.0'),@('PSMutant','0.6.0'),@('PSScriptAnalyzer','1.25.0'))){
        $found=Get-Module -ListAvailable $tool[0]|Where-Object Version -EQ ([version]$tool[1])|Select-Object -First 1
        if(!$found){throw ('Pinned image tool is missing: '+($tool -join ' '))}
        @{Name=$found.Name;Version=$found.Version.ToString()}
    })
    $summary.Tools=$tools
    if($Profile -eq 'Ag'){
        $version=Invoke-ImageNative ag @('--version')
        Confirm-ImageCheck AgVersion ($version.Outcome -eq 'Success' -and $version.Stdout -match '(?m)^ag version (?<version>\S+)')
        $summary.AgVersion=$Matches.version
        $fixture=Join-Path $ProofDirectory 'ag-input.txt'
        [IO.File]::WriteAllText($fixture,"needle one`ncontext`nneedle two`n")
        $count=Invoke-ImageNative ag @('--nocolor','--count','needle',$fixture)
        Confirm-ImageCheck AgMatches ($count.Outcome -eq 'Success' -and $count.Stdout.Trim() -match '^(?:.*:)?2$')
        $context=Invoke-ImageNative ag @('--nocolor','-C','1','needle',$fixture)
        Confirm-ImageCheck AgContext ($context.Outcome -eq 'Success' -and $context.Stdout.Contains('context'))
        $partial=Invoke-ImageNative ag @('--nocolor','--count','needle',$fixture,(Join-Path $ProofDirectory 'missing-input.txt'))
        Confirm-ImageCheck AgPartialDiagnostic ($partial.Stdout -match '(?m)^(?:.*:)?2\s*$' -and $partial.Stderr.Contains('missing-input.txt'))
        $summary.Smoke=@{Matches=2;PartialObservedMatches=2;PartialExitCode=$partial.ExitCode;Context=$true}
    }else{
        $version=Invoke-ImageNative journalctl @('--version')
        Confirm-ImageCheck JournalVersion ($version.Outcome -eq 'Success' -and $version.Stdout -match '(?m)^systemd (?<version>.+)$')
        $summary.JournalctlVersion=$Matches.version
        if(!$ExpectedDotnetVersion){throw 'The expected SDK version is required.'}
        $sdk=Invoke-ImageNative dotnet @('--version')
        Confirm-ImageCheck DotnetVersion ($sdk.Outcome -eq 'Success' -and $sdk.Stdout.Trim() -ceq $ExpectedDotnetVersion)
        $project=Join-Path $ProofDirectory 'offline-sdk'
        [void][IO.Directory]::CreateDirectory($project)
        [IO.File]::WriteAllText((Join-Path $project 'Smoke.csproj'),'<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>')
        [IO.File]::WriteAllText((Join-Path $project 'Program.cs'),'System.Console.WriteLine("mutator-sdk-ok");')
        [IO.File]::WriteAllText((Join-Path $project 'NuGet.Config'),'<configuration><packageSources><clear /></packageSources></configuration>')
        $build=Invoke-ImageNative dotnet @('build','Smoke.csproj','--configuration','Release','--nologo','--verbosity','quiet','-p:UseSharedCompilation=false') $project 120
        Confirm-ImageCheck OfflineSdkBuild ($build.Outcome -eq 'Success')
        $compiled=Invoke-ImageNative dotnet @((Join-Path $project 'bin/Release/net10.0/Smoke.dll'))
        Confirm-ImageCheck OfflineSdkExecution ($compiled.Outcome -eq 'Success' -and $compiled.Stdout.Trim() -ceq 'mutator-sdk-ok')
        $empty=Join-Path $ProofDirectory 'empty-journal';[void][IO.Directory]::CreateDirectory($empty)
        $query=Invoke-ImageNative journalctl @('--directory',$empty,'--no-pager')
        Confirm-ImageCheck EmptyJournal ($query.Outcome -eq 'Success')
    }
    $summary.Outcome='Success'
}catch{$summary.Outcome='Failed';$summary.Failed++;$summary.Error=& $module {param($Message) Protect-MutatorDiagnostic $Message} $_.Exception.Message}
foreach($metric in @(@('MemoryPeakBytes','memory.peak'),@('MemoryLimitBytes','memory.max'))){$file='/sys/fs/cgroup/'+$metric[1];if(Test-Path $file){$summary[$metric[0]]=(Get-Content $file -Raw).Trim()}}
$summary|ConvertTo-Json -Depth 8|Set-Content (Join-Path $ProofDirectory 'qualification.json')
$summary|ConvertTo-Json -Depth 8 -Compress
if($summary.Outcome -ne 'Success'){exit 1}
exit 0
