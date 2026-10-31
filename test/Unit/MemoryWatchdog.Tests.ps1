<#
.SYNOPSIS
Expected behavior for the MemoryWatchdog tests.

.DESCRIPTION
Pressure is measured across total host RAM, but recovery targets only registered owned workers.
Recycled PIDs and editor sessions are excluded; failures remain visible and state-file locking stays
bounded.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    & (Get-Module FrenchExDev.Mutator.PoSh) {. (Join-Path $script:MutatorRoot 'test/Fixtures/WindowsCimContracts.ps1')}
}
Describe 'Host RAM watchdog' {
    It 'reacts to total host RAM and selects only a registered owned worker' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $settings=@{TriggerBytes=48e9;MinimumProcessBytes=1e9}
            Mock Get-MutatorOwnedMemoryRun {param($Target);if($Target.Id -eq 2){@{Path='owned'}}}
            $sample=@{UsedBytes=49e9;Processes=@(@{Id=1;WorkingSetBytes=2e9},@{Id=2;WorkingSetBytes=8e9},@{Id=$PID;WorkingSetBytes=20e9})}
            (Get-MutatorMemoryRecoveryTarget $sample $settings).Id|Should -Be 2
            $sample.UsedBytes=47e9
            Get-MutatorMemoryRecoveryTarget $sample $settings|Should -BeNullOrEmpty
            $sample.UsedBytes=51e9;$sample.Processes=@(@{Id=1;WorkingSetBytes=1e6})
            Get-MutatorMemoryRecoveryTarget $sample $settings|Should -BeNullOrEmpty
        }
    }
    It 'refuses a recycled PID before attempting any recovery' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $target=@{Id=99;ParentId=1;StartedUtc='2026-10-26T00:00:00.0000000Z';WorkingSetBytes=9e9}
            Mock Get-CimInstance { [pscustomobject]@{Name='pwsh.exe';CreationDate=[datetime]'2026-10-26T01:00:00Z';ParentProcessId=1} }
            {Invoke-MutatorMemoryRecovery $target $Root}|Should -Throw '*identity changed*'
            Test-Path (Join-Path $Root 'events')|Should -BeFalse
        }
    }
    It 'reports a monitoring error without claiming success or killing processes' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            Write-MutatorJson (Join-Path $Root 'watchdog.json') @{PollSeconds=1;TriggerBytes=48e9;MinimumProcessBytes=1e9}
            Mock Get-MutatorHostMemorySample { throw 'OS counters inaccessible' }
            Mock Start-Sleep { Write-MutatorJson (Join-Path $Root 'stop.json') @{} }
            Mock Invoke-MutatorMemoryRecovery { throw 'Must never run on a bad sample' }
            Invoke-MutatorMemoryWatchdogLoop $Root
            (Read-MutatorJson (Join-Path $Root 'state.json')).Error|Should -BeExactly 'OS counters inaccessible'
            Should -Invoke Invoke-MutatorMemoryRecovery -Times 0
        }
    }
    It 'excludes even verified Editor Services processes from memory recovery' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $target=@{Id=99;ParentId=1;StartedUtc=([datetime]'2026-10-26T00:00:00Z').ToUniversalTime().ToString('O');WorkingSetBytes=9e9}
            Mock Get-CimInstance {
                param($Filter)
                if($Filter -eq 'ProcessId=99'){return [pscustomobject]@{Name='pwsh.exe';CreationDate=[datetime]'2026-10-26T00:00:00Z';ParentProcessId=1;CommandLine='Start-EditorServices PowerShellEditorServices'}}
                [pscustomobject]@{Name='Code - Insiders.exe'}
            }
            Mock Stop-MutatorMemoryProcess {}
            Mock Restart-MutatorEditorSession { @{Id=100;Mode='VerifiedVSCodeCommand'} }
            {Invoke-MutatorMemoryRecovery $target $Root}|Should -Throw '*registered owned Mutator worker*'
            Should -Invoke Stop-MutatorMemoryProcess -Times 0
            Should -Invoke Restart-MutatorEditorSession -Times 0
            Test-Path (Join-Path $Root 'events')|Should -BeFalse
        }
    }
}
Describe 'Atomic state updates during concurrent reads' {
    It 'waits for a transient exclusive state-file handle without failing the supervisor' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $path=Join-Path $Root 'temporarily-locked.json'
            Write-MutatorJson $path @{Outcome='Monitoring';UsedBytes=37000000000L;Utc='2026-10-26T19:00:00Z'}
            $handle=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $worker=[powershell]::Create()
            try {
                [void]$worker.AddScript('param($Handle);Start-Sleep -Milliseconds 300;$Handle.Dispose()').AddArgument($handle)
                $pending=$worker.BeginInvoke()
                $state=Read-MutatorJson $path
                $state.Outcome|Should -BeExactly Monitoring
                $state.UsedBytes|Should -Be 37000000000L
                $state.Utc|Should -BeOfType ([string])
                $null=$worker.EndInvoke($pending)
            } finally {$handle.Dispose();$worker.Dispose()}
        }
    }
    It 'distinguishes absent JSON from invalid retained state' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            Read-MutatorJson (Join-Path $Root 'absent.json')|Should -BeNullOrEmpty
            $path=Join-Path $Root 'invalid.json'
            [IO.File]::WriteAllText($path,'not JSON')
            {Read-MutatorJson $path}|Should -Throw
        }
    }
    It 'publishes a complete replacement while preserving an already open reader' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $path=Join-Path $Root 'atomic.json';Write-MutatorJson $path @{Value=1}
            $reader=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $worker=[powershell]::Create()
            try{
                if($IsWindows){
                    [void]$worker.AddScript('param($Handle);Start-Sleep -Milliseconds 300;$Handle.Dispose()').AddArgument($reader)
                    $pending=$worker.BeginInvoke()
                }
                Write-MutatorJson $path @{Value=2}
                if(!$IsWindows){
                    $original=[IO.StreamReader]::new($reader,[Text.Encoding]::UTF8,$true,1024,$true)
                    try {($original.ReadToEnd()|ConvertFrom-Json).Value|Should -Be 1}
                    finally {$original.Dispose()}
                }
                if($IsWindows){$null=$worker.EndInvoke($pending)}
                (Read-MutatorJson $path).Value|Should -Be 2
            }finally{$reader.Dispose();$worker.Dispose()}
        }
    }
}
