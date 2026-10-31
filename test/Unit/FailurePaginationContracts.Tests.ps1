<#
.SYNOPSIS
Expected behavior for the FailurePaginationContracts tests.

.DESCRIPTION
Return complete masked failure entries within item/UTF-8 byte limits. Pagination must expose omitted
data and the next offset without silently skipping an oversized entry.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Mutation failure evidence pagination' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            $script:FailureRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:FailureView=[pscustomobject]@{Id='failure-run';Path=$script:FailureRoot;Outcome='Failed';Error='supervisor failure';Report='run.json';Packages=@(@{Id='p0000';Name='Fixture';Error='package failure';FailedPhase='PSMutant'})}
            Write-MutatorJson (Join-Path $script:FailureRoot 'packages/p0000/mutation.json') @{mutants=@(
                @{Status='Survived';File='Source.ps1';Line=7;Id=1;Operator='Negate';Description='survived change'},
                @{Status='Killed';File='Source.ps1';Line=8;Id=2;Operator='Negate';Description='detected change'})}
            Write-MutatorJson (Join-Path $script:FailureRoot 'packages/p0000/stryker/reports/mutation-report.json') @{files=@{'Source.cs'=@{mutants=@(
                @{status='Survived';id='cs-1';mutatorName='Boolean';location=@{start=@{line=11}}},
                @{status='NoCoverage';id='cs-2';mutatorName='Boolean';location=@{start=@{line=12}}},
                @{status='Killed';id='cs-3';mutatorName='Boolean';location=@{start=@{line=13}}})}}}
            Mock Get-MutatorRun {$script:FailureView}
        }
        It 'retains supervisor, package, PowerShell and C# failures while excluding killed mutants' {
            $r=Get-MutatorFailure -Path $script:FailureRoot
            $r.TotalFailures|Should -Be 5
            $r.Returned|Should -Be 5
            $r.Truncated|Should -BeFalse
            $r.Items.Kind|Should -Contain Supervisor
            $r.Items.Kind|Should -Contain Execution
            @($r.Items|Where-Object Kind -EQ Stryker).Count|Should -Be 2
            @($r.Items|Where-Object Kind -EQ Stryker)[1].Status|Should -BeExactly NoCoverage
            @($r.Items|Where-Object Kind -EQ PSMutant)[0].Line|Should -Be 7
        }
        It 'advances a stable cursor and returns a final nontruncated page' {
            $a=Get-MutatorFailure -Path $script:FailureRoot -MaxItems 2
            $a.NextSkip|Should -Be 2
            $b=Get-MutatorFailure -Path $script:FailureRoot -MaxItems 2 -Skip $a.NextSkip
            $b.NextSkip|Should -Be 4
            $c=Get-MutatorFailure -Path $script:FailureRoot -MaxItems 2 -Skip $b.NextSkip
            $c.Returned|Should -Be 1
            $c.Truncated|Should -BeFalse
            $c.NextSkip|Should -BeNullOrEmpty
            (Get-MutatorFailure -Path $script:FailureRoot -Skip 99).Returned|Should -Be 0
        }
        It 'signals when even one complete failure cannot fit the requested byte budget' {
            $script:FailureView.Error='large diagnostic '*1000
            $r=Get-MutatorFailure -Path $script:FailureRoot -MaxOutputBytes 1024
            $r.Returned|Should -Be 0
            $r.Truncated|Should -BeTrue
            $r.NextSkip|Should -Be 0
            $r.Advice|Should -Match 'Increase MaxOutputBytes'
            [Text.Encoding]::UTF8.GetByteCount(($r|ConvertTo-Json -Depth 12 -Compress))|Should -BeLessOrEqual 1024
        }
        It 'shrinks a page to whole entries without losing its total count' {
            $script:FailureView.Error='diagnostic '*50
            $r=Get-MutatorFailure -Path $script:FailureRoot -MaxOutputBytes 1024
            $r.TotalFailures|Should -Be 5
            $r.Returned|Should -BeLessThan 5
            $r.Returned|Should -BeGreaterThan 0
            $r.NextSkip|Should -Be $r.Returned
            [Text.Encoding]::UTF8.GetByteCount(($r|ConvertTo-Json -Depth 12 -Compress))|Should -BeLessOrEqual 1024
        }
    }
}
