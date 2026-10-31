BeforeAll {
    $script:ValidationModuleRoot=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:ValidationModuleRoot 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Validation entry point and platform selection' {
    BeforeEach {
        $script:ReportDirectory=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock -ModuleName FrenchExDev.Mutator.PoSh Start-MutatorMemoryWatchdog { @{Path='owned-watchdog'} }
        Mock -ModuleName FrenchExDev.Mutator.PoSh Stop-MutatorMemoryWatchdog { }
        Mock -ModuleName FrenchExDev.Mutator.PoSh New-MutatorValidationSource { @{Path='frozen-source';Sha256='frozen-sha'} }
        Mock -ModuleName FrenchExDev.Mutator.PoSh Invoke-MutatorValidationContainer {
            param($Platform,$Source,$Request,$OutputDirectory,$Connection)
            @{Outcome='Success';Suites=@{};Connection=$Connection;ReceivedTests=$Request.Test;FullGateSatisfied=($Request.Test.Count -eq 3)}
        }
    }
    It 'defaults to the three suites on Linux and Windows with absolutely no macOS operation' {
        $run=Invoke-MutatorValidation -OutputDirectory $script:ReportDirectory
        $run.Outcome|Should -BeExactly Success
        $run.FullGateSatisfied|Should -BeTrue
        $run.Platforms.MacOS.Outcome|Should -BeExactly NotSelected
        @($run.Test) -join ','|Should -BeExactly 'Unit,Integration,Mutations'
        $run.Modules|Should -Contain 'FrenchExDev.Mutator.PoSh'
        Should -Invoke -ModuleName FrenchExDev.Mutator.PoSh Invoke-MutatorValidationContainer -Times 2 -Exactly
        Should -Invoke -ModuleName FrenchExDev.Mutator.PoSh Invoke-MutatorValidationContainer -Times 0 -Exactly -ParameterFilter {$Platform -eq 'MacOS'}
        Test-Path (Join-Path $script:ReportDirectory 'summary.json')|Should -BeTrue
        Get-Content (Join-Path $script:ReportDirectory 'index.html') -Raw|Should -Match 'NotSelected'
    }
    It 'selects one OS and orders suites without claiming a complete gate' {
        $run=Invoke-MutatorValidation -Test Integration,Unit -OS Linux -OutputDirectory $script:ReportDirectory
        $run.FullGateSatisfied|Should -BeFalse
        $run.Platforms.Windows.Outcome|Should -BeExactly NotSelected
        $run.Platforms.Linux.ReceivedTests -join ','|Should -BeExactly 'Unit,Integration'
        Should -Invoke -ModuleName FrenchExDev.Mutator.PoSh Invoke-MutatorValidationContainer -Times 1 -Exactly
    }
    It 'uses the configured default engine or an explicit Engine override: <Explicit>' -ForEach @(@{Explicit=$false},@{Explicit=$true}) {
        Mock -ModuleName FrenchExDev.Mutator.PoSh Get-MutatorEngineSetting {
            param($Engine,[switch]$Default)
            $name=if($Default){'Docker'}else{$Engine}
            @{Name=$name;Enabled=$true;Default=($name -eq 'Docker');Pipe=('tcp://'+$name.ToLowerInvariant()+':8080');ConfigurationPath='fixture/config.yaml'}
        }
        InModuleScope FrenchExDev.Mutator.PoSh {$script:MutatorPreferredContainerEngine=$null;$script:MutatorPreferredContainerConnection=$null}
        $options=if($Explicit){@{Engine='Podman'}}else{@{}}
        $run=Invoke-MutatorValidation -OS Linux -OutputDirectory $script:ReportDirectory @options
        $expected=if($Explicit){'Podman'}else{'Docker'}
        $run.Outcome|Should -BeExactly Success
        $run.ContainerEngine|Should -BeExactly $expected
        $run.ContainerSetting.Name|Should -BeExactly $expected
        $run.ContainerConnection|Should -BeNullOrEmpty
    }
    It 'uses a configured Podman pipe without injecting the historical machine connection' {
        Mock -ModuleName FrenchExDev.Mutator.PoSh Get-MutatorEngineSetting {@{Name='Podman';Enabled=$true;Pipe='\\.\pipe\configured-machine';ConfigurationPath='fixture/config.yaml'}}
        InModuleScope FrenchExDev.Mutator.PoSh {Set-MutatorContainerContext Podman $null}
        try{
            $run=Invoke-MutatorValidation -OS Linux -OutputDirectory $script:ReportDirectory
            $run.Outcome|Should -BeExactly Success
            $run.ContainerConnection|Should -BeNullOrEmpty
            $run.ContainerSetting.Pipe|Should -BeExactly '\\.\pipe\configured-machine'
            $run.Platforms.Linux.Connection|Should -BeNullOrEmpty
        }finally{InModuleScope FrenchExDev.Mutator.PoSh {Set-MutatorContainerContext Podman $null}}
    }
    It 'requires a dedicated macOS connection only when selected and still executes Linux' {
        $run=Invoke-MutatorValidation -OS Linux,MacOS -OutputDirectory $script:ReportDirectory
        $run.Outcome|Should -BeExactly Failed
        $run.Platforms.Linux.Outcome|Should -BeExactly Success
        $run.Platforms.MacOS.Outcome|Should -BeExactly Blocked
        $run.Platforms.MacOS.Error|Should -Match 'MacOSConnection'
        Should -Invoke -ModuleName FrenchExDev.Mutator.PoSh Invoke-MutatorValidationContainer -Times 0 -Exactly -ParameterFilter {$Platform -eq 'MacOS'}
    }
    It 'routes macOS exclusively to its explicitly selected connection' {
        $run=Invoke-MutatorValidation -OS MacOS -MacOSConnection apple-tests -OutputDirectory $script:ReportDirectory
        $run.Platforms.MacOS.Connection|Should -BeExactly apple-tests
        Should -Invoke -ModuleName FrenchExDev.Mutator.PoSh Invoke-MutatorValidationContainer -Times 1 -Exactly -ParameterFilter {$Platform -eq 'MacOS' -and $Connection -eq 'apple-tests'}
    }
    It 'retains a blocked image preparation and continues with the next OS' {
        Mock -ModuleName FrenchExDev.Mutator.PoSh Invoke-MutatorValidationContainer { throw 'Prepare the Windows seed' } -ParameterFilter {$Platform -eq 'Windows'}
        $run=Invoke-MutatorValidation -OutputDirectory $script:ReportDirectory
        $run.Platforms.Windows.Outcome|Should -BeExactly Blocked
        $run.Platforms.Windows.Suites.Mutations.Reason|Should -Match 'Windows seed'
        $run.Platforms.Linux.Outcome|Should -BeExactly Success
        $run.FullGateSatisfied|Should -BeFalse
    }
    It 'does not start anything under WhatIf' {
        Invoke-MutatorValidation -OutputDirectory $script:ReportDirectory -WhatIf
        Test-Path $script:ReportDirectory|Should -BeFalse
        Should -Invoke -ModuleName FrenchExDev.Mutator.PoSh New-MutatorValidationSource -Times 0 -Exactly
        Should -Invoke -ModuleName FrenchExDev.Mutator.PoSh Start-MutatorMemoryWatchdog -Times 0 -Exactly
    }
    It 'rejects an existing report directory and preserves its contents' {
        $null=New-Item $script:ReportDirectory -ItemType Directory
        Set-Content (Join-Path $script:ReportDirectory 'keep.txt') 'original'
        {Invoke-MutatorValidation -OutputDirectory $script:ReportDirectory}|Should -Throw '*new or empty*'
        Get-Content (Join-Path $script:ReportDirectory 'keep.txt')|Should -BeExactly original
    }
    It 'refuses an impossible worker budget before creating a run' {
        {Invoke-MutatorValidation -Workers 3 -WorkerBudget 2 -OutputDirectory $script:ReportDirectory}|Should -Throw '*WorkerBudget*'
        Test-Path $script:ReportDirectory|Should -BeFalse
    }
    It 'keeps a source-freezing failure in the aggregate report' {
        Mock -ModuleName FrenchExDev.Mutator.PoSh New-MutatorValidationSource {throw 'Sources changed'}
        $run=Invoke-MutatorValidation -OutputDirectory $script:ReportDirectory
        $run.Outcome|Should -BeExactly Failed
        $run.Error|Should -Match 'Sources changed'
        Test-Path (Join-Path $script:ReportDirectory 'summary.json')|Should -BeTrue
    }
    It 'exports the public function and provides a parseable thin script' {
        Get-Command Invoke-MutatorValidation -Module FrenchExDev.Mutator.PoSh|Should -Not -BeNullOrEmpty
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ValidationModuleRoot 'Invoke-Validation.ps1'),[ref]$tokens,[ref]$errors)
        @($errors).Count|Should -Be 0
        @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-MutatorValidation'},$true)).Count|Should -Be 1
    }
}
