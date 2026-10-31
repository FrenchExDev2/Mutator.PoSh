<#
.SYNOPSIS
Expected behavior for the ContainerDefinitions tests.

.DESCRIPTION
Contributor metadata must produce complete platform definitions with existing COPY inputs. Preserve
recipe ownership, canonical platform names, explicit incompatibility and manual edits unless
regeneration is authorized.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:ContainerModuleRoot=Split-Path (Split-Path $PSScriptRoot)
    $script:WorkspaceModules=Split-Path $script:ContainerModuleRoot
    Import-Module (Join-Path $script:ContainerModuleRoot 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    . (Join-Path $script:ContainerModuleRoot 'test/Fixtures/ContainerWorkspace.ps1')
    $script:WorkspaceModules=New-MutatorContainerWorkspace -Path (Join-Path $TestDrive 'definitions-workspace')
    $script:ContainerRuntime=Get-Content (Join-Path $script:WorkspaceModules 'FrenchExDev.Mutator.PoSh/resources/containers/base/runtime.json') -Raw|ConvertFrom-Json -AsHashtable
    $script:BootstrapFingerprint=(Get-MutatorSourceSnapshot (Join-Path $script:ContainerModuleRoot 'resources/containers/definitions/bootstrap')).Sha256
}
Describe 'Per-module Linux, Windows and macOS Dockerfiles' {
    It 'covers every active module with complete <Platform> metadata and existing COPY sources' -ForEach @(
        @{Platform='Linux';Directory='linux'}
        @{Platform='Windows';Directory='windows'}
        @{Platform='MacOS';Directory='macos'}
    ) {
        $modules=@(Get-ChildItem $script:WorkspaceModules -Directory -Filter 'FrenchExDev.*.PoSh'|Where-Object{Test-Path (Join-Path $_.FullName ($_.Name+'.psd1'))})
        $modules.Count | Should -BeGreaterThan 0
        foreach($module in $modules){
            $metadata=Get-Content (Join-Path $module.FullName 'containers/image.json') -Raw|ConvertFrom-Json -AsHashtable
            $metadata.Module | Should -BeExactly $module.Name
            $sharedGit=$metadata.SchemaVersion -eq 2 -and $module.Name -ceq 'FrenchExDev.Tools.Git.PoSh'
            if($sharedGit){
                $runtime=Get-Content (Join-Path $script:WorkspaceModules 'FrenchExDev.CliEnvironment.PoSh/containers/base/runtime.json') -Raw|ConvertFrom-Json -AsHashtable
                $metadata.BaseFingerprint|Should -BeExactly $runtime.Fingerprint
                $metadata.Fingerprint|Should -BeExactly $runtime.Fingerprint
                $metadata.Qualified|Should -BeFalse
                $metadata.Git.Version|Should -Match '^\d+\.\d+\.\d+$'
            }else{
                $metadata.BaseFingerprint | Should -BeExactly $script:ContainerRuntime.Fingerprint
                $metadata.MacBaseFingerprint | Should -BeExactly $script:ContainerRuntime.MacFingerprint
                $metadata.BootstrapSha256 | Should -BeExactly $script:BootstrapFingerprint
            }
            $metadata['Platforms'] | Should -BeOfType ([Collections.IDictionary]) -Because $module.Name
            $metadata.Platforms.Contains($Platform) | Should -BeTrue -Because ($module.Name+' requires the canonical '+$Platform+' key')
            $toolProfile=$metadata.Platforms[$Platform]
            $toolProfile | Should -BeOfType ([Collections.IDictionary]) -Because ($module.Name+' / '+$Platform)
            if($sharedGit -and $Platform -in @('Linux','Windows')){
                $toolProfile.Status|Should -BeExactly Prepared
                $toolProfile.Binary|Should -BeExactly git
                if($Platform -ceq 'Linux'){$toolProfile.Method|Should -BeExactly SourceGit;$toolProfile.Version|Should -BeExactly $metadata.Git.Version}
                else{$toolProfile.Method|Should -BeExactly OfficialInstaller;$toolProfile.Version|Should -BeExactly $metadata.Git.Windows.Tag}
            }else{
                $toolProfile.Contains('BuildValidated') | Should -BeTrue
                $toolProfile.BuildValidated | Should -BeOfType ([bool])
                $toolProfile.BuildValidated | Should -BeFalse
            }
            $toolProfile.Contains('Method') | Should -BeTrue
            $toolProfile.Method | Should -BeOfType ([string])
            $toolProfile.Method | Should -Not -BeNullOrEmpty
            $toolProfile.Method | Should -Not -Be Unconfigured
            $toolProfile.Status | Should -BeIn @('Prepared','NeedsArtifact','NeedsManualSetup','Unsupported')
            if($toolProfile.Status -eq 'Unsupported'){
                $toolProfile.Method | Should -BeExactly Unsupported
                $toolProfile.Reason | Should -Not -BeNullOrEmpty
            }
            if($toolProfile.Status -eq 'NeedsArtifact'){$toolProfile.Method | Should -BeExactly Artifact}
            if($toolProfile.Status -eq 'NeedsManualSetup'){$toolProfile.Method | Should -BeExactly Xcode}
            $path=Join-Path $module.FullName ('containers/'+$Directory+'/Dockerfile')
            $text=[IO.File]::ReadAllText($path)
            $text | Should -Not -Match '__[A-Z_]+__' -Because $path
            Test-Path ($path+'.dockerignore') | Should -BeTrue
            foreach($line in $text -split "`n"){
                if($line.StartsWith('COPY ') -and !$line.StartsWith('COPY --from=')){
                    $line | Should -Match '^COPY \[' -Because 'COPY must preserve source and destination as separate arguments'
                }
                if($line.StartsWith('COPY [')){
                    $copy=$line.Substring(5)|ConvertFrom-Json
                    @($copy).Count | Should -Be 2 -Because $line
                    Test-Path (Join-Path $script:WorkspaceModules $copy[0]) | Should -BeTrue -Because $line
                }
                elseif($line -match '^(RUN|ENTRYPOINT|CMD) \['){
                    $arguments=@($line.Substring($line.IndexOf('['))|ConvertFrom-Json)
                    $arguments.Count | Should -BeGreaterThan 0
                }
            }
        }
    }
    It 'keeps Alpine for Ag, uses glibc PowerShell for Debian and prepares dockurr guests by default' {
        $ag=[IO.File]::ReadAllText((Join-Path $script:WorkspaceModules 'FrenchExDev.Tools.Ag.PoSh/containers/linux/Dockerfile'))
        $ag | Should -Match ':alpine-pwsh-'
        $ag | Should -Not -Match 'Initialize-Image\.ps1|powershell/releases'
        $ag | Should -Match 'Initialize-ImageModules\.ps1'
        $alpineBase=[IO.File]::ReadAllText((Join-Path $script:WorkspaceModules 'FrenchExDev.Mutator.PoSh/resources/containers/base/alpine/Dockerfile'))
        $alpineBase | Should -Match 'alpine@sha256:'
        $alpineBase | Should -Match 'linux-musl-x64.tar.gz'
        foreach($name in @('Brew','Gt','Journalctl','Playwright','Quarto','Swift','Systemctl')){
            $root=Join-Path $script:WorkspaceModules ('FrenchExDev.Tools.'+$name+'.PoSh/containers')
            $metadata=Get-Content (Join-Path $root 'image.json') -Raw|ConvertFrom-Json -AsHashtable
            $metadata.Platforms.Linux.Distribution | Should -BeExactly Debian
            $text=[IO.File]::ReadAllText((Join-Path $root 'linux/Dockerfile'))
            $text | Should -Match ':(debian|swift)-pwsh-'
            $text | Should -Not -Match 'linux-musl|apk add'
        }
        $windows=[IO.File]::ReadAllText((Join-Path $script:WorkspaceModules 'FrenchExDev.Tools.Ag.PoSh/containers/windows/Dockerfile'))
        $windows | Should -Match ':windows-pwsh-'
        $windows | Should -Match '/shared/mutator/modules/'
        $windows | Should -Not -Match '(?m)^ENTRYPOINT|servercore'
        $metadata=Get-Content (Join-Path $script:WorkspaceModules 'FrenchExDev.Tools.Ag.PoSh/containers/image.json') -Raw|ConvertFrom-Json -AsHashtable
        $metadata.Platforms.Windows.Backend | Should -BeExactly Dockurr
        $metadata.Platforms.Windows.ContainerOS | Should -BeExactly Linux
        $metadata.Platforms.Windows.Installation | Should -BeExactly OnCloneBoot
        $metadata.Runtime.WindowsSHA256 | Should -Match '^[a-fA-F0-9]{64}$'
        $compose=[IO.File]::ReadAllText((Join-Path $script:WorkspaceModules 'FrenchExDev.Tools.Ag.PoSh/containers/windows/compose.yaml'))
        $compose | Should -Match 'name: frenchexdev-tools-ag'
        $compose | Should -Match '/dev/kvm'
        $mac=[IO.File]::ReadAllText((Join-Path $script:WorkspaceModules 'FrenchExDev.Tools.Ag.PoSh/containers/macos/Dockerfile'))
        $mac | Should -Match ':macos-pwsh-'
        $mac | Should -Match '/shared/mutator/modules/'
        $metadata.Platforms.MacOS.HardwareRequirement | Should -BeExactly 'Apple hardware'
        $xcode=Get-Content (Join-Path $script:WorkspaceModules 'FrenchExDev.Tools.Xcodebuild.PoSh/containers/image.json') -Raw|ConvertFrom-Json -AsHashtable
        $xcode.Platforms.MacOS.Status | Should -BeExactly NeedsManualSetup
    }
    It 'fails unsupported tool images explicitly before installing or claiming an executable' {
        $root=Join-Path $TestDrive 'unsupported';[void][IO.Directory]::CreateDirectory($root)
        @{Module='Fixture';Platforms=@{Windows=@{Method='Unsupported';Reason='Needs macOS'}}}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $root 'image.json')
        {& (Join-Path $script:ContainerModuleRoot 'resources/containers/definitions/bootstrap/Install-ImageTool.ps1') -Root $root -Platform Windows} | Should -Throw '*Needs macOS*'
        Test-Path (Join-Path $root 'installed-tool.json') | Should -BeFalse
    }
    It 'never overwrites the shared Git definitions through the legacy generator, even with Force' {
        $git=Join-Path $TestDrive 'FrenchExDev.QuietCli.Git.PoSh'
        [void][IO.Directory]::CreateDirectory((Join-Path $git 'containers'))
        $file=Join-Path $git 'containers/image.json';[IO.File]::WriteAllText($file,'shared Git definitions')
        {Export-MutatorContainerDefinition -ModulePath $git -Force}|Should -Throw '*owned by CliEnvironment*'
        [IO.File]::ReadAllText($file)|Should -BeExactly 'shared Git definitions'
    }
    It 'selects canonical <Canonical> metadata for platform argument <InputPlatform>' -ForEach @(
        @{InputPlatform='Linux';Canonical='Linux'}
        @{InputPlatform='linux';Canonical='Linux'}
        @{InputPlatform='lInUx';Canonical='Linux'}
        @{InputPlatform='Windows';Canonical='Windows'}
        @{InputPlatform='windows';Canonical='Windows'}
        @{InputPlatform='wInDoWs';Canonical='Windows'}
        @{InputPlatform='MacOS';Canonical='MacOS'}
        @{InputPlatform='macos';Canonical='MacOS'}
        @{InputPlatform='mAcOs';Canonical='MacOS'}
    ) {
        $root=Join-Path $TestDrive $InputPlatform
        [void][IO.Directory]::CreateDirectory($root)
        $profiles=@{}
        foreach($key in @('Linux','Windows','MacOS')){$profiles[$key]=@{Method='Unsupported';Reason=('Selected '+$key+' profile')}}
        @{Module='Fixture';Platforms=$profiles}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $root 'image.json')
        {& (Join-Path $script:ContainerModuleRoot 'resources/containers/definitions/bootstrap/Install-ImageTool.ps1') -Root $root -Platform $InputPlatform} | Should -Throw ('*Selected '+$Canonical+' profile*')
        Test-Path (Join-Path $root 'installed-tool.json') | Should -BeFalse
        Test-Path (Join-Path $root 'bin') | Should -BeFalse
    }
    It 'rejects <Name> before changing the image environment or writing an install receipt' -ForEach @(
        @{Name='missing Platforms';Metadata=@{Module='Fixture'}}
        @{Name='null Platforms';Metadata=@{Module='Fixture';Platforms=$null}}
        @{Name='non-object Platforms';Metadata=@{Module='Fixture';Platforms=@('Windows')}}
        @{Name='missing Windows profile';Metadata=@{Module='Fixture';Platforms=@{Linux=@{Method='None'}}}}
        @{Name='mis-cased metadata key';Metadata=@{Module='Fixture';Platforms=@{windows=@{Method='None'}}}}
        @{Name='null profile';Metadata=@{Module='Fixture';Platforms=@{Windows=$null}}}
        @{Name='non-object profile';Metadata=@{Module='Fixture';Platforms=@{Windows='None'}}}
        @{Name='missing Method';Metadata=@{Module='Fixture';Platforms=@{Windows=@{Binary=$null}}}}
        @{Name='empty Method';Metadata=@{Module='Fixture';Platforms=@{Windows=@{Method=' '}}}}
        @{Name='non-string Method';Metadata=@{Module='Fixture';Platforms=@{Windows=@{Method=1}}}}
    ) {
        $root=Join-Path $TestDrive $Name
        [void][IO.Directory]::CreateDirectory($root)
        $Metadata|ConvertTo-Json -Depth 5|Set-Content (Join-Path $root 'image.json')
        $originalPath=$env:PATH
        try{
            {& (Join-Path $script:ContainerModuleRoot 'resources/containers/definitions/bootstrap/Install-ImageTool.ps1') -Root $root -Platform Windows} | Should -Throw '*Invalid Windows image profile*'
            $env:PATH | Should -BeExactly $originalPath
            Test-Path (Join-Path $root 'installed-tool.json') | Should -BeFalse
            Test-Path (Join-Path $root 'bin') | Should -BeFalse
        }finally{$env:PATH=$originalPath}
    }
    It 'writes a canonical receipt for a valid built-in profile with argument <InputPlatform>' -ForEach @(
        @{InputPlatform='Windows'}
        @{InputPlatform='windows'}
        @{InputPlatform='wInDoWs'}
    ) {
        $root=Join-Path $TestDrive ('builtin-'+$InputPlatform)
        [void][IO.Directory]::CreateDirectory($root)
        @{Module='Fixture';Platforms=@{Windows=@{Method='None';Binary=$null}}}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $root 'image.json')
        $originalEnvironment=@{}
        foreach($name in @('PATH','COMPOSER_HOME','GEM_HOME','GOBIN','NPM_CONFIG_PREFIX')){$originalEnvironment[$name]=[Environment]::GetEnvironmentVariable($name)}
        try{
            & (Join-Path $script:ContainerModuleRoot 'resources/containers/definitions/bootstrap/Install-ImageTool.ps1') -Root $root -Platform $InputPlatform
            $receipt=Get-Content (Join-Path $root 'installed-tool.json') -Raw|ConvertFrom-Json -AsHashtable
            $receipt.Module | Should -BeExactly Fixture
            $receipt.Platform | Should -BeExactly Windows
            $receipt.Method | Should -BeExactly None
            $receipt.Executable | Should -BeNullOrEmpty
        }finally{foreach($name in $originalEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$originalEnvironment[$name])}}
    }
    It 'generates inside the contributor and protects manual Dockerfile edits and WhatIf' {
        $root=Join-Path $TestDrive 'workspace'
        $ag=Join-Path $root 'FrenchExDev.Tools.Ag.PoSh'
        $engine=Join-Path $root 'FrenchExDev.Mutator.PoSh/test'
        [void][IO.Directory]::CreateDirectory($ag);[void][IO.Directory]::CreateDirectory($engine)
        Copy-Item (Join-Path $script:WorkspaceModules 'FrenchExDev.Tools.Ag.PoSh/FrenchExDev.Tools.Ag.PoSh.psd1') $ag
        Copy-Item -LiteralPath (Join-Path $script:WorkspaceModules 'QuietCliEcosystem') -Destination (Join-Path $root 'QuietCliEcosystem') -Recurse
        $null=Export-MutatorContainerDefinition $ag
        $file=Join-Path $ag 'containers/linux/Dockerfile'
        Set-Content $file 'manual content'
        {Export-MutatorContainerDefinition $ag} | Should -Throw '*already exist*'
        $null=Export-MutatorContainerDefinition $ag -Force -WhatIf
        [IO.File]::ReadAllText($file).Trim() | Should -BeExactly 'manual content'
        $null=Export-MutatorContainerDefinition $ag -Force
        [IO.File]::ReadAllText($file) | Should -Match ':alpine-pwsh-'
        $null=Export-MutatorContainerDefinition $ag -Force -WindowsBackend Native
        $native=Get-Content (Join-Path $ag 'containers/windows/Dockerfile') -TotalCount 1
        $native | Should -BeExactly '# escape=`'
        [IO.File]::ReadAllText((Join-Path $ag 'containers/windows/Dockerfile')) | Should -Match ':windows-native-pwsh-'
    }
    It 'generates special-case layers from contributor metadata: <Key>' -ForEach @(
        @{Key='Gradle';Commands=@('wrapper');Binary='gradle'},@{Key='Mvn';Commands=@('wrapper');Binary='mvn'},
        @{Key='Pytest';Commands=@('wrapper');Binary='pytest'},@{Key='Engine';Commands=@();Binary=$null},
        @{Key='Hadolint';Commands=@('hadolint');Binary='hadolint'},@{Key='Brew';Commands=@('brew');Binary='brew'},
        @{Key='Swift';Commands=@('swift');Binary='swift'},@{Key='Journalctl';Commands=@('journalctl');Binary='journalctl'}
    ) {
        $parent=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $name=if($Key -eq 'Engine'){'FrenchExDev.Mutator.PoSh'}else{'FrenchExDev.Tools.'+$Key+'.PoSh'}
        $module=Join-Path $parent $name;$engine=Join-Path $parent 'FrenchExDev.Mutator.PoSh/test'
        [void][IO.Directory]::CreateDirectory($module);[void][IO.Directory]::CreateDirectory($engine)
        Copy-Item -LiteralPath (Join-Path $script:WorkspaceModules 'QuietCliEcosystem') -Destination (Join-Path $parent 'QuietCliEcosystem') -Recurse
        $literalCommands=@($Commands|ForEach-Object {"'"+$_+"'"}) -join ','
        [IO.File]::WriteAllText((Join-Path $module ($name+'.psd1')),("@{ModuleVersion='1.0.0';PrivateData=@{Mutator=@{Commands=@("+$literalCommands+")}}}"))
        $r=Export-MutatorContainerDefinition $module -WindowsBackend Native -IncludeMacOS
        $metadata=Get-Content (Join-Path $module 'containers/image.json') -Raw|ConvertFrom-Json -AsHashtable
        $metadata.Commands|Should -Be $Commands
        $metadata.Platforms.Linux.Binary|Should -Be $Binary
        $linux=[IO.File]::ReadAllText((Join-Path $module 'containers/linux/Dockerfile'))
        if($Key -eq 'Hadolint'){$linux|Should -Match 'COPY --from='}
        if($Key -eq 'Brew'){$linux|Should -Match '(?m)^USER linuxbrew'}
        if($Key -eq 'Swift'){$linux|Should -Match ':swift-pwsh-'}
        if($Key -eq 'Journalctl'){
            $windows=[IO.File]::ReadAllText((Join-Path $module 'containers/windows/Dockerfile'))
            $windows|Should -Match '^# escape=`\r?\n# UNSUPPORTED:'
        }
        $r.MacOS|Should -Not -BeNullOrEmpty
        Test-Path (Join-Path $module 'containers/macos/compose.yaml')|Should -BeTrue
    }
    It 'refuses a foreign contributor and never writes container definitions' {
        $module=Join-Path $TestDrive 'Foreign.Module';[void][IO.Directory]::CreateDirectory($module)
        [IO.File]::WriteAllText((Join-Path $module 'Foreign.Module.psd1'),"@{ModuleVersion='1.0.0';PrivateData=@{}}")
        {Export-MutatorContainerDefinition $module}|Should -Throw '*require a FrenchExDev module*'
        Test-Path (Join-Path $module 'containers')|Should -BeFalse
    }
}
