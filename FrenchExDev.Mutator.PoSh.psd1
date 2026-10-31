@{
    RootModule = 'FrenchExDev.Mutator.PoSh.psm1'
    ModuleVersion = '1.0.0'
    GUID = '31c775c2-983a-4c42-a144-7c876636b9f0'
    Author = 'FrenchExDev'
    Description = 'Isolated mutation runs, PSMutant and Stryker adapters, resource budgets, resumable evidence and a run dashboard.'
    PowerShellVersion = '7.6'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('Confirm-MutatorResume', 'Export-MutatorContainerBaseDefinition', 'Export-MutatorContainerDefinition', 'Export-MutatorGuestBase', 'Export-MutatorReport', 'Export-MutatorWindowsBase', 'Get-MutatorEngine', 'Get-MutatorFailure', 'Get-MutatorGuestBase', 'Get-MutatorMemoryWatchdog', 'Get-MutatorPreview', 'Get-MutatorProgress', 'Get-MutatorRetentionPlan', 'Get-MutatorRun', 'Get-MutatorSourceSnapshot', 'Get-MutatorSubtree', 'Import-MutatorRun', 'Import-MutatorTestModule', 'Import-MutatorTool', 'Invoke-MutatorGitImageValidation', 'Invoke-MutatorGuestValidation', 'Invoke-MutatorRecheck', 'Invoke-MutatorRun', 'Invoke-MutatorStryker', 'Invoke-MutatorValidation', 'Merge-MutatorBranchCoverage', 'Merge-MutatorCoverage', 'Move-MutatorEngineConfiguration', 'New-MutatorConfiguration', 'New-MutatorContainerImage', 'New-MutatorContext', 'New-MutatorSchedule', 'New-MutatorToolImage', 'Remove-MutatorRun', 'Restart-MutatorGuestBase', 'Resume-MutatorRun', 'Save-MutatorArtifact', 'Set-MutatorContainerEngine', 'Set-MutatorEngine', 'Set-MutatorTestOrder', 'Show-MutatorDashboard', 'Start-MutatorGuestBase', 'Start-MutatorGuestModule', 'Start-MutatorMemoryWatchdog', 'Stop-MutatorGitImageValidation', 'Stop-MutatorGuestBase', 'Stop-MutatorMemoryWatchdog', 'Stop-MutatorRun', 'Test-MutatorContainerImage', 'Test-MutatorGuestHost', 'Test-MutatorGuestSeed', 'Test-MutatorPowerShellQualityGate', 'Update-MutatorContainerDefinition', 'Wait-MutatorGuestBase', 'Watch-MutatorRun')
    AliasesToExport = @('mutator')
    CmdletsToExport = @()
    VariablesToExport = @()
    PrivateData = @{
        PSData = @{
            LicenseUri = 'https://opensource.org/license/mit'
            Tags = @('PowerShell', 'Testing', 'Mutation', 'PSMutant', 'Stryker', 'PSEdition_Core')
        }
    }
}
