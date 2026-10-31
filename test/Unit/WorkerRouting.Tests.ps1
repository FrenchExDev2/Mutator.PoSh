BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Supervisor and package process ownership' {
    It 'routes the supervisor through the durable Windows launcher or native Unix process' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            Mock Start-MutatorDetachedWorker {param($RunDirectory) $RunDirectory | Should -BeExactly $Root;@{Id=12345;Role='supervisor';Launcher='CimDetached'}}
            Mock Start-Process {[pscustomobject]@{Id=12345;StartTime=[datetime]'2026-10-26T00:00:00Z'}}
            $identity=Start-MutatorWorker $Root
            $identity.Id | Should -Be 12345
            $identity.Role | Should -BeExactly supervisor
            if($IsWindows){
                $identity.Launcher | Should -BeExactly CimDetached
                Should -Invoke Start-MutatorDetachedWorker -Times 1
                Should -Invoke Start-Process -Times 0
            }else{
                Should -Invoke Start-MutatorDetachedWorker -Times 0
                Should -Invoke Start-Process -Times 1
            }
        }
    }
    It 'keeps a package attached to its supervisor and retains separate captured streams' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $directory=Join-Path $Root 'run with spaces'
            Mock Start-MutatorDetachedWorker {throw 'Only the supervisor is detached.'}
            Mock Start-Process {
                param($FilePath,$ArgumentList,$RedirectStandardOutput,$RedirectStandardError,$WindowStyle)
                $FilePath | Should -BeExactly (Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'}))
                $ArgumentList | Should -Contain '"-Package"'
                $ArgumentList | Should -Contain '"p0000"'
                $ArgumentList | Should -Contain ('"'+$directory+'"')
                $RedirectStandardOutput | Should -BeExactly (Join-Path $directory 'p0000.stdout.log')
                $RedirectStandardError | Should -BeExactly (Join-Path $directory 'p0000.stderr.log')
                if($IsWindows){$WindowStyle | Should -BeExactly Hidden}
                [pscustomobject]@{Id=54321;StartTime=[datetime]'2026-10-26T00:00:00Z'}
            }
            $identity=Start-MutatorWorker $directory p0000
            $identity.Id | Should -Be 54321
            $identity.Role | Should -BeExactly p0000
            $identity.StartedUtc | Should -BeExactly ([datetime]'2026-10-26T00:00:00Z').ToUniversalTime().ToString('O')
            Should -Invoke Start-MutatorDetachedWorker -Times 0
            Should -Invoke Start-Process -Times 1
        }
    }
}
