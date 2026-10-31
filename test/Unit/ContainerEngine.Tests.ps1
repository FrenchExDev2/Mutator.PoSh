BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Explicit Docker and Podman engine selection' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {Set-MutatorContainerContext Podman $null;$script:MutatorPreferredContainerEngine=$null;$script:MutatorPreferredContainerConnection=$null}
        AfterEach {Set-MutatorContainerContext Podman $null;$script:MutatorPreferredContainerEngine=$null;$script:MutatorPreferredContainerConnection=$null}
        It 'selects an engine for the session without mutating a CLI global default: <Engine>/<Connection>' -ForEach @(
            @{Engine='Docker';Connection='test-context'},@{Engine='Docker';Connection=$null},@{Engine='Podman';Connection='machine-root'}
        ) {
            Mock Invoke-MutatorNative {throw 'Selecting a module engine must not change the CLI configuration.'}
            $r=Set-MutatorContainerEngine -Engine $Engine -Connection $Connection
            $r.Engine|Should -BeExactly $Engine
            if($null -eq $Connection){$r.Connection|Should -BeNullOrEmpty}else{$r.Connection|Should -Be $Connection}
            $script:MutatorContainerEngine|Should -BeExactly $Engine
            $null=Set-MutatorContainerEngine -Engine Podman -WhatIf
            $script:MutatorContainerEngine|Should -BeExactly $Engine
            Should -Invoke Invoke-MutatorNative -Times 0
        }
        It 'restores the engine and connection recorded by a worker or guest: <Legacy>' -ForEach @(@{Legacy=$true},@{Legacy=$false}) {
            $run=if($Legacy){@{Connection='old-machine'}}else{@{ContainerEngine='Docker';ContainerConnection='docker-context'}}
            Restore-MutatorContainerContext $run
            $script:MutatorContainerEngine|Should -BeExactly $(if($Legacy){'Podman'}else{'Docker'})
            $script:MutatorContainerConnection|Should -BeExactly $(if($Legacy){'old-machine'}else{'docker-context'})
        }
        It 'preserves arguments and chooses the correct connection flag: <Engine>/<ExplicitDefault>' -ForEach @(
            @{Engine='Podman';ExplicitDefault=$false},@{Engine='Docker';ExplicitDefault=$false},
            @{Engine='Podman';ExplicitDefault=$true},@{Engine='Docker';ExplicitDefault=$true}
        ) {
            Set-MutatorContainerContext $Engine selected
            Mock Invoke-MutatorNative {param($Command,$Arguments) @{Outcome='Success';ExitCode=0;Stdout=($Arguments -join '|');Stderr='';Tool=$Command}}
            $r=Invoke-MutatorContainerCommand @('image','inspect','image with spaces') $TestDrive -DefaultConnection:$ExplicitDefault
            $r.Tool|Should -BeExactly $Engine.ToLowerInvariant()
            $r.Stdout|Should -BeExactly $(if($ExplicitDefault){'image|inspect|image with spaces'}else{$(if($Engine -eq 'Docker'){'--context'}else{'--connection'})+'|selected|image|inspect|image with spaces'})
        }
        It 'normalizes only proven Docker resource capabilities: <Memory>/<Cpu>/<Rootless>' -ForEach @(
            @{Memory=$true;Cpu=$true;Rootless=$true},@{Memory=$false;Cpu=$false;Rootless=$false},@{Memory=$true;Cpu=$false;Rootless=$false}
        ) {
            Set-MutatorContainerContext Docker context
            $script:DockerHostInfo=@{MemoryLimit=$Memory;CpuCfsQuota=$Cpu;SecurityOptions=$(if($Rootless){@('name=rootless')}else{@()});NCPU=4;MemTotal=8GB;OSType='linux';ServerVersion='recorded'}
            Mock Invoke-MutatorNative {@{Outcome='Success';ExitCode=0;Stdout=($script:DockerHostInfo|ConvertTo-Json -Compress);Stderr=''}}
            $r=Invoke-MutatorContainerCommand @('info','--format','json') $TestDrive
            $normalized=$r.Stdout|ConvertFrom-Json -AsHashtable
            ($normalized.host.cgroupControllers -contains 'memory')|Should -Be $Memory
            ($normalized.host.cgroupControllers -contains 'cpu')|Should -Be $Cpu
            $normalized.host.security.rootless|Should -Be $Rootless
            $normalized.runtime.ServerVersion|Should -BeExactly recorded
            Should -Invoke Invoke-MutatorNative -Times 1 -Exactly -ParameterFilter {$Arguments -contains '{{json .}}' -and $Arguments -contains '--context'}
        }
        It 'converts Docker JSON lines into a complete array without inventing rows: <Rows>' -ForEach @(@{Rows=0},@{Rows=1},@{Rows=2}) {
            Set-MutatorContainerContext Docker $null
            $script:DockerRows=$Rows
            Mock Invoke-MutatorNative {@{Outcome='Success';ExitCode=0;Stdout=$(@(for($i=0;$i -lt $script:DockerRows;$i++){ @{Id=$i}|ConvertTo-Json -Compress}) -join "`n");Stderr=''}}
            $r=Invoke-MutatorContainerCommand @('ps','--format','json') $TestDrive
            @($r.Stdout|ConvertFrom-Json -AsHashtable).Count|Should -Be $Rows
            $r.Stdout.StartsWith('[')|Should -BeTrue
        }
        It 'retains a failed Docker command without parsing or replacing its diagnostic output' {
            Set-MutatorContainerContext Docker $null
            Mock Invoke-MutatorNative {@{Outcome='Failed';ExitCode=7;Stdout='not json';Stderr='retained cause'}}
            $r=Invoke-MutatorContainerCommand @('info','--format','json') $TestDrive
            $r.ExitCode|Should -Be 7;$r.Stdout|Should -BeExactly 'not json';$r.Stderr|Should -BeExactly 'retained cause'
        }
        It 'delegates Docker builds to the bounded BuildKit adapter' {
            Set-MutatorContainerContext Docker context
            Mock Invoke-MutatorDockerBuild {@{Outcome='Success';BackendProof='retained'}}
            $r=Invoke-MutatorContainerCommand @('build','--file','Dockerfile','.') $TestDrive 42
            $r.BackendProof|Should -BeExactly retained
            Should -Invoke Invoke-MutatorDockerBuild -Times 1 -Exactly -ParameterFilter {$Connection -ceq 'context' -and $TimeoutSeconds -eq 42}
        }
        It 'never probes Podman connections when Docker is selected' {
            Set-MutatorContainerContext Docker context
            Mock Invoke-MutatorContainerCommand {@{Outcome='Success';Stdout='{"host":{"cgroupControllers":[],"security":{"rootless":false}}}'}}
            Get-MutatorRootlessSiblingConnection $TestDrive context|Should -BeNullOrEmpty
            $r=Resolve-MutatorContainerConnection $TestDrive
            $r.Engine|Should -BeExactly Docker
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'system'}
        }
    }
}
Describe 'Configured engine defaults and call overrides' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            Set-MutatorContainerContext Podman $null
            $script:MutatorContainerContextSelected=$false
            $script:MutatorPreferredContainerEngine=$null;$script:MutatorPreferredContainerConnection=$null
            $script:ConfiguredDefaultEngine='Docker'
            Mock Get-MutatorEngineSetting {
                param($Engine,[switch]$Default)
                $name=if($Default){$script:ConfiguredDefaultEngine}else{$Engine}
                @{Name=$name;Enabled=$true;Default=($name -eq $script:ConfiguredDefaultEngine);Pipe=('unix:///run/'+$name.ToLowerInvariant()+'.sock');ConfigurationPath='fixture/config.yaml'}
            }
        }
        AfterEach {
            Set-MutatorContainerContext Podman $null
            $script:MutatorContainerContextSelected=$false
            $script:MutatorPreferredContainerEngine=$null;$script:MutatorPreferredContainerConnection=$null
        }
        It 'reads the configured default without selecting the initial hardcoded context: <Default>' -ForEach @(@{Default='Docker'},@{Default='Podman'}) {
            $script:ConfiguredDefaultEngine=$Default
            Resolve-MutatorEngineSelection|Should -BeExactly $Default
            Should -Invoke Get-MutatorEngineSetting -Times 1 -Exactly -ParameterFilter {$Default}
            $script:MutatorContainerContextSelected|Should -BeFalse
        }
        It 'lets an explicit engine override configuration and session preferences without changing the saved default' {
            $null=Set-MutatorContainerEngine -Engine Podman -Connection session-root
            Resolve-MutatorEngineSelection|Should -BeExactly Podman
            Resolve-MutatorEngineSelection docker|Should -BeExactly Docker
            $script:ConfiguredDefaultEngine|Should -BeExactly Docker
            $script:MutatorPreferredContainerConnection|Should -BeExactly session-root
            $null=Set-MutatorContainerEngine -Engine Docker -Connection ignored -WhatIf
            Resolve-MutatorEngineSelection|Should -BeExactly Podman
            Should -Invoke Get-MutatorEngineSetting -Times 0
        }
        It 'keeps nested builds on their frozen run engine while new runs follow configuration' {
            $script:ConfiguredDefaultEngine='Podman'
            Restore-MutatorContainerContext @{ContainerEngine='Docker';ContainerConnection='frozen-context';ContainerSetting=@{Name='Docker';Enabled=$true;Default=$false;Pipe='tcp://frozen:2376';ConfigurationPath='frozen.yaml'}}
            Resolve-MutatorEngineSelection -UseContext|Should -BeExactly Docker
            Resolve-MutatorEngineSelection|Should -BeExactly Podman
            Resolve-MutatorEngineSelection Podman -UseContext|Should -BeExactly Podman
            $script:MutatorContainerSetting.Pipe|Should -BeExactly 'tcp://frozen:2376'
            $script:MutatorContainerConnection|Should -BeExactly frozen-context
        }
        It 'exposes Engine as an alias on the mutation, validation and image entry points' {
            foreach($name in @('Invoke-MutatorRun','Invoke-MutatorValidation','New-MutatorContainerImage','New-MutatorToolImage')){
                (Get-Command $name).Parameters.ContainerEngine.Aliases|Should -Contain Engine
            }
        }
        It 'requires Podman for a Linux campaign independently of the configured build engine: <Mode>' -ForEach @(
            @{Mode='Configured';Expected='Podman'},@{Mode='Explicit';Expected='Podman'},@{Mode='Session';Expected='Podman'},@{Mode='OverrideSession';Expected='Podman'}
        ) {
            $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$module=Join-Path $root 'Fixture'
            Write-MutatorJson (Join-Path $module 'test/psmutant.config.json') @{coveredLinesOnly=$false;sandboxSubtrees=@('Fixture');mutate=@('Fixture/Value.ps1');tests=@{'Fixture/Value.ps1'=@('Fixture/test/Value.Tests.ps1')}}
            Mock Invoke-MutatorRunCore {}
            Mock Start-MutatorWorker {throw 'No real worker may be launched by a selection contract.'}
            Mock Get-MutatorMemoryWatchdog {$null}
            if($Mode -in @('Session','OverrideSession')){$null=Set-MutatorContainerEngine Podman -Connection session-root}
            $options=@{}
            if($Mode -eq 'Explicit'){$options.Engine='Podman'}
            if($Mode -eq 'OverrideSession'){$options.Engine='Docker'}
            if($Mode -eq 'OverrideSession'){
                {Invoke-MutatorRun -Path $module -OS Linux -SourceRoot $root -RunRoot (Join-Path $root 'runs') @options}|Should -Throw '*require Podman*'
                Should -Invoke Invoke-MutatorRunCore -Times 0
                return
            }
            $r=Invoke-MutatorRun -Path $module -OS Linux -SourceRoot $root -RunRoot (Join-Path $root 'runs') @options
            $stored=Read-MutatorJson (Join-Path $r.Path 'run.json')
            $stored.ContainerEngine|Should -BeExactly $Expected
            $stored.ContainerSetting.Name|Should -BeExactly $Expected
            $stored.ContainerSetting.Pipe|Should -BeExactly ('unix:///run/'+$Expected.ToLowerInvariant()+'.sock')
            if($Mode -eq 'Session'){$stored.ContainerConnection|Should -BeExactly session-root}else{$stored.ContainerConnection|Should -BeNullOrEmpty}
            Should -Invoke Invoke-MutatorRunCore -Times 1 -Exactly
            Should -Invoke Start-MutatorWorker -Times 0
        }
    }
}
