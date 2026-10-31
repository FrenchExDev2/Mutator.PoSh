BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Independent engine endpoints and configuration isolation' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            Set-MutatorContainerContext Podman $null
            $script:EndpointSetting=@{Name='Podman';Enabled=$true;Pipe=$null;ConfigurationPath='fixture/config.yaml'}
            Mock Get-MutatorEngineSetting {$script:EndpointSetting}
        }
        AfterEach {Set-MutatorContainerContext Podman $null}
        It 'normalizes only named pipes and preserves other endpoints: <Endpoint>' -ForEach @(
            @{Endpoint='\\.\pipe\docker_engine';Expected='npipe:////./pipe/docker_engine'},
            @{Endpoint='npipe:////./pipe/docker_engine';Expected='npipe:////./pipe/docker_engine'},
            @{Endpoint='tcp://docker.example:2376';Expected='tcp://docker.example:2376'},
            @{Endpoint='unix:///run/docker.sock';Expected='unix:///run/docker.sock'}
        ) {ConvertTo-MutatorDockerHost $Endpoint|Should -BeExactly $Expected}
        It 'uses independent pipes without changing either global CLI context' {
            $script:EndpointSetting.Pipe='\\.\pipe\docker_engine'
            @(Get-MutatorContainerPrefix Docker $null $TestDrive)|Should -Be @('--host','npipe:////./pipe/docker_engine')
            $script:EndpointSetting.Pipe='unix:///run/podman/podman.sock'
            @(Get-MutatorContainerPrefix Podman $null $TestDrive)|Should -Be @('--url','unix:///run/podman/podman.sock')
            @(Get-MutatorContainerPrefix Docker 'explicit-context' $TestDrive)|Should -Be @('--context','explicit-context')
            @(Get-MutatorContainerPrefix Podman 'explicit-machine' $TestDrive)|Should -Be @('--connection','explicit-machine')
            @(Get-MutatorContainerPrefix Docker $null $TestDrive -DefaultConnection).Count|Should -Be 0
            $script:EndpointSetting.Pipe=$null
            @(Get-MutatorContainerPrefix Podman $null $TestDrive).Count|Should -Be 0
        }
        It 'refuses a disabled engine before native execution even with an explicit context or default switch: <Default>' -ForEach @(@{Default=$false},@{Default=$true}) {
            $script:EndpointSetting.Enabled=$false
            Mock Invoke-MutatorNative {throw 'A disabled engine must never launch.'}
            {Invoke-MutatorContainerCommand @('info') $TestDrive -Connection explicit -DefaultConnection:$Default}|Should -Throw '*Podman engine is disabled*fixture/config.yaml*'
            Should -Invoke Invoke-MutatorNative -Times 0
        }
        It 'preserves direct native Podman transports: <Endpoint>' -ForEach @(
            @{Endpoint='ssh://user@host:2222/run/podman.sock'},@{Endpoint='tcp://host:8080'},@{Endpoint='unix:///run/podman.sock'}
        ) {
            Mock Invoke-MutatorNative {throw 'Direct transports do not require machine discovery.'}
            $r=Resolve-MutatorPodmanEndpoint $Endpoint $TestDrive
            $r.Arguments|Should -Be @('--url',$Endpoint);$r.Endpoint|Should -BeExactly $Endpoint
            Should -Invoke Invoke-MutatorNative -Times 0
        }
        It 'rejects an unsupported native Podman transport' {
            {Resolve-MutatorPodmanEndpoint 'https://unrelated' $TestDrive}|Should -Throw '*SSH, TCP or Unix endpoint*'
        }
        It 'discovers sibling storage on the configured machine instead of the CLI default machine' {
            $script:EndpointSetting.Pipe='\\.\pipe\chosen-machine'
            Mock Resolve-MutatorPodmanEndpoint {@{Connection='chosen-machine-root';Arguments=@('--url','ssh://root@chosen')}}
            Mock Invoke-MutatorContainerCommand {@{Outcome='Success';Stdout='[{"Name":"unrelated-root","Default":true},{"Name":"unrelated"},{"Name":"chosen-machine-root"},{"Name":"chosen-machine"}]'}}
            Get-MutatorRootlessSiblingConnection $TestDrive|Should -BeExactly chosen-machine
            Should -Invoke Resolve-MutatorPodmanEndpoint -Times 1 -Exactly -ParameterFilter {$Endpoint -ceq '\\.\pipe\chosen-machine'}
        }
        It 'does not discover unrelated machine storage for a direct remote socket' {
            $script:EndpointSetting.Pipe='unix:///run/podman.sock'
            Mock Invoke-MutatorContainerCommand {throw 'No managed machine is identified by a direct remote socket.'}
            Get-MutatorRootlessSiblingConnection $TestDrive|Should -BeNullOrEmpty
            Should -Invoke Invoke-MutatorContainerCommand -Times 0
        }
        It 'does not substitute the CLI default rootful machine when a configured endpoint lacks memory controls' {
            $script:EndpointSetting.Pipe='tcp://configured:8080'
            Mock Invoke-MutatorContainerCommand {@{Outcome='Success';Stdout='{"host":{"cgroupControllers":[],"security":{"rootless":true}}}'}}
            $r=Resolve-MutatorContainerConnection $TestDrive
            $r.Controllers.Count|Should -Be 0;$r.Rootless|Should -BeTrue
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'system'}
        }
        It 'freezes run settings independently and restores legacy runs without inheriting a previous endpoint' {
            $setting=@{Name='Docker';Enabled=$true;Pipe='tcp://first:2376';ConfigurationPath='one.yaml'}
            Set-MutatorContainerContext Docker $null -Setting $setting
            $setting.Pipe='tcp://changed:2376'
            @(Get-MutatorContainerPrefix Docker $null $TestDrive)|Should -Be @('--host','tcp://first:2376')
            Should -Invoke Get-MutatorEngineSetting -Times 0
            Restore-MutatorContainerContext @{ContainerEngine='Podman';ContainerConnection='second-root';ContainerSetting=@{Name='Podman';Enabled=$true;Pipe='unix:///second';ConfigurationPath='two.yaml'}}
            $script:MutatorContainerSetting.Pipe|Should -BeExactly 'unix:///second'
            @(Get-MutatorContainerPrefix Podman $script:MutatorContainerConnection $TestDrive)|Should -Be @('--connection','second-root')
            Restore-MutatorContainerContext @{Connection='legacy'}
            $script:MutatorContainerSetting|Should -BeNullOrEmpty
            $script:MutatorContainerConnection|Should -BeExactly legacy
        }
    }
}
Describe 'Podman named pipe mapping' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            Set-MutatorContainerContext Podman $null
            $script:PipeFault='';$script:PipeRootful=$true
            Mock Invoke-MutatorNative {
                param($Command,$Arguments)
                if($Command -cne 'podman'){throw 'Unexpected engine.'}
                $operation=$Arguments[0]+' '+$Arguments[1]
                $data=switch($operation){
                    'machine list' {if($script:PipeFault -eq 'empty'){@()}else{@(@{Name='other'},@{Name='machine'})}}
                    'machine inspect' {
                        $machine=@{Name='machine';Rootful=$script:PipeRootful;ConnectionInfo=@{PodmanPipe=@{Path='\\.\pipe\machine'}}}
                        if($script:PipeFault -eq 'mismatch'){$machine.ConnectionInfo.PodmanPipe.Path='\\.\pipe\other'}
                        if($script:PipeFault -eq 'ambiguous'){@($machine,$machine)}else{@($machine)}
                    }
                    'system connection' {
                        if($script:PipeFault -eq 'missing'){@()}else{
                            @(@{Name='machine';URI='ssh://user@localhost:2222/run/user/1000/podman.sock';Identity='fixture identity'},
                              @{Name='machine-root';URI='ssh://root@localhost:2222/run/podman.sock';Identity=$(if($script:PipeFault -eq 'identity'){$null}else{'fixture identity'})})
                        }
                    }
                    default {throw ('Unexpected native operation: '+$operation)}
                }
                @{Outcome=$(if($script:PipeFault -eq $operation){'Failed'}else{'Success'});Stdout=(ConvertTo-Json -InputObject @($data) -Depth 8 -Compress)}
            }
        }
        AfterEach {Set-MutatorContainerContext Podman $null}
        It 'maps the selected pipe to the correct native socket and identity and caches discovery: <Rootful>' -ForEach @(@{Rootful=$true},@{Rootful=$false}) {
            $script:PipeRootful=$Rootful
            $r=Resolve-MutatorPodmanEndpoint '\\.\pipe\machine' $TestDrive
            $r.Connection|Should -BeExactly $(if($Rootful){'machine-root'}else{'machine'})
            $r.Arguments[0]|Should -BeExactly '--url';$r.Arguments[1]|Should -Match $(if($Rootful){'^ssh://root@'}else{'^ssh://user@'})
            $r.Arguments[2..3]|Should -Be @('--identity','fixture identity')
            $cached=Resolve-MutatorPodmanEndpoint 'npipe:////./pipe/machine' $TestDrive
            $cached.Connection|Should -BeExactly $r.Connection
            Should -Invoke Invoke-MutatorNative -Times 3 -Exactly
            Should -Invoke Invoke-MutatorNative -Times 1 -Exactly -ParameterFilter {$Arguments[0] -ceq 'machine' -and $Arguments[1] -ceq 'inspect' -and $Arguments.Count -eq 4 -and $Arguments[2] -ceq 'other' -and $Arguments[3] -ceq 'machine'}
            Set-MutatorContainerContext Podman $null
            $null=Resolve-MutatorPodmanEndpoint '\\.\pipe\machine' $TestDrive
            Should -Invoke Invoke-MutatorNative -Times 6 -Exactly
        }
        It 'fails closed when a pipe cannot be resolved: <Fault>' -ForEach @(
            @{Fault='machine list';Expected='*could not be listed*'},@{Fault='empty';Expected='*No Podman machine*'},
            @{Fault='machine inspect';Expected='*could not be inspected*'},@{Fault='mismatch';Expected='*exactly one*'},
            @{Fault='ambiguous';Expected='*exactly one*'},@{Fault='system connection';Expected='*could not be read*'},
            @{Fault='missing';Expected='*unambiguous native connection*'},@{Fault='identity';Expected='*unambiguous native connection*'}
        ) {
            $script:PipeFault=$Fault
            {Resolve-MutatorPodmanEndpoint '\\.\pipe\machine' $TestDrive}|Should -Throw $Expected
            $script:MutatorPipeConnectionCache.Count|Should -Be 0
        }
    }
}
Describe 'Mutator configuration reader' {
    It 'reads container settings from Mutator without relying on OPumper2 configuration' {
        $config=Join-Path $TestDrive 'config.yaml'
        [IO.File]::WriteAllText($config,"docker: {enabled: false, pipe: 'tcp://docker:2376'}`npodman: {enabled: true, default: true, pipe: 'unix:///run/podman.sock'}`n")
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Config=$config} {
            param($Config)
            $script:ReaderFixturePath=$Config
            Mock Get-MutatorEngineConfigurationPath {$script:ReaderFixturePath}
            $docker=Get-MutatorEngineSetting Docker
            $podman=Get-MutatorEngineSetting Podman
            $docker.Enabled|Should -BeFalse;$docker.Pipe|Should -BeExactly 'tcp://docker:2376'
            $podman.Enabled|Should -BeTrue;$podman.Pipe|Should -BeExactly 'unix:///run/podman.sock'
            $podman.Default|Should -BeTrue
            (Get-MutatorEngineSetting -Default).Name|Should -BeExactly Podman
            $docker.ConfigurationPath|Should -BeExactly $Config
            $podman.ConfigurationPath|Should -BeExactly $Config
        }
    }
}