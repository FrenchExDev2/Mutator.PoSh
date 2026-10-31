<#
.SYNOPSIS
Expected behavior for the Recheck tests.

.DESCRIPTION
Recheck retains dedicated counts and an unchanged baseline with no overall score/full gate. Mocked
tool failure and cancellation must retain explicit failed/interrupted proof rather than invented
counters.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:MutatorRoot=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:MutatorRoot 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    Import-Module (Join-Path (Split-Path $script:MutatorRoot) 'FrenchExDev.DevPoSh.PoSh/FrenchExDev.DevPoSh.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Survivor checks keep the full gate separate' {
    AfterEach { & (Get-Module FrenchExDev.Mutator.PoSh) { $script:MutatorIsolationBoundary=$null } }
    BeforeEach {
        $script:Fixture=New-DevPoShModule -Name ('Fixture.Recheck'+[guid]::NewGuid().ToString('N')) -Path $TestDrive -Function Get-Value
        Set-Content (Join-Path $script:Fixture.Path 'test/Unit/Value.Tests.ps1') 'Describe value {It works {1|Should -Be 1}}'
        $null=New-MutatorConfiguration -ModulePath $script:Fixture.Path
        $script:Prior=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'.json')
        @{survivors=@(@{Id=1;File='Value.ps1'})}|ConvertTo-Json -Depth 5|Set-Content $script:Prior
    }
    It 'writes diagnostic counts without modifying the original baseline or promising a complete score' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{ModulePath=$script:Fixture.Path;Baseline=$script:Prior;Output=(Join-Path $TestDrive 'proof')} {
            param($ModulePath,$Baseline,$Output)
            $script:MutatorIsolationBoundary='Fixture'
            function Invoke-PSMutation {
                <#
                .SYNOPSIS
                Declare the mutation-tool boundary that this unit test must mock.

                .DESCRIPTION
                Throws if the scenario fails to replace it. These tests exercise orchestration and retained evidence
                without executing real mutants.
                #>
                param($ConfigFile,$SourceRoot,$RecheckFrom,[switch]$Quiet) throw 'Mock required'}
            Mock Import-MutatorTool {@{Version='0.6.0'}}
            Mock Invoke-PSMutation {
                param($ConfigFile,$SourceRoot,$RecheckFrom)
                $config=Read-MutatorJson $ConfigFile
                $full=Join-Path $SourceRoot $config.reportPath
                $report=Join-Path (Split-Path $full) 'mutation.recheck.json'
                Write-MutatorJson $report @{mode='Recheck';rechecked=1;nowKilled=1;survivors=@();mutants=@(@{Status='Killed'})}
                @{ExitCode=0}
            }
            $before=(Get-FileHash $Baseline).Hash
            $result=Invoke-MutatorRecheckCore -ModulePath $ModulePath -ReportPath $Baseline -OutputDirectory $Output
            $result.Outcome|Should -BeExactly Success
            $result.Rechecked|Should -Be 1
            $result.NowKilled|Should -Be 1
            $result.Score|Should -BeNullOrEmpty
            $result.FullGateSatisfied|Should -BeFalse
            (Get-FileHash $Baseline).Hash|Should -BeExactly $before
            Test-Path $result.Report|Should -BeTrue
            $preview=$Output+'-preview'
            $null=Invoke-MutatorRecheckCore -ModulePath $ModulePath -ReportPath $Baseline -OutputDirectory $preview -WhatIf
            Test-Path $preview|Should -BeFalse
            {Invoke-MutatorRecheckCore -ModulePath $ModulePath -ReportPath $Baseline -OutputDirectory $Output}|Should -Throw '*already exists*'
        }
    }
    It 'retains an explicit tool failure instead of a successful empty result' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{ModulePath=$script:Fixture.Path;Baseline=$script:Prior;Output=(Join-Path $TestDrive 'failure')} {
            param($ModulePath,$Baseline,$Output)
            $script:MutatorIsolationBoundary='Fixture'
            function Invoke-PSMutation {
                <#
                .SYNOPSIS
                Declare the mutation-tool boundary that this unit test must mock.

                .DESCRIPTION
                Throws if the scenario fails to replace it. These tests exercise orchestration and retained evidence
                without executing real mutants.
                #>
                param($ConfigFile,$SourceRoot,$RecheckFrom,[switch]$Quiet) throw 'Mock required'}
            Mock Import-MutatorTool {@{Version='0.6.0'}}
            Mock Invoke-PSMutation {throw 'Source hashes differ'}
            $result=Invoke-MutatorRecheckCore -ModulePath $ModulePath -ReportPath $Baseline -OutputDirectory $Output
            $result.Outcome|Should -BeExactly Failed
            $result.Error|Should -BeExactly 'Source hashes differ'
            $result.FullGateSatisfied|Should -BeFalse
            Test-Path (Join-Path $Output 'recheck.json')|Should -BeTrue
        }
    }
    It 'retains cancellation as Interrupted without a score or invented recheck counters' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{ModulePath=$script:Fixture.Path;Baseline=$script:Prior;Output=(Join-Path $TestDrive 'cancelled');Stop=(Join-Path $TestDrive 'stop.json')} {
            param($ModulePath,$Baseline,$Output,$Stop)
            $script:MutatorIsolationBoundary='Fixture'
            function Invoke-PSMutation {
                <#
                .SYNOPSIS
                Declare the mutation-tool boundary that this unit test must mock.

                .DESCRIPTION
                Throws if the scenario fails to replace it. These tests exercise orchestration and retained evidence
                without executing real mutants.
                #>
                param($ConfigFile,$SourceRoot,$RecheckFrom,[switch]$Quiet) throw 'Mock required'}
            Mock Import-MutatorTool {
                param($ProgressPath,$StopPath)
                $StopPath|Should -BeExactly $Stop
                @{Version='0.6.0'}
            }
            Mock Invoke-PSMutation {Write-MutatorJson $Stop @{Reason='FixtureStop'};throw [OperationCanceledException]::new('Fixture cancellation')}
            $result=Invoke-MutatorRecheckCore -ModulePath $ModulePath -ReportPath $Baseline -OutputDirectory $Output -StopPath $Stop
            $result.Outcome|Should -BeExactly Interrupted
            $result.Rechecked|Should -BeNullOrEmpty
            $result.Score|Should -BeNullOrEmpty
            $result.FullGateSatisfied|Should -BeFalse
            Test-Path (Join-Path $Output 'recheck.json')|Should -BeTrue
        }
    }
}
