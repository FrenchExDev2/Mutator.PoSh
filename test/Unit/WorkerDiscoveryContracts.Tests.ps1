BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    & (Get-Module FrenchExDev.Mutator.PoSh) {. (Join-Path $script:MutatorRoot 'test/Fixtures/WindowsCimContracts.ps1')}
}
Describe 'Worker discovery verifies executable arguments and source directory identity' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            . (Join-Path $script:MutatorRoot 'test/Fixtures/WindowsCimContracts.ps1')
            $script:DiscoveryRun=Join-Path $TestDrive 'owned'
            $script:DiscoveryFault='none';$script:DiscoveryWindows=$true;$script:DiscoveryLinux=$false
            Mock Test-MutatorWindowsPlatform {$script:DiscoveryWindows}
            Mock Test-MutatorLinuxPlatform {$script:DiscoveryLinux}
            Mock Get-Process {@([pscustomobject]@{Id=$PID;StartTime=[datetime]'2026-10-27'},[pscustomobject]@{Id=987654;StartTime=[datetime]'2026-10-27'})}
            Mock Get-CimInstance {
                if($script:DiscoveryFault -eq 'missing'){return $null}
                $directory=if($script:DiscoveryFault -eq 'foreign'){Join-Path $script:DiscoveryRun 'other'}elseif($script:DiscoveryFault -eq 'invalid'){[string][char]0}else{$script:DiscoveryRun}
                $file=if($script:DiscoveryFault -eq 'wrong executable'){'Other.ps1'}else{'Run-Worker.ps1'}
                $line='pwsh -NoProfile -File "C:/mutator/'+$file+'"'
                if($script:DiscoveryFault -ne 'no run'){$line+=' -RunDirectory '+$(if($script:DiscoveryFault -eq 'unquoted'){$directory}else{'"'+$directory+'"'})}
                [pscustomobject]@{CommandLine=$line}
            }
            Mock Read-MutatorProcessArgument {
                if($script:DiscoveryFault -eq 'read denied'){throw 'Process exited'}
                switch($script:DiscoveryFault){
                    'no file' {return @('pwsh','-RunDirectory',$script:DiscoveryRun)}
                    'file missing value' {return @('pwsh','-File')}
                    'wrong executable' {return @('pwsh','-File','Other.ps1','-RunDirectory',$script:DiscoveryRun)}
                    'run missing value' {return @('pwsh','-File','/mutator/Run-Worker.ps1','-RunDirectory')}
                    'no run' {return @('pwsh','-File','/mutator/Run-Worker.ps1')}
                    default {return @('pwsh','-File','/mutator/Run-Worker.ps1','-RunDirectory',$script:DiscoveryRun)}
                }
            }
        }
        It 'finds the Windows worker with quoted or unquoted arguments: <Fault>' -ForEach @(@{Fault='none'},@{Fault='unquoted'}) {
            $script:DiscoveryFault=$Fault
            $r=@(Get-MutatorRunWorkerIdentity $script:DiscoveryRun)
            $r.Count|Should -Be 1
            $r[0].Id|Should -Be 987654
            $r[0].StartedUtc|Should -BeExactly ([datetime]'2026-10-27').ToUniversalTime().ToString('O')
            Should -Invoke Get-CimInstance -Times 1 -Exactly
        }
        It 'ignores unowned or invalid Windows processes: <Fault>' -ForEach @(@{Fault='missing'},@{Fault='wrong executable'},@{Fault='no run'},@{Fault='foreign'},@{Fault='invalid'}) {
            $script:DiscoveryFault=$Fault
            @(Get-MutatorRunWorkerIdentity $script:DiscoveryRun).Count|Should -Be 0
        }
        It 'finds the Linux worker using null-delimited native argv' {
            $script:DiscoveryWindows=$false;$script:DiscoveryLinux=$true
            @(Get-MutatorRunWorkerIdentity $script:DiscoveryRun)[0].Id|Should -Be 987654
            Should -Invoke Get-CimInstance -Times 0 -Exactly
        }
        It 'ignores incomplete or unreadable Linux argv: <Fault>' -ForEach @(@{Fault='read denied'},@{Fault='no file'},@{Fault='file missing value'},@{Fault='wrong executable'},@{Fault='no run'},@{Fault='run missing value'}) {
            $script:DiscoveryWindows=$false;$script:DiscoveryLinux=$true;$script:DiscoveryFault=$Fault
            @(Get-MutatorRunWorkerIdentity $script:DiscoveryRun).Count|Should -Be 0
        }
        It 'does not infer ownership on an unsupported process platform' {
            $script:DiscoveryWindows=$false;$script:DiscoveryLinux=$false
            @(Get-MutatorRunWorkerIdentity $script:DiscoveryRun).Count|Should -Be 0
            Should -Invoke Read-MutatorProcessArgument -Times 0 -Exactly
        }
    }
}
Describe 'Proc argument reader' {
    It 'preserves spaces and dollar signs without interpreting them' {
        & (Get-Module FrenchExDev.Mutator.PoSh) {
            param($Root)
            $file=Join-Path $Root '321/cmdline';[void][IO.Directory]::CreateDirectory((Split-Path $file))
            $argv=@('pwsh','-File','/path with spaces/Run-Worker.ps1','-RunDirectory','/literal/$directory')
            [IO.File]::WriteAllText($file,($argv -join [char]0))
            @(Read-MutatorProcessArgument -Id 321 -ProcRoot $Root)|Should -Be $argv
            Test-MutatorWindowsPlatform|Should -Be $IsWindows
            Test-MutatorLinuxPlatform|Should -Be $IsLinux
        } (Join-Path $TestDrive 'proc-reader')
    }
}
