#requires -Version 7.6
param([Parameter(Mandatory)][string]$BaseImage)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
$proof=Join-Path $root ('test/Artifacts/development/container-smoke-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
$source=Join-Path $proof 'source'
$module=Get-Module FrenchExDev.Mutator.PoSh
& $module {
    param($Root,$Destination)
    Copy-MutatorTree $Root (Join-Path $Destination 'FrenchExDev.Mutator.PoSh')
    Copy-MutatorTree (Join-Path (Split-Path $Root) 'QuietCliEcosystem/FrenchExDev.QuietCli.PoSh') (Join-Path $Destination 'QuietCliEcosystem/FrenchExDev.QuietCli.PoSh')
} $root $source
$fixture=Join-Path $source 'Fixture.Container'
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'test'))
[IO.File]::WriteAllText((Join-Path $fixture 'Value.ps1'),'function Get-ContainerValue { param([bool]$Enabled) if ($Enabled) { 1 } else { 2 } }')
[IO.File]::WriteAllText((Join-Path $fixture 'test/Value.Tests.ps1'),@'
BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'Value.ps1') }
Describe 'Linux worker' {
    It 'keeps the value and provides the requested native binary' {
        Get-ContainerValue $true | Should -Be 1
        Get-ContainerValue $false | Should -Be 2
        (Get-Command ag -CommandType Application).Source | Should -Not -BeNullOrEmpty
        $IsLinux | Should -BeTrue
    }
}
'@)
$configuration=@{workers=1;coveredLinesOnly=$false;mutate=@('Fixture.Container/Value.ps1');tests=@{'Fixture.Container/Value.ps1'=@('Fixture.Container/test/Value.Tests.ps1')}
    thresholds=@{high=100;low=100;break=100};sandboxSubtrees=@('Fixture.Container');reportPath='Fixture.Container/test/Artifacts/mutation.json'}
$configuration|ConvertTo-Json -Depth 6|Set-Content (Join-Path $fixture 'test/psmutant.config.json')
Set-Content (Join-Path $fixture 'test/mutator.container.psd1') "@{Binary='ag';UseWhen='Always';Packages=@('the_silver_searcher=2.2.0-r1')}"
$run=Invoke-MutatorRun -ModulePath $fixture -RunRoot (Join-Path $proof 'runs') -Workers 1 -WorkerBudget 1 -ContainerBaseImage $BaseImage -SkipStryker
$summary=@{Outcome=$run.Outcome;Completed=$run.CompletedPackages;Platform=$run.Packages[0]['Platform'];PSMutant=$run.Packages[0]['PSMutant'];Error=$run.Packages[0]['Error'];Path=$run.Path}
$summary|ConvertTo-Json -Depth 6|Set-Content (Join-Path $proof 'receipt.json')
@{Outcome=$summary.Outcome;Completed=$summary.Completed;Platform=$summary.Platform;Error=$summary.Error;Report=(Join-Path $proof 'receipt.json')}|ConvertTo-Json -Compress
if($run.Outcome -ne 'Success'){exit 1}
