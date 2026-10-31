<#
.SYNOPSIS
Expected behavior for the ValidationEntry tests.

.DESCRIPTION
The thin script forwards selections and typed budgets and returns structured JSON plus exit zero
only for success. Failed gates and orchestration exceptions return exit one with retained
diagnostics.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:EntryModuleRoot=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:EntryModuleRoot 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    function Invoke-ValidationEntryFixture {
        <#
        .SYNOPSIS
        Run the validation entry script against a controlled stub module.

        .DESCRIPTION
        Retains forwarded parameters, JSON, stderr and exit code so script contracts can be asserted without
        running platform validation.
        #>

        param([string]$Mode='Success',[switch]$Explicit)
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null=New-Item $root -ItemType Directory
        Copy-Item (Join-Path $script:EntryModuleRoot 'Invoke-Validation.ps1') (Join-Path $root 'Invoke-Validation.ps1')
        [IO.File]::WriteAllText((Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1'),"@{RootModule='stub.psm1';ModuleVersion='1.0.0';FunctionsToExport=@('Invoke-MutatorValidation')}")
        $stub=@'
function Invoke-MutatorValidation {
    param([string[]]$Test,[string[]]$OS,[string[]]$ModulePath,[string]$ContainerEngine,[string]$ContainerConnection,[string]$MacOSConnection,[string]$OutputDirectory,[switch]$UI,[string]$Ram,[int]$Workers,[int]$WorkerBudget,[int]$MemoryBudgetMiB)
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'received.json'),($PSBoundParameters|ConvertTo-Json -Compress))
    if ('__MODE__' -eq 'Throw') { throw 'entry-tool-failure' }
    @{Outcome='__MODE__';Modules=@();Platforms=@{MacOS=@{Outcome='NotSelected'}}}
}
'@
        [IO.File]::WriteAllText((Join-Path $root 'stub.psm1'),$stub.Replace('__MODE__',$Mode))
        $command="& '"+(Join-Path $root 'Invoke-Validation.ps1').Replace("'","''")+"'"
        if($Explicit){$command+=" -Test Unit,Integration -OS Linux -ModulePath module-a,module-b -Engine Docker -ContainerConnection local-root -MacOSConnection apple -OutputDirectory proof -UI -Ram 40go -Workers 2 -WorkerBudget 4 -MemoryBudgetMiB 8192"}
        $native=& (Get-Module FrenchExDev.Mutator.PoSh) {param($Command) Invoke-MutatorNative (Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})) @('-NoProfile','-Command',$Command) $script:MutatorRoot 60} $command
        @{ExitCode=$native.ExitCode;Outcome=$native.Outcome;Received=(Get-Content (Join-Path $root 'received.json') -Raw|ConvertFrom-Json -AsHashtable);Json=$(if($Mode -ne 'Throw'){$native.Stdout|ConvertFrom-Json -AsHashtable}else{$null});Error=$native.Stderr}
    }
}
Describe 'Validation script process contract' {
    It 'returns exit zero and structured JSON for a successful validation' {
        $r=Invoke-ValidationEntryFixture
        $r.ExitCode|Should -Be 0
        $r.Json.Outcome|Should -BeExactly Success
        $r.Json.Platforms.MacOS.Outcome|Should -BeExactly NotSelected
        $r.Received.Count|Should -Be 0
    }
    It 'forwards all explicit selections and resource limits without changing their types' {
        $r=Invoke-ValidationEntryFixture -Explicit
        $r.ExitCode|Should -Be 0
        $r.Received.Test -join ','|Should -BeExactly 'Unit,Integration'
        $r.Received.OS|Should -Contain Linux
        $r.Received.ModulePath -join ','|Should -BeExactly 'module-a,module-b'
        $r.Received.ContainerConnection|Should -BeExactly local-root
        $r.Received.ContainerEngine|Should -BeExactly Docker
        $r.Received.MacOSConnection|Should -BeExactly apple
        $r.Received.OutputDirectory|Should -BeExactly proof
        $r.Received.UI|Should -BeTrue
        $r.Received.Ram|Should -BeExactly 40go
        $r.Received.Workers|Should -Be 2
        $r.Received.WorkerBudget|Should -Be 4
        $r.Received.MemoryBudgetMiB|Should -Be 8192
    }
    It 'returns exit one for a failed gate while retaining its structured result' {
        $r=Invoke-ValidationEntryFixture -Mode Failed
        $r.ExitCode|Should -Be 1
        $r.Json.Outcome|Should -BeExactly Failed
    }
    It 'returns exit one and a diagnostic when orchestration throws' {
        $r=Invoke-ValidationEntryFixture -Mode Throw
        $r.ExitCode|Should -Be 1
        $r.Error|Should -Match 'entry-tool-failure'
    }
}
Describe 'Original validation entry script remains directly observable by the coverage collector' {
    BeforeEach {
        Mock Import-Module {}
        Mock Invoke-MutatorValidation {@{Outcome='Success';Platforms=@{MacOS=@{Outcome='NotSelected'}}}}
        Mock New-MutatorValidationSource -ModuleName FrenchExDev.Mutator.PoSh {throw 'An actual validation must never run in entry contracts'}
        Mock Start-MutatorMemoryWatchdog -ModuleName FrenchExDev.Mutator.PoSh {throw 'An actual watchdog must never run in entry contracts'}
    }
    It 'returns structured success and exit zero from the original script' {
        $text=& (Join-Path $script:EntryModuleRoot 'Invoke-Validation.ps1') -Test Unit -OS Linux -OutputDirectory $TestDrive
        $global:LASTEXITCODE|Should -Be 0
        ($text|ConvertFrom-Json -AsHashtable).Outcome|Should -BeExactly Success
        Should -Invoke Invoke-MutatorValidation -Times 1 -Exactly -ParameterFilter {$OS -contains 'Linux' -and $Test -contains 'Unit'}
    }
    It 'returns exit one for a failed selected gate' {
        Mock Invoke-MutatorValidation {@{Outcome='Failed'}}
        $text=& (Join-Path $script:EntryModuleRoot 'Invoke-Validation.ps1') -Test Unit -OS Linux -OutputDirectory $TestDrive
        $global:LASTEXITCODE|Should -Be 1
        ($text|ConvertFrom-Json -AsHashtable).Outcome|Should -BeExactly Failed
    }
    It 'reports an orchestration exception with exit one' {
        Mock Invoke-MutatorValidation {throw 'original entry fixture failure'}
        & (Join-Path $script:EntryModuleRoot 'Invoke-Validation.ps1') -Test Unit -OS Linux -OutputDirectory $TestDrive 2>$null
        $global:LASTEXITCODE|Should -Be 1
    }
}
