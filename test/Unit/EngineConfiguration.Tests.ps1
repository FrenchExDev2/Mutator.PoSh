<#
.SYNOPSIS
Expected behavior for the EngineConfiguration tests.

.DESCRIPTION
Engine YAML must preserve typed canonical settings and reject malformed, duplicate or unknown data.
Persistence/migration must honor WhatIf, atomic replacement and unrelated source settings.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Mutator owns persistent container configuration' {
    BeforeEach {$script:EngineConfig=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'/config.yaml')}
    It 'uses its own home path and environment override without consulting QuietCli settings' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $previous=$env:MUTATOR_CONFIG_PATH
            try{
                $env:MUTATOR_CONFIG_PATH=$null
                Get-MutatorEngineConfigurationPath|Should -BeExactly (Join-Path $HOME '.mutator/config.yaml')
                $env:MUTATOR_CONFIG_PATH='custom/mutator.yaml'
                Get-MutatorEngineConfigurationPath|Should -BeExactly 'custom/mutator.yaml'
            }finally{$env:MUTATOR_CONFIG_PATH=$previous}
        }
    }
    It 'keeps container configuration and command-line engine selection out of the QuietCli runtime' {
        $path=Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot))) 'QuietCliEcosystem/FrenchExDev.QuietCli.PoSh/FrenchExDev.QuietCli.PoSh.psd1'
        $core=Import-Module $path -DisableNameChecking -PassThru
        @($core.ExportedFunctions.Keys|Where-Object {$_ -match 'Engine'}).Count|Should -Be 0
        $core.ExportedFunctions['Invoke-QuietCli'].Parameters.ContainsKey('Engine')|Should -BeFalse
        (Get-Command Set-MutatorEngine).ModuleName|Should -BeExactly FrenchExDev.Mutator.PoSh
        (Get-Command Get-MutatorEngine).ModuleName|Should -BeExactly FrenchExDev.Mutator.PoSh
    }
    It 'writes both engines independently and reads the same default file when Path is omitted' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Config=$script:EngineConfig} {
            param($Config)
            $script:EnginePathFixture=$Config;Mock Get-MutatorEngineConfigurationPath {$script:EnginePathFixture}
            $r=@(Set-MutatorEngine -Docker '\\.\pipe\docker_engine' -DockerEnabled:$true -Podman '\\.\pipe\machine' -PodmanEnabled:$true -DefaultEngine Podman)
            $r.Count|Should -Be 2
            (Get-MutatorEngine -Default).Name|Should -BeExactly Podman
            (Get-MutatorEngine -Name Docker).Pipe|Should -BeExactly '\\.\pipe\docker_engine'
            (Get-MutatorEngine -Name Podman).Pipe|Should -BeExactly '\\.\pipe\machine'
            @($r.ConfigurationPath|Sort-Object -Unique)|Should -Be @($Config)
        }
    }
    It 'switches the default atomically while preserving the other endpoint and enabled state' {
        $null=Set-MutatorEngine -Path $script:EngineConfig -Docker 'tcp://docker:2376' -Podman 'unix:///run/podman.sock' -DefaultEngine Podman
        $null=Set-MutatorEngine -Path $script:EngineConfig -DefaultEngine Docker
        $r=@(Get-MutatorEngine -Path $script:EngineConfig)
        @($r|Where-Object Default).Count|Should -Be 1
        ($r|Where-Object Default).Name|Should -BeExactly Docker
        ($r|Where-Object Name -EQ Podman).Pipe|Should -BeExactly 'unix:///run/podman.sock'
        {Set-MutatorEngine -Path $script:EngineConfig -DockerEnabled:$false}|Should -Throw '*default container engine must be enabled*'
        $null=Set-MutatorEngine -Path $script:EngineConfig -DefaultEngine Podman -DockerEnabled:$false
        (Get-MutatorEngine -Path $script:EngineConfig -Name Docker).Enabled|Should -BeFalse
        (Get-MutatorEngine -Path $script:EngineConfig -Name Docker).Pipe|Should -BeExactly 'tcp://docker:2376'
        $null=Set-MutatorEngine -Path $script:EngineConfig -Docker ''
        (Get-MutatorEngine -Path $script:EngineConfig -Name Docker).Pipe|Should -BeNullOrEmpty
    }
    It 'does not create configuration under WhatIf and reports defaults without a file' {
        $null=Set-MutatorEngine -Path $script:EngineConfig -DockerEnabled:$true -WhatIf
        Test-Path $script:EngineConfig|Should -BeFalse
        (Get-MutatorEngine -Path $script:EngineConfig -Default).Name|Should -BeExactly Podman
        $null=Set-MutatorEngine -Path $script:EngineConfig -PodmanEnabled:$false
        (Get-MutatorEngine -Path $script:EngineConfig -Default).Name|Should -BeExactly Docker
        $null=Set-MutatorEngine -Path $script:EngineConfig -DockerEnabled:$false
        {Get-MutatorEngine -Path $script:EngineConfig -Default}|Should -Throw '*No container engine is enabled*'
        @((Get-Command Set-MutatorEngine).Parameters.Values.Aliases)|Should -Not -Contain DockerEnaled
    }
    It 'rejects invalid configuration without changing it: <Content>' -ForEach @(
        @{Content='docker: []';Expected='*mapping*'},@{Content='docker: {enabled: "false"}';Expected='*true or false*'},
        @{Content='podman: {pipe: 42}';Expected='*endpoint string*'},@{Content='podman: {pipe: " "}';Expected='*endpoint string*'},
        @{Content='docker: {unknown: true}';Expected='*Unknown docker setting*'},@{Content='[1,2]';Expected='*mapping of sections*'},
        @{Content='docker: {default: true}; podman: {default: true}';Expected='*Only one container engine*'},
        @{Content='docker: {default: true, enabled: false}';Expected='*default container engine must be enabled*'},
        @{Content='podman: {default: "true"}';Expected='*podman.default must be true or false*'},
        @{Content='general: {}';Expected='*Unknown Mutator configuration section*'}
    ) {
        [void][IO.Directory]::CreateDirectory((Split-Path $script:EngineConfig))
        $yaml=$Content.Replace('; ',"`n");[IO.File]::WriteAllText($script:EngineConfig,$yaml)
        {Get-MutatorEngine -Path $script:EngineConfig}|Should -Throw $Expected
        {Set-MutatorEngine -Path $script:EngineConfig -PodmanEnabled:$true}|Should -Throw $Expected
        [IO.File]::ReadAllText($script:EngineConfig)|Should -BeExactly $yaml
    }
}
Describe 'Explicit transfer of misplaced container configuration' {
    BeforeEach {
        $script:SourceConfig=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'/opumper2.yaml')
        $script:TargetConfig=Join-Path (Split-Path $script:SourceConfig) 'mutator/config.yaml'
        [void][IO.Directory]::CreateDirectory((Split-Path $script:SourceConfig))
        [IO.File]::WriteAllText($script:SourceConfig,"general: {MaxItems: 7}`npumps: [{name: git, module: Pester, enabled: false, priority: 9}]`ndocker: {pipe: 'tcp://docker:2376', enabled: true}`npodman: {pipe: 'unix:///run/podman.sock', enabled: true, default: true}`n")
    }
    It 'moves only container sections and keeps the entire original as a backup' {
        $original=[IO.File]::ReadAllText($script:SourceConfig)
        $r=Move-MutatorEngineConfiguration -From $script:SourceConfig -Path $script:TargetConfig
        $r.Outcome|Should -BeExactly Moved
        [IO.File]::ReadAllText($r.SourceBackup)|Should -BeExactly $original
        (Get-MutatorEngine -Path $script:TargetConfig -Default).Name|Should -BeExactly Podman
        (Get-MutatorEngine -Path $script:TargetConfig -Name Docker).Pipe|Should -BeExactly 'tcp://docker:2376'
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Source=$script:SourceConfig} {
            param($Source)
            $kept=Read-MutatorYamlDocument $Source
            $kept.general.MaxItems|Should -Be 7
            $kept.pumps[0].priority|Should -Be 9;$kept.pumps[0].enabled|Should -BeFalse
            $kept.Contains('docker')|Should -BeFalse;$kept.Contains('podman')|Should -BeFalse
        }
        (Move-MutatorEngineConfiguration -From $script:SourceConfig -Path $script:TargetConfig).Outcome|Should -BeExactly Unchanged
    }
    It 'does not touch either file under WhatIf' {
        $original=[IO.File]::ReadAllText($script:SourceConfig)
        $null=Move-MutatorEngineConfiguration -From $script:SourceConfig -Path $script:TargetConfig -WhatIf
        [IO.File]::ReadAllText($script:SourceConfig)|Should -BeExactly $original
        Test-Path $script:TargetConfig|Should -BeFalse
    }
    It 'refuses conflicting destination values before either file is modified' {
        $null=Set-MutatorEngine -Path $script:TargetConfig -Docker 'tcp://different:2376'
        $source=[IO.File]::ReadAllText($script:SourceConfig);$target=[IO.File]::ReadAllText($script:TargetConfig)
        {Move-MutatorEngineConfiguration -From $script:SourceConfig -Path $script:TargetConfig}|Should -Throw '*already has different docker settings*'
        [IO.File]::ReadAllText($script:SourceConfig)|Should -BeExactly $source
        [IO.File]::ReadAllText($script:TargetConfig)|Should -BeExactly $target
    }
    It 'accepts an identical existing destination and rejects moving onto itself' {
        $null=Set-MutatorEngine -Path $script:TargetConfig -Docker 'tcp://docker:2376' -Podman 'unix:///run/podman.sock' -DefaultEngine Podman
        (Move-MutatorEngineConfiguration -From $script:SourceConfig -Path $script:TargetConfig).Outcome|Should -BeExactly Moved
        {Move-MutatorEngineConfiguration -From $script:SourceConfig -Path $script:SourceConfig}|Should -Throw '*must differ*'
    }
    It 'refuses a scalar source without creating a destination' {
        [IO.File]::WriteAllText($script:SourceConfig,'[1,2]')
        {Move-MutatorEngineConfiguration -From $script:SourceConfig -Path $script:TargetConfig}|Should -Throw '*source configuration must be a mapping*'
        Test-Path $script:TargetConfig|Should -BeFalse
    }
}
