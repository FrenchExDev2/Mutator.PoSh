BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Shared mutation resource leases' {
    It 'replaces an idle stale pool policy so a larger guest reservation can start' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $Root=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $run=Join-Path $Root 'larger-run';[void][IO.Directory]::CreateDirectory($run)
            Write-MutatorJson (Join-Path $Root 'resources.json') @{WorkerBudget=1;MemoryBudgetMiB=4096;Leases=@()}
            Mock Start-MutatorWorker {@{Id=$PID;StartedUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('O')}}
            $plan=@{WorkerBudget=2;MemoryBudgetMiB=6144;ReservedMemoryMiB=6144;Slots=1;Workers=1}
            (Start-MutatorLeasedWorker $run p0000 $plan).Id|Should -Be $PID
            (Read-MutatorJson (Join-Path $Root 'resources.json')).MemoryBudgetMiB|Should -Be 6144
        }
    }
    It 'rejects an impossible reservation before starting a worker' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $Root=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $run=Join-Path $Root 'impossible-run';[void][IO.Directory]::CreateDirectory($run)
            Mock Start-MutatorWorker {throw 'Must not launch'}
            {Start-MutatorLeasedWorker $run p0000 @{WorkerBudget=1;MemoryBudgetMiB=4096;ReservedMemoryMiB=6144;Slots=1;Workers=1}}|Should -Throw '*exceeds its own*'
            Should -Invoke Start-MutatorWorker -Times 0
        }
    }
    It 'starts the first package from an empty pool and blocks another reservation at capacity' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $run=Join-Path $Root 'run'
            [void][IO.Directory]::CreateDirectory($run)
            Mock Start-MutatorWorker {@{Id=$PID;StartedUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('O')}}
            $plan=@{WorkerBudget=2;MemoryBudgetMiB=2048;ReservedMemoryMiB=2048;Slots=1;Workers=2}
            $first=Start-MutatorLeasedWorker $run p0000 $plan
            $first.Id | Should -Be $PID
            $second=Start-MutatorLeasedWorker $run p0001 $plan
            $second | Should -BeNullOrEmpty
            Should -Invoke Start-MutatorWorker -Times 1 -Exactly
        }
    }
}
