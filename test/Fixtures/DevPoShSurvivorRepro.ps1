#requires -Version 7.6
param([ValidateSet('SyntaxDiagnostic','ConsoleEncoding')][string]$Case='SyntaxDiagnostic')
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Case)
    $proof=Join-Path $script:MutatorRoot ('test/Artifacts/development/devposh-survivor-repro-'+[guid]::NewGuid().ToString('N'))
    $source=Join-Path $proof 'source'
    $original=Join-Path (Split-Path $script:MutatorRoot) 'FrenchExDev.DevPoSh.PoSh'
    $before=Get-MutatorSourceSnapshot $original
    foreach($name in @('FrenchExDev.DevPoSh.PoSh','FrenchExDev.Mutator.PoSh','QuietCliEcosystem/FrenchExDev.QuietCli.PoSh')){
        Copy-MutatorTree (Join-Path (Split-Path $script:MutatorRoot) $name) (Join-Path $source $name)
    }
    $subject=Join-Path $source 'FrenchExDev.DevPoSh.PoSh'
    $harness=Join-Path $source 'FrenchExDev.Mutator.PoSh/test/Invoke-Tests.ps1'
    $tests=Join-Path $subject $(if($Case -eq 'ConsoleEncoding'){'test/Unit/Lifecycle.Tests.ps1'}else{'test/Unit/MutationContracts.Tests.ps1'})
    $invoke={
        param($Phase)
        $native=Invoke-MutatorNative (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile','-File',$harness,'-Path',$tests) $proof 180
        $json=@($native.Stdout -split "`r?`n"|Where-Object {$_ -like '{*'})
        if(!$json.Count){throw 'No structured candidate-check result.'}
        $result=$json[-1]|ConvertFrom-Json -AsHashtable
        Write-MutatorJson (Join-Path $proof ($Phase+'.json')) $result
        @{Phase=$Phase;Outcome=$native.Outcome;Passed=$result.Passed;Failed=$result.Failed;Failures=$result.Failures;Report=$result.Report}
    }
    $baseline=& $invoke 'baseline'
    if($baseline.Outcome -ne 'Success' -or !$baseline.Passed -or $baseline.Failed){throw 'Candidate check baseline failed.'}
    Import-Module PSMutant -RequiredVersion 0.6.0
    $file=Join-Path $subject $(if($Case -eq 'ConsoleEncoding'){'src/Private/Configuration/Initialize-DevPoShConsole.ps1'}else{'src/Private/Modules/Manifest.ps1'})
    $candidate=@(& (Get-Module PSMutant) {
        param($File,$Case)
        Get-PSMutationCandidate $File|Where-Object {
            if($Case -eq 'ConsoleEncoding'){$_.Function -eq 'Initialize-DevPoShConsole' -and $_.Original -eq '$false' -and $_.Mutated -eq '$true'}
            else{$_.Function -eq 'Get-DevPoShModuleAst' -and $_.Original -eq '0' -and $_.Mutated -eq '1'}
        }
    } $file $Case)
    if($candidate.Count -ne 1){throw 'Expected exactly one reviewed diagnostic candidate.'}
    $code=& (Get-Module PSMutant) {param($File,$Candidate) Set-PSMutationText ([IO.File]::ReadAllText($File)) $Candidate} $file $candidate[0]
    [IO.File]::WriteAllText($file,$code,[Text.UTF8Encoding]::new($false))
    $mutated=& $invoke 'mutated'
    if((Get-MutatorSourceSnapshot $original).Sha256 -cne $before.Sha256){throw 'Original DevPoSh sources changed during candidate check.'}
    $result=@{Mode='DiagnosticOnly';Proof=$proof;Baseline=$baseline;Mutated=$mutated;Candidate=$candidate[0];SourcesUnchanged=$true}
    Write-MutatorJson (Join-Path $proof 'result.json') $result
    @{Mode=$result.Mode;Proof=$proof;Baseline=$baseline.Outcome;Mutated=$mutated.Outcome;Failures=$mutated.Failures}|ConvertTo-Json -Depth 5 -Compress
} $Case
