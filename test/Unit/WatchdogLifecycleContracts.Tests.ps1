BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    & (Get-Module FrenchExDev.Mutator.PoSh) {. (Join-Path $script:MutatorRoot 'test/Fixtures/WindowsCimContracts.ps1')}
}
Describe 'Memory watchdog lifecycle and retained measurements' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            . (Join-Path $script:MutatorRoot 'test/Fixtures/WindowsCimContracts.ps1')
            $script:WatchdogRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:WatchdogLiveness=[Collections.Generic.Queue[bool]]::new()
            Mock Test-MutatorWindowsPlatform {$true}
            Mock Get-CimInstance { [pscustomobject]@{TotalVisibleMemorySize=100000;FreePhysicalMemory=50000} }
            Mock Start-MutatorDetachedWorker { @{Id=987654;StartedUtc='2026-10-27T00:00:00Z'} }
            Mock Test-MutatorProcess {
                if($script:WatchdogLiveness.Count){return $script:WatchdogLiveness.Dequeue()}
                $false
            }
            Mock Start-Sleep {}
        }
        It 'arms and stops a private watchdog with the exact requested thresholds' {
            $r=Start-MutatorMemoryWatchdog -LimitGB 40 -HeadroomGB 2 -PollSeconds 3 -MinimumProcessGB 1.5 -Path $script:WatchdogRoot -PodmanMachine dedicated
            $r.LimitGB|Should -Be 40
            $r.TriggerGB|Should -Be 38
            $r.UsedGB|Should -BeNullOrEmpty
            $r.Outcome|Should -BeExactly Starting
            $r.PodmanMachine|Should -BeExactly dedicated
            $config=Read-MutatorJson (Join-Path $script:WatchdogRoot 'watchdog.json')
            $config.PollSeconds|Should -Be 3
            $config.MinimumProcessBytes|Should -Be 1500000000L
            $config.Process.Id|Should -Be 987654
            $null=Stop-MutatorMemoryWatchdog -Path $script:WatchdogRoot
            Test-Path (Join-Path $script:WatchdogRoot 'stop.json')|Should -BeTrue
            Should -Invoke Start-MutatorDetachedWorker -Times 1 -Exactly -ParameterFilter {$Kind -eq 'MemoryWatchdog'}
        }
        It 'refuses an unsupported platform or impossible headroom before reading OS counters' {
            Mock Test-MutatorWindowsPlatform {$false}
            {Start-MutatorMemoryWatchdog -Path $script:WatchdogRoot}|Should -Throw '*requires Windows*'
            Mock Test-MutatorWindowsPlatform {$true}
            {Start-MutatorMemoryWatchdog -LimitGB 4 -HeadroomGB 4 -Path $script:WatchdogRoot}|Should -Throw '*headroom*'
            Should -Invoke Get-CimInstance -Times 0 -Exactly
            Should -Invoke Start-MutatorDetachedWorker -Times 0 -Exactly
        }
        It 'does not claim to be armed when counters are inaccessible' {
            Mock Get-CimInstance {throw 'OS access denied'}
            {Start-MutatorMemoryWatchdog -Path $script:WatchdogRoot}|Should -Throw '*OS access denied*'
            Test-Path (Join-Path $script:WatchdogRoot 'watchdog.json')|Should -BeFalse
        }
        It 'preserves existing files under WhatIf' {
            Write-MutatorJson (Join-Path $script:WatchdogRoot 'stop.json') @{Retained=$true}
            Start-MutatorMemoryWatchdog -Path $script:WatchdogRoot -WhatIf
            (Read-MutatorJson (Join-Path $script:WatchdogRoot 'stop.json')).Retained|Should -BeTrue
            Should -Invoke Start-MutatorDetachedWorker -Times 0 -Exactly
        }
        It 'reuses a living watchdog only when the complete policy matches' {
            Write-MutatorJson (Join-Path $script:WatchdogRoot 'watchdog.json') @{Process=@{Id=1};LimitBytes=40e9;TriggerBytes=38e9;PollSeconds=2;MinimumProcessBytes=1e9;PodmanMachine='dedicated';Outcome='Monitoring'}
            Mock Test-MutatorProcess {$true}
            $r=Start-MutatorMemoryWatchdog -LimitGB 40 -Path $script:WatchdogRoot -PodmanMachine dedicated
            $r.Outcome|Should -BeExactly Monitoring
            Should -Invoke Start-MutatorDetachedWorker -Times 0 -Exactly
            Should -Invoke Get-CimInstance -Times 0 -Exactly
        }
        It 'changes policy after the previous watchdog exits and removes its stale stop signal' {
            Write-MutatorJson (Join-Path $script:WatchdogRoot 'watchdog.json') @{Process=@{Id=1};LimitBytes=50e9;TriggerBytes=48e9;PollSeconds=2;MinimumProcessBytes=1e9;PodmanMachine=$null}
            foreach($v in @($true,$true,$false,$false)){$script:WatchdogLiveness.Enqueue($v)}
            $r=Start-MutatorMemoryWatchdog -LimitGB 40 -Path $script:WatchdogRoot
            $r.LimitGB|Should -Be 40
            Test-Path (Join-Path $script:WatchdogRoot 'stop.json')|Should -BeFalse
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter {$Milliseconds -eq 250}
        }
        It 'projects retained usage, last action and protected errors without a live process' {
            Write-MutatorJson (Join-Path $script:WatchdogRoot 'watchdog.json') @{Process=@{Id=1};LimitBytes=40e9;TriggerBytes=38e9;Outcome='Starting'}
            Write-MutatorJson (Join-Path $script:WatchdogRoot 'state.json') @{UsedBytes=39000000000L;Outcome='Monitoring';Utc='2026-10-27T00:00:00Z';LastAction=@{Kind='Recovery'};Error='token=secret-value'}
            $r=Get-MutatorMemoryWatchdog -Path $script:WatchdogRoot
            $r.Running|Should -BeFalse
            $r.UsedGB|Should -Be 39
            $r.LastAction.Kind|Should -BeExactly Recovery
            $r.LastSampleUtc|Should -BeExactly '2026-10-27T00:00:00Z'
            {Get-MutatorMemoryWatchdog -Path (Join-Path $script:WatchdogRoot 'missing')}|Should -Throw '*No retained*'
            Stop-MutatorMemoryWatchdog -Path $script:WatchdogRoot -WhatIf|Out-Null
            Test-Path (Join-Path $script:WatchdogRoot 'stop.json')|Should -BeFalse
        }
        It 'computes host usage in bytes and refuses impossible samples' {
            Mock Get-CimInstance {
                param($ClassName)
                if($ClassName -eq 'Win32_OperatingSystem'){return [pscustomobject]@{TotalVisibleMemorySize=100000;FreePhysicalMemory=50000}}
                @([pscustomobject]@{ProcessId=$PID;ParentProcessId=1;CreationDate=[datetime]'2026-10-27';WorkingSetSize=100;ExecutablePath='self';CommandLine='self'},
                  [pscustomobject]@{ProcessId=99;ParentProcessId=1;CreationDate=[datetime]'2026-10-27';WorkingSetSize=123456;ExecutablePath='pwsh';CommandLine='pwsh'})
            }
            $r=Get-MutatorHostMemorySample
            $r.UsedBytes|Should -Be 51200000
            $r.TotalBytes|Should -Be 102400000
            $r.Processes.Count|Should -Be 1
            $r.Processes[0].WorkingSetBytes|Should -Be 123456
            Mock Get-CimInstance { [pscustomobject]@{TotalVisibleMemorySize=100;FreePhysicalMemory=100} }
            {Get-MutatorHostMemorySample}|Should -Throw '*invalid*'
        }
    }
}
