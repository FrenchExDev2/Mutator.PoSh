BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    . (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'test/Fixtures/ContainerWorkspace.ps1')
    $script:BaseWorkspace=New-MutatorContainerWorkspace -Path (Join-Path $TestDrive 'base-workspace')
}
Describe 'Shared prepared Windows base' {
    It 'prepares the glibc SDK with a checked archive in Debian and Swift bases' {
        $modules=$script:BaseWorkspace
        foreach($variant in @('debian','swift')){
            $text=Get-Content (Join-Path $modules ('FrenchExDev.Mutator.PoSh/resources/containers/base/'+$variant+'/Dockerfile')) -Raw
            $text | Should -Match 'dotnet-sdk-10\.0\.402-linux-x64\.tar\.gz'
            $text | Should -Match '[a-fA-F0-9]{128}  /tmp/dotnet\.tar\.gz.*sha512sum -c -'
            $text | Should -Match 'DOTNET_ROOT=/opt/dotnet'
        }
    }
    It 'preserves complete bootstrap paths in the shared <Variant> Dockerfile' -ForEach @(
        @{Variant='alpine';Root='/opt/mutator'}
        @{Variant='debian';Root='/opt/mutator'}
        @{Variant='swift';Root='/opt/mutator'}
        @{Variant='windows-native';Root='C:/mutator'}
    ) {
        $modules=$script:BaseWorkspace
        $text=Get-Content (Join-Path $modules ('FrenchExDev.Mutator.PoSh/resources/containers/base/'+$Variant+'/Dockerfile'))
        $copy=@($text|Where-Object {$_ -like 'COPY *'})
        $copy.Count | Should -Be 1
        $arguments=@($copy[0].Substring(5)|ConvertFrom-Json)
        $arguments.Count | Should -Be 2
        $arguments[1] | Should -BeExactly ($Root+'/bootstrap/Initialize-Image.ps1')
        $run=@($text|Where-Object {$_.StartsWith('RUN [') -and $_ -match 'Initialize-Image'})
        $run.Count | Should -Be 1
        $arguments=@($run[0].Substring(4)|ConvertFrom-Json)
        $arguments.Count | Should -Be 5
        $arguments[4] | Should -BeExactly ($Root+'/bootstrap/Initialize-Image.ps1')
    }
    It 'uses a canonical identity independent of dictionary insertion order' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $first=ConvertTo-MutatorContainerJson @{z=@(@{b=2;a=1});a='value'}
            $second=ConvertTo-MutatorContainerJson ([ordered]@{a='value';z=@([ordered]@{a=1;b=2})})
            $first | Should -BeExactly $second
            $value=$first|ConvertFrom-Json -AsHashtable
            @($value.z).Count | Should -Be 1
        }
    }
    It 'changes both base identities when any shared bootstrap input changes' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{ModuleRoot=$script:BaseWorkspace} {
            param($ModuleRoot)
            $script:BootstrapHash='a'*64
            Mock Get-MutatorSourceSnapshot { @{Sha256=$script:BootstrapHash} } -ParameterFilter {(Split-Path $Root -Leaf) -eq 'bootstrap'}
            $first=Get-MutatorContainerRuntime $ModuleRoot
            $script:BootstrapHash='b'*64
            $second=Get-MutatorContainerRuntime $ModuleRoot
            $first.Fingerprint | Should -Not -BeExactly $second.Fingerprint
            $first.MacFingerprint | Should -Not -BeExactly $second.MacFingerprint
            $first.Images.Windows | Should -Not -BeExactly $second.Images.Windows
            $first.Images.MacOS | Should -Not -BeExactly $second.Images.MacOS
            Should -Invoke Get-MutatorSourceSnapshot -Times 2 -Exactly
        }
    }
    It 'invalidates shared bases when the pinned glibc SDK changes' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{ModuleRoot=$script:BaseWorkspace} {
            param($ModuleRoot)
            $script:PinnedVersions=Read-MutatorJson (Join-Path $script:MutatorRoot 'resources/containers/definitions/package-versions.json')
            $script:ImageLock=Read-MutatorJson (Join-Path $ModuleRoot 'FrenchExDev.Mutator.PoSh/resources/containers/definitions/container-images.lock.json')
            Mock Read-MutatorJson {param($Path);if((Split-Path $Path -Leaf) -eq 'package-versions.json'){$script:PinnedVersions}else{$script:ImageLock}}
            $first=Get-MutatorContainerRuntime $ModuleRoot
            $script:PinnedVersions.LinuxGlibc.Dotnet.Version='10.0.403'
            $second=Get-MutatorContainerRuntime $ModuleRoot
            $first.Fingerprint | Should -Not -BeExactly $second.Fingerprint
            $first.Images.Debian | Should -Not -BeExactly $second.Images.Debian
            $first.MacFingerprint | Should -BeExactly $second.MacFingerprint
        }
    }
    It 'refuses live disks before copying any data' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            Mock Get-MutatorContainerRuntime { @{Fingerprint='base'} }
            Mock Invoke-MutatorContainerCommand { @{Outcome='Success';Stdout='[{"Id":"owned","State":{"Running":true,"Status":"running","ExitCode":0}}]'} }
            {Export-MutatorWindowsBase -Container fixture -ModuleRoot $Root -Destination (Join-Path $Root 'seed')} | Should -Throw '*Shut down*'
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'cp'}
            Test-Path (Join-Path $Root 'seed') | Should -BeFalse
        }
    }
    It 'keeps large mutable guest disks out of source trees and requires isolated qcow2 overlays' {
        $root=Split-Path (Split-Path $PSScriptRoot)
        $modules=Split-Path $root
        $windows=[IO.File]::ReadAllText((Join-Path $modules 'FrenchExDev.Mutator.PoSh/resources/containers/base/windows/Dockerfile'))
        $windows | Should -Match 'test/Artifacts/container-bases/windows/seed'
        $mac=[IO.File]::ReadAllText((Join-Path $modules 'FrenchExDev.Mutator.PoSh/resources/containers/base/macos/Dockerfile'))
        $mac | Should -Match 'test/Artifacts/container-bases/macos/seed'
        $script=[IO.File]::ReadAllText((Join-Path $root 'resources/containers/definitions/guest/Start-SeededGuest.sh'))
        $script | Should -Match 'qemu-img create -f qcow2 -F qcow2 -b'
        $script | Should -Match 'Refusing to overwrite nonempty'
        $bootstrap=[IO.File]::ReadAllText((Join-Path $root 'resources/containers/definitions/guest/Initialize-WindowsModule.ps1'))
        $bootstrap | Should -Not -Match 'Initialize-Image.ps1|PowerShell/releases'
    }
    It 'refuses a failed guest preparation even when its container is stopped' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $destination=Join-Path $Root 'failed-seed'
            Mock Get-MutatorContainerRuntime { @{Fingerprint='base'} }
            Mock Invoke-MutatorContainerCommand {
                param($Arguments)
                if($Arguments[0] -eq 'inspect'){return @{Outcome='Success';Stdout='[{"Id":"owned","State":{"Running":false,"Status":"exited","ExitCode":0},"Config":{"Labels":{"org.frenchexdev.mutator.fingerprint":"base"}}}]'}}
                Write-MutatorJson $Arguments[2] @{Fingerprint='base';Outcome='Failed'}
                @{Outcome='Success'}
            }
            {Export-MutatorWindowsBase -Container fixture -ModuleRoot $Root -Destination $destination} | Should -Throw '*preparation gate*'
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'cp' -and $Arguments[1] -like '*:/storage/*'}
        }
    }
}
