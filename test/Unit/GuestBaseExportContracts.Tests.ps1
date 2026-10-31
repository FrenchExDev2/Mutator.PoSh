BeforeAll {
    $script:ExportModuleRoot=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:ExportModuleRoot 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Guest seed exports verify real qcow2 disks and readiness' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            $script:ExportRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($script:ExportRoot)
            $script:ExportDestination=Join-Path $script:ExportRoot 'seed'
            $script:ExportFault='none';$script:ExportDiskVersion=3
            $script:ExportIdentity=@{Id=('a'*64);State=@{Running=$false;Status='exited';ExitCode=0};Config=@{Labels=@{'org.frenchexdev.mutator.fingerprint'='windows-fp'}}}
            Mock Get-MutatorContainerRuntime { @{Fingerprint='windows-fp';MacFingerprint='mac-fp'} }
            Mock Invoke-MutatorContainerCommand {
                param($Arguments)
                if($Arguments[0] -eq 'inspect'){
                    if($script:ExportFault -eq 'inspect') {return @{Outcome='Failed'}}
                    return @{Outcome='Success';Stdout=(@($script:ExportIdentity)|ConvertTo-Json -Depth 7 -Compress)}
                }
                if($Arguments[1] -like '*:/shared/base-ready.json'){
                    if($script:ExportFault -eq 'receipt copy'){return @{Outcome='Failed'}}
                    $proof=@{Outcome='Success';Fingerprint=$script:ExportIdentity.Config.Labels['org.frenchexdev.mutator.fingerprint']}
                    if($script:ExportFault -eq 'receipt failed'){$proof.Outcome='Failed'}
                    if($script:ExportFault -eq 'receipt fingerprint'){$proof.Fingerprint='foreign'}
                    if($script:ExportFault -ne 'receipt missing'){Write-MutatorJson $Arguments[2] $proof}
                    return @{Outcome='Success'}
                }
                if($script:ExportFault -eq 'storage copy'){return @{Outcome='Failed'}}
                $destination=$Arguments[2]
                [void][IO.Directory]::CreateDirectory((Join-Path $destination 'firmware'))
                [IO.File]::WriteAllText((Join-Path $destination 'firmware/vars.bin'),'non-disk firmware')
                if($script:ExportFault -eq 'link'){
                    $type=if($IsWindows){'Junction'}else{'SymbolicLink'}
                    $null=New-Item -Path (Join-Path $destination 'linked-storage') -ItemType $type -Target (Join-Path $destination 'firmware')
                }
                if($script:ExportFault -ne 'no disk'){
                    $disk=Join-Path $destination 'data.qcow2'
                    Copy-Item (Join-Path $script:MutatorRoot ('test/Fixtures/Disks/qcow2-v'+$script:ExportDiskVersion+'.qcow2')) $disk
                    if($script:ExportFault -in @('short','magic','version','backing')){
                        $bytes=[IO.File]::ReadAllBytes($disk)
                        switch($script:ExportFault){short {$bytes=[byte[]]@(1,2,3)};magic {$bytes[0]=0};version {$bytes[7]=4};backing {$bytes[19]=1}}
                        [IO.File]::WriteAllBytes($disk,$bytes)
                    }
                }
                @{Outcome='Success'}
            }
        }
        It 'exports qcow2 version <Version> with verifiable byte counts and lower-case hashes' -ForEach @(@{Version=2},@{Version=3}) {
            $script:ExportDiskVersion=$Version
            $r=Export-MutatorGuestBase -Container original -ModuleRoot $script:ExportRoot -Destination $script:ExportDestination -Connection dedicated
            $r.Outcome|Should -BeExactly Success
            $r.Files|Should -Be 2
            $proof=Read-MutatorJson (Join-Path $script:ExportDestination 'base.json')
            $proof.CleanShutdown|Should -BeTrue
            $proof.Fingerprint|Should -BeExactly windows-fp
            $proof.ContainerId|Should -BeExactly ('a'*64)
            foreach($file in $proof.Files){
                $path=Join-Path (Join-Path $script:ExportDestination 'storage') $file.Path
                $file.Bytes|Should -Be (Get-Item $path).Length
                $file.Sha256|Should -BeExactly (Get-FileHash $path).Hash.ToLowerInvariant()
                $file.Path|Should -Not -Match '\\'
            }
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -Exactly -ParameterFilter {$Arguments[0] -eq 'cp' -and $TimeoutSeconds -eq 7200 -and $Connection -eq 'dedicated'}
        }
        It 'uses a distinct macOS fingerprint and its default destination' {
            $script:ExportIdentity.Config.Labels['org.frenchexdev.mutator.fingerprint']='mac-fp'
            $r=Export-MutatorGuestBase -Container original -ModuleRoot $script:ExportRoot -Platform MacOS
            $r.Fingerprint|Should -BeExactly mac-fp
            $r.Path|Should -BeExactly (Join-Path $script:ExportRoot 'FrenchExDev.Mutator.PoSh/test/Artifacts/container-bases/macos/seed')
        }
        It 'refuses an unclean or foreign container: <Fault>' -ForEach @(
            @{Fault='inspect'},@{Fault='running'},@{Fault='status'},@{Fault='exit'},@{Fault='fingerprint'}
        ) {
            $script:ExportFault=$Fault
            switch($Fault){running {$script:ExportIdentity.State.Running=$true};status {$script:ExportIdentity.State.Status='created'};exit {$script:ExportIdentity.State.ExitCode=1};fingerprint {$script:ExportIdentity.Config.Labels['org.frenchexdev.mutator.fingerprint']='foreign'}}
            {Export-MutatorGuestBase -Container original -ModuleRoot $script:ExportRoot -Destination $script:ExportDestination}|Should -Throw
            Test-Path (Join-Path $script:ExportDestination 'base.json')|Should -BeFalse
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -Exactly -ParameterFilter {$Arguments[0] -eq 'cp'}
        }
        It 'retains a failed export without claiming a valid seed: <Fault>' -ForEach @(
            @{Fault='receipt copy'},@{Fault='receipt failed'},@{Fault='receipt fingerprint'},@{Fault='receipt missing'},
            @{Fault='storage copy'},@{Fault='short'},@{Fault='magic'},@{Fault='version'},@{Fault='backing'},@{Fault='no disk'},@{Fault='link'}
        ) {
            $script:ExportFault=$Fault
            try{{Export-MutatorGuestBase -Container original -ModuleRoot $script:ExportRoot -Destination $script:ExportDestination}|Should -Throw}
            finally{if($Fault -eq 'link'){[IO.Directory]::Delete((Join-Path $script:ExportDestination 'storage/linked-storage'),$false)}}
            Test-Path $script:ExportDestination|Should -BeTrue
            Test-Path (Join-Path $script:ExportDestination 'base.json')|Should -BeFalse
        }
        It 'preserves an existing seed and accepts a gitignore-only destination' {
            [void][IO.Directory]::CreateDirectory($script:ExportDestination)
            [IO.File]::WriteAllText((Join-Path $script:ExportDestination 'keep.bin'),'existing')
            {Export-MutatorGuestBase -Container original -ModuleRoot $script:ExportRoot -Destination $script:ExportDestination}|Should -Throw '*not empty*'
            [IO.File]::ReadAllText((Join-Path $script:ExportDestination 'keep.bin'))|Should -BeExactly existing
            Remove-Item -LiteralPath (Join-Path $script:ExportDestination 'keep.bin')
            [IO.File]::WriteAllText((Join-Path $script:ExportDestination '.gitignore'),'*')
            (Export-MutatorGuestBase -Container original -ModuleRoot $script:ExportRoot -Destination $script:ExportDestination).Outcome|Should -BeExactly Success
            Test-Path (Join-Path $script:ExportDestination '.gitignore')|Should -BeTrue
        }
        It 'inspects but copies nothing under WhatIf' {
            Export-MutatorGuestBase -Container original -ModuleRoot $script:ExportRoot -Destination $script:ExportDestination -WhatIf
            Test-Path $script:ExportDestination|Should -BeFalse
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -Exactly -ParameterFilter {$Arguments[0] -eq 'cp'}
        }
    }
}
