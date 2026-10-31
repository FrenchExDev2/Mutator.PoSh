#requires -Version 7.6
# Objectif : Qualifier Ag et QuietCli dans un invité Windows préparé.
param([Parameter(Mandatory)][string]$ProofDirectory,[string]$ModuleRoot='C:\mutator\modules')
& (Join-Path $ModuleRoot 'FrenchExDev.Mutator.PoSh/resources/containers/probes/Invoke-ImageQualification.ps1') -Profile Ag -ExpectedOS Windows -ModuleRoot $ModuleRoot -ProofDirectory $ProofDirectory
exit $LASTEXITCODE
