BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    . (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'test/Fixtures/ContainerWorkspace.ps1')
    $workspace=New-MutatorContainerWorkspace -Path (Join-Path $TestDrive 'host-workspace')
    & (Get-Module FrenchExDev.Mutator.PoSh) {param($Path);$script:HostTestWorkspace=$Path} $workspace
}
Describe 'PowerShell Core in every container host' {
    It 'installs and executes Core in Windows and macOS VM base recipes without changing the guest disk identity' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $modules=$script:HostTestWorkspace
            $runtime=Get-MutatorContainerRuntime $modules
            $runtime.ControllerFingerprint|Should -Match '^[a-f0-9]{64}$'
            foreach($variant in @('windows','windows-bootstrap','macos','macos-bootstrap')){
                $text=[IO.File]::ReadAllText((Join-Path $modules ('FrenchExDev.Mutator.PoSh/resources/containers/base/'+$variant+'/Dockerfile')))
                $text|Should -Match 'FROM \$\{POWERSHELL_IMAGE\} AS mutator-pwsh'
                $text|Should -Match 'COPY --from=mutator-pwsh /opt/microsoft/powershell/7/'
                $text|Should -Match 'RUN \["pwsh".*Required PowerShell Core version is unavailable'
                $text|Should -Not -Match '__PWSH_VERSION__|__CONTROLLER_FINGERPRINT__'
            }
            $runtime.Images.Windows|Should -Match '-controller-'
        }
    }
    It 'requires Core at build time for every generated Windows module layer' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $modules=@(Get-ChildItem $script:HostTestWorkspace -Directory -Filter 'FrenchExDev.*.PoSh'|Where-Object {Test-Path (Join-Path $_.FullName ($_.Name+'.psd1'))})
            $modules.Count|Should -Be 130
            foreach($module in $modules){
                $text=[IO.File]::ReadAllText((Join-Path $module.FullName 'containers/windows/Dockerfile'))
                $metadata=Read-MutatorJson (Join-Path $module.FullName 'containers/image.json')
                if($module.Name -ceq 'FrenchExDev.Tools.Git.PoSh' -and $metadata.SchemaVersion -eq 2){
                    $bootstrap=Join-Path (Split-Path $script:MutatorRoot) 'FrenchExDev.CliEnvironment.PoSh/resources/containers/windows/Install-Base.ps1'
                    $installer=[IO.File]::ReadAllText($bootstrap)
                    $installer|Should -Match 'pwsh\.exe'
                    $installer|Should -Match 'The installed PowerShell runtime differs'
                    [version]$metadata.Runtime.Version|Should -BeGreaterOrEqual ([version]'7.6')
                    $text|Should -Match 'Git is installed once per isolated clone in Windows'
                }else{$text|Should -Match 'RUN \["pwsh".*PowerShell Core 7.6\+ is required in the container host'}
            }
        }
    }
    It 'changes the controller fingerprint without invalidating the guest disk when only the host template changes' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $modules=$script:HostTestWorkspace
            $before=Get-MutatorContainerRuntime $modules
            $owned=Join-Path $TestDrive 'controller-template'
            Copy-MutatorTree (Join-Path $script:MutatorRoot 'resources/containers/definitions') (Join-Path $owned 'resources/containers/definitions')
            [void][IO.Directory]::CreateDirectory((Join-Path $owned 'src/Private'))
            Copy-Item (Join-Path $script:MutatorRoot 'src/Private/Add-MutatorHostPowerShell.ps1') (Join-Path $owned 'src/Private/Add-MutatorHostPowerShell.ps1')
            Add-Content (Join-Path $owned 'resources/containers/definitions/Dockerfile.host-powershell.template') '# controller-only fixture change'
            $saved=$script:MutatorRoot
            try{$script:MutatorRoot=$owned;$after=Get-MutatorContainerRuntime $modules}finally{$script:MutatorRoot=$saved}
            $after.Fingerprint|Should -BeExactly $before.Fingerprint
            $after.MacFingerprint|Should -BeExactly $before.MacFingerprint
            $after.ControllerFingerprint|Should -Not -Be $before.ControllerFingerprint
        }
    }
}
