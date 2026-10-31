#requires -Version 7.6
param([Parameter(Mandatory)][string]$CacheRoot)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
$tool=Import-MutatorTool -CacheRoot $CacheRoot
@{Sha256=(Get-MutatorSourceSnapshot (Split-Path $tool.Path)).Sha256;Adapter=$tool.AdapterSha256}|ConvertTo-Json -Compress
