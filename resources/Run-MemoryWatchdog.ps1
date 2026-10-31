#requires -Version 7.6
param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Import-Module (Join-Path (Split-Path $PSScriptRoot) 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {param($Directory);Invoke-MutatorMemoryWatchdogLoop $Directory} $Path
