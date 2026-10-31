#requires -Version 7.6
param([Parameter(Mandatory)][ValidateSet('Windows','MacOS')][string]$Platform,[Parameter(Mandatory)][string]$Root,
    [string]$Share,[string]$PowerShellExecutable)
$ErrorActionPreference='Stop'
if(!$Share){$Share=if($Platform -eq 'Windows'){'\\host.lan\Data\mutator'}else{'/Volumes/shared/mutator'}}
Copy-Item -LiteralPath (Join-Path $share 'request.json') -Destination (Join-Path $Root 'request.json') -Force
$pwsh=if($PowerShellExecutable){$PowerShellExecutable}else{[Environment]::ProcessPath}
$metadata=Get-Content (Join-Path $Root 'image.json') -Raw|ConvertFrom-Json -AsHashtable
if($metadata.Module -cne 'FrenchExDev.Mutator.PoSh'){
    & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-ImageTool.Original.ps1') -Platform $Platform -Root $Root
    if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
}
& $pwsh -NoProfile -File (Join-Path $Root 'modules/FrenchExDev.Mutator.PoSh/resources/validation/Invoke-ValidationWorkload.ps1') -Root $Root -ReportRoot (Join-Path $share 'reports')
exit $LASTEXITCODE
