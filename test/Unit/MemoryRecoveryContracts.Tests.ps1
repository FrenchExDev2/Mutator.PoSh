<#
.SYNOPSIS
Expected behavior for the MemoryRecoveryContracts tests.

.DESCRIPTION
Recheck PID/time/parent ownership before stopping anything and exclude ordinary shells. Restart only
unfinished packages after all owned workers exit, preserving partial proof and run options.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    & (Get-Module FrenchExDev.Mutator.PoSh) {. (Join-Path $script:MutatorRoot 'test/Fixtures/WindowsCimContracts.ps1')}
}
Describe 'Memory recovery refuses stale identities and retains outcomes' {
    It 'refuses identity changes before stopping anything: <Fault>' -ForEach @(
        @{Fault='missing'},@{Fault='application'},@{Fault='parent'},@{Fault='self'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive;Fault=$Fault} {
            param($Root,$Fault)
            $Root=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $script:RecoveryTarget=@{Id=987654;ParentId=12;StartedUtc=([datetime]'2026-10-26T00:00:00Z').ToUniversalTime().ToString('O');WorkingSetBytes=9e9}
            $script:RecoveryCurrent=[pscustomobject]@{Name='pwsh.exe';CreationDate=[datetime]'2026-10-26T00:00:00Z';ParentProcessId=12}
            switch($Fault){
                missing {$script:RecoveryCurrent=$null}
                application {$script:RecoveryCurrent.Name='other.exe'}
                parent {$script:RecoveryCurrent.ParentProcessId=13}
                self {$script:RecoveryTarget.Id=$PID}
            }
            Mock Get-CimInstance {$script:RecoveryCurrent}
            Mock Stop-MutatorMemoryProcess {throw 'Identity must be verified before stopping.'}
            Mock Start-Process {throw 'Identity must be verified before restarting.'}
            if($Fault -eq 'self'){{Invoke-MutatorMemoryRecovery $script:RecoveryTarget $Root}|Should -Throw '*cannot stop itself*'}
            else{{Invoke-MutatorMemoryRecovery $script:RecoveryTarget $Root}|Should -Throw '*identity changed*'}
            Should -Invoke Stop-MutatorMemoryProcess -Times 0
            Should -Invoke Start-Process -Times 0
            Test-Path -LiteralPath (Join-Path $Root 'events') | Should -BeFalse
        }
    }

    It 'refuses an ordinary shell before any stop or restart: <Fault>' -ForEach @(
        @{Fault='none'},@{Fault='missing executable'},@{Fault='stop denied'},@{Fault='editor impostor'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive;Fault=$Fault} {
            param($Root,$Fault)
            $Root=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $target=@{Id=987654;ParentId=12;StartedUtc=([datetime]'2026-10-26T00:00:00Z').ToUniversalTime().ToString('O');WorkingSetBytes=9e9}
            $script:RecoveryExecutable=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
            $script:RecoveryCommand='pwsh -File do-not-replay.ps1'
            if($Fault -eq 'missing executable'){$script:RecoveryExecutable=Join-Path $Root 'absent.exe'}
            if($Fault -eq 'editor impostor'){$script:RecoveryCommand='Start-EditorServices PowerShellEditorServices'}
            Mock Get-CimInstance {
                param($Filter)
                if($Filter -eq 'ProcessId=12'){return [pscustomobject]@{Name='Unrelated.exe'}}
                [pscustomobject]@{Name='pwsh.exe';CreationDate=[datetime]'2026-10-26T00:00:00Z';ParentProcessId=12;ExecutablePath=$script:RecoveryExecutable;CommandLine=$script:RecoveryCommand}
            }
            Mock Stop-MutatorMemoryProcess {if($Fault -eq 'stop denied'){throw 'fixture permission denied'}}
            Mock Restart-MutatorEditorSession {throw 'An unverified editor must not be restarted.'}
            Mock Start-Process {
                param($FilePath,$ArgumentList,$WindowStyle)
                $FilePath | Should -BeExactly $script:RecoveryExecutable
                $ArgumentList | Should -Be @('-NoLogo','-NoProfile','-NoExit')
                $WindowStyle | Should -BeExactly Normal
                [pscustomobject]@{Id=12345}
            }
            {Invoke-MutatorMemoryRecovery $target $Root}|Should -Throw '*registered owned Mutator worker*'
            Should -Invoke Start-Process -Times 0
            Should -Invoke Stop-MutatorMemoryProcess -Times 0
            Should -Invoke Restart-MutatorEditorSession -Times 0
            Test-Path (Join-Path $Root 'events')|Should -BeFalse
        }
    }
}

Describe 'Memory recovery of an owned mutation worker' {
    It 'restarts only unfinished packages and preserves partial reports: <Partial>' -ForEach @(@{Partial=$true},@{Partial=$false}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive;Partial=$Partial} {
            param($Root,$Partial)
            $Root=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $script:RecoveryRun=Join-Path $Root 'owned-run'
            $target=@{Id=987654;ParentId=12;StartedUtc=([datetime]'2026-10-26T00:00:00Z').ToUniversalTime().ToString('O');WorkingSetBytes=9e9}
            $worker=Join-Path $script:MutatorRoot 'resources/Run-Worker.ps1'
            $script:RecoveryCommand='pwsh -File "'+$worker+'" -RunDirectory "'+$script:RecoveryRun+'"'
            Write-MutatorJson (Join-Path $script:RecoveryRun 'run.json') @{
                SourceRoot=$Root;TestOrder='FocusedFirst';Schedule=@{Workers=3;WorkerBudget=4;MemoryBudgetMiB=4096};ContainerConnection='owned-connection';ContainerBaseImage='verified-base'
                Process=@{Id=$target.Id;StartedUtc=$target.StartedUtc};ContainerEngine='Docker';StrykerRuntime='Host';WindowsGuestTimeoutMinutes=7;WindowsGuestJobTimeoutSeconds=45
                Packages=@(@{Id='done';Name='Done';ModulePath=(Join-Path $Root 'Done');Stryker=$false},@{Id='todo';Name='Todo';ModulePath=(Join-Path $Root 'Todo');Stryker=$true})
            }
            if($Partial){Write-MutatorJson (Join-Path $script:RecoveryRun 'packages/todo/mutation.json') @{mode='Partial';mutants=@()}}
            Mock Get-CimInstance { [pscustomobject]@{Name='pwsh.exe';CreationDate=[datetime]'2026-10-26T00:00:00Z';ParentProcessId=12;CommandLine=$script:RecoveryCommand} }
            Mock Get-MutatorRun { @{Process=@{Id=987654};Packages=@(@{Id='done';Outcome='Success'},@{Id='todo';Outcome='Interrupted'})} }
            $script:RecoveryIdentityChecks=0
            Mock Test-MutatorProcess {$script:RecoveryIdentityChecks++;$script:RecoveryIdentityChecks -eq 1}
            Mock Stop-MutatorRun {}
            Mock Start-Sleep {throw 'A stopped fixture must not be waited on.'}
            Mock Stop-MutatorMemoryProcess {throw 'Mutator must stop through its owned run.'}
            Mock Invoke-MutatorRun {
                param($ModulePath,$SourceRoot,$Workers,$WorkerBudget,$ThrottleLimit,$MemoryBudgetMiB,$TestOrder,$SkipStryker,$ResumeFrom,$ContainerConnection,$ContainerBaseImage,$ContainerEngine,$StrykerRuntime,$WindowsGuestTimeoutMinutes,$WindowsGuestJobTimeoutSeconds)
                $ModulePath | Should -BeExactly (Join-Path $Root 'Todo')
                $SourceRoot | Should -BeExactly $Root
                $Workers | Should -Be 3
                $WorkerBudget | Should -Be 4
                $ThrottleLimit | Should -Be 1
                $MemoryBudgetMiB | Should -Be 4096
                $TestOrder | Should -BeExactly FocusedFirst
                $SkipStryker | Should -BeFalse
                $ContainerConnection | Should -BeExactly owned-connection
                $ContainerBaseImage | Should -BeExactly verified-base
                $ContainerEngine|Should -BeExactly Docker
                $StrykerRuntime|Should -BeExactly Host
                $WindowsGuestTimeoutMinutes|Should -Be 7
                $WindowsGuestJobTimeoutSeconds|Should -Be 45
                if($Partial){$ResumeFrom | Should -BeExactly (Join-Path $script:RecoveryRun 'packages/todo/mutation.json')}
                else{$ResumeFrom | Should -BeNullOrEmpty}
                @{Path=(Join-Path $Root 'replacement-run')}
            }
            $result=Invoke-MutatorMemoryRecovery $target $Root
            $result.Outcome | Should -BeExactly Restarted
            $result.Kind | Should -BeExactly Mutator
            $result.Restarts.Count | Should -Be 1
            $result.Restarts[0].Module | Should -BeExactly Todo
            $result.Restarts[0].Mode | Should -BeExactly $(if($Partial){'ResumePartial'}else{'FreshRestart'})
            Should -Invoke Invoke-MutatorRun -Times 1
            Should -Invoke Stop-MutatorRun -Times 1
            Should -Invoke Stop-MutatorMemoryProcess -Times 0
        }
    }
}
