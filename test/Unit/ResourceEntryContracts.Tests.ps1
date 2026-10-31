<#
.SYNOPSIS
Expected behavior for the ResourceEntryContracts tests.

.DESCRIPTION
Entrypoints must dispatch the intended worker/workload using current runtime paths and return actual
outcomes. Stubbed workers/installers must retain diagnostics without launching real supervisors or
watchdog recovery.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:ResourceModuleRoot=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:ResourceModuleRoot 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Guest validation adapter preserves the request and installer/workload boundary' {
    BeforeEach {
        $script:PayloadRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:PayloadShare=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach($path in @($script:PayloadRoot,$script:PayloadShare)){[void][IO.Directory]::CreateDirectory($path)}
        [IO.File]::WriteAllText((Join-Path $script:PayloadShare 'request.json'),'{"RunId":"owned-request"}')
        [IO.File]::WriteAllText((Join-Path $script:PayloadRoot 'image.json'),'{"Module":"FrenchExDev.Mutator.PoSh"}')
        $script:PayloadContractModule=New-Module -Name MutatorPayloadContracts -ScriptBlock {
            $script:PayloadState=@{Calls=[Collections.Generic.List[object]]::new();FailTools=$false}
            $payloadState=$script:PayloadState
            Set-Item Function:Invoke-ValidationPowerShellFixture -Value ({
                $payloadState.Calls.Add(@($args))
                $global:LASTEXITCODE=if($payloadState.FailTools -and @($args|Where-Object {$_ -like '*Install-ImageTool.Original.ps1'}).Count){7}else{0}
            }.GetNewClosure())
            Export-ModuleMember -Function @()
        }
        Import-Module $script:PayloadContractModule -Global -Force
    }
    AfterEach {Remove-Module MutatorPayloadContracts -Force -ErrorAction Ignore}
    It 'runs only the workload for an infrastructure payload: <Platform>' -ForEach @(@{Platform='Windows'},@{Platform='MacOS'}) {
        InModuleScope MutatorPayloadContracts -Parameters @{Script=(Join-Path $script:ResourceModuleRoot 'resources/validation/Install-ValidationPayload.ps1');Root=$script:PayloadRoot;Share=$script:PayloadShare;Platform=$Platform} {
            param($Script,$Root,$Share,$Platform)
            & $Script -Platform $Platform -Root $Root -Share $Share -PowerShellExecutable Invoke-ValidationPowerShellFixture
            $global:LASTEXITCODE|Should -Be 0
            (Get-Content (Join-Path $Root 'request.json') -Raw|ConvertFrom-Json -AsHashtable).RunId|Should -BeExactly owned-request
            $script:PayloadState.Calls.Count|Should -Be 1
            $script:PayloadState.Calls[0]|Should -Contain (Join-Path $Root 'modules/FrenchExDev.Mutator.PoSh/resources/validation/Invoke-ValidationWorkload.ps1')
            $script:PayloadState.Calls[0]|Should -Contain (Join-Path $Share 'reports')
        }
    }
    It 'runs a tool installer before its workload and refuses a failed install: <Fail>' -ForEach @(@{Fail=$false},@{Fail=$true}) {
        [IO.File]::WriteAllText((Join-Path $script:PayloadRoot 'image.json'),'{"Module":"Fixture.Tool"}')
        InModuleScope MutatorPayloadContracts -Parameters @{Script=(Join-Path $script:ResourceModuleRoot 'resources/validation/Install-ValidationPayload.ps1');Root=$script:PayloadRoot;Share=$script:PayloadShare;Fail=$Fail} {
            param($Script,$Root,$Share,$Fail)
            $script:PayloadState.FailTools=$Fail
            & $Script -Platform Windows -Root $Root -Share $Share -PowerShellExecutable Invoke-ValidationPowerShellFixture
            if($Fail){$global:LASTEXITCODE|Should -Be 7;$script:PayloadState.Calls.Count|Should -Be 1}
            else{$global:LASTEXITCODE|Should -Be 0;$script:PayloadState.Calls.Count|Should -Be 2}
            @($script:PayloadState.Calls[0]|Where-Object {$_ -like '*Install-ImageTool.Original.ps1'}).Count|Should -Be 1
        }
    }
    It 'defaults to the running PowerShell executable without assuming an OS-specific filename' {
        $worker=Join-Path $script:PayloadRoot 'modules/FrenchExDev.Mutator.PoSh/resources/validation/Invoke-ValidationWorkload.ps1'
        [void][IO.Directory]::CreateDirectory((Split-Path $worker))
        [IO.File]::WriteAllText($worker,'param($Root,$ReportRoot) [IO.File]::WriteAllText((Join-Path $Root "native-proof.txt"),$PSVersionTable.PSVersion.ToString())')
        & (Join-Path $script:ResourceModuleRoot 'resources/validation/Install-ValidationPayload.ps1') -Platform Windows -Root $script:PayloadRoot -Share $script:PayloadShare
        $global:LASTEXITCODE|Should -Be 0
        [IO.File]::ReadAllText((Join-Path $script:PayloadRoot 'native-proof.txt'))|Should -BeExactly $PSVersionTable.PSVersion.ToString()
    }
}
Describe 'Original worker entry scripts keep execution inside the module boundary' {
    BeforeEach {
        $script:ResourceEvidence=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:ResourceEvidence)
        $script:SavedResourceEncoding=[Console]::OutputEncoding
        Mock Import-Module {}
        Mock Invoke-MutatorPackage -ModuleName FrenchExDev.Mutator.PoSh {}
        Mock Invoke-MutatorRunCore -ModuleName FrenchExDev.Mutator.PoSh {}
        Mock Invoke-MutatorMemoryWatchdogLoop -ModuleName FrenchExDev.Mutator.PoSh {}
        Mock Invoke-MutatorValidationWorkload -ModuleName FrenchExDev.Mutator.PoSh {@{Outcome='Success'}}
    }
    AfterEach {[Console]::OutputEncoding=$script:SavedResourceEncoding}
    It 'dispatches package and supervisor entrypoints without starting real workers' {
        & (Join-Path $script:ResourceModuleRoot 'resources/Run-Worker.ps1') -RunDirectory $script:ResourceEvidence -Package p0000
        & (Join-Path $script:ResourceModuleRoot 'resources/Run-Worker.ps1') -RunDirectory $script:ResourceEvidence
        Should -Invoke Invoke-MutatorPackage -ModuleName FrenchExDev.Mutator.PoSh -Times 1 -Exactly -ParameterFilter {$Package -eq 'p0000'}
        Should -Invoke Invoke-MutatorRunCore -ModuleName FrenchExDev.Mutator.PoSh -Times 1 -Exactly
    }
    It 'retains detached-supervisor diagnostics and its failure state' {
        Mock Invoke-MutatorRunCore -ModuleName FrenchExDev.Mutator.PoSh {throw 'entry supervisor failure'}
        {& (Join-Path $script:ResourceModuleRoot 'resources/Run-DetachedWorker.ps1') -RunDirectory $script:ResourceEvidence}|Should -Throw '*entry supervisor failure*'
        $proof=Get-Content (Join-Path $script:ResourceEvidence 'supervisor-failure.json') -Raw|ConvertFrom-Json -AsHashtable
        $proof.Phase|Should -BeExactly SupervisorStartup
        $proof.Error|Should -BeExactly 'entry supervisor failure'
        Get-Content (Join-Path $script:ResourceEvidence 'supervisor.stderr.log') -Raw|Should -Match 'entry supervisor failure'
    }
    It 'retains successful detached-supervisor output in its owned run directory' {
        & (Join-Path $script:ResourceModuleRoot 'resources/Run-DetachedWorker.ps1') -RunDirectory $script:ResourceEvidence
        Test-Path (Join-Path $script:ResourceEvidence 'supervisor.stdout.log')|Should -BeTrue
        Test-Path (Join-Path $script:ResourceEvidence 'supervisor-failure.json')|Should -BeFalse
    }
    It 'dispatches the watchdog entrypoint without observing or recovering any process' {
        & (Join-Path $script:ResourceModuleRoot 'resources/Run-MemoryWatchdog.ps1') -Path $script:ResourceEvidence
        Should -Invoke Invoke-MutatorMemoryWatchdogLoop -ModuleName FrenchExDev.Mutator.PoSh -Times 1 -Exactly
    }
    It 'returns the selected workload outcome as an exit code: <Outcome>' -ForEach @(@{Outcome='Success';Exit=0},@{Outcome='Failed';Exit=1}) {
        $workloadOutcome=@{Value=$Outcome}
        Mock Invoke-MutatorValidationWorkload -ModuleName FrenchExDev.Mutator.PoSh -MockWith ({@{Outcome=$workloadOutcome.Value}}.GetNewClosure())
        & (Join-Path $script:ResourceModuleRoot 'resources/validation/Invoke-ValidationWorkload.ps1') -Root $script:ResourceEvidence -ReportRoot $script:ResourceEvidence
        $global:LASTEXITCODE|Should -Be $Exit
        Should -Invoke Invoke-MutatorValidationWorkload -ModuleName FrenchExDev.Mutator.PoSh -Times 1 -Exactly
    }
}
