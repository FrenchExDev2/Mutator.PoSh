#requires -Version 7.6
[CmdletBinding()]
param(
    [ValidateSet('Unit','Mutations','Integration')][string[]]$Test,
    [ValidateSet('Linux','Windows','MacOS')][string[]]$OS,
    [Alias('Engine')][ValidateSet('Podman','Docker')][string]$ContainerEngine,
    [string[]]$ModulePath,[string]$ContainerConnection,
    [string]$MacOSConnection,[string]$OutputDirectory,[switch]$UI,[string]$Ram,
    [ValidateRange(1,64)][int]$Workers,
    [ValidateRange(1,64)][int]$WorkerBudget,
    [ValidateRange(2048,1048576)][int]$MemoryBudgetMiB
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
try {
    $result=Invoke-MutatorValidation @PSBoundParameters
    $result|ConvertTo-Json -Depth 12 -Compress
    if($result.Outcome -cne 'Success'){exit 1}
    exit 0
}catch{
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
