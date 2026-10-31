#requires -Version 7.6
param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ReportRoot)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $Root 'modules/FrenchExDev.Mutator.PoSh/FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
$result=& (Get-Module FrenchExDev.Mutator.PoSh) {param($Root,$ReportRoot) Invoke-MutatorValidationWorkload -Root $Root -ReportRoot $ReportRoot} $Root $ReportRoot
if($result.Outcome -cne 'Success'){exit 1}
exit 0
