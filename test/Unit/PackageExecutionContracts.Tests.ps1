BeforeAll {
    $script:ExecutionModuleRoot=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:ExecutionModuleRoot 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    Import-Module (Join-Path (Split-Path $script:ExecutionModuleRoot) 'FrenchExDev.DevPoSh.PoSh/FrenchExDev.DevPoSh.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Owned package execution retains evidence and enforces the complete gate' {
    It 'handles <Scenario> without a real mutation campaign or C# process' -ForEach @(
        @{Scenario='success'},@{Scenario='survivor'},@{Scenario='partial'},@{Scenario='stopped'},@{Scenario='stopped full'},
        @{Scenario='source changed'},@{Scenario='Stryker failure'},@{Scenario='container C#'},
        @{Scenario='resume'},@{Scenario='invalid resume'},@{Scenario='covered only'},@{Scenario='host C#'},@{Scenario='invalid report'}
    ) {
        $fixture=New-DevPoShModule -Name ('Fixture.Execution'+[guid]::NewGuid().ToString('N')) -Path $TestDrive -Function Get-Sample
        Set-Content -LiteralPath (Join-Path $fixture.Path 'test/Unit/Sample.Tests.ps1') 'Describe sample {It value {1|Should -Be 1}}'
        $null=New-MutatorConfiguration -ModulePath $fixture.Path
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive;ModulePath=$fixture.Path;Scenario=$Scenario} {
            param($Root,$ModulePath,$Scenario)
            function Invoke-PSMutation {param($ConfigFile,$SourceRoot,$ResumeFrom,[switch]$Quiet) throw 'Mock required'}
            $script:ExecutionScenario=$Scenario
            $script:ExecutionOriginal=$ModulePath
            $name=Split-Path $ModulePath -Leaf
            $runPath=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $artifacts=Join-Path $runPath 'packages/p0000'
            $configuration=Join-Path $ModulePath 'test/psmutant.config.json'
            $resume=if($Scenario -in @('resume','invalid resume')){Join-Path $Root 'retained-partial.json'}else{$null}
            $entry=@{Id='p0000';Name=$name;ModulePath=$ModulePath;Configuration=$configuration;ResumeFrom=$resume;Stryker=($Scenario -in @('Stryker failure','container C#','host C#','stopped full'))}
            $ownedStopPath=Join-Path $runPath 'owned-stop.json'
            Write-MutatorJson (Join-Path $runPath 'run.json') @{
                Packages=@($entry);SourceRoot=$Root;Schedule=@{Workers=1};TestOrder='FocusedFirst';StopPath=$ownedStopPath;StrykerRuntime='Host'
                ToolCacheRoot=(Join-Path $Root 'owned-tool-cache');ContainerImageId=$(if($Scenario -eq 'container C#'){'verified-container'})
            }
            if($Scenario -eq 'covered only'){
                $config=Read-MutatorJson $configuration;$config.coveredLinesOnly=$true;Write-MutatorJson $configuration $config
            }
            if($Scenario -eq 'invalid report'){$config=Read-MutatorJson $configuration;$config.reportPath='../outside.json';Write-MutatorJson $configuration $config}
            Mock Import-MutatorTool {
                param($ProgressPath,$StopPath,$CacheRoot)
                $StopPath | Should -BeExactly $ownedStopPath
                $CacheRoot | Should -BeExactly (Join-Path $Root 'owned-tool-cache')
                $ProgressPath | Should -BeExactly (Join-Path $artifacts 'mutants.jsonl')
                @{Version='fixture-tool'}
            }
            Mock New-MutatorContext { @{Sha256='context-identity';Identity=@{Runtime='fixture'}} }
            Mock Confirm-MutatorResume {if($script:ExecutionScenario -eq 'invalid resume'){throw 'fixture resume fingerprint differs'}}
            Mock Invoke-PSMutation {
                param($ConfigFile,$SourceRoot,$ResumeFrom)
                if($script:ExecutionScenario -eq 'resume'){$ResumeFrom | Should -BeExactly $resume}
                else{$ResumeFrom | Should -BeNullOrEmpty}
                $config=Read-MutatorJson $ConfigFile
                $config.workers | Should -Be 1
                $config.coveredLinesOnly | Should -BeFalse
                $detail=@{total=2;killed=2;survived=0;mutationScore=100;declaredEquivalent=0;timedOut=0;skippedAsUncovered=0;staleEquivalents=@();filesWithoutTestMapping=@()}
                $result=@{Total=2;Killed=2;Score=100;ExitCode=0}
                if($script:ExecutionScenario -eq 'survivor'){$detail.killed=1;$detail.survived=1;$detail.mutationScore=50;$result.Killed=1;$result.Score=50}
                if($script:ExecutionScenario -in @('partial','stopped')){$detail.mode='Partial'}
                Write-MutatorJson (Join-Path $SourceRoot $config.reportPath) $detail
                if($script:ExecutionScenario -in @('stopped','stopped full')){Write-MutatorJson $ownedStopPath @{Reason='FixtureStop'}}
                if($script:ExecutionScenario -eq 'source changed'){Add-Content -LiteralPath (Join-Path $script:ExecutionOriginal 'src/Public/Get-Sample.ps1') '# changed during execution'}
                $result
            }
            Mock Invoke-MutatorStrykerCore {
                param($ModulePath)
                if($script:ExecutionScenario -eq 'Stryker failure'){throw 'fixture Stryker failed'}
                $ModulePath | Should -BeExactly (Join-Path $artifacts ('stage/'+$name))
                @{Detected=2;Undetected=0;Total=2}
            }
            Invoke-MutatorPackage $runPath p0000
            $state=Read-MutatorJson (Join-Path $artifacts 'state.json')
            $expected=if($Scenario -in @('stopped','stopped full')){'Interrupted'}elseif($Scenario -in @('success','container C#','host C#','resume')){'Success'}else{'Failed'}
            $state.Outcome | Should -BeExactly $expected
            $state.CompletedUtc | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $artifacts 'stage') | Should -BeFalse
            if($Scenario -notin @('covered only','invalid resume','invalid report')){
                Should -Invoke Invoke-PSMutation -Times 1
                Test-Path -LiteralPath (Join-Path $artifacts 'mutation.json') | Should -BeTrue
                $receipt=Read-MutatorJson (Join-Path $artifacts 'mutation.json.context.json')
                $receipt.Sha256 | Should -BeExactly context-identity
                $receipt.ReportSha256 | Should -BeExactly (Get-FileHash -LiteralPath (Join-Path $artifacts 'mutation.json')).Hash
            }else{Should -Invoke Invoke-PSMutation -Times 0}
            if($Scenario -in @('partial','stopped')){$state.PSMutant | Should -BeNullOrEmpty}
            if($Scenario -eq 'survivor'){$state.PSMutant.Survived | Should -Be 1}
            if($Scenario -eq 'source changed'){$state.Error | Should -BeExactly 'Module source changed during mutation.'}
            if($Scenario -eq 'Stryker failure'){$state.FailedPhase | Should -BeExactly Stryker;$state.Error | Should -BeExactly 'fixture Stryker failed'}
            if($Scenario -eq 'invalid resume'){$state.Error | Should -BeExactly 'fixture resume fingerprint differs'}
            if($Scenario -eq 'covered only'){$state.Error | Should -Match 'coveredLinesOnly: false';Should -Invoke Import-MutatorTool -Times 0}
            if($Scenario -in @('resume','invalid resume')){Should -Invoke Confirm-MutatorResume -Times 1}
            else{Should -Invoke Confirm-MutatorResume -Times 0}
            if($Scenario -in @('Stryker failure','container C#','host C#')){Should -Invoke Invoke-MutatorStrykerCore -Times 1}
            else{Should -Invoke Invoke-MutatorStrykerCore -Times 0}
        }
    }
}
