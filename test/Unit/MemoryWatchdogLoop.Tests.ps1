<#
.SYNOPSIS
Expected behavior for the MemoryWatchdogLoop tests.

.DESCRIPTION
Retain the actual recovery action/error and honor cooldowns. Repeated pressure must not cause
unbounded duplicate recovery or invent an owned process target.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'RAM watchdog recovery and cooldown outcomes' {
    It 'retains the actual action and limits repeated recovery: <Scenario>' -ForEach @(
        @{Scenario='low pressure';Expected='Monitoring';Loops=1}
        @{Scenario='PowerShell recovery';Expected='Restarted';Loops=1}
        @{Scenario='PowerShell cooldown';Expected='Restarted';Loops=2}
        @{Scenario='cache recovery';Expected='CacheReclaimed';Loops=1}
        @{Scenario='cache cooldown';Expected='CacheReclaimed';Loops=2}
        @{Scenario='no reclaimable target';Expected='PressureWithoutOwnedWorker';Loops=1}
        @{Scenario='cache unavailable';Expected='MonitoringFailed';Loops=1}
        @{Scenario='recovery refused';Expected='RecoveryFailed';Loops=1}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive;Scenario=$Scenario;Expected=$Expected;Loops=$Loops} {
            param($Root,$Scenario,$Expected,$Loops)
            $watchdogDirectory=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $machine=if($Scenario -like 'cache*'){'fixture-vm'}else{$null}
            Write-MutatorJson (Join-Path $watchdogDirectory 'watchdog.json') @{PollSeconds=2;TriggerBytes=38e9;MinimumProcessBytes=1e9;PodmanMachine=$machine}
            $script:LoopScenario=$Scenario
            $script:LoopStates=[Collections.Generic.List[object]]::new()
            Mock Get-MutatorHostMemorySample {
                @{Utc=[datetime]::UtcNow.ToString('O');UsedBytes=$(if($script:LoopScenario -eq 'low pressure'){37e9}else{40e9});Processes=@()}
            }
            Mock Get-MutatorMemoryRecoveryTarget {
                if($script:LoopScenario -like 'PowerShell*' -or $script:LoopScenario -eq 'recovery refused'){@{Id=12345;WorkingSetBytes=2e9}}
            }
            Mock Invoke-MutatorMemoryRecovery {
                param($Target,$Directory)
                $Target.Id | Should -Be 12345
                $Directory | Should -BeExactly $watchdogDirectory
                if($script:LoopScenario -eq 'recovery refused'){@{Outcome='RecoveryFailed';Error='fixture identity refused'}}
                else{@{Outcome='Restarted';Id=$Target.Id}}
            }
            Mock Invoke-MutatorPodmanCacheRecovery {
                param($Machine)
                $Machine | Should -BeExactly fixture-vm
                if($script:LoopScenario -eq 'cache unavailable'){throw 'fixture VM unavailable'}
                @{Outcome='CacheReclaimed';Kind='PodmanCache';Machine=$Machine;CachedBytes=2e9}
            }
            Mock Start-Sleep {
                param($Seconds)
                $Seconds | Should -Be 2
                $script:LoopStates.Add((Read-MutatorJson (Join-Path $watchdogDirectory 'state.json')))
                if($script:LoopStates.Count -ge $Loops){Write-MutatorJson (Join-Path $watchdogDirectory 'stop.json') @{Reason='FixtureComplete'}}
            }
            Invoke-MutatorMemoryWatchdogLoop $watchdogDirectory
            $script:LoopStates.Count | Should -Be $Loops
            $script:LoopStates[0].Outcome | Should -BeExactly $Expected
            $final=Read-MutatorJson (Join-Path $watchdogDirectory 'state.json')
            $final.Outcome | Should -BeExactly Stopped
            if($Scenario -like 'PowerShell*'){
                $final.LastAction.Id | Should -Be 12345
                Should -Invoke Invoke-MutatorMemoryRecovery -Times 1
            }elseif($Scenario -eq 'recovery refused'){
                $final.Error | Should -BeExactly 'fixture identity refused'
                Should -Invoke Invoke-MutatorMemoryRecovery -Times 1
            }else{Should -Invoke Invoke-MutatorMemoryRecovery -Times 0}
            if($Scenario -like 'cache*'){
                Should -Invoke Invoke-MutatorPodmanCacheRecovery -Times 1
                if($Scenario -eq 'cache unavailable'){$final.Error | Should -BeExactly 'fixture VM unavailable'}
                else{
                    $final.LastAction.Machine | Should -BeExactly fixture-vm
                    @(Get-ChildItem -LiteralPath (Join-Path $watchdogDirectory 'events') -File).Count | Should -Be 1
                }
            }else{Should -Invoke Invoke-MutatorPodmanCacheRecovery -Times 0}
            if($Scenario -eq 'no reclaimable target'){$final.Error | Should -Match 'no registered Mutator worker above the minimum'}
            if($Loops -eq 2){$script:LoopStates[1].Outcome | Should -BeExactly Monitoring}
            Should -Invoke Get-MutatorHostMemorySample -Times $Loops
        }
    }
}
