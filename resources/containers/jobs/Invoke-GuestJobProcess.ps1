#requires -Version 7.6
param(
    [Parameter(Mandatory)][string]$ScriptFile,
    [Parameter(Mandatory)][ValidateSet('JobDirectory','ProofDirectory')][string]$ParameterName,
    [Parameter(Mandatory)][string]$Directory,
    [string]$Root,
    [string]$JobsDirectory
)
$ErrorActionPreference='Stop'
$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$LASTEXITCODE=0
$invocationParameters=@{}
$invocationParameters[$ParameterName]=$Directory
if($ParameterName -eq 'JobDirectory'){
    if($Root){$invocationParameters.Root=$Root}
    if($JobsDirectory){$invocationParameters.JobsDirectory=$JobsDirectory}
}
& $ScriptFile @invocationParameters
exit $LASTEXITCODE
