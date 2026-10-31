BeforeAll { Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking }
Describe 'Force stop with missing run metadata' {
    It 'handles a deleted run without recreating its directory or touching unrelated processes' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $path=Join-Path $Root 'deleted'
            Mock Get-MutatorRunWorkerIdentity { @() }
            $result=Stop-MutatorRun $path -Force
            $result.Outcome | Should -Be Interrupted
            Test-Path -LiteralPath $path | Should -BeFalse
            Should -Invoke Get-MutatorRunWorkerIdentity -Times 1 -ParameterFilter {$RunDirectory -eq $path}
            {Stop-MutatorRun $path} | Should -Throw '*absent*'
        }
    }
    It 'retains reports and marks running package states interrupted without inventing a run receipt' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $path=Join-Path $Root 'missing-metadata'
            Write-MutatorJson (Join-Path $path 'packages/p0/state.json') @{Outcome='Running';Phase='PSMutant'}
            Write-MutatorJson (Join-Path $path 'packages/p0/mutation.json') @{mode='Partial';evaluated=1}
            Mock Get-MutatorRunWorkerIdentity { @() }
            $null=Stop-MutatorRun $path -Force
            (Read-MutatorJson (Join-Path $path 'packages/p0/state.json')).Outcome | Should -Be Interrupted
            (Read-MutatorJson (Join-Path $path 'packages/p0/mutation.json')).evaluated | Should -Be 1
            Test-Path (Join-Path $path 'run.json') | Should -BeFalse
            Test-Path (Join-Path $path 'stop.json') | Should -BeTrue
        }
    }
    It 'honors WhatIf before discovering or stopping any worker' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $path=Join-Path $Root 'whatif'
            Mock Get-MutatorRunWorkerIdentity { throw 'Must not discover processes' }
            $null=Stop-MutatorRun $path -Force -WhatIf
            Should -Invoke Get-MutatorRunWorkerIdentity -Times 0
            Test-Path -LiteralPath $path | Should -BeFalse
        }
    }
}
