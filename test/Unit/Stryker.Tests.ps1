<#
.SYNOPSIS
Expected behavior for the Stryker tests.

.DESCRIPTION
Require nonempty complete detection and shared worker allocation. Restore failures block mutation
and ignored, unknown or pending verdicts cannot become successful detection.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Stryker ownership and evidence' {
    It 'keeps exclusions separate and refuses pending or unknown mutants as successful detection' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $report=@{files=@{'Source.cs'=@{mutants=@(@{status='Killed'},@{status='Survived'},@{status='NoCoverage'},@{status='Pending'},@{status='Ignored'},@{status='CompileError'})}}}
            $summary=Get-MutatorStrykerSummary $report
            $summary.Total|Should -Be 6
            $summary.Detected|Should -Be 1
            $summary.Undetected|Should -Be 5
            $summary.Ignored|Should -Be 1
            $summary.CompileErrors|Should -Be 1
            $summary.Score|Should -Be (100/6)
            {Get-MutatorStrykerSummary @{files=@{}}}|Should -Not -Throw
            {Get-MutatorStrykerSummary @{}}|Should -Throw '*empty or*'
        }
    }
    It 'shares the worker allocation and requires nonempty complete detection' {
        $global:MutatorStrykerFixture=Join-Path $TestDrive 'output'
        [void][IO.Directory]::CreateDirectory((Join-Path $TestDrive 'module/engine'))
        [IO.File]::WriteAllText((Join-Path $TestDrive 'module/engine/mutator.json'),'{"Project":"Fixture.csproj","TestProject":"Fixture.Tests.csproj"}')
        Mock Invoke-MutatorNative -ModuleName FrenchExDev.Mutator.PoSh {
            param($Command,$Arguments)
            if($Arguments[0] -eq 'stryker'){
                $output=$Arguments[[array]::IndexOf($Arguments,'--output')+1]
                [void][IO.Directory]::CreateDirectory((Join-Path $output 'reports'))
                [IO.File]::WriteAllText((Join-Path $output 'reports/mutation-report.json'),'{"files":{"Source.cs":{"mutants":[{"status":"Killed"},{"status":"Timeout"}]}}}')
            }
            @{Outcome='Success';ExitCode=0}
        }
        $result=Invoke-MutatorStryker -ModulePath (Join-Path $TestDrive 'module') -Artifacts $global:MutatorStrykerFixture -Workers 2
        $result.Score | Should -Be 100
        $result.Detected | Should -Be 2
        Should -Invoke Invoke-MutatorNative -ModuleName FrenchExDev.Mutator.PoSh -Times 1 -ParameterFilter {$Arguments[0] -eq 'stryker' -and $Arguments[[array]::IndexOf($Arguments,'--concurrency')+1] -eq '2'}
        Remove-Variable MutatorStrykerFixture -Scope Global
    }
    It 'fails before mutation when the tool restore fails' {
        [void][IO.Directory]::CreateDirectory((Join-Path $TestDrive 'engine'))
        [IO.File]::WriteAllText((Join-Path $TestDrive 'engine/mutator.json'),'{"Project":"Fixture.csproj","TestProject":"Fixture.Tests.csproj"}')
        Mock Invoke-MutatorNative -ModuleName FrenchExDev.Mutator.PoSh {@{Outcome='Failed';ExitCode=1}}
        {Invoke-MutatorStryker -ModulePath $TestDrive -Artifacts (Join-Path $TestDrive 'out')} | Should -Throw '*restore failed*'
        Should -Invoke Invoke-MutatorNative -ModuleName FrenchExDev.Mutator.PoSh -Times 1 -Exactly
    }
}
