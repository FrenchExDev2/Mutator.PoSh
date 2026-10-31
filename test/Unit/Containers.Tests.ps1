<#
.SYNOPSIS
Expected behavior for the Containers tests.

.DESCRIPTION
Custom recipes require explicit verified bases and safe inputs; discovery must not silently
substitute host execution. Retain build phases/failures, run workers offline and apply only reported
resource controls.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Linux tool images' {
    It 'requires an explicit base for custom recipes instead of discovering obsolete test images' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $recipe=Join-Path $Root 'custom.psd1'
            Set-Content $recipe "@{Binary='ag';Packages=@('ag')}"
            Mock Invoke-MutatorContainerCommand {throw 'must not discover images'}
            {New-MutatorToolImage $recipe -OutputDirectory $Root}|Should -Throw '*require -BaseImage explicitly*'
            Should -Invoke Invoke-MutatorContainerCommand -Times 0
        }
    }
    It 'builds from the resolved base identity, probes the binary and retains reproducible evidence' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $recipe=Join-Path $Root 'ag.psd1'
            Set-Content $recipe "@{Binary='ag';Packages=@('the_silver_searcher=2.2.0-r1')}"
            Mock Invoke-MutatorNative {
                param($Command,$Arguments,$Directory)
                if($Arguments[0] -eq 'build') {
                    $script:Built=$true
                    $file=[IO.File]::ReadAllText((Join-Path $Directory 'Containerfile'))
                    $file | Should -Match ('FROM '+('a'*64))
                    $file | Should -Match 'the_silver_searcher=2.2.0-r1'
                    $file | Should -Match 'Get-Command ag'
                    $file | Should -Match 'PowerShell 7.6'
                    return @{Outcome='Success';Stdout='built';Stderr=''}
                }
                if($Arguments[-1] -eq 'base'){return @{Outcome='Success';Stdout=('[{"Id":"'+('a'*64)+'","Os":"linux"}]')}}
                if(!$script:Built){return @{Outcome='Failed';Stdout='';Stderr='missing'}}
                @{Outcome='Success';Stdout=('[{"Id":"'+('b'*64)+'","Os":"linux"}]')}
            }
            $script:Built=$false
            $result=New-MutatorToolImage -RecipePath $recipe -BaseImage base -OutputDirectory (Join-Path $Root 'image')
            $result.Reused | Should -BeFalse
            $result.ImageId | Should -BeExactly ('b'*64)
            (Read-MutatorJson (Join-Path $Root 'image/image.json')).BaseImageId | Should -BeExactly ('a'*64)
            Should -Invoke Invoke-MutatorNative -Times 1 -ParameterFilter {$Arguments[0] -eq 'build'}
            $again=New-MutatorToolImage -RecipePath $recipe -BaseImage base -OutputDirectory (Join-Path $Root 'image2')
            $again.Reused | Should -BeTrue
            $again.Image | Should -BeExactly $result.Image
            Should -Invoke Invoke-MutatorNative -Times 1 -ParameterFilter {$Arguments[0] -eq 'build'}
        }
    }
    It 'rejects shell syntax before calling the native runtime' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $recipe=Join-Path $Root 'bad.psd1'
            Set-Content $recipe "@{Binary='ag';Packages=@('ag; touch /tmp/injected')}"
            Mock Invoke-MutatorNative {throw 'Must not run'}
            {New-MutatorToolImage $recipe -BaseImage base -OutputDirectory $Root} | Should -Throw '*shell syntax*'
            Should -Invoke Invoke-MutatorNative -Times 0
        }
    }
    It 'does not build a Windows base using the Linux adapter' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $recipe=Join-Path $Root 'windows.psd1'
            Set-Content $recipe "@{Binary='ag';Packages=@('ag')}"
            Mock Invoke-MutatorNative { @{Outcome='Success';Stdout=('[{"Id":"'+('a'*64)+'","Os":"windows"}]')} }
            {New-MutatorToolImage $recipe -BaseImage windows -OutputDirectory $Root} | Should -Throw '*Linux base*'
            Should -Invoke Invoke-MutatorNative -Times 0 -ParameterFilter {$Arguments[0] -eq 'build'}
        }
    }
    It 'keeps a build failure distinct from a baseline failure' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $runPath=Join-Path $Root 'build-failure'
            $artifacts=Join-Path $runPath 'packages/p0000'
            $recipe=Join-Path $Root 'failing.psd1'
            Set-Content $recipe "@{Binary='ag';Packages=@('ag')}"
            $entry=@{Id='p0000';Name='Ag';ResumeFrom=$null;ContainerRecipe=@{Path=$recipe;Sha256=(Get-FileHash $recipe).Hash}}
            Write-MutatorJson (Join-Path $runPath 'run.json') @{Packages=@($entry);ContainerBaseImage='base'}
            Mock New-MutatorToolImage {
                $state=Read-MutatorJson (Join-Path $OutputDirectory '../state.json')
                $state.Phase | Should -BeExactly 'Building Container'
                throw 'fixture build failed'
            }
            Mock Resolve-MutatorContainerConnection { @{Connection='';Controllers=@();Rootless=$true} }
            Mock Import-MutatorTool {throw 'Baseline must not start'}
            Invoke-MutatorPackage $runPath p0000
            $state=Read-MutatorJson (Join-Path $artifacts 'state.json')
            $state.Outcome | Should -Be Failed
            $state.FailedPhase | Should -BeExactly 'Building Container'
            $state.Error | Should -BeExactly 'fixture build failed'
            Should -Invoke Import-MutatorTool -Times 0
        }
    }
    It 'does not classify an absent tool as Linux-only without a declared recipe' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $module=Join-Path $Root 'Unknown'
            [void][IO.Directory]::CreateDirectory($module)
            Get-MutatorContainerRecipe $module | Should -BeNullOrEmpty
            [void][IO.Directory]::CreateDirectory((Join-Path $module 'test'))
            Set-Content (Join-Path $module 'test/mutator.container.psd1') "@{Binary='linux-only-tool';UseWhen='Always';Packages=@('tool')}"
            (Get-MutatorContainerRecipe $module).Binary | Should -BeExactly 'linux-only-tool'
        }
    }
    It 'shows the complete building phase and does not display unknown counts as a slash' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $run=[pscustomobject]@{Id='build';Platform='windows';Outcome='Running';ProcessedPackages=0;TotalPackages=1;CompletedPackages=0;FailedPackages=0;ErrorPercent=0;InterruptedPackages=0
                EvaluatedMutants=0;PlannedMutants=0;SurvivedMutants=0;CreatedUtc=[datetime]::UtcNow.ToString('O');CompletedUtc=$null;Path='fixture'
                Packages=@(@{Name='Ag';Phase='Building Container';Outcome='Running';Container=@{Connection='machine-root';ResourceLimits=@{Memory=$true;MemoryMiB=1024}}},
                    @{Name='AstGrep';Phase='Baseline';Outcome='Running'})}
            $text=Format-MutatorTerminalFrame $run
            $text | Should -Match 'Building Container\s+Running\s+non demarre'
            $text | Should -Match 'MUTANTS\s+PLATEFORME\s+RAM\s+CONNEXION'
            $text | Should -Match 'Ag\s+Building Container\s+Running\s+non demarre\s+Linux\s+1024 Mio max\s+machine-root'
            $text | Should -Match 'AstGrep\s+Baseline\s+Running\s+non demarre\s+Windows\s+-\s+-'
            $text | Should -Not -Match 'Linux \| RAM'
        }
    }
    It 'runs the Linux worker offline, drains reports and applies only available resource controllers' -ForEach @(
        @{Controllers=@('cpu','memory');Enforced=$true},@{Controllers=@();Enforced=$false}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive;Controllers=$Controllers;Enforced=$Enforced} {
            param($Root,$Controllers,$Enforced)
            $directory=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $artifacts=Join-Path $directory 'packages/p0'
            $recipe=Join-Path $Root 'worker.psd1'
            Set-Content $recipe "@{Binary='ag';Packages=@('ag')}"
            $entry=@{Id='p0';Name='Fixture';ModulePath=(Join-Path $Root 'Fixture');Configuration=(Join-Path $Root 'Fixture/test/config.json');Stryker=$false;ResumeFrom=$null
                ContainerRecipe=@{Path=$recipe;Sha256=(Get-FileHash $recipe).Hash}}
            $state=@{Outcome='Running';Phase='Baseline'}
            $run=@{SourceRoot=$Root;TestOrder='Configured';ContainerBaseImage='base';Schedule=@{Workers=1;Slots=1;ReservedMemoryMiB=1024}}
            Mock New-MutatorToolImage { [pscustomobject]@{Image='tool';ImageId=('b'*64);BaseImageId=('a'*64);Reused=$true} }
            Mock Resolve-MutatorContainerConnection { @{Connection='';Controllers=$Controllers;Rootless=$true} }
            Mock Invoke-MutatorNative {
                param($Command,$Arguments,$Directory)
                if($Arguments[0] -eq 'info'){return @{Outcome='Success';Stdout=(@{host=@{cgroupControllers=$Controllers}}|ConvertTo-Json -Depth 4 -Compress)}}
                $Arguments | Should -Contain '--network=none'
                ($Arguments -contains '--memory') | Should -Be $Enforced
                ($Arguments -contains '--cpus') | Should -Be $Enforced
                $Arguments | Should -Contain ('type=bind,source='+$Root+',target=/mutator/source,readonly')
                $inside=Join-Path $Directory 'container-run/packages/p0'
                Write-MutatorJson (Join-Path $inside 'state.json') @{Outcome='Success';Phase='Completed';PSMutant=@{Total=3;Score=100}}
                Write-MutatorJson (Join-Path $inside 'mutation.json') @{mode='Full';mutationScore=100}
                @{Outcome='Success';Stdout='';Stderr=''}
            }
            Invoke-MutatorContainerPackage $directory $run $entry $state (Join-Path $artifacts 'state.json')
            $state.Outcome | Should -Be Success
            $state.PSMutant.Total | Should -Be 3
            $state.Container.ResourceLimits.Memory | Should -Be $Enforced
            Test-Path (Join-Path $artifacts 'mutation.json') | Should -BeTrue
            $inner=Read-MutatorJson (Join-Path $artifacts 'container-run/run.json')
            $inner.ContainerImageId | Should -BeExactly ('b'*64)
            $inner.StopPath | Should -BeExactly '/mutator/owner/stop.json'
            Should -Invoke Invoke-MutatorNative -Times 0 -ParameterFilter {$Arguments[0] -eq 'rm'}
        }
    }
    It 'selects the existing rootful connection when rootless cannot enforce memory and does not change the default' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            Mock Invoke-MutatorContainerCommand {
                param($Arguments,$Connection)
                if($Arguments[0] -eq 'system') {return @{Outcome='Success';Stdout='[{"Name":"machine","Default":true},{"Name":"machine-root","Default":false}]'}}
                $controllers=if($Connection -eq 'machine-root'){@('cpu','memory')}else{@()}
                @{Outcome='Success';Stdout=(@{host=@{cgroupControllers=$controllers;security=@{rootless=(!$Connection)}}}|ConvertTo-Json -Depth 5 -Compress)}
            }
            $selected=Resolve-MutatorContainerConnection -Directory $Root
            $selected.Connection | Should -BeExactly 'machine-root'
            $selected.Controllers | Should -Contain memory
            $selected.Rootless | Should -BeFalse
            Should -Invoke Invoke-MutatorContainerCommand -Times 3
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments -contains 'default'}
            $explicit=Resolve-MutatorContainerConnection -Directory $Root -Connection machine
            $explicit.Connection | Should -BeExactly machine
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'system'}
        }
    }
    It 'transfers a prepared base once to the selected storage and removes its temporary archive' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $recipe=Join-Path $Root 'transfer.psd1'
            Set-Content $recipe "@{Binary='ag';Packages=@('ag')}"
            $script:Transferred=$false
            Mock Invoke-MutatorContainerCommand {
                param($Arguments,$Connection)
                if($Arguments[0] -eq 'save'){
                    $Connection | Should -BeNullOrEmpty
                    Set-Content -LiteralPath $Arguments[2] -Value 'fixture archive'
                    return @{Outcome='Success'}
                }
                if($Arguments[0] -eq 'load'){
                    $Connection | Should -BeExactly target
                    Test-Path -LiteralPath $Arguments[2] | Should -BeTrue
                    $script:Transferred=$true
                    return @{Outcome='Success'}
                }
                if($Arguments[-1] -eq 'base' -and $Connection -eq 'target' -and !$script:Transferred){return @{Outcome='Failed'}}
                @{Outcome='Success';Stdout=('[{"Id":"'+('a'*64)+'","Os":"linux"}]')}
            }
            $result=New-MutatorToolImage $recipe -BaseImage base -Connection target -OutputDirectory (Join-Path $Root 'transfer')
            $result.Connection | Should -BeExactly target
            @(Get-ChildItem (Join-Path $Root 'transfer') -File -Filter '*.tar').Count | Should -Be 0
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'save'}
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'load'}
        }
    }
}
