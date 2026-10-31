#requires -Version 7.6
# Objectif : Qualifier journalctl et une compilation SDK hors réseau dans une image Linux.
param([string]$ModuleRoot='/opt/mutator/modules',[string]$ProofDirectory='/proof',[Parameter(Mandatory)][string]$ExpectedDotnetVersion)
& (Join-Path $ModuleRoot 'FrenchExDev.Mutator.PoSh/resources/containers/probes/Invoke-ImageQualification.ps1') -Profile Journalctl -ModuleRoot $ModuleRoot -ProofDirectory $ProofDirectory -ExpectedDotnetVersion $ExpectedDotnetVersion
exit $LASTEXITCODE
