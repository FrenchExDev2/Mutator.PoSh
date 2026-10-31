BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    & (Get-Module FrenchExDev.Mutator.PoSh) {. (Join-Path $script:MutatorRoot 'test/Fixtures/WindowsCimContracts.ps1')}
}
Describe 'Durable hidden Windows supervisor launch' {
    It 'starts only an owned plan, hidden, and records the actual process identity' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $directory=Join-Path $Root 'owned run with spaces'
            Write-MutatorJson (Join-Path $directory 'run.json') @{Id='fixture';Packages=@()}
            Mock Start-Process {throw 'A detached supervisor must not inherit the calling process tree.'}
            Mock New-CimInstance {
                param($ClassName,$ClientOnly,$Property)
                $ClassName | Should -BeExactly Win32_ProcessStartup
                $ClientOnly | Should -BeTrue
                $Property.ShowWindow | Should -Be 0
                $Property.CreateFlags | Should -Be 0x01000410
                $Property.EnvironmentVariables | Should -Contain 'MUTATOR_TEST_INHERITED=accents é conservés'
                @{FixtureStartup=$true}
            }
            Mock Invoke-CimMethod {
                param($ClassName,$MethodName,$Arguments)
                $ClassName | Should -BeExactly Win32_Process
                $MethodName | Should -BeExactly Create
                $Arguments.CurrentDirectory | Should -BeExactly $directory
                $Arguments.ProcessStartupInformation.FixtureStartup | Should -BeTrue
                $Arguments.CommandLine | Should -Match ([regex]::Escape('"'+(Join-Path $PSHOME 'pwsh.exe')+'"'))
                $Arguments.CommandLine | Should -Match ([regex]::Escape('"'+$directory+'"'))
                $Arguments.CommandLine | Should -Match 'Run-DetachedWorker\.ps1'
                @{ReturnValue=0;ProcessId=12345}
            }
            $script:DetachedDisposed=$false
            Mock Get-Process {
                $process=[pscustomobject]@{Id=12345;StartTime=[datetime]'2026-10-26T00:00:00Z'}
                $process|Add-Member -MemberType ScriptMethod -Name Dispose -Value {$script:DetachedDisposed=$true}
                $process
            }
            $saved=[Environment]::GetEnvironmentVariable('MUTATOR_TEST_INHERITED')
            try{
                [Environment]::SetEnvironmentVariable('MUTATOR_TEST_INHERITED','accents é conservés')
                $identity=Start-MutatorDetachedWorker $directory
            }finally{[Environment]::SetEnvironmentVariable('MUTATOR_TEST_INHERITED',$saved)}
            $identity.Id | Should -Be 12345
            $identity.StartedUtc | Should -BeExactly ([datetime]'2026-10-26T00:00:00Z').ToUniversalTime().ToString('O')
            $identity.Role | Should -BeExactly supervisor
            $identity.Launcher | Should -BeExactly CimDetached
            $script:DetachedDisposed | Should -BeTrue
            Should -Invoke Start-Process -Times 0
            Should -Invoke Invoke-CimMethod -Times 1
        }
    }
    It 'does not claim a running supervisor after creation failure: <Fault>' -ForEach @(
        @{Fault='denied'},@{Fault='no PID'},@{Fault='no result'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive;Fault=$Fault} {
            param($Root,$Fault)
            $directory=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            Write-MutatorJson (Join-Path $directory 'run.json') @{Id='fixture';Packages=@()}
            Mock New-CimInstance { @{FixtureStartup=$true} }
            Mock Invoke-CimMethod {
                switch($Fault){denied {@{ReturnValue=2;ProcessId=0}};'no PID' {@{ReturnValue=0;ProcessId=0}};'no result' {$null}}
            }
            Mock Get-Process {throw 'No process identity may be claimed.'}
            {Start-MutatorDetachedWorker $directory} | Should -Throw '*Detached worker creation failed*'
            Should -Invoke Get-Process -Times 0
        }
    }
    It 'refuses launch without an existing run plan' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            Mock New-CimInstance {throw 'Must not create anything.'}
            {Start-MutatorDetachedWorker $Root} | Should -Throw '*retained run plan*'
            Should -Invoke New-CimInstance -Times 0
        }
    }
    It 'launches the RAM watchdog with its retained policy and STA, without requiring a mutation plan' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $directory=Join-Path $Root 'watchdog-only'
            Write-MutatorJson (Join-Path $directory 'watchdog.json') @{LimitBytes=40e9;TriggerBytes=38e9}
            Mock New-CimInstance {@{FixtureStartup=$true}}
            Mock Invoke-CimMethod {
                param($Arguments)
                $Arguments.CurrentDirectory | Should -BeExactly $directory
                $Arguments.CommandLine | Should -Match '"-STA"'
                $Arguments.CommandLine | Should -Match 'Run-MemoryWatchdog\.ps1'
                $Arguments.CommandLine | Should -Match '"-Path"'
                $Arguments.CommandLine | Should -Not -Match 'Run-DetachedWorker\.ps1'
                @{ReturnValue=0;ProcessId=12345}
            }
            Mock Get-Process {
                $process=[pscustomobject]@{Id=12345;StartTime=[datetime]'2026-10-26T00:00:00Z'}
                $process|Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
                $process
            }
            $identity=Start-MutatorDetachedWorker $directory -Kind MemoryWatchdog
            $identity.Role | Should -BeExactly memory-watchdog
            $identity.Launcher | Should -BeExactly CimDetached
            Should -Invoke Invoke-CimMethod -Times 1
            Test-Path -LiteralPath (Join-Path $directory 'run.json') | Should -BeFalse
        }
    }
    It 'launches a Git validation controller from its own retained request' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $directory=Join-Path $Root 'git controller with spaces'
            Write-MutatorJson (Join-Path $directory 'controller.request.json') @{OS=@('Linux','Windows')}
            Mock New-CimInstance {@{FixtureStartup=$true}}
            Mock Invoke-CimMethod {
                param($Arguments)
                $Arguments.CurrentDirectory|Should -BeExactly $directory
                $Arguments.CommandLine|Should -Match 'Invoke-GitImageController\.ps1'
                $Arguments.CommandLine|Should -Match ([regex]::Escape('"'+(Join-Path $directory 'controller.request.json')+'"'))
                $Arguments.CommandLine|Should -Not -Match '"-STA"'
                @{ReturnValue=0;ProcessId=12345}
            }
            Mock Get-Process {
                $process=[pscustomobject]@{Id=12345;StartTime=[datetime]'2026-10-27T00:00:00Z'}
                $process|Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
                $process
            }
            $identity=Start-MutatorDetachedWorker $directory -Kind GitValidation
            $identity.Role|Should -BeExactly git-validation
            $identity.Launcher|Should -BeExactly CimDetached
            Should -Invoke Invoke-CimMethod -Times 1
            Test-Path (Join-Path $directory 'run.json')|Should -BeFalse
        }
    }
}
