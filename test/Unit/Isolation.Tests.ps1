BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Required PSMutant isolation' {
    It 'keeps default reports in the tested software directory without creating a real run' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $script:SelectedReportDirectory=$null
            Mock Write-MutatorJson {
                param($Path,$Value)
                if((Split-Path $Path -Leaf) -eq 'run.json'){$script:SelectedReportDirectory=Split-Path $Path}
            }
            Mock Start-MutatorWorker {@{Id=77}}
            Mock Get-MutatorRun {[pscustomobject]@{Path=$script:SelectedReportDirectory}}
            $result=Invoke-MutatorRun -ModulePath $script:MutatorRoot -OS Linux -Workers 1 -WorkerBudget 1 -SkipStryker -Background
            $expected=Join-Path $script:MutatorRoot 'test/Artifacts/mutator'
            (Split-Path $result.Path)|Should -BeExactly $expected
        }
    }
    It 'records the requested target and never starts a native host package' -ForEach @(@{Target='Linux';Expected='Podman'},@{Target='Windows';Expected='WindowsSandbox'}) {
        if($Target -eq 'Windows' -and !$IsWindows){return}
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive;Target=$Target;Expected=$Expected} {
            param($Root,$Target,$Expected)
            Mock Start-MutatorWorker { @{Id=77;StartedUtc=[datetime]::UtcNow.ToString('O')} }
            Mock Test-MutatorProcess {$true}
            Mock Invoke-MutatorRunCore {throw 'must not run host mutation core'}
            Mock Get-MutatorMemoryWatchdog {$null}
            if($Target -eq 'Windows'){Mock Get-MutatorEngineSetting {throw 'Windows Sandbox must not depend on Podman settings.'}}
            $result=Invoke-MutatorRun -ModulePath $script:MutatorRoot -OS $Target -RunRoot $Root -Workers 1 -WorkerBudget 1 -MemoryBudgetMiB 4096 -SkipStryker -Background
            $run=Read-MutatorJson (Join-Path $result.Path 'run.json')
            $run.TargetOS|Should -BeExactly $Target
            $run.Isolation|Should -BeExactly $Expected
            $run.Packages[0].IsolationRuntime|Should -BeExactly $Expected
            if($Target -eq 'Linux'){$run.Packages[0].ContainerRecipe|Should -Not -BeNullOrEmpty}
            else{$run.Packages[0].ContainerRecipe|Should -BeNullOrEmpty}
            Should -Invoke Start-MutatorWorker -Times 1
            Should -Invoke Invoke-MutatorRunCore -Times 0
        }
    }
    It 'rejects Docker and the legacy Windows guest rather than executing mutations on the host' {
        {Invoke-MutatorRun -ModulePath absent -OS Linux -ContainerEngine Docker}|Should -Throw '*require Podman*'
        {Invoke-MutatorRun -ModulePath absent -WindowsGuestImage legacy}|Should -Throw '*require Windows Sandbox*'
    }
    It 'selects a container even when the native binary exists' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $path=Join-Path $Root 'Fixture'
            [void][IO.Directory]::CreateDirectory((Join-Path $path 'test'))
            Set-Content -LiteralPath (Join-Path $path 'test/mutator.container.psd1') "@{Binary='pwsh';UseWhen='Missing';Packages=@('git')}"
            (Get-MutatorContainerRecipe $path -Required).Kind|Should -BeExactly Recipe
        }
    }
    It 'requires a Linux runtime instead of falling back to the host when a recipe is absent' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            [void][IO.Directory]::CreateDirectory($Root)
            $recipe=Get-MutatorContainerRecipe $Root -Required
            $recipe.Kind|Should -BeExactly Runtime
            $recipe.Sha256|Should -Match '^[A-Fa-f0-9]{64}$'
        }
    }
    It 'reports the actual host execution of a legacy run despite its configured Podman engine' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            Write-MutatorJson (Join-Path $Root 'run.json') @{Id='legacy';Outcome='Failed';Platform='windows';Runtime='7.6.9';CreatedUtc=[datetime]::UtcNow.ToString('O');ContainerEngine='Podman';Packages=@(@{Id='p0';Name='Fixture'})}
            Write-MutatorJson (Join-Path $Root 'packages/p0/state.json') @{Id='p0';Name='Fixture';Phase='Baseline';Outcome='Failed'}
            $run=Get-MutatorRun -Path $Root
            $run.Packages[0].ExecutionRuntime|Should -BeExactly Host
            $text=Format-MutatorTerminalFrame $run
            $text|Should -Match 'Host'
            $text|Should -Not -Match 'Podman'
        }
    }
    It 'distinguishes a required environment from a started environment' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            Write-MutatorJson (Join-Path $Root 'run.json') @{Id='pending';Outcome='Failed';Platform='windows';Runtime='7.6.9';CreatedUtc=[datetime]::UtcNow.ToString('O');Isolation='WindowsSandbox';TargetOS='Windows';Packages=@(@{Id='p0';Name='Fixture';IsolationRuntime='WindowsSandbox';Platform='windows'})}
            $view=Get-MutatorRun -Path $Root
            $view.Packages[0].ExecutionRuntime|Should -BeExactly Pending
            $view.Packages[0].RequiredRuntime|Should -BeExactly WindowsSandbox
            Write-MutatorJson (Join-Path $Root 'packages/p0/state.json') @{Id='p0';Name='Fixture';Phase='Starting Windows Sandbox';Outcome='Running';Container=@{Engine='WindowsSandbox';Started=$false}}
            (Get-MutatorRun -Path $Root).Packages[0].ExecutionRuntime|Should -BeExactly Pending
            Write-MutatorJson (Join-Path $Root 'packages/p0/state.json') @{Id='p0';Name='Fixture';Phase='Baseline';Outcome='Running';Container=@{Engine='WindowsSandbox'}}
            (Get-MutatorRun -Path $Root).Packages[0].ExecutionRuntime|Should -BeExactly WindowsSandbox
        }
    }
    It 'retains the target OS when preparing a resume' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $run=@{SourceRoot='source';TargetOS='Linux';Schedule=@{Workers=2;WorkerBudget=2;MemoryBudgetMiB=4096};TestOrder='FocusedFirst';ContainerEngine='Podman'}
            (Get-MutatorRestartOptions $run @{ModulePath='module';Stryker=$false} 'runs').OS|Should -BeExactly Linux
        }
    }
}
Describe 'Windows Sandbox boundary' {
    It 'disables network and clipboard and exposes only the artifact directory for writing' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $xml=[xml](New-MutatorSandboxConfiguration -Mappings @(
                @{HostPath='C:\source & tools';GuestPath='C:\Input';ReadOnly=$true},
                @{HostPath='C:\artifacts';GuestPath='C:\Output';ReadOnly=$false}) -MemoryMiB 3072)
            $xml.Configuration.Networking|Should -BeExactly Disable
            $xml.Configuration.ClipboardRedirection|Should -BeExactly Disable
            $xml.Configuration.MemoryInMB|Should -BeExactly '3072'
            $folders=@($xml.Configuration.MappedFolders.MappedFolder)
            $folders[0].HostFolder|Should -BeExactly 'C:\source & tools'
            $folders[0].ReadOnly|Should -BeExactly true
            @($folders|Where-Object ReadOnly -EQ false).Count|Should -Be 1
            $folders[1].SandboxFolder|Should -BeExactly 'C:\Output'
        }
    }
    It 'refuses an invalid session ID without calling the native client' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Mock Invoke-MutatorSandboxCommand {throw 'must not run'}
            {Stop-MutatorWindowsSandbox -Id 'all' -Directory 'unused'}|Should -Throw '*valid owned ID*'
            Should -Invoke Invoke-MutatorSandboxCommand -Times 0
        }
    }
    It 'runs an owned isolated worker and retains evidence on <Scenario>' -Skip:(!$IsWindows) -ForEach @(
        @{Scenario='success'},@{Scenario='guest failure'},@{Scenario='exec failure'},@{Scenario='start failure'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive;Scenario=$Scenario} {
            param($Root,$Scenario)
            $runPath=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $artifacts=Join-Path $runPath 'packages/p0'
            [void][IO.Directory]::CreateDirectory($artifacts)
            $state=@{Id='p0';Name='Fixture';Outcome='Running';Phase='Baseline'}
            $entry=@{Id='p0';Name='Fixture';ModulePath=$script:MutatorRoot;Configuration=(Join-Path $script:MutatorRoot 'test/psmutant.config.json');ResumeFrom=$null;Stryker=$false}
            $run=@{SourceRoot=(Split-Path $script:MutatorRoot);Schedule=@{Workers=1;Slots=1;ReservedMemoryMiB=2048};TestOrder='FocusedFirst'}
            $script:SandboxScenario=$Scenario
            $script:SandboxId=$null
            Mock Get-Command { @{Name='wsb'} } -ParameterFilter {$Name -eq 'wsb'}
            Mock Copy-MutatorSandboxRuntime {}
            Mock Invoke-MutatorSandboxCommand {
                param($Arguments,$Directory)
                if($Arguments[0] -eq 'start'){
                    $script:SandboxId=$Arguments[2]
                    ([xml]$Arguments[4]).Configuration.Networking|Should -BeExactly Disable
                    if($script:SandboxScenario -eq 'start failure'){throw 'fixture startup failed'}
                }
                if($Arguments[0] -eq 'exec'){
                    $Arguments[2]|Should -BeExactly $script:SandboxId
                    $Arguments|Should -Contain 'System'
                    ($Arguments -join ' ')|Should -Match 'tools\\pwsh\\pwsh.exe'
                    $innerPath=Join-Path $Directory 'sandbox-run/packages/p0'
                    $inner=Read-MutatorJson (Join-Path $Directory 'sandbox-run/run.json')
                    $inner.IsolationBoundary|Should -BeExactly WindowsSandbox
                    $inner.StopPath|Should -BeExactly 'C:\MutatorRun\stop.json'
                    $inner.Packages[0].Contains('ContainerRecipe')|Should -BeFalse
                    Write-MutatorJson (Join-Path $innerPath 'mutation.json') @{mode='Full';total=1;killed=1}
                    $outcome=if($script:SandboxScenario -eq 'guest failure'){'Failed'}else{'Success'}
                    Write-MutatorJson (Join-Path $innerPath 'state.json') @{Outcome=$outcome;Phase='Completed';Error=$null;PSMutant=@{Total=1;Killed=1;Survived=0}}
                    if($script:SandboxScenario -eq 'exec failure'){throw 'fixture exec failed'}
                }
                if($Arguments[0] -eq 'stop'){$Arguments[2]|Should -BeExactly $script:SandboxId}
                @{Outcome='Success';Stdout='';Stderr=''}
            }
            if($Scenario -in @('start failure','exec failure')){
                {Invoke-MutatorWindowsSandboxPackage $runPath $run $entry $state (Join-Path $artifacts 'state.json')}|Should -Throw '*fixture*failed*'
            }else{
                Invoke-MutatorWindowsSandboxPackage $runPath $run $entry $state (Join-Path $artifacts 'state.json')
                $state.Outcome|Should -BeExactly $(if($Scenario -eq 'guest failure'){'Failed'}else{'Success'})
            }
            $state.Container.Stopped|Should -BeTrue
            $state.Container.Engine|Should -BeExactly WindowsSandbox
            Should -Invoke Copy-MutatorSandboxRuntime -Times 1
            Should -Invoke Invoke-MutatorSandboxCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'stop'}
            Test-Path (Join-Path $artifacts 'mutation.json')|Should -Be ($Scenario -ne 'start failure')
        }
    }
}
