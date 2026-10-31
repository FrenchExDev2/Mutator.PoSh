BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Audit ownership and advisory monitoring' {
    It 'recognizes the registered <Worker> with quoted native options' -ForEach @(@{Worker='Run-Worker.ps1'},@{Worker='Run-DetachedWorker.ps1'}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive;Worker=$Worker} {
            param($Root,$Worker)
            $target=@{Id=9988;StartedUtc='2026-10-31T00:00:00.0000000Z'}
            Write-MutatorJson (Join-Path $Root 'run.json') @{Process=$target;Packages=@(@{Id='p0000'})}
            Mock Test-MutatorProcess {$true}
            $command='pwsh "-NoProfile" "-File" "'+(Join-Path $script:MutatorRoot ('resources/'+$Worker))+'" "-RunDirectory" "'+$Root+'"'
            (Get-MutatorOwnedMemoryRun $target $command).Path|Should -BeExactly $Root
            $target.StartedUtc='2026-10-30T00:00:00.0000000Z'
            Get-MutatorOwnedMemoryRun $target $command|Should -BeNullOrEmpty
        }
    }
    It 'rejects a command string that only mentions the worker filename' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $command='pwsh -Command ''-File "'+(Join-Path $script:MutatorRoot 'resources/Run-Worker.ps1')+'" -RunDirectory C:/foreign'''
            Get-MutatorOwnedMemoryRun @{Id=9988;StartedUtc='2026-10-31T00:00:00Z'} $command|Should -BeNullOrEmpty
        }
    }
    It 'keeps dashboard failure advisory and retains a masked error' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $run=@{Outcome='Success'}
            Mock Show-MutatorDashboard {throw 'dashboard inaccessible'}
            {Update-MutatorSupervisionDashboard $Root $run}|Should -Not -Throw
            $run.Outcome|Should -BeExactly Success
            (Read-MutatorJson (Join-Path $Root 'dashboard-error.json')).Error|Should -Match 'dashboard inaccessible'
        }
    }
}
