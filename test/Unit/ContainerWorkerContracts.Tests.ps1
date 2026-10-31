<#
.SYNOPSIS
Expected behavior for the ContainerWorkerContracts tests.

.DESCRIPTION
Workers use immutable images and read-only inputs, including resume reports. Inner business failures
remain failures despite client exit zero; cleanup targets only the generated container name.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Container package ownership, mount safety and retained failures' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            $script:CpkgRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $recipe=Join-Path $script:CpkgRoot 'recipe.psd1'
            [void][IO.Directory]::CreateDirectory($script:CpkgRoot);[IO.File]::WriteAllText($recipe,"@{Binary='fixture';UseWhen='Always';Packages=@('fixture')}")
            $script:CpkgEntry=@{Id='p0';Name='Fixture';ModulePath=(Join-Path $script:CpkgRoot 'Fixture');Configuration=(Join-Path $script:CpkgRoot 'Fixture/test/config.json');Stryker=$true;ResumeFrom=$null;ContainerRecipe=@{Path=$recipe;Sha256=(Get-FileHash $recipe).Hash}}
            $script:CpkgRun=@{SourceRoot=$script:CpkgRoot;ContainerBaseImage='explicit-base';ContainerConnection='rootful';TestOrder='Configured';Schedule=@{Slots=1;Workers=2;ReservedMemoryMiB=2048}}
            $script:CpkgState=@{Outcome='Running';Phase='Pending'}
            $script:CpkgStatePath=Join-Path $script:CpkgRoot 'packages/p0/state.json'
            $script:CpkgMode='Success'
            Mock Resolve-MutatorContainerConnection {@{Connection='rootful';Controllers=@('cpu','memory');Rootless=$false}}
            Mock New-MutatorToolImage {@{Image='tool';ImageId=('a'*64);BaseImageId=('b'*64);Reused=$true}}
            Mock New-MutatorContainerImage {@{Image='generated';ImageId=('a'*64);BaseImageId=('b'*64);Reused=$true}}
            Mock Invoke-MutatorContainerCommand {
                param($Arguments,$Directory)
                if($Arguments[0] -eq 'rm'){return @{Outcome='Success';Stdout='';Stderr=''}}
                if($Arguments[0] -ne 'run'){throw 'Unexpected native invocation'}
                if($script:CpkgMode -eq 'NativeThrow'){throw 'podman disconnected'}
                if($script:CpkgMode -ne 'MissingReport'){
                    $folder=Join-Path $Directory 'container-run/packages/p0'
                    Write-MutatorJson (Join-Path $folder 'state.json') @{Outcome=$(if($script:CpkgMode -eq 'RunningReport'){'Running'}elseif($script:CpkgMode -eq 'BusinessFailure'){'Failed'}else{'Success'});Phase='Completed';PSMutant=@{Total=3;Score=100};Stryker=@{Score=100};Error='retained cause';ContextSha256='context';SourceSha256='source'}
                    Write-MutatorJson (Join-Path $folder 'mutation.json') @{mutants=@(@{Id=12;Status='Killed'})}
                    Write-MutatorJson (Join-Path $folder 'stryker/reports/mutation-report.json') @{schemaVersion='1'}
                }
                @{Outcome=$(if($script:CpkgMode -eq 'NativeFailure'){'Failed'}else{'Success'});Stdout='local stdout';Stderr='local stderr'}
            }
        }
        It 'runs with an immutable image and a read-only resume directory: <Generated>' -ForEach @(@{Generated=$true},@{Generated=$false}) {
            if($Generated){
                $recipe=$script:CpkgEntry.ContainerRecipe;$recipe.Kind='Generated'
                foreach($pair in @(@('DefinitionPath','DefinitionSha256'),@('DockerfilePath','DockerfileSha256'),@('IgnorefilePath','IgnorefileSha256'))){
                    $path=Join-Path $script:CpkgRoot $pair[0];[IO.File]::WriteAllText($path,'frozen source')
                    $recipe[$pair[0]]=$path;$recipe[$pair[1]]=(Get-FileHash $path).Hash
                }
            }
            $resume=Join-Path $script:CpkgRoot 'resume/mutation.json';Write-MutatorJson $resume @{mutants=@()};$script:CpkgEntry.ResumeFrom=$resume
            Invoke-MutatorContainerPackage $script:CpkgRoot $script:CpkgRun $script:CpkgEntry $script:CpkgState $script:CpkgStatePath
            $script:CpkgState.Outcome|Should -BeExactly Success
            $script:CpkgState.Container.BuildKind|Should -BeExactly $(if($Generated){'Generated'}else{'ExplicitRecipe'})
            $inner=Read-MutatorJson (Join-Path (Split-Path $script:CpkgStatePath) 'container-run/run.json')
            $inner.Packages[0].ResumeFrom|Should -BeExactly '/mutator/resume/mutation.json'
            (Read-MutatorJson (Join-Path (Split-Path $script:CpkgStatePath) 'mutation.json')).mutants[0].Id|Should -Be 12
            Test-Path (Join-Path (Split-Path $script:CpkgStatePath) 'stryker/reports/mutation-report.json')|Should -BeTrue
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -Exactly -ParameterFilter {$Arguments[0] -eq 'run' -and $Arguments -contains ('a'*64) -and $Arguments -contains ('type=bind,source='+(Split-Path $resume)+',target=/mutator/resume,readonly') -and $Connection -ceq 'rootful'}
            if($Generated){Should -Invoke New-MutatorContainerImage -Times 1 -Exactly -ParameterFilter {$BaseImage -ceq 'explicit-base' -and $MemoryMiB -eq 2048 -and $Cpus -eq 2 -and $Reuse}}
            else{Should -Invoke New-MutatorToolImage -Times 1 -Exactly}
        }
        It 'retains a business failure even when Podman exits successfully' {
            $script:CpkgMode='BusinessFailure'
            Invoke-MutatorContainerPackage $script:CpkgRoot $script:CpkgRun $script:CpkgEntry $script:CpkgState $script:CpkgStatePath
            $script:CpkgState.Outcome|Should -BeExactly Failed;$script:CpkgState.Error|Should -BeExactly 'retained cause'
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'rm'}
        }
        It 'distinguishes worker and client failures and cleans up only its generated name: <Mode>' -ForEach @(
            @{Mode='MissingReport';Message='*without a final package report*';Cleanup=$false},
            @{Mode='RunningReport';Message='*without a final package report*';Cleanup=$false},
            @{Mode='NativeFailure';Message='*Podman worker execution failed*';Cleanup=$true},
            @{Mode='NativeThrow';Message='*podman disconnected*';Cleanup=$true}
        ) {
            $script:CpkgMode=$Mode
            {Invoke-MutatorContainerPackage $script:CpkgRoot $script:CpkgRun $script:CpkgEntry $script:CpkgState $script:CpkgStatePath}|Should -Throw $Message
            Should -Invoke Invoke-MutatorContainerCommand -Times ([int]$Cleanup) -Exactly -ParameterFilter {$Arguments[0] -eq 'rm' -and $Arguments[1] -eq '--force' -and $Arguments[2] -match '^mutator-[a-f0-9]{32}$' -and $Connection -ceq 'rootful'}
            if($Mode -ne 'NativeThrow'){[IO.File]::ReadAllText((Join-Path (Split-Path $script:CpkgStatePath) 'container.stderr.log'))|Should -BeExactly 'local stderr'}
        }
        It 'rejects unsafe inputs before executing a worker: <Fault>' -ForEach @(
            @{Fault='ChangedRecipe';Message='*recipe changed*'},@{Fault='ChangedGenerated';Message='*definition changed*'},
            @{Fault='MissingBase';Message='*explicit -ContainerBaseImage*'},@{Fault='Stopped';Message='*stopped before container execution*'},
            @{Fault='ResumeComma';Message='*containing commas*'},@{Fault='SourceComma';Message='*containing commas*'}
        ) {
            switch($Fault){
                'ChangedRecipe' {[IO.File]::AppendAllText($script:CpkgEntry.ContainerRecipe.Path,'#changed')}
                'ChangedGenerated' {$recipe=$script:CpkgEntry.ContainerRecipe;$recipe.Kind='Generated';$recipe.DefinitionPath=$recipe.Path;$recipe.DefinitionSha256='changed'}
                'MissingBase' {$script:CpkgRun.Remove('ContainerBaseImage')}
                'Stopped' {Write-MutatorJson (Join-Path $script:CpkgRoot 'stop.json') @{}}
                'ResumeComma' {$resume=Join-Path $script:CpkgRoot 'with,comma/mutation.json';Write-MutatorJson $resume @{};$script:CpkgEntry.ResumeFrom=$resume}
                'SourceComma' {$script:CpkgRun.SourceRoot=Join-Path $script:CpkgRoot 'with,comma'}
            }
            {Invoke-MutatorContainerPackage $script:CpkgRoot $script:CpkgRun $script:CpkgEntry $script:CpkgState $script:CpkgStatePath}|Should -Throw $Message
            Should -Invoke Invoke-MutatorContainerCommand -Times 0
        }
    }
}
Describe 'Podman memory connection discovery refuses unverifiable runtimes' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        It 'fails explicitly at the failing discovery step: <Fault>' -ForEach @(
            @{Fault='info';Message='*inspect the selected Podman connection*'},
            @{Fault='list';Message='*discover a Podman connection with memory controls*'},
            @{Fault='root';Message='*rootful Podman connection is unavailable*'}
        ) {
            $script:DiscoveryFault=$Fault
            Mock Invoke-MutatorContainerCommand {
                param($Arguments,$Connection)
                if(($Arguments[0] -eq 'info' -and !$Connection -and $script:DiscoveryFault -eq 'info') -or ($Arguments[0] -eq 'system' -and $script:DiscoveryFault -eq 'list') -or $Connection){return @{Outcome='Failed';Stdout=''}}
                if($Arguments[0] -eq 'system'){return @{Outcome='Success';Stdout='[{"Name":"machine","Default":true},{"Name":"machine-root","Default":false}]'}}
                @{Outcome='Success';Stdout='{"host":{"cgroupControllers":[],"security":{"rootless":true}}}'}
            }
            {Resolve-MutatorContainerConnection $TestDrive}|Should -Throw $Message
        }
        It 'does not invent a rootful connection when default selection is absent or ambiguous: <Defaults>' -ForEach @(@{Defaults=0},@{Defaults=2}) {
            $script:DiscoveryDefaults=$Defaults
            Mock Invoke-MutatorContainerCommand {
                param($Arguments)
                if($Arguments[0] -eq 'system'){
                    $connections=@(@{Name='one';Default=($script:DiscoveryDefaults -eq 2)},@{Name='two';Default=($script:DiscoveryDefaults -eq 2)})
                    return @{Outcome='Success';Stdout=(ConvertTo-Json -InputObject $connections -Compress)}
                }
                @{Outcome='Success';Stdout='{"host":{"cgroupControllers":[],"security":{"rootless":true}}}'}
            }
            $r=Resolve-MutatorContainerConnection $TestDrive
            $r.Connection|Should -BeNullOrEmpty;$r.Rootless|Should -BeTrue
            Should -Invoke Invoke-MutatorContainerCommand -Times 2 -Exactly
        }
    }
}
