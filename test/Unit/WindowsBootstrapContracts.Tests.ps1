<#
.SYNOPSIS
Expected behavior for the WindowsBootstrapContracts tests.

.DESCRIPTION
Bootstrap must preserve verified ownership, runtime paths and payload hashes before publishing
readiness or registering mocked tasks. Each failed stage retains local/shared diagnostics and cannot
be overridden by obsolete proof.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:GuestDefinitions=Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'resources/containers/definitions/guest'
    $script:BaseInstaller=Join-Path $script:GuestDefinitions 'Install-WindowsBase.ps1'
    $script:ModuleInstaller=Join-Path $script:GuestDefinitions 'Initialize-WindowsModule.ps1'
    $script:HostPowerShell=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
    $script:BaseArchive=Join-Path $TestDrive 'powershell-fixture.zip'
    $content=Join-Path $TestDrive 'powershell-payload';[void][IO.Directory]::CreateDirectory($content)
    [IO.File]::WriteAllText((Join-Path $content 'README'),'verified runtime archive fixture')
    [IO.Compression.ZipFile]::CreateFromDirectory($content,$script:BaseArchive)
    $script:BaseArchiveSha=(Get-FileHash $script:BaseArchive).Hash
    function Save-GuestFixtureJson {
        <#
        .SYNOPSIS
        Write controlled Windows bootstrap metadata or proof.

        .DESCRIPTION
        Creates fixture parent directories and serializes test data without preparing a real guest.
        #>

        param([string]$Path,[object]$Data)
        [void][IO.Directory]::CreateDirectory((Split-Path $Path))
        [IO.File]::WriteAllText($Path,($Data|ConvertTo-Json -Depth 8))
    }
    function Invoke-BaseBootstrapFixture {
        <#
        .SYNOPSIS
        Execute the base bootstrap inside its mocked fixture module.

        .DESCRIPTION
        Uses controlled installer options to test readiness, failure retention and task-registration
        arguments without provisioning Windows.
        #>

        InModuleScope MutatorGuestBootstrapContracts -Parameters @{Installer=$script:BaseInstaller;Options=$script:BaseOptions} {
            param($Installer,$Options)
            . $Installer @Options
        }
    }
    function Invoke-ModuleBootstrapFixture {
        <#
        .SYNOPSIS
        Execute module bootstrap inside its mocked fixture module.

        .DESCRIPTION
        Uses controlled payloads and native mocks to verify ownership, reinstall decisions and local/shared
        failure evidence.
        #>

        InModuleScope MutatorGuestBootstrapContracts -Parameters @{Installer=$script:ModuleInstaller;Options=$script:ModuleOptions} {
            param($Installer,$Options)
            . $Installer @Options
        }
    }
}

Describe 'Windows guest base bootstrap in an isolated process environment' {
    BeforeEach {
        $script:BootstrapEnvironment=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach($name in @('PATH','Path','PSModulePath','MUTATOR_MODULE','TOOL_VERSION','TOOL_URL','TOOL_SHA256','MUTATOR_BASE_INIT_EXIT','MUTATOR_BASE_TOOL_EXIT','MUTATOR_BASE_VERIFY_EXIT','MUTATOR_BASE_MISSING_PROOF')){
            $script:BootstrapEnvironment[$name]=[Environment]::GetEnvironmentVariable($name)
        }
        foreach($name in @('TOOL_VERSION','TOOL_URL','TOOL_SHA256','MUTATOR_BASE_INIT_EXIT','MUTATOR_BASE_TOOL_EXIT','MUTATOR_BASE_VERIFY_EXIT','MUTATOR_BASE_MISSING_PROOF')){[Environment]::SetEnvironmentVariable($name,$null)}
        $script:PreviousTls=[Net.ServicePointManager]::SecurityProtocol
        $script:GuestCase=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:GuestRoot=Join-Path $script:GuestCase 'installed'
        $script:GuestSource=Join-Path $script:GuestCase 'payload'
        $script:GuestShare=Join-Path $script:GuestCase 'share'
        [void][IO.Directory]::CreateDirectory((Join-Path $script:GuestSource 'bootstrap'))
        [void][IO.Directory]::CreateDirectory($script:GuestShare)
        Save-GuestFixtureJson (Join-Path $script:GuestSource 'image.json') @{Module='Fixture.WindowsBase';BaseFingerprint='fixture-base';Runtime=@{WindowsUri='https://example.invalid/powershell.zip';WindowsSHA256=$script:BaseArchiveSha}}
        [IO.File]::WriteAllLines((Join-Path $script:GuestSource 'tool-inputs.txt'),@('1.2.3','https://example.invalid/tool.zip','abc123'))
        [IO.File]::WriteAllText((Join-Path $script:GuestSource 'bootstrap/Initialize-Image.ps1'),@'
if($env:MUTATOR_BASE_INIT_EXIT){exit ([int]$env:MUTATOR_BASE_INIT_EXIT)}
'fixture initialization completed'
'@)
        [IO.File]::WriteAllText((Join-Path $script:GuestSource 'bootstrap/Install-ImageTool.ps1'),@'
param([string]$Platform,[string]$Root)
if($env:MUTATOR_BASE_TOOL_EXIT){exit ([int]$env:MUTATOR_BASE_TOOL_EXIT)}
[IO.File]::AppendAllText((Join-Path $Root 'native-invocations.txt'),"installed`n")
[IO.File]::WriteAllText((Join-Path $Root 'native-inputs.json'),(@{Platform=$Platform;Root=$Root;Version=$env:TOOL_VERSION;Uri=$env:TOOL_URL;Sha=$env:TOOL_SHA256}|ConvertTo-Json))
'@)
        $verification=Join-Path $script:GuestCase 'verify-runtime.ps1'
        [IO.File]::WriteAllText($verification,@'
param([string]$Root)
if($env:MUTATOR_BASE_VERIFY_EXIT){exit ([int]$env:MUTATOR_BASE_VERIFY_EXIT)}
if(!$env:MUTATOR_BASE_MISSING_PROOF){[IO.File]::WriteAllText((Join-Path $Root 'base-runtime.json'),(@{Outcome='Success';Fingerprint='fixture-base';PowerShell=$PSVersionTable.PSVersion.ToString()}|ConvertTo-Json))}
'@)
        $script:BaseOptions=@{Root=$script:GuestRoot;Source=$script:GuestSource;Share=$script:GuestShare;PowerShellDirectory=(Join-Path $script:GuestCase 'runtime');PowerShellExecutable=$script:HostPowerShell;ValidationScript=$verification;EnvironmentTarget='Process'}
        $script:GuestTestModule=New-Module -Name MutatorGuestBootstrapContracts -ScriptBlock {
            function New-ScheduledTaskAction {
                <#
                .SYNOPSIS
                Declare a scheduled-task action boundary that must be mocked.

                .DESCRIPTION
                Throws if reached without a mock, preventing bootstrap unit tests from creating real scheduled
                tasks.
                #>
                param($Execute,$Argument) throw 'Scheduled task commands must be mocked.'}
            function New-ScheduledTaskTrigger {
                <#
                .SYNOPSIS
                Declare a scheduled-task trigger boundary that must be mocked.

                .DESCRIPTION
                Throws if reached without a mock, keeping startup behavior an asserted contract rather than a host
                change.
                #>
                param([switch]$AtStartup) throw 'Scheduled task commands must be mocked.'}
            function New-ScheduledTaskPrincipal {
                <#
                .SYNOPSIS
                Declare a scheduled-task principal boundary that must be mocked.

                .DESCRIPTION
                Throws unless replaced by the test, so account and privilege choices are inspected without host
                configuration.
                #>
                param($UserId,$LogonType,$RunLevel) throw 'Scheduled task commands must be mocked.'}
            function New-ScheduledTaskSettingsSet {
                <#
                .SYNOPSIS
                Declare a scheduled-task settings boundary that must be mocked.

                .DESCRIPTION
                Throws unless replaced by the test, keeping task policy verification independent of the host
                scheduler.
                #>
                param([switch]$StartWhenAvailable,$MultipleInstances,$ExecutionTimeLimit) throw 'Scheduled task commands must be mocked.'}
            function Register-ScheduledTask {
                <#
                .SYNOPSIS
                Declare scheduled-task registration as an explicit mock boundary.

                .DESCRIPTION
                Throws unless mocked; the fixture must never persist a real task on the developer workstation.
                #>
                param($TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force) throw 'Scheduled task commands must be mocked.'}
            Export-ModuleMember -Function @()
        }
        Import-Module $script:GuestTestModule -Global -Force
        InModuleScope MutatorGuestBootstrapContracts -Parameters @{Archive=$script:BaseArchive} {
            param($Archive)
            $script:OfflineBaseArchive=$Archive
            Mock Invoke-WebRequest {param($OutFile) Copy-Item -LiteralPath $script:OfflineBaseArchive -Destination $OutFile}
            Mock New-ScheduledTaskAction {param($Execute,$Argument) @{Execute=$Execute;Argument=$Argument}}
            Mock New-ScheduledTaskTrigger {@{AtStartup=$true}}
            Mock New-ScheduledTaskPrincipal {@{UserId='SYSTEM'}}
            Mock New-ScheduledTaskSettingsSet {@{MultipleInstances='IgnoreNew'}}
            Mock Register-ScheduledTask {}
        }
    }
    AfterEach {
        Remove-Module MutatorGuestBootstrapContracts -Force -ErrorAction Ignore
        foreach($name in $script:BootstrapEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$script:BootstrapEnvironment[$name])}
        [Net.ServicePointManager]::SecurityProtocol=$script:PreviousTls
    }

    It 'publishes only the verified runtime proof and schedules the installed module path' {
        $machineBefore=[Environment]::GetEnvironmentVariable('MUTATOR_MODULE','Machine')
        Invoke-BaseBootstrapFixture
        $ready=Get-Content (Join-Path $script:GuestShare 'base-ready.json') -Raw|ConvertFrom-Json
        $ready.Outcome|Should -BeExactly Success
        $ready.Fingerprint|Should -BeExactly fixture-base
        $progress=Get-Content (Join-Path $script:GuestRoot 'base-progress.json') -Raw|ConvertFrom-Json
        $progress.Stage|Should -BeExactly Ready
        Test-Path (Join-Path $script:GuestRoot 'powershell.zip')|Should -BeFalse
        Test-Path (Join-Path $script:BaseOptions.PowerShellDirectory 'README')|Should -BeTrue
        [Environment]::GetEnvironmentVariable('MUTATOR_MODULE','Machine')|Should -BeExactly $machineBefore
        $env:MUTATOR_MODULE|Should -BeExactly Fixture.WindowsBase
        $inputs=Get-Content (Join-Path $script:GuestRoot 'native-inputs.json') -Raw|ConvertFrom-Json
        $inputs.Version|Should -BeExactly '1.2.3'
        $inputs.Uri|Should -BeExactly 'https://example.invalid/tool.zip'
        $inputs.Sha|Should -BeExactly abc123
        InModuleScope MutatorGuestBootstrapContracts -Parameters @{Runtime=$script:HostPowerShell;Destination=$script:GuestRoot;Share=$script:GuestShare} {
            param($Runtime,$Destination,$Share)
            Should -Invoke New-ScheduledTaskAction -Times 1 -ParameterFilter {$Execute -ceq $Runtime -and $Argument.Contains($Destination) -and $Argument.Contains((Join-Path $Share 'mutator')) -and $Argument.Contains('-EnvironmentTarget Process')}
            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {$TaskName -ceq 'Mutator-InstallModule' -and $Force}
        }
    }

    It 'accepts omitted optional tool inputs and preserves additional search paths' {
        Remove-Item (Join-Path $script:GuestSource 'tool-inputs.txt')
        $extra=Join-Path $script:GuestCase 'extra-tool-bin'
        Save-GuestFixtureJson (Join-Path $script:GuestSource 'tool-path.json') @($extra)
        Invoke-BaseBootstrapFixture
        $inputs=Get-Content (Join-Path $script:GuestRoot 'native-inputs.json') -Raw|ConvertFrom-Json
        $inputs.Version|Should -BeNullOrEmpty
        $env:PATH.Split([IO.Path]::PathSeparator)|Should -Contain $extra
    }

    It 'refuses invalid archives or tool inputs before registering a task: <Fault>' -ForEach @(
        @{Fault='checksum';Expected='*SHA256 mismatch*'},@{Fault='two inputs';Expected='*Invalid guest tool input*'},@{Fault='four inputs';Expected='*Invalid guest tool input*'}
    ) {
        if($Fault -eq 'checksum'){
            $path=Join-Path $script:GuestSource 'image.json';$metadata=Get-Content $path -Raw|ConvertFrom-Json
            $metadata.Runtime.WindowsSHA256='0'*64;Save-GuestFixtureJson $path $metadata
        }else{
            $values=if($Fault -eq 'two inputs'){@('a','b')}else{@('a','b','c','d')}
            [IO.File]::WriteAllLines((Join-Path $script:GuestSource 'tool-inputs.txt'),$values)
        }
        {Invoke-BaseBootstrapFixture}|Should -Throw $Expected
        $failure=Get-Content (Join-Path $script:GuestShare 'guest-failed.json') -Raw|ConvertFrom-Json
        $failure.Outcome|Should -BeExactly Failed
        $failure.Error|Should -BeLike $Expected
        Test-Path (Join-Path $script:GuestRoot 'base-ready.json')|Should -BeFalse
        InModuleScope MutatorGuestBootstrapContracts {Should -Invoke Register-ScheduledTask -Times 0}
    }

    It 'distinguishes failures of each native bootstrap stage: <Stage>' -ForEach @(
        @{Stage='initialize';Variable='MUTATOR_BASE_INIT_EXIT';Expected='*PowerShell tools bootstrap failed*'},
        @{Stage='tool';Variable='MUTATOR_BASE_TOOL_EXIT';Expected='*Native tool bootstrap failed*'},
        @{Stage='verification';Variable='MUTATOR_BASE_VERIFY_EXIT';Expected='*runtime failed verification*'}
    ) {
        [Environment]::SetEnvironmentVariable($Variable,'7')
        {Invoke-BaseBootstrapFixture}|Should -Throw $Expected
        $failure=Get-Content (Join-Path $script:GuestRoot 'guest-failed.json') -Raw|ConvertFrom-Json
        $failure.Error|Should -BeLike $Expected
        Test-Path (Join-Path $script:GuestRoot 'base-ready.json')|Should -BeFalse
        InModuleScope MutatorGuestBootstrapContracts {Should -Invoke Register-ScheduledTask -Times 0}
    }

    It 'retains an early copy failure even before metadata has been read' {
        $script:BaseOptions.Source=Join-Path $script:GuestCase 'absent-payload'
        {Invoke-BaseBootstrapFixture}|Should -Throw
        $failure=Get-Content (Join-Path $script:GuestRoot 'guest-failed.json') -Raw|ConvertFrom-Json
        $failure.Module|Should -BeNullOrEmpty
        $failure.Outcome|Should -BeExactly Failed
        $failure.Error|Should -Not -BeLike '*property*Module*'
    }

    It 'refuses a verifier that exits successfully without producing its proof' {
        $env:MUTATOR_BASE_MISSING_PROOF='1'
        {Invoke-BaseBootstrapFixture}|Should -Throw
        Test-Path (Join-Path $script:GuestRoot 'base-ready.json')|Should -BeFalse
        Test-Path (Join-Path $script:GuestRoot 'guest-failed.json')|Should -BeTrue
    }

    It 'uses the installed executable path by default and reports a missing executable' {
        [void]$script:BaseOptions.Remove('PowerShellExecutable')
        {Invoke-BaseBootstrapFixture}|Should -Throw
        Test-Path (Join-Path $script:GuestRoot 'guest-failed.json')|Should -BeTrue
        InModuleScope MutatorGuestBootstrapContracts {Should -Invoke Register-ScheduledTask -Times 0}
    }

    It 'retains the original failure when the host share cannot receive progress or diagnostics' {
        $script:BaseOptions.Share=Join-Path $script:GuestCase 'absent/share'
        $env:MUTATOR_BASE_TOOL_EXIT='7'
        {Invoke-BaseBootstrapFixture}|Should -Throw '*Native tool bootstrap failed*'
        (Get-Content (Join-Path $script:GuestRoot 'guest-failed.json') -Raw|ConvertFrom-Json).Error|Should -BeLike '*Native tool bootstrap failed*'
        Test-Path (Join-Path $script:GuestRoot 'base-progress.json')|Should -BeTrue
    }

    Describe 'Installing a module onto a verified guest base' {
        BeforeEach {
            $script:ModuleShare=Join-Path $script:GuestShare 'mutator'
            [void][IO.Directory]::CreateDirectory($script:ModuleShare)
            foreach($name in @('bootstrap','modules')){[void][IO.Directory]::CreateDirectory((Join-Path $script:ModuleShare $name))}
            Copy-Item -LiteralPath (Join-Path $script:GuestSource 'bootstrap/Install-ImageTool.ps1') -Destination (Join-Path $script:ModuleShare 'bootstrap/Install-ImageTool.ps1')
            Save-GuestFixtureJson (Join-Path $script:GuestRoot 'base-ready.json') @{Fingerprint='fixture-base';Outcome='Success'}
            Save-GuestFixtureJson (Join-Path $script:ModuleShare 'image.json') @{Module='Fixture.WindowsModule';BaseFingerprint='fixture-base'}
            [IO.File]::WriteAllLines((Join-Path $script:ModuleShare 'tool-inputs.txt'),@('1.2.3','https://example.invalid/tool.zip','abc123'))
            $script:ModuleOptions=@{Root=$script:GuestRoot;Share=$script:ModuleShare;PowerShellExecutable=$script:HostPowerShell;EnvironmentTarget='Process';WaitTimeoutSeconds=10}
        }
        It 'copies the payload, installs once and binds the receipt to both input hashes' {
            $machineBefore=[Environment]::GetEnvironmentVariable('MUTATOR_MODULE','Machine')
            Invoke-ModuleBootstrapFixture
            $readyPath=Join-Path $script:GuestRoot 'module-ready.json'
            $ready=Get-Content $readyPath -Raw|ConvertFrom-Json
            $identity=(Get-FileHash (Join-Path $script:ModuleShare 'image.json')).Hash+'-'+(Get-FileHash (Join-Path $script:ModuleShare 'tool-inputs.txt')).Hash
            $ready.Identity|Should -BeExactly $identity
            $ready.BaseFingerprint|Should -BeExactly fixture-base
            $ready.Module|Should -BeExactly Fixture.WindowsModule
            $ready.Outcome|Should -BeExactly Success
            (Get-FileHash $readyPath).Hash|Should -BeExactly (Get-FileHash (Join-Path $script:ModuleShare 'module-ready.json')).Hash
            Invoke-ModuleBootstrapFixture
            @(Get-Content (Join-Path $script:GuestRoot 'native-invocations.txt')).Count|Should -Be 1
            [Environment]::GetEnvironmentVariable('MUTATOR_MODULE','Machine')|Should -BeExactly $machineBefore
        }
        It 'reinstalls when tool inputs change instead of trusting an obsolete ready receipt' {
            Invoke-ModuleBootstrapFixture
            [IO.File]::WriteAllLines((Join-Path $script:ModuleShare 'tool-inputs.txt'),@('2.0.0','https://example.invalid/new.zip','new-sha'))
            Invoke-ModuleBootstrapFixture
            @(Get-Content (Join-Path $script:GuestRoot 'native-invocations.txt')).Count|Should -Be 2
            (Get-Content (Join-Path $script:GuestRoot 'native-inputs.json') -Raw|ConvertFrom-Json).Version|Should -BeExactly '2.0.0'
        }
        It 'refuses a module belonging to a different base before installation' {
            Save-GuestFixtureJson (Join-Path $script:ModuleShare 'image.json') @{Module='Fixture';BaseFingerprint='foreign-base'}
            {Invoke-ModuleBootstrapFixture}|Should -Throw '*fingerprints differ*'
            Test-Path (Join-Path $script:GuestRoot 'native-invocations.txt')|Should -BeFalse
        }
        It 'times out a missing payload without installing or claiming readiness' {
            Remove-Item (Join-Path $script:ModuleShare 'image.json')
            $script:ModuleOptions.WaitTimeoutSeconds=0
            {Invoke-ModuleBootstrapFixture}|Should -Throw '*payload is not available*'
            Test-Path (Join-Path $script:GuestRoot 'module-ready.json')|Should -BeFalse
        }
        It 'waits for a payload that arrives after the first poll' {
            $backup=Join-Path $script:GuestCase 'delayed-image.json'
            Copy-Item (Join-Path $script:ModuleShare 'image.json') $backup
            Remove-Item (Join-Path $script:ModuleShare 'image.json')
            InModuleScope MutatorGuestBootstrapContracts -Parameters @{Backup=$backup;Share=$script:ModuleShare} {
                param($Backup,$Share)
                $script:DelayedGuestMetadata=$Backup;$script:DelayedGuestShare=$Share
                Mock Start-Sleep {Copy-Item -LiteralPath $script:DelayedGuestMetadata -Destination (Join-Path $script:DelayedGuestShare 'image.json')}
            }
            Invoke-ModuleBootstrapFixture
            InModuleScope MutatorGuestBootstrapContracts {Should -Invoke Start-Sleep -Times 1 -ParameterFilter {$Seconds -eq 3}}
            Test-Path (Join-Path $script:GuestRoot 'module-ready.json')|Should -BeTrue
        }
        It 'retains local and shared diagnostics for invalid module tool inputs: <Count>' -ForEach @(@{Count=2},@{Count=4}) {
            [IO.File]::WriteAllLines((Join-Path $script:ModuleShare 'tool-inputs.txt'),@((1..$Count)|ForEach-Object {[string]$_}))
            {Invoke-ModuleBootstrapFixture}|Should -Throw '*Invalid module tool input*'
            (Get-Content (Join-Path $script:GuestRoot 'module-failed.json') -Raw|ConvertFrom-Json).Error|Should -BeLike '*Invalid module tool input*'
            Test-Path (Join-Path $script:ModuleShare 'module-failed.json')|Should -BeTrue
            Test-Path (Join-Path $script:GuestRoot 'module-ready.json')|Should -BeFalse
        }
        It 'distinguishes a failed native installation from a ready module' {
            $env:MUTATOR_BASE_TOOL_EXIT='7'
            {Invoke-ModuleBootstrapFixture}|Should -Throw '*Module tool installation failed*'
            Test-Path (Join-Path $script:ModuleShare 'module-failed.json')|Should -BeTrue
            Test-Path (Join-Path $script:GuestRoot 'module-ready.json')|Should -BeFalse
        }
    }
}
