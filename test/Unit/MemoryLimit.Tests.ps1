<#
.SYNOPSIS
Expected behavior for the MemoryLimit tests.

.DESCRIPTION
Parse decimal French/English and binary RAM units correctly. Requested watchdog limits update policy
without changing mutation worker reservations.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    & (Get-Module FrenchExDev.Mutator.PoSh) {. (Join-Path $script:MutatorRoot 'test/Fixtures/WindowsCimContracts.ps1')}
}
Describe 'Host RAM command argument' {
    It 'accepts French decimal Go and distinguishes binary GiB' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            ConvertTo-MutatorMemoryLimit 40go|Should -Be 40000000000L
            ConvertTo-MutatorMemoryLimit '40 GB'|Should -Be 40000000000L
            ConvertTo-MutatorMemoryLimit '40GiB'|Should -Be 42949672960L
            ConvertTo-MutatorMemoryLimit '40,5go'|Should -Be 40500000000L
            {ConvertTo-MutatorMemoryLimit '0go'}|Should -Throw '*between*'
            {ConvertTo-MutatorMemoryLimit '40mb'}|Should -Throw '*Ram expects*'
        }
    }
    It 'starts the requested host watchdog and records its limit without changing worker reservations' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $module=Join-Path $Root 'P'
            Write-MutatorJson (Join-Path $module 'test/psmutant.config.json') @{coveredLinesOnly=$false;sandboxSubtrees=@('P');mutate=@('P/Value.ps1');tests=@{'P/Value.ps1'=@('P/test/Value.Tests.ps1')}}
            Mock Start-MutatorMemoryWatchdog { [pscustomobject]@{Path='watchdog';Running=$true} }
            Mock Invoke-MutatorRunCore {}
            $result=Invoke-MutatorRun -ModulePath $module -SourceRoot $Root -RunRoot (Join-Path $Root 'runs') -Ram 40go -MemoryBudgetMiB 4096
            $stored=Read-MutatorJson (Join-Path $result.Path 'run.json')
            $stored.HostMemoryLimitBytes|Should -Be 40000000000L
            $stored.Schedule.MemoryBudgetMiB|Should -Be 4096
            Should -Invoke Start-MutatorMemoryWatchdog -Times 1 -ParameterFilter {$LimitGB -eq 40}
        }
    }
    It 'replaces an existing 50 Go policy when 40 Go is requested' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $script:PolicyPath=Join-Path $Root 'policy'
            Write-MutatorJson (Join-Path $script:PolicyPath 'watchdog.json') @{LimitBytes=50e9;TriggerBytes=48e9;PollSeconds=2;MinimumProcessBytes=1e9;Process=@{Id=123;StartedUtc='2026-10-26T00:00:00Z'}}
            Mock Test-MutatorProcess {param($Identity);$Identity.Id -ne 123 -or !(Test-Path (Join-Path $script:PolicyPath 'stop.json'))}
            Mock Get-CimInstance { [pscustomobject]@{} }
            Mock Start-MutatorDetachedWorker { @{Id=124;StartedUtc=[datetime]::UtcNow.ToString('O')} }
            if(!$IsWindows){
                {Start-MutatorMemoryWatchdog -Path $script:PolicyPath -LimitGB 40}|Should -Throw '*requires Windows*'
                (Read-MutatorJson (Join-Path $script:PolicyPath 'watchdog.json')).LimitBytes|Should -Be 50000000000L
                Should -Invoke Start-MutatorDetachedWorker -Times 0
                Should -Invoke Get-CimInstance -Times 0
                return
            }
            $result=Start-MutatorMemoryWatchdog -Path $script:PolicyPath -LimitGB 40
            $result.LimitGB|Should -Be 40
            $result.TriggerGB|Should -Be 38
            Should -Invoke Start-MutatorDetachedWorker -Times 1 -ParameterFilter {$Kind -eq 'MemoryWatchdog'}
        }
    }
}
