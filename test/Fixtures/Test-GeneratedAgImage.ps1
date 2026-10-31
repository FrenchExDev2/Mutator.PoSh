#requires -Version 7.6
# Objectif : Qualifier Ag et QuietCli dans une image Linux préparée par Mutator.
param([string]$ModuleRoot='/opt/mutator/modules',[string]$ProofDirectory='/proof')
& (Join-Path $ModuleRoot 'FrenchExDev.Mutator.PoSh/resources/containers/probes/Invoke-ImageQualification.ps1') -Profile Ag -ModuleRoot $ModuleRoot -ProofDirectory $ProofDirectory
exit $LASTEXITCODE
