<#
.SYNOPSIS
Expected behavior for the NativeBoundaryContracts tests.

.DESCRIPTION
Keep native streams local, preserve actual exit codes and emit only consistent advisory counters.
Worker argv/identity and platform routing must stay literal and owned.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Captured native boundary and worker launch identities' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        It 'keeps both streams local and records only consistent Stryker progress counters' {
            $progress=Join-Path $TestDrive 'native-progress.jsonl'
            $pwsh=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
            $command="'Mutation testing 1/2';'tested mutants 3/2';'mutation testing 0/0';[Console]::Error.WriteLine('retained diagnostic')"
            $r=Invoke-MutatorNative $pwsh @('-NoProfile','-Command',$command) $script:MutatorRoot 30 $progress
            $r.Outcome|Should -BeExactly Success
            $r.Stdout|Should -Match 'Mutation testing 1/2'
            $r.Stderr|Should -Match 'retained diagnostic'
            $records=@(Get-Content $progress|ForEach-Object {$_|ConvertFrom-Json -AsHashtable})
            $records.Count|Should -Be 1
            $records[0].Evaluated|Should -Be 1
            $records[0].Planned|Should -Be 2
        }
        It 'retains a failed command once and exposes its actual exit code' {
            $pwsh=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
            $r=Invoke-MutatorNative $pwsh @('-NoProfile','-Command',"[Console]::Error.WriteLine('fixture failure');exit 7") $script:MutatorRoot 30
            $r.Outcome|Should -BeExactly Failed
            $r.ExitCode|Should -Be 7
            $r.Stderr|Should -Match 'fixture failure'
            $r.Failure|Should -Not -BeNullOrEmpty
        }
        It 'starts package workers with literal quoted arguments and a retained process identity: <Windows>' -ForEach @(@{Windows=$true},@{Windows=$false}) {
            $script:NativeFixtureWindows=$Windows
            $directory=Join-Path $TestDrive 'run with spaces'
            Mock Test-MutatorWindowsPlatform {$script:NativeFixtureWindows}
            Mock Start-Process { [pscustomobject]@{Id=987654;StartTime=[datetime]'2026-10-27T00:00:00Z'} }
            $r=Start-MutatorWorker -RunDirectory $directory -Package p0000
            $r.Id|Should -Be 987654
            $r.Role|Should -BeExactly p0000
            $r.StartedUtc|Should -BeExactly ([datetime]'2026-10-27T00:00:00Z').ToUniversalTime().ToString('O')
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $ArgumentList -contains ('"'+$directory+'"') -and $RedirectStandardOutput -eq (Join-Path $directory 'p0000.stdout.log') -and
                $FilePath -ceq (Get-MutatorPowerShellExecutable) -and $(if($script:NativeFixtureWindows){$WindowStyle -eq 'Hidden'}else{!$WindowStyle})
            }
        }
        It 'delegates the Windows supervisor to the owned detached-worker boundary' {
            Mock Test-MutatorWindowsPlatform {$true}
            Mock Start-MutatorDetachedWorker {@{Id=12345}}
            Mock Start-Process {throw 'No direct supervisor process on Windows'}
            (Start-MutatorWorker -RunDirectory $TestDrive).Id|Should -Be 12345
            Should -Invoke Start-MutatorDetachedWorker -Times 1 -Exactly
        }
        It 'starts the Linux supervisor without a package argument' {
            Mock Test-MutatorWindowsPlatform {$false}
            Mock Start-Process { [pscustomobject]@{Id=12345;StartTime=[datetime]'2026-10-27T00:00:00Z'} }
            (Start-MutatorWorker -RunDirectory $TestDrive).Role|Should -BeExactly supervisor
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {$ArgumentList -notcontains '"-Package"'}
        }
        It 'refuses incomplete process identities without querying live processes' {
            Mock Get-Process {throw 'No query for an incomplete identity'}
            foreach($identity in @($null,@{},@{Id=1},@{StartedUtc='2026-10-27'})){Test-MutatorProcess $identity|Should -BeFalse}
            Should -Invoke Get-Process -Times 0 -Exactly
        }
        It 'uses the documented owned run root when none is specified' {
            Get-MutatorRunRoot|Should -BeExactly (Join-Path $script:MutatorRoot 'test/Artifacts/mutator')
        }
    }
}
