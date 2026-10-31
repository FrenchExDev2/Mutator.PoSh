<#
.SYNOPSIS
Expected behavior for the ContainerBuild tests.

.DESCRIPTION
Reuse requires exact build identity; explicit bases resolve to immutable images and dependency
changes invalidate reuse. Builds retain resources/logs, never retry automatically, and reject bad
inspection or WhatIf allocation.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    $script:BuildModules=Split-Path (Split-Path (Split-Path $PSScriptRoot))
    . (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'test/Fixtures/ContainerWorkspace.ps1')
    $script:BuildModules=New-MutatorContainerWorkspace -Path (Join-Path $TestDrive 'build-workspace')
}
Describe 'Generated container builds owned by Mutator' {
    It 'reuses only an image with the exact build identity and retains a receipt' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Modules=$script:BuildModules;Output=$TestDrive} {
            param($Modules,$Output)
            $script:CacheIdentity=$null
            Mock Invoke-MutatorContainerCommand {
                param($Arguments)
                if($Arguments[0] -eq 'build'){
                    $script:CacheIdentity=($Arguments[$Arguments.IndexOf('--label')+1] -split '=',2)[1]
                    return @{Outcome='Success';ExitCode=0;Stdout='built';Stderr=''}
                }
                @{Outcome='Success';Stdout=(@(@{Os='linux';Id=('a'*64);Size=100;Config=@{Labels=@{'org.frenchexdev.mutator.build-identity'=$script:CacheIdentity;'org.frenchexdev.mutator.base-image-id'=('a'*64)}}})|ConvertTo-Json -Depth 6 -Compress)}
            }
            $path=Join-Path $Modules 'FrenchExDev.Tools.Ag.PoSh'
            $first=New-MutatorContainerImage -ModulePath $path -OutputDirectory (Join-Path $Output 'first') -Reuse
            $again=New-MutatorContainerImage -ModulePath $path -OutputDirectory (Join-Path $Output 'again') -Reuse
            $first.Reused|Should -BeFalse
            $again.Reused|Should -BeTrue
            $again.Outcome|Should -BeExactly Success
            $again.ImageId|Should -BeExactly $first.ImageId
            $again.BaseImageId|Should -BeExactly $first.BaseImageId
            $again.CompletedUtc|Should -Not -BeNullOrEmpty
            (Read-MutatorJson (Join-Path $Output 'again/build.json')).Reused|Should -BeTrue
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -Exactly -ParameterFilter {$Arguments[0] -eq 'build'}
        }
    }
    It 'pins an explicit module base to its immutable identity and skips the default base' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Modules=$script:BuildModules;Output=$TestDrive} {
            param($Modules,$Output)
            Mock Initialize-MutatorImagePrerequisite {@()}
            Mock Invoke-MutatorContainerCommand {param($Arguments);@{Outcome='Success';ExitCode=0;Stdout=$(if($Arguments[0] -eq 'image'){'[{"Os":"linux","Id":"'+('a'*64)+'","Size":100}]'}else{''});Stderr=''}}
            $result=New-MutatorContainerImage -ModulePath (Join-Path $Modules 'FrenchExDev.Tools.Ag.PoSh') -BaseImage explicit -OutputDirectory $Output
            $result.BaseImageId|Should -BeExactly ('a'*64)
            $result.SourceFingerprints.baseImage|Should -BeExactly ('a'*64)
            Should -Invoke Initialize-MutatorImagePrerequisite -Times 1 -ParameterFilter {$BaseImage -eq 'explicit'}
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'build' -and $Arguments -contains ('BASE_IMAGE='+('a'*64))}
        }
    }
    It 'refuses an invalid explicit base before dependency construction' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Modules=$script:BuildModules;Output=$TestDrive} {
            param($Modules,$Output)
            Mock Invoke-MutatorContainerCommand {@{Outcome='Success';Stdout='[{"Os":"windows","Id":"invalid"}]'}}
            Mock Initialize-MutatorImagePrerequisite {throw 'must not build'}
            {New-MutatorContainerImage -ModulePath (Join-Path $Modules 'FrenchExDev.Tools.Ag.PoSh') -BaseImage invalid -OutputDirectory $Output}|Should -Throw '*valid Linux image identity*'
            (Read-MutatorJson (Join-Path $Output 'build.json')).Outcome|Should -BeExactly Failed
            Should -Invoke Initialize-MutatorImagePrerequisite -Times 0
        }
    }
    It 'invalidates the module image when an explicit base tag resolves to another image' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Modules=$script:BuildModules;Output=$TestDrive} {
            param($Modules,$Output)
            $script:OverrideId='a'*64
            Mock Initialize-MutatorImagePrerequisite {@()}
            Mock Invoke-MutatorContainerCommand {param($Arguments);@{Outcome='Success';ExitCode=0;Stdout=$(if($Arguments[0] -eq 'image'){'[{"Os":"linux","Id":"'+$script:OverrideId+'","Size":100}]'}else{''});Stderr=''}}
            $first=New-MutatorContainerImage -ModulePath (Join-Path $Modules 'FrenchExDev.Tools.Ag.PoSh') -BaseImage mutable -OutputDirectory (Join-Path $Output 'first')
            $script:OverrideId='b'*64
            $second=New-MutatorContainerImage -ModulePath (Join-Path $Modules 'FrenchExDev.Tools.Ag.PoSh') -BaseImage mutable -OutputDirectory (Join-Path $Output 'second')
            $first.Image|Should -Not -BeExactly $second.Image
            $second.BaseImageId|Should -BeExactly ('b'*64)
        }
    }
    It 'builds the Linux dockurr Windows bootstrap recipe without booting a guest' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Modules=$script:BuildModules;Output=$TestDrive} {
            param($Modules,$Output)
            Mock Invoke-MutatorContainerCommand {
                param($Arguments)
                @{Outcome='Success';ExitCode=0;Stdout=$(if($Arguments[0] -eq 'image'){'[{"Os":"linux","Id":"'+('a'*64)+'","Size":100}]'}else{''});Stderr=''}
            }
            $result=New-MutatorContainerImage -ModulePath (Join-Path $Modules 'FrenchExDev.Mutator.PoSh') -BaseVariant WindowsBootstrap -OutputDirectory $Output
            $result.Image|Should -Match ':windows-bootstrap-pwsh-'
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'build' -and ($Arguments[$Arguments.IndexOf('--file')+1] -replace '\\','/') -like '*/base/windows-bootstrap/Dockerfile'}
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -in @('create','start','run')}
        }
    }
    It 'selects the Windows dockurr module layer explicitly' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Modules=$script:BuildModules;Output=$TestDrive} {
            param($Modules,$Output)
            Mock Invoke-MutatorContainerCommand {param($Arguments);@{Outcome='Success';ExitCode=0;Stdout=$(if($Arguments[0] -eq 'image'){'[{"Os":"linux","Id":"'+('a'*64)+'","Size":100}]'}else{''});Stderr=''}}
            $result=New-MutatorContainerImage -ModulePath (Join-Path $Modules 'FrenchExDev.Tools.Ag.PoSh') -Platform Windows -OutputDirectory $Output
            $result.Image|Should -Match ':windows-'
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'build' -and ($Arguments[$Arguments.IndexOf('--file')+1] -replace '\\','/') -like '*/containers/windows/Dockerfile'}
        }
    }
    It 'builds a shared base with explicit resources and no automatic retry, then records its identity' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Modules=$script:BuildModules;Output=$TestDrive} {
            param($Modules,$Output)
            Mock Invoke-MutatorContainerCommand {
                param($Arguments)
                if($Arguments[0] -eq 'build'){return @{Outcome='Success';ExitCode=0;Stdout='retained build';Stderr=''}}
                @{Outcome='Success';ExitCode=0;Stdout=('[{"Os":"linux","Id":"'+('a'*64)+'","Size":12345}]');Stderr=''}
            }
            $result=New-MutatorContainerImage -ModulePath (Join-Path $Modules 'FrenchExDev.Mutator.PoSh') -BaseVariant Alpine -OutputDirectory $Output -Connection fixture -MemoryMiB 1024 -Cpus 3
            $result.Outcome | Should -BeExactly Success
            $result.ImageId | Should -BeExactly ('a'*64)
            $result.SizeBytes | Should -Be 12345
            $result.DurationSeconds | Should -BeGreaterOrEqual 0
            (Get-Content $result.StdoutLog -Raw) | Should -BeExactly 'retained build'
            (Read-MutatorJson (Join-Path $Output 'build.json')).Outcome | Should -BeExactly Success
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -Exactly -ParameterFilter {
                $Arguments[0] -eq 'build' -and $Arguments -contains '--pull=missing' -and $Arguments -contains '--ignorefile' -and
                $Arguments[$Arguments.IndexOf('--retry')+1] -eq '0' -and
                $Arguments[$Arguments.IndexOf('--memory')+1] -eq '1024m' -and
                $Arguments[$Arguments.IndexOf('--memory-swap')+1] -eq '1024m' -and
                $Arguments[$Arguments.IndexOf('--cpu-quota')+1] -eq '300000' -and $Connection -eq 'fixture'
            }
        }
    }
    It 'retains failure logs and the native failure without retry or inspection' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Modules=$script:BuildModules;Output=$TestDrive} {
            param($Modules,$Output)
            Mock Invoke-MutatorContainerCommand { @{Outcome='TimedOut';ExitCode=$null;Stdout='partial';Stderr='original diagnostic'} }
            {New-MutatorContainerImage -ModulePath (Join-Path $Modules 'FrenchExDev.Mutator.PoSh') -BaseVariant Alpine -OutputDirectory $Output} | Should -Throw '*retained receipt*'
            $receipt=Read-MutatorJson (Join-Path $Output 'build.json')
            $receipt.Outcome | Should -BeExactly TimedOut
            (Get-Content $receipt.StderrLog -Raw) | Should -BeExactly 'original diagnostic'
            $receipt.CompletedUtc | Should -Not -BeNullOrEmpty
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -Exactly
        }
    }
    It 'never pulls a missing shared base while building a tool layer' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Modules=$script:BuildModules;Output=$TestDrive} {
            param($Modules,$Output)
            Mock Invoke-MutatorContainerCommand {
                param($Arguments)
                if($Arguments[0] -eq 'build'){return @{Outcome='Success';ExitCode=0;Stdout='';Stderr=''}}
                @{Outcome='Success';Stdout=('[{"Os":"linux","Id":"'+('b'*64)+'","Size":100}]')}
            }
            $result=New-MutatorContainerImage -ModulePath (Join-Path $Modules 'FrenchExDev.Tools.Ag.PoSh') -OutputDirectory $Output
            $result.Image | Should -Match '^localhost/frenchexdev\.tools\.ag:linux-[a-f0-9]{16}$'
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'build' -and $Arguments -contains '--pull=never'}
        }
    }
    It 'rejects invalid inspection results even after a successful build' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Modules=$script:BuildModules;Output=$TestDrive} {
            param($Modules,$Output)
            Mock Invoke-MutatorContainerCommand {param($Arguments);@{Outcome='Success';ExitCode=0;Stdout=$(if($Arguments[0] -eq 'image'){'[{"Os":"windows","Id":"invalid"}]'}else{''});Stderr=''}}
            {New-MutatorContainerImage -ModulePath (Join-Path $Modules 'FrenchExDev.Mutator.PoSh') -BaseVariant Alpine -OutputDirectory $Output}|Should -Throw '*Invalid built Linux*'
            (Read-MutatorJson (Join-Path $Output 'build.json')).Outcome | Should -BeExactly Failed
        }
    }
    It 'honors WhatIf before creating a build directory or calling Podman' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Modules=$script:BuildModules;Output=(Join-Path $TestDrive 'not-created')} {
            param($Modules,$Output)
            Mock Invoke-MutatorContainerCommand {throw 'must not execute'}
            $null=New-MutatorContainerImage -ModulePath (Join-Path $Modules 'FrenchExDev.Mutator.PoSh') -BaseVariant Alpine -OutputDirectory $Output -WhatIf
            Test-Path $Output | Should -BeFalse
            Should -Invoke Invoke-MutatorContainerCommand -Times 0
        }
    }
    It 'changes the tool image identity when a copied engine dependency changes' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Modules=$script:BuildModules;Output=$TestDrive} {
            param($Modules,$Output)
            $script:CopiedEngineHash='a'*64
            $script:BuildBootstrapHash=(Get-MutatorSourceSnapshot (Join-Path $script:MutatorRoot 'resources/containers/definitions/bootstrap')).Sha256
            Mock Get-MutatorSourceSnapshot {
                param($Root)
                @{Sha256=$(if((Split-Path $Root -Leaf) -eq 'FrenchExDev.QuietCli.PoSh'){$script:CopiedEngineHash}elseif((Split-Path $Root -Leaf) -eq 'bootstrap'){$script:BuildBootstrapHash}else{'c'*64})}
            }
            Mock Invoke-MutatorContainerCommand {
                param($Arguments)
                @{Outcome='Success';ExitCode=0;Stdout=$(if($Arguments[0] -eq 'image'){'[{"Os":"linux","Id":"'+('b'*64)+'","Size":100}]'}else{''});Stderr=''}
            }
            $first=New-MutatorContainerImage -ModulePath (Join-Path $Modules 'FrenchExDev.Tools.Ag.PoSh') -OutputDirectory (Join-Path $Output 'first')
            $script:CopiedEngineHash='d'*64
            $second=New-MutatorContainerImage -ModulePath (Join-Path $Modules 'FrenchExDev.Tools.Ag.PoSh') -OutputDirectory (Join-Path $Output 'second')
            $first.Image | Should -Not -BeExactly $second.Image
            $second.SourceFingerprints['FrenchExDev.QuietCli.PoSh'] | Should -BeExactly ('d'*64)
        }
    }
}
