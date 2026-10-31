BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Generated container selection' {
    BeforeEach {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $script:GeneratedModule=Join-Path (Join-Path $Root ([guid]::NewGuid().ToString('N'))) 'FrenchExDev.Tools.Fixture.PoSh'
            $script:GeneratedMetadata=@{Module='FrenchExDev.Tools.Fixture.PoSh';Commands=@('fixture-tool');Platforms=@{Linux=@{Status='Prepared';Binary='fixture-tool';Distribution='Alpine';Method='Apk';Packages=@('fixture')}}}
            Write-MutatorJson (Join-Path $script:GeneratedModule 'containers/image.json') $script:GeneratedMetadata
            [void][IO.Directory]::CreateDirectory((Join-Path $script:GeneratedModule 'containers/linux'))
            Set-Content (Join-Path $script:GeneratedModule 'containers/linux/Dockerfile') 'FROM localhost/runtime:fixture'
            Set-Content (Join-Path $script:GeneratedModule 'containers/linux/Dockerfile.dockerignore') '**/Artifacts'
            Mock Get-Command { $null } -ParameterFilter {$Name -eq 'fixture-tool'}
        }
    }
    It 'selects a declared generated image for a missing binary without a legacy recipe' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $route=Get-MutatorContainerRecipe $script:GeneratedModule
            $route.Kind|Should -BeExactly Generated
            $route.Binary|Should -BeExactly 'fixture-tool'
            $route.DefinitionPath|Should -BeExactly (Join-Path $script:GeneratedModule 'containers/image.json')
            $route.DockerfileSha256|Should -BeExactly (Get-FileHash (Join-Path $script:GeneratedModule 'containers/linux/Dockerfile')).Hash
        }
    }
    It 'keeps a native executable on the host unless the recipe explicitly selects a container' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Mock Get-Command { [pscustomobject]@{Source='native'} } -ParameterFilter {$Name -eq 'fixture-tool'}
            Get-MutatorContainerRecipe $script:GeneratedModule|Should -BeNullOrEmpty
            [void][IO.Directory]::CreateDirectory((Join-Path $script:GeneratedModule 'test'))
            Set-Content (Join-Path $script:GeneratedModule 'test/mutator.container.psd1') "@{Binary='fixture-tool';UseWhen='Always';Packages=@('fixture')}"
            (Get-MutatorContainerRecipe $script:GeneratedModule).Kind|Should -BeExactly Generated
        }
    }
    It 'refuses an unsupported declared platform instead of falling back to host execution' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $script:GeneratedMetadata.Platforms.Linux.Status='Unsupported'
            $script:GeneratedMetadata.Platforms.Linux.Reason='requires an unavailable runtime'
            Write-MutatorJson (Join-Path $script:GeneratedModule 'containers/image.json') $script:GeneratedMetadata
            {Get-MutatorContainerRecipe $script:GeneratedModule}|Should -Throw '*requires an unavailable runtime*'
        }
    }
    It 'refuses a missing Dockerfile and metadata belonging to another module' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Remove-Item (Join-Path $script:GeneratedModule 'containers/linux/Dockerfile')
            {Get-MutatorContainerRecipe $script:GeneratedModule}|Should -Throw '*Dockerfile*'
            $script:GeneratedMetadata.Module='FrenchExDev.Tools.Other.PoSh'
            Write-MutatorJson (Join-Path $script:GeneratedModule 'containers/image.json') $script:GeneratedMetadata
            {Get-MutatorContainerRecipe $script:GeneratedModule}|Should -Throw '*module identity*'
        }
    }
    It 'uses the generated builder with the slot budget and stops on a build failure' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $entry=@{ModulePath=$script:GeneratedModule;ContainerRecipe=(Get-MutatorContainerRecipe $script:GeneratedModule)}
            $state=@{}
            Mock Resolve-MutatorContainerConnection {@{Connection='selected';Controllers=@('cpu','memory');Rootless=$false}}
            Mock New-MutatorContainerImage {throw 'fixture generated build failed'}
            Mock New-MutatorToolImage {throw 'legacy builder must not run'}
            Mock Invoke-MutatorContainerCommand {throw 'worker must not run'}
            {Invoke-MutatorContainerPackage $Root @{Schedule=@{ReservedMemoryMiB=4096;Slots=2;Workers=2}} $entry $state (Join-Path $Root 'package/state.json')}|Should -Throw '*fixture generated build failed*'
            $state.Phase|Should -BeExactly 'Building Container'
            Should -Invoke New-MutatorContainerImage -Times 1 -Exactly -ParameterFilter {$ModulePath -eq $script:GeneratedModule -and $Reuse -and $MemoryMiB -eq 2048 -and $Cpus -eq 2 -and $Connection -eq 'selected' -and !$BaseImage}
            Should -Invoke New-MutatorToolImage -Times 0
            Should -Invoke Invoke-MutatorContainerCommand -Times 0
        }
    }
    It 'refuses definition changes between scheduling and building' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $entry=@{ModulePath=$script:GeneratedModule;ContainerRecipe=(Get-MutatorContainerRecipe $script:GeneratedModule)}
            Add-Content (Join-Path $script:GeneratedModule 'containers/linux/Dockerfile') '# changed'
            Mock Resolve-MutatorContainerConnection {@{Connection='selected'}}
            Mock New-MutatorContainerImage {throw 'must not build'}
            {Invoke-MutatorContainerPackage $Root @{} $entry @{} (Join-Path $Root 'package/state.json')}|Should -Throw '*changed since scheduling*'
            Should -Invoke New-MutatorContainerImage -Times 0
        }
    }
}
