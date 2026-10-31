#requires -Version 7.6
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
$proof=Join-Path $root ('test/Artifacts/development/detached-worker-smoke-'+[guid]::NewGuid().ToString('N'))
$module=Join-Path $proof 'source/Fixture.Detached.PoSh'
[void][IO.Directory]::CreateDirectory((Join-Path $module 'src/Public'))
[void][IO.Directory]::CreateDirectory((Join-Path $module 'test/Unit'))
Set-Content -LiteralPath (Join-Path $module 'Fixture.Detached.PoSh.psd1') "@{RootModule='Fixture.Detached.PoSh.psm1';ModuleVersion='1.0.0';FunctionsToExport=@('Get-DetachedValue')}"
Set-Content -LiteralPath (Join-Path $module 'Fixture.Detached.PoSh.psm1') '. "$PSScriptRoot/src/Public/Get-DetachedValue.ps1"; Export-ModuleMember -Function Get-DetachedValue'
Set-Content -LiteralPath (Join-Path $module 'src/Public/Get-DetachedValue.ps1') 'function Get-DetachedValue {42}'
Set-Content -LiteralPath (Join-Path $module 'test/Unit/Value.Tests.ps1') 'BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) "Fixture.Detached.PoSh.psd1") -Force}; Describe value {It exact {$env:MUTATOR_SMOKE_INHERITED|Should -BeExactly "héritage validé";Get-DetachedValue|Should -Be 42}}'
$null=New-MutatorConfiguration -ModulePath $module
$env:MUTATOR_SMOKE_INHERITED='héritage validé'
$run=Invoke-MutatorRun -ModulePath $module -SourceRoot (Split-Path $module) -RunRoot (Join-Path $proof 'runs') -Workers 1 -WorkerBudget 1 -ThrottleLimit 1 -MemoryBudgetMiB 2048 -SkipStryker -Background
$receipt=@{Outcome=$run.Outcome;Path=$run.Path;Proof=$proof;Supervisor=$run.Process}
$receipt|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $proof 'launch.json')
$receipt|ConvertTo-Json -Depth 5 -Compress
