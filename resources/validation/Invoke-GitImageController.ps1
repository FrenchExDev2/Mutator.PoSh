#requires -Version 7.6
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference='Stop'
$directory=Split-Path (Resolve-Path -LiteralPath $RequestPath).ProviderPath
$exitCode=1
try{
    $options=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json -AsHashtable
    if([IO.Path]::GetFullPath($options.OutputDirectory) -cne [IO.Path]::GetFullPath($directory)){throw 'The controller request must own its report directory.'}
    Import-Module (Join-Path $PSScriptRoot '../../FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
    $result=Invoke-MutatorGitImageValidation @options
    @{Outcome=$result.Outcome;Path=$result.Path}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $directory 'controller.result.json') -Encoding utf8NoBOM
    if($result.Outcome -ceq 'Success'){$exitCode=0}
}catch{
    @{Outcome='Failed';Error=$_.Exception.Message}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $directory 'controller.result.json') -Encoding utf8NoBOM
}
exit $exitCode
