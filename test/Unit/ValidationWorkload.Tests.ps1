<#
.SYNOPSIS
Expected behavior for the ValidationWorkload tests.

.DESCRIPTION
Check frozen sources/OS before suites and enforce semantic, command, branch and mutation evidence
independently. Failed prerequisites block mutation; stopping waits for owned children while
retaining the primary error and partial proof.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Source-bound validation workload' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            $script:ValidationRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:ValidationReports=Join-Path $script:ValidationRoot 'reports'
            $script:ValidationOS=if($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'}
            $request=@{SchemaVersion=1;RunId='test-run';OS=$script:ValidationOS;SourceSha256='fixed';Modules=@('Fixture.Validation');Test=@('Unit','Integration','Mutations');Workers=1;WorkerBudget=2;MemoryBudgetMiB=6144}
            Write-MutatorJson (Join-Path $script:ValidationRoot 'request.json') $request
            $script:Origin=Join-Path $script:ValidationRoot 'origin'
            Write-MutatorJson (Join-Path $script:Origin 'coverage.json') @{Metric='Commands'}
            [IO.File]::WriteAllText((Join-Path $script:Origin 'tests.xml'),'<test-results/>')
            $script:BranchOrigin=Join-Path $script:ValidationRoot 'branch'
            Write-MutatorJson (Join-Path $script:BranchOrigin 'coverage.json') @{Metric='BranchOutcomes'}
            Write-MutatorJson (Join-Path $script:BranchOrigin 'manifest.json') @{}
            Write-MutatorJson (Join-Path $script:BranchOrigin 'tests.json') @{}
            Mock Get-MutatorSourceSnapshot { @{Sha256='fixed'} }
            Mock Invoke-MutatorValidationChild {
                param($Arguments,$Directory,$Proof)
                [void][IO.Directory]::CreateDirectory($Proof)
                if(@($Arguments|Where-Object {$_ -like '*DevPoShBranchCoverage.ps1'}).Count){
                    @{NativeOutcome='Success';ExitCode=0;Summary=@{Proof=$script:BranchOrigin}}
                }else{
                    @{NativeOutcome='Failed';ExitCode=1;Summary=@{Passed=3;Failed=0;Skipped=0;DiscoveryErrors=0;SourceUnchanged=$true;Report=(Join-Path $script:Origin 'tests.xml')}}
                }
            }
            Mock Merge-MutatorCoverage { @{FullGateSatisfied=$true} }
            Mock Merge-MutatorBranchCoverage { }
            Mock Invoke-MutatorRun { @{Path='isolated-mutation'} }
            Mock Get-MutatorProgress { @{Outcome='Success';CompletionPercent=100;FailedPackages=0;EvaluatedMutants=2;PlannedMutants=2} }
            Mock Get-MutatorRun { @{Path='isolated-mutation';Outcome='Success';EvaluatedMutants=2;PlannedMutants=2;SurvivedMutants=0} }
            Mock Export-MutatorReport { }
            Mock Copy-MutatorValidationMutationProof { }
        }
        It 'stops its mutation child before returning the original mirror failure' {
            $script:FailureOrder=[Collections.Generic.List[string]]::new()
            Mock Copy-MutatorValidationMutationProof {$script:FailureOrder.Add('copy');throw 'primary mirror replacement failed'}
            Mock Stop-MutatorValidationMutation {$script:FailureOrder.Add('stop-and-wait');@{Stopped=$true;ReportsCopied=$true;PartialReportAvailable=$true}}
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Outcome|Should -BeExactly Failed
            $r.RetainSandbox|Should -BeTrue
            $r.Modules['Fixture.Validation'].Suites.Mutations.Error|Should -BeExactly 'primary mirror replacement failed'
            $r.Modules['Fixture.Validation'].Suites.Mutations.ContainsKey('Score')|Should -BeFalse
            $script:FailureOrder -join ','|Should -BeExactly 'copy,stop-and-wait'
        }
        It 'honors a stop signal before starting any baseline or mutation' {
            Write-MutatorJson (Join-Path $script:ValidationReports 'stop.json') @{RunId='test-run'}
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Outcome|Should -BeExactly Interrupted
            $r.RetainSandbox|Should -BeTrue
            $r.FullGateSatisfied|Should -BeFalse
            $progress=Read-MutatorJson (Join-Path $script:ValidationReports 'progress.json')
            $progress.Phase|Should -BeExactly Interrupted
            $progress.CompletionPercent|Should -BeNullOrEmpty
            Should -Invoke Invoke-MutatorValidationChild -Times 0 -Exactly
            Should -Invoke Invoke-MutatorRun -Times 0 -Exactly
        }
        It 'waits for the mutation child when a stop arrives during progress polling' {
            Mock Get-MutatorProgress { @{Outcome='Running';FailedPackages=0;EvaluatedMutants=1;PlannedMutants=2} }
            Mock Start-Sleep {}
            Mock Copy-MutatorValidationMutationProof {Write-MutatorJson (Join-Path $script:ValidationReports 'stop.json') @{RunId='test-run'}}
            Mock Stop-MutatorValidationMutation { @{Stopped=$true;ReportsCopied=$true;PartialReportAvailable=$true} }
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Outcome|Should -BeExactly Interrupted
            $r.Modules['Fixture.Validation'].Suites.Mutations.Stop.Stopped|Should -BeTrue
            $r.Modules['Fixture.Validation'].Suites.Mutations.ContainsKey('Score')|Should -BeFalse
            $r.RetainSandbox|Should -BeTrue
            Should -Invoke Stop-MutatorValidationMutation -Times 1 -Exactly
        }
        It 'keeps semantic success distinct from the command coverage child exit and runs strict mutation' {
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Outcome|Should -BeExactly Success -Because ($r|ConvertTo-Json -Depth 8 -Compress)
            $r.FullGateSatisfied|Should -BeTrue
            $r.Modules['Fixture.Validation'].Suites.Mutations.Score|Should -Be 100
            Test-Path (Join-Path $script:ValidationReports 'unit/Fixture.Validation/tests.xml')|Should -BeTrue
            Test-Path (Join-Path $script:ValidationReports 'integration/Fixture.Validation/coverage.json')|Should -BeTrue
            Should -Invoke Export-MutatorReport -Times 1 -Exactly -ParameterFilter {$RunId -eq 'test-run'}
        }
        It 'continues Integration after a Unit assertion fails and blocks the expensive mutation' {
            Mock Invoke-MutatorValidationChild { @{NativeOutcome='Failed';Summary=@{Passed=1;Failed=1;Skipped=0;DiscoveryErrors=0;SourceUnchanged=$true}} } -ParameterFilter {$Arguments -contains (Join-Path $script:ValidationRoot 'modules/Fixture.Validation/test/Unit')}
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Modules['Fixture.Validation'].Suites.Unit.Outcome|Should -BeExactly Failed
            $r.Modules['Fixture.Validation'].Suites.Integration.Outcome|Should -BeExactly Success
            $r.Modules['Fixture.Validation'].Suites.Mutations.Outcome|Should -BeExactly Blocked
            Should -Invoke Invoke-MutatorRun -Times 0 -Exactly
        }
        It 'fails closed on empty Pester discovery' {
            Mock Invoke-MutatorValidationChild { @{NativeOutcome='Success';Summary=@{Passed=0;Failed=0;Skipped=0;DiscoveryErrors=0;SourceUnchanged=$true}} }
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Outcome|Should -BeExactly Failed
            $r.FullGateSatisfied|Should -BeFalse
        }
        It 'fails closed on timeout even with a plausible Pester summary' {
            Mock Invoke-MutatorValidationChild { @{NativeOutcome='Timeout';Summary=@{Passed=3;Failed=0;Skipped=0;DiscoveryErrors=0;SourceUnchanged=$true}} }
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Modules['Fixture.Validation'].Suites.Mutations.Outcome|Should -BeExactly Blocked
        }
        It 'does not invent a complete gate for a selected unit suite' {
            $request=Read-MutatorJson (Join-Path $script:ValidationRoot 'request.json');$request.Test=@('Unit');Write-MutatorJson (Join-Path $script:ValidationRoot 'request.json') $request
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Outcome|Should -BeExactly Success -Because ($r|ConvertTo-Json -Depth 8 -Compress)
            $r.FullGateSatisfied|Should -BeFalse
            Should -Invoke Invoke-MutatorRun -Times 0 -Exactly
            Should -Invoke Invoke-MutatorValidationChild -Times 1 -Exactly -ParameterFilter {$Arguments -contains '-TestScope' -and $Arguments -contains 'Unit'}
        }
        It 'refuses a coverage gate below 100 percent' {
            Mock Merge-MutatorCoverage { @{FullGateSatisfied=$false} }
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Modules['Fixture.Validation'].Coverage.Outcome|Should -BeExactly CoverageIncomplete -Because ($r|ConvertTo-Json -Depth 8 -Compress)
            $r.Outcome|Should -BeExactly Failed
        }
        It 'refuses a survivor despite a rounded score of 100' {
            Mock Get-MutatorRun { @{Path='isolated-mutation';Outcome='Success';EvaluatedMutants=10001;PlannedMutants=10001;SurvivedMutants=1} }
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Modules['Fixture.Validation'].Suites.Mutations.Outcome|Should -BeExactly Failed
        }
        It 'rejects the wrong guest OS before executing a test' {
            $request=Read-MutatorJson (Join-Path $script:ValidationRoot 'request.json');$request.OS='ForeignOS';Write-MutatorJson (Join-Path $script:ValidationRoot 'request.json') $request
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Outcome|Should -BeExactly Failed
            Should -Invoke Invoke-MutatorValidationChild -Times 0 -Exactly
            Test-Path (Join-Path $script:ValidationReports 'result.json')|Should -BeTrue
        }
        It 'rejects modified frozen sources before test discovery' {
            Mock Get-MutatorSourceSnapshot { @{Sha256='different'} }
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Outcome|Should -BeExactly Failed
            Should -Invoke Invoke-MutatorValidationChild -Times 0 -Exactly
        }
        It 'retains a missing report as failure' {
            Remove-Item -LiteralPath (Join-Path $script:Origin 'tests.xml')
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Outcome|Should -BeExactly Failed
        }
        It 'retains XML diagnostics even when the baseline fails' {
            Mock Invoke-MutatorValidationChild {
                @{NativeOutcome='Failed';Summary=@{Passed=1;Failed=1;Skipped=0;DiscoveryErrors=0;SourceUnchanged=$true;Report=(Join-Path $script:Origin 'tests.xml')}}
            }
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Modules['Fixture.Validation'].Suites.Mutations.Outcome|Should -BeExactly Blocked
            Test-Path (Join-Path $script:ValidationReports 'unit/Fixture.Validation/tests.xml')|Should -BeTrue
            Test-Path (Join-Path $script:ValidationReports 'integration/Fixture.Validation/tests.xml')|Should -BeTrue
        }
        It 'refuses unsafe module names before discovery: <Name>' -ForEach @(@{Name='../Foreign'},@{Name=''},@{Name='a/b'},@{Name='a\b'}) {
            $request=Read-MutatorJson (Join-Path $script:ValidationRoot 'request.json');$request.Modules=@($Name)
            Write-MutatorJson (Join-Path $script:ValidationRoot 'request.json') $request
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Outcome|Should -BeExactly Failed
            Should -Invoke Invoke-MutatorValidationChild -Times 0
        }
        It 'refuses missing coverage and missing branch proof independently: <Fault>' -ForEach @(@{Fault='coverage'},@{Fault='branch'}) {
            if($Fault -eq 'coverage'){Remove-Item -LiteralPath (Join-Path $script:Origin 'coverage.json')}
            else{Mock Invoke-MutatorValidationChild {@{NativeOutcome='Success';Summary=@{}}} -ParameterFilter {$Arguments -contains '-TestScope'}}
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Outcome|Should -BeExactly Failed
            if($Fault -eq 'coverage'){$r.Modules['Fixture.Validation'].Suites.Mutations.Outcome|Should -BeExactly Blocked}
            else{$r.Modules['Fixture.Validation'].Coverage.Error|Should -BeLike '*Branch qualification failed*'}
        }
        It 'uses Integration-only coverage without claiming a complete gate' {
            $request=Read-MutatorJson (Join-Path $script:ValidationRoot 'request.json');$request.Test=@('Integration')
            Write-MutatorJson (Join-Path $script:ValidationRoot 'request.json') $request
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Outcome|Should -BeExactly Success;$r.FullGateSatisfied|Should -BeFalse
            Should -Invoke Invoke-MutatorValidationChild -Times 1 -Exactly -ParameterFilter {$Arguments -contains 'Integration' -and $Arguments -contains '-TestScope'}
            Should -Invoke Merge-MutatorCoverage -Times 1 -Exactly -ParameterFilter {$Path.Count -eq 1}
        }
        It 'polls mutation progress and records the configured C# report rather than declaring it inapplicable' {
            Write-MutatorJson (Join-Path $script:ValidationRoot 'modules/Fixture.Validation/engine/dotnet-tools.json') @{}
            $script:ValidationMutationPolls=0
            Mock Get-MutatorProgress {
                $script:ValidationMutationPolls++
                @{Outcome=$(if($script:ValidationMutationPolls -eq 1){'Running'}else{'Success'});CompletionPercent=50;FailedPackages=0;EvaluatedMutants=1;PlannedMutants=2}
            }
            Mock Start-Sleep {}
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.Modules['Fixture.Validation'].Suites.Mutations.Stryker.Outcome|Should -BeExactly Success
            $r.Modules['Fixture.Validation'].Suites.Mutations.Stryker.Report|Should -BeExactly 'mutations/Fixture.Validation/runs/packages/p0000/stryker/reports'
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter {$Seconds -eq 2}
            Should -Invoke Copy-MutatorValidationMutationProof -Times 3 -Exactly
        }
        It 'invalidates all evidence if the frozen sources change after execution' {
            $script:ValidationSnapshots=0
            Mock Get-MutatorSourceSnapshot {$script:ValidationSnapshots++;@{Sha256=$(if($script:ValidationSnapshots -eq 1){'fixed'}else{'changed'})}}
            $r=Invoke-MutatorValidationWorkload $script:ValidationRoot $script:ValidationReports
            $r.SourceUnchanged|Should -BeFalse;$r.FullGateSatisfied|Should -BeFalse;$r.Outcome|Should -BeExactly Failed
        }
    }
}
Describe 'Validation child capture preserves parseable summaries and native diagnostics' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        It 'retains both streams and returns only the last structured summary: <HasSummary>' -ForEach @(@{HasSummary=$true},@{HasSummary=$false}) {
            $script:ChildHasSummary=$HasSummary
            Mock Invoke-MutatorNative {@{Stdout=$(if($script:ChildHasSummary){"progress`n{`"Passed`":2}"}else{'progress only'});Stderr='retained error';Outcome='Failed';ExitCode=7;Failure=@{Message='business failure'}}}
            $proof=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $result=Invoke-MutatorValidationChild @('-NoProfile','-File','fixture.ps1') $TestDrive $proof 31
            $result.ExitCode|Should -Be 7;$result.NativeOutcome|Should -BeExactly Failed
            if($HasSummary){$result.Summary.Passed|Should -Be 2}else{$result.Summary|Should -BeNullOrEmpty}
            [IO.File]::ReadAllText((Join-Path $proof 'stderr.log'))|Should -BeExactly 'retained error'
            (Read-MutatorJson (Join-Path $proof 'native.json')).Failure.Message|Should -BeExactly 'business failure'
            Should -Invoke Invoke-MutatorNative -Times 1 -Exactly -ParameterFilter {$TimeoutSeconds -eq 31 -and $Arguments -contains 'fixture.ps1'}
        }
        It 'rejects malformed JSON while retaining the original logs' {
            Mock Invoke-MutatorNative {@{Stdout='{invalid';Stderr='';Outcome='Success';ExitCode=0;Failure=$null}}
            $proof=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            {Invoke-MutatorValidationChild @() $TestDrive $proof}|Should -Throw
            [IO.File]::ReadAllText((Join-Path $proof 'stdout.log'))|Should -BeExactly '{invalid'
        }
        It 'identifies the host platform from OS boundaries: <Platform>' -ForEach @(@{Platform='Windows'},@{Platform='Linux'},@{Platform='MacOS'}) {
            $script:ContractPlatform=$Platform
            Mock Test-MutatorWindowsPlatform {$script:ContractPlatform -eq 'Windows'}
            Mock Test-MutatorLinuxPlatform {$script:ContractPlatform -eq 'Linux'}
            Get-MutatorHostPlatform|Should -BeExactly $Platform
        }
    }
}
Describe 'Guest-local mutation proof mirror' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        It 'exports package evidence and Stryker reports without copying mutation sandboxes' {
            $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $destination=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            Write-MutatorJson (Join-Path $root 'run.json') @{Id='proof-run'}
            Write-MutatorJson (Join-Path $root 'packages/p0000/state.json') @{Outcome='Failed';Error='Survivor'}
            Write-MutatorJson (Join-Path $root 'packages/p0000/stryker/reports/mutation-report.json') @{Score=50}
            Write-MutatorJson (Join-Path $root 'packages/p0000/sandbox/private.json') @{NeverExport=$true}
            Copy-MutatorValidationMutationProof $root $destination
            (Read-MutatorJson (Join-Path $destination 'packages/p0000/state.json')).Error|Should -BeExactly Survivor
            Test-Path (Join-Path $destination 'packages/p0000/stryker/reports/mutation-report.json')|Should -BeTrue
            Test-Path (Join-Path $destination 'packages/p0000/sandbox')|Should -BeFalse
            Write-MutatorJson (Join-Path $root 'packages/p0000/state.json') @{Outcome='Success'}
            Copy-MutatorValidationMutationProof $root $destination
            (Read-MutatorJson (Join-Path $destination 'packages/p0000/state.json')).Outcome|Should -BeExactly Success
            @(Get-ChildItem $destination -Recurse -File -Filter '*.tmp').Count|Should -Be 0
        }
    }
}
