<#
.SYNOPSIS
Expected behavior for the WindowsResume tests.

.DESCRIPTION
Resume only with unchanged exact dependency hashes, report bytes and guest context. Reject
duplicates/drift before allocation and preserve target runtime and Stryker selection.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Windows resume retains complete source and report evidence' {
    BeforeEach {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $script:ResumeRoot=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $script:ResumeReport=Join-Path $script:ResumeRoot 'mutation.json'
            $module=Join-Path $script:ResumeRoot 'P';[void][IO.Directory]::CreateDirectory($module)
            Set-Content (Join-Path $module 'Value.ps1') 'function Get-Value { 1 }'
            Write-MutatorJson $script:ResumeReport @{mode='Partial';evaluated=1;planned=4}
            $script:ResumeReceipt=@{Sha256='context';ReportSha256=(Get-FileHash $script:ResumeReport).Hash;Identity=@{Dependencies=@(@{Path='P';Sha256=(Get-MutatorSourceSnapshot $module).Sha256})}}
            Write-MutatorJson ($script:ResumeReport+'.context.json') $script:ResumeReceipt
        }
    }
    It 'accepts unchanged declared sources and a fingerprinted partial report' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Confirm-MutatorResume $script:ResumeReport @{Sha256='context'}
            Confirm-MutatorWindowsResumeSource $script:ResumeReport $script:ResumeRoot @('P')
        }
    }
    It 'rejects changed source bytes before allocating a guest' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Add-Content (Join-Path $script:ResumeRoot 'P/Value.ps1') '# changed'
            {Confirm-MutatorWindowsResumeSource $script:ResumeReport $script:ResumeRoot @('P')}|Should -Throw '*bytes differ*'
        }
    }
    It 'rejects changed dependency sets and duplicate receipts' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            {Confirm-MutatorWindowsResumeSource $script:ResumeReport $script:ResumeRoot @('P','Other')}|Should -Throw '*set differs*'
            $script:ResumeReceipt.Identity.Dependencies+=@{Path='P';Sha256='duplicate'}
            Write-MutatorJson ($script:ResumeReport+'.context.json') $script:ResumeReceipt
            {Confirm-MutatorWindowsResumeSource $script:ResumeReport $script:ResumeRoot @('P')}|Should -Throw '*set differs*'
        }
    }
    It 'rejects an edited partial report and a mismatched guest context' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            {Confirm-MutatorResume $script:ResumeReport @{Sha256='different-runtime'}}|Should -Throw '*tools differ*'
            Add-Content $script:ResumeReport ' '
            {Confirm-MutatorResume $script:ResumeReport @{Sha256='context'}}|Should -Throw '*report changed*'
        }
    }
    It 'preserves the Windows runtime and explicit Stryker selection through the public resume command' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Mock Get-MutatorRun {[pscustomobject]@{Id='old';Path=$script:ResumeRoot;Outcome='Interrupted';Origin=$null;Packages=@(@{Id='p0000';Name='P'})}}
            Mock Read-MutatorJson {@{SourceRoot=$script:ResumeRoot;TestOrder='Configured';StrykerRuntime='Host';WindowsGuestImage='windows-image';WindowsGuestTimeoutMinutes=20;ContainerConnection='rootful';Packages=@(@{Id='p0000';Stryker=$false});Schedule=@{WorkerBudget=1;Workers=1;MemoryBudgetMiB=6144}}}
            Mock Invoke-MutatorRun { [pscustomobject]@{Outcome='Starting'} }
            $null=Resume-MutatorRun -Path $script:ResumeRoot -ModulePath (Join-Path $script:ResumeRoot 'P') -Background
            Should -Invoke Invoke-MutatorRun -Times 1 -ParameterFilter {$WindowsGuestImage -ceq 'windows-image' -and $WindowsGuestTimeoutMinutes -eq 20 -and $ContainerConnection -ceq 'rootful' -and $SkipStryker}
        }
    }
}
