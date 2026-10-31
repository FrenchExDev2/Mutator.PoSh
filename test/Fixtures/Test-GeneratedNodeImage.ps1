#requires -Version 7.6
param([string]$ModuleRoot='/opt/mutator/modules',[string]$ProofDirectory='/proof')
$ErrorActionPreference='Stop'
if(!$IsLinux){throw 'This qualification requires the generated Linux Npm image.'}
$module=Import-Module (Join-Path $ModuleRoot 'FrenchExDev.Mutator.PoSh/FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking -PassThru
function Invoke-NodeImageCommand {
    param([string]$Command,[string[]]$Arguments,[string]$WorkingDirectory='/tmp')
    $result=& $module {param($Command,$Arguments,$Directory) Invoke-MutatorNative $Command $Arguments $Directory 120} $Command $Arguments $WorkingDirectory
    if($result.Outcome -ne 'Success'){throw ('Node image qualification command failed: '+$Command+'; '+$result.Outcome)}
    if($result.StdoutTruncated -or $result.StderrTruncated){throw 'Node qualification output was incomplete.'}
    $result.Stdout
}
$definition=Get-Content '/opt/mutator/image.json' -Raw|ConvertFrom-Json -AsHashtable
$runtime=Get-Content '/opt/mutator/module-runtime.json' -Raw|ConvertFrom-Json -AsHashtable
$installed=Get-Content '/opt/mutator/installed-tool.json' -Raw|ConvertFrom-Json -AsHashtable
if($PSVersionTable.PSVersion.ToString() -cne $definition.Runtime.Version){throw 'The image PowerShell version differs from its pinned runtime.'}
if($installed.Module -cne 'FrenchExDev.Tools.Npm.PoSh' -or $installed.Platform -cne 'Linux'){throw 'The installed tool receipt does not identify the Npm Linux image.'}
$node=(Invoke-NodeImageCommand node @('-p','JSON.stringify({version:process.versions.node,platform:process.platform,arch:process.arch})'))|ConvertFrom-Json
$npm=Invoke-NodeImageCommand npm @('--version')
$packages=$definition.Platforms.Linux.Packages
$expectedNode=(@($packages|Where-Object {$_ -like 'nodejs=*'})[0] -split '=',2)[1] -replace '-r\d+$',''
$expectedNpm=(@($packages|Where-Object {$_ -like 'npm=*'})[0] -split '=',2)[1] -replace '-r\d+$',''
if($node.version -cne $expectedNode -or $npm -cne $expectedNpm -or $node.platform -cne 'linux' -or $node.arch -cne 'x64'){
    throw 'The installed Node/npm versions or target differ from the pinned Alpine recipe.'
}
$work='/tmp/node-image-workload';[void][IO.Directory]::CreateDirectory($work)
[IO.File]::WriteAllText((Join-Path $work 'verify.cjs'),"const assert=require('node:assert/strict');const fs=require('node:fs');fs.writeFileSync('proof.txt','offline verified');assert.equal(fs.readFileSync('proof.txt','utf8'),'offline verified');console.log(JSON.stringify({verified:true,bytes:16}));")
@{private=$true;scripts=@{verify='node verify.cjs'}}|ConvertTo-Json|Set-Content (Join-Path $work 'package.json')
$workload=(Invoke-NodeImageCommand npm @('run','--offline','--silent','verify') $work)|ConvertFrom-Json
if(!$workload.verified -or $workload.bytes -ne 16){throw 'The offline npm/Node workload failed.'}
Import-Module Pester -RequiredVersion 6.2.0
$config=New-PesterConfiguration
$config.Run.Path=Join-Path $ModuleRoot 'FrenchExDev.Tools.Npm.PoSh/test'
$config.Run.ExcludePath=@('*/Artifacts/*');$config.Run.PassThru=$true;$config.Run.Parallel=$false
$config.TestRegistry.Enabled=$false;$config.Output.Verbosity='None'
$config.TestResult.Enabled=$true;$config.TestResult.OutputFormat='NUnitXml';$config.TestResult.OutputPath=Join-Path $ProofDirectory 'npm-tests.xml'
$tests=Invoke-Pester -Configuration $config 6>$null
$result=@{PowerShell=$PSVersionTable.PSVersion.ToString();Node=$node.version;Npm=$npm;RuntimeIdentifier=$runtime.RuntimeIdentifier
    OfflineWorkload=[bool]$workload.verified;Passed=$tests.PassedCount;Failed=$tests.FailedCount;Skipped=$tests.SkippedCount;DiscoveryErrors=$tests.FailedContainersCount
    Failures=@($tests.Failed|Select-Object -First 5|ForEach-Object {@{Name=$_.ExpandedPath;Messages=@($_.ErrorRecord|ForEach-Object {$_.Exception.Message})}})
    Discovery=@($tests.FailedContainers|ForEach-Object {@{Name=$_.Name;Messages=@($_.ErrorRecord|ForEach-Object {$_.Exception.Message})}})
    MemoryLimitBytes=(Get-Content '/sys/fs/cgroup/memory.max' -Raw).Trim();MemoryPeakBytes=(Get-Content '/sys/fs/cgroup/memory.peak' -Raw).Trim()}
$result|ConvertTo-Json -Depth 5|Set-Content (Join-Path $ProofDirectory 'qualification.json')
$result|ConvertTo-Json -Depth 5 -Compress
if(!$tests.PassedCount -or $tests.FailedCount -or $tests.SkippedCount -or $tests.FailedContainersCount){exit 1}
