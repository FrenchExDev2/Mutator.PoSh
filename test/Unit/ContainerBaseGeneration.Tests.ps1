BeforeAll {
    $script:GenerationModules=Split-Path (Split-Path (Split-Path $PSScriptRoot))
    Import-Module (Join-Path $script:GenerationModules 'FrenchExDev.Mutator.PoSh/FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Generating shared container runtime definitions' {
    BeforeEach {
        $script:GenerationRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:GenerationRoot)
    }
    It 'writes a complete pinned <Variant> recipe without building an image' -ForEach @(
        @{Variant='alpine'},@{Variant='debian'},@{Variant='swift'},@{Variant='windows-native'},
        @{Variant='windows-bootstrap'},@{Variant='windows'},@{Variant='macos-bootstrap'},@{Variant='macos'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GenerationRoot;Modules=$script:GenerationModules;Variant=$Variant} {
            param($Root,$Modules,$Variant)
            $script:GenerationRuntime=Get-MutatorContainerRuntime $Modules
            Mock Get-MutatorContainerRuntime {$script:GenerationRuntime}
            Mock Invoke-MutatorContainerCommand {throw 'Definition generation must not start a build or VM.'}
            $result=Export-MutatorContainerBaseDefinition -ModuleRoot $Root
            $result.Fingerprint|Should -BeExactly $script:GenerationRuntime.Fingerprint
            $result.Images.Alpine|Should -BeExactly $script:GenerationRuntime.Images.Alpine
            $text=Get-Content (Join-Path $result.Path ($Variant+'/Dockerfile')) -Raw
            $text|Should -Not -Match '__[A-Z_]+__'
            $text|Should -Match ([regex]::Escape($script:GenerationRuntime.Runtime.Version))
            Test-Path (Join-Path $result.Path ($Variant+'/Dockerfile.dockerignore'))|Should -BeTrue
            if($Variant -in @('alpine','debian','swift','windows-native')){
                $copy=@($text -split "`n"|Where-Object {$_ -like 'COPY *'})
                $copy.Count|Should -Be 1
                $arguments=@($copy[0].Substring(5)|ConvertFrom-Json)
                $arguments[0]|Should -BeExactly 'FrenchExDev.Mutator.PoSh/resources/containers/definitions/bootstrap/Initialize-Image.ps1'
                $target=if($Variant -eq 'windows-native'){'C:/mutator'}else{'/opt/mutator'}
                $arguments[1]|Should -BeExactly ($target+'/bootstrap/Initialize-Image.ps1')
                $text|Should -Match ([regex]::Escape($script:GenerationRuntime.Fingerprint))
            }
            if($Variant -in @('windows','macos')){
                $ignore=Get-Content (Join-Path $result.Path ($Variant+'/Dockerfile.dockerignore')) -Raw
                $ignore|Should -Match ([regex]::Escape('!FrenchExDev.Mutator.PoSh/test/Artifacts/container-bases/'+$Variant+'/seed/**'))
                $text|Should -Match ([regex]::Escape('/container-bases/'+$Variant+'/seed/'))
            }
            $runtime=Read-MutatorJson (Join-Path $result.Path 'runtime.json')
            $runtime.BuildValidated|Should -BeFalse
            $runtime.ControllerFingerprint|Should -BeExactly $script:GenerationRuntime.ControllerFingerprint
            $runtime.MacFingerprint|Should -BeExactly $script:GenerationRuntime.MacFingerprint
            $windows=Read-MutatorJson (Join-Path $result.Path 'windows-bootstrap/image.json')
            $windows.Platforms.Windows.Packages|Should -BeExactly @('dotnet-sdk='+$script:GenerationRuntime.Versions.Windows['dotnet-sdk'])
            $mac=Read-MutatorJson (Join-Path $result.Path 'macos-bootstrap/runtime.json')
            $mac.HomebrewSha256|Should -BeExactly $script:GenerationRuntime.Versions.Sources.HomebrewBootstrapSHA256
            Should -Invoke Invoke-MutatorContainerCommand -Times 0
        }
    }
    It 'keeps existing identical files and repairs a changed recipe' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GenerationRoot;Modules=$script:GenerationModules} {
            param($Root,$Modules)
            $script:GenerationRuntime=Get-MutatorContainerRuntime $Modules
            Mock Get-MutatorContainerRuntime {$script:GenerationRuntime}
            $result=Export-MutatorContainerBaseDefinition -ModuleRoot $Root
            $path=Join-Path $result.Path 'alpine/Dockerfile'
            $expected=[IO.File]::ReadAllText($path)
            [IO.File]::SetLastWriteTimeUtc($path,[datetime]'2020-01-01T00:00:00Z')
            $stamp=[IO.File]::GetLastWriteTimeUtc($path)
            $null=Export-MutatorContainerBaseDefinition -ModuleRoot $Root
            [IO.File]::GetLastWriteTimeUtc($path)|Should -Be $stamp
            [IO.File]::WriteAllText($path,'obsolete recipe')
            $null=Export-MutatorContainerBaseDefinition -ModuleRoot $Root
            [IO.File]::ReadAllText($path)|Should -BeExactly $expected
        }
    }
    It 'previews identities without creating any recipe or seed directory' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GenerationRoot;Modules=$script:GenerationModules} {
            param($Root,$Modules)
            $script:GenerationRuntime=Get-MutatorContainerRuntime $Modules
            Mock Get-MutatorContainerRuntime {$script:GenerationRuntime}
            $result=Export-MutatorContainerBaseDefinition -ModuleRoot $Root -WhatIf
            $result.Fingerprint|Should -BeExactly $script:GenerationRuntime.Fingerprint
            Test-Path $result.Path|Should -BeFalse
            Test-Path (Join-Path $Root 'FrenchExDev.Mutator.PoSh/test/Artifacts/container-bases')|Should -BeFalse
        }
    }
    It 'refuses a runtime template without the shared bootstrap boundary' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GenerationRoot;Modules=$script:GenerationModules} {
            param($Root,$Modules)
            $script:GenerationRuntime=Get-MutatorContainerRuntime $Modules
            Mock Get-MutatorContainerRuntime {$script:GenerationRuntime}
            $owned=Join-Path $Root 'owned-template-fixture'
            Copy-MutatorTree (Join-Path $script:MutatorRoot 'resources/containers/definitions') (Join-Path $owned 'resources/containers/definitions')
            [IO.File]::WriteAllText((Join-Path $owned 'resources/containers/definitions/Dockerfile.linux.template'),'FROM fixture')
            $saved=$script:MutatorRoot
            try {
                $script:MutatorRoot=$owned
                {Export-MutatorContainerBaseDefinition -ModuleRoot $Root}|Should -Throw '*Missing shared runtime boundary*'
            } finally {$script:MutatorRoot=$saved}
            Test-Path (Join-Path $Root 'FrenchExDev.Mutator.PoSh/resources/containers/base')|Should -BeFalse
        }
    }
}
