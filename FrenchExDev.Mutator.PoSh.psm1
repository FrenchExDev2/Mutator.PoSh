#requires -Version 7.6
#requires -PSEdition Core
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:MutatorRoot = $PSScriptRoot
$script:MutatorIsolationBoundary = $null
$script:MutatorContainerEngine = 'Podman'
$script:MutatorContainerConnection = $null
$script:MutatorContainerSetting = $null
$script:MutatorContainerContextSelected = $false
$script:MutatorPreferredContainerEngine = $null
$script:MutatorPreferredContainerConnection = $null
$script:MutatorMessageCatalog = @{}
$script:MutatorPipeConnectionCache = @{}
foreach ($folder in @('Private','Public')) {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot "src/$folder") -File -Filter '*.ps1' -Recurse |
        Sort-Object FullName | ForEach-Object { . $_.FullName }
}
$public = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src/Public') -File -Filter '*.ps1' | ForEach-Object BaseName)
Set-Alias -Name mutator -Value Invoke-MutatorRun
Export-ModuleMember -Function $public -Alias @('mutator') -Cmdlet @() -Variable @()
