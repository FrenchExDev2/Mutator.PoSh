#requires -Version 7.6
param([Parameter(Mandatory)][string]$RunDirectory, [string]$Package = '')
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Import-Module (Join-Path (Split-Path $PSScriptRoot) 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
$module = Get-Module FrenchExDev.Mutator.PoSh
& $module {
    param($Directory,$Selected)
    if ($Selected) { Invoke-MutatorPackage $Directory $Selected }
    else { Invoke-MutatorRunCore $Directory }
} $RunDirectory $Package
