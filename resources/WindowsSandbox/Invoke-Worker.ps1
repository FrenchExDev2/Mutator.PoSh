# Objectif : Exécuter PSMutant uniquement dans Windows Sandbox et conserver sa progression sur le partage de rapports.
#requires -Version 7.6
#requires -PSEdition Core
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$env:PSModulePath='C:\MutatorTools\modules'+[IO.Path]::PathSeparator+(Join-Path $PSHOME 'Modules')
$env:QUIETCLI_CONFIG_PATH='C:\MutatorRun\quietcli.yaml'
$env:MUTATOR_CONFIG_PATH='C:\MutatorRun\mutator.yaml'
[IO.File]::WriteAllText($env:MUTATOR_CONFIG_PATH,"podman: {enabled: true, pipe: null}`n")
[IO.File]::WriteAllText($env:QUIETCLI_CONFIG_PATH,"history: {enabled: false}`nmeasurement: {enabled: false}`n")
$request=Get-Content -LiteralPath 'C:\MutatorPayload\request.json' -Raw|ConvertFrom-Json
$mutator=Join-Path 'C:\MutatorInput' $request.MutatorRelative
Import-Module (Join-Path $mutator 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
$module=Get-Module FrenchExDev.Mutator.PoSh
& $module {
    param($Request)
    foreach($subtree in $Request.Subtrees){
        if(Test-Path -LiteralPath 'C:\MutatorRun\stop.json'){throw 'Stopped before source preparation.'}
        Copy-MutatorTree (Join-Path 'C:\MutatorInput' $subtree) (Join-Path 'C:\MutatorSource' $subtree)
    }
} $request
# Reimport from the private source copy so caches and test fixtures cannot write to the host checkout.
Remove-Module FrenchExDev.Mutator.PoSh
$mutator=Join-Path 'C:\MutatorSource' $request.MutatorRelative
Import-Module (Join-Path $mutator 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {param($Package) Invoke-MutatorPackage 'C:\MutatorRun' $Package} $request.Package
