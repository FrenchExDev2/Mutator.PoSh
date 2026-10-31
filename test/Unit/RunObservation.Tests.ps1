<#
.SYNOPSIS
Expected behavior for the RunObservation tests.

.DESCRIPTION
Report startup failures separately from interrupted local runs and do not query foreign-host PIDs.
Preserve exact discovered/evaluated counts, including historical equivalence observations.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Retained supervisor startup failure' {
    It 'reports a failed startup and its diagnostic rather than a running or interrupted campaign' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $path=Join-Path $Root 'startup-failure'
            $platform=if($IsWindows){'windows'}elseif($IsMacOS){'macos'}else{'linux'}
            Write-MutatorJson (Join-Path $path 'run.json') @{Id='fixture';Outcome='Starting';Platform=$platform;HostName=[Environment]::MachineName
                Runtime=$PSVersionTable.PSVersion.ToString();CreatedUtc=[datetime]::UtcNow.ToString('O');Process=@{Id=12345;StartedUtc='2026-10-26T00:00:00Z'};Packages=@(@{Id='p0';Name='Fixture'})}
            Write-MutatorJson (Join-Path $path 'supervisor-failure.json') @{Outcome='Failed';Phase='SupervisorStartup';Error='fixture startup failed'}
            Mock Test-MutatorProcess {$false}
            Mock Get-MutatorMemoryWatchdog {@{Running=$false}}
            $run=Get-MutatorRun -Path $path
            $run.Outcome | Should -BeExactly Failed
            $run.Error | Should -BeExactly 'fixture startup failed'
            $run.EvaluatedMutants | Should -Be 0
            $progress=Get-MutatorProgress -Path $path
            $progress.Outcome | Should -BeExactly Failed
            $progress.Error | Should -BeExactly 'fixture startup failed'
        }
    }
}
Describe 'Run observations respect process namespaces and complete discovery counts' {
    It 'does not query local process IDs for a remote run: <Remote>' -ForEach @(@{Remote='platform'},@{Remote='host'}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=(Join-Path $TestDrive $Remote);Remote=$Remote} {
            param($Root,$Remote)
            $platform=if($IsWindows){'windows'}elseif($IsMacOS){'macos'}else{'linux'}
            $hostName=[Environment]::MachineName
            if($Remote -eq 'platform'){$platform=if($platform -eq 'linux'){'windows'}else{'linux'}}else{$hostName='remote-mutation-host'}
            Write-MutatorJson (Join-Path $Root 'run.json') @{Id='remote';Platform=$platform;Runtime='7.6.7';HostName=$hostName;Outcome='Running';CreatedUtc='2026-10-26T00:00:00Z';Process=@{Id=1;StartedUtc='2026-10-26T00:00:00Z'};Packages=@()}
            Mock Get-MutatorMemoryWatchdog {[pscustomobject]@{Running=$true;Outcome='Monitoring'}}
            Mock Test-MutatorProcess {throw 'A remote PID is not a local process identity.'}
            $view=Get-MutatorRun -Path $Root
            $view.Outcome|Should -BeExactly Running
            $view.ObserverLocal|Should -BeFalse
            Should -Invoke Test-MutatorProcess -Times 0
        }
    }
    It 'still reports an interrupted local run when its recorded process has exited' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=(Join-Path $TestDrive 'local')} {
            param($Root)
            $platform=if($IsWindows){'windows'}elseif($IsMacOS){'macos'}else{'linux'}
            Write-MutatorJson (Join-Path $Root 'run.json') @{Id='local';Platform=$platform;Runtime='7.6.7';HostName=[Environment]::MachineName;Outcome='Running';CreatedUtc='2026-10-26T00:00:00Z';Process=@{Id=1;StartedUtc='2026-10-26T00:00:00Z'};Packages=@()}
            Mock Test-MutatorProcess {$false}
            $view=Get-MutatorRun -Path $Root
            $view.Outcome|Should -BeExactly Interrupted
            $view.ObserverLocal|Should -BeTrue
            Should -Invoke Test-MutatorProcess -Times 1
        }
    }
    It 'retains equivalent mutants in the number evaluated and discovered after completion' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=(Join-Path $TestDrive 'completed')} {
            param($Root)
            Write-MutatorJson (Join-Path $Root 'run.json') @{Id='completed';Platform='linux';Runtime='7.6.7';Outcome='Success';CreatedUtc='2026-10-26T00:00:00Z';Process=$null;Packages=@(@{Id='p0';Name='Fixture'})}
            Write-MutatorJson (Join-Path $Root 'packages/p0/state.json') @{Id='p0';Name='Fixture';Outcome='Success';Phase='Completed';PSMutant=@{Total=344;Killed=344;Survived=0;Equivalent=7;Score=100}}
            $view=Get-MutatorRun -Path $Root
            $view.EvaluatedMutants|Should -Be 351
            $view.PlannedMutants|Should -Be 351
            $view.EquivalentMutants|Should -Be 7
            $view.SurvivedMutants|Should -Be 0
            $view.Packages[0].EvaluatedMutants|Should -Be 351
        }
    }
}
