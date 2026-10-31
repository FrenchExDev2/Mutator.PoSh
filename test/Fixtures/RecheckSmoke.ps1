#requires -Version 7.6
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
Import-Module (Join-Path (Split-Path $root) 'FrenchExDev.DevPoSh.PoSh/FrenchExDev.DevPoSh.PoSh.psd1') -DisableNameChecking
$proof=Join-Path $root ('test/Artifacts/development/recheck-smoke-'+[guid]::NewGuid().ToString('N'))
$fixture=New-DevPoShModule -Name Fixture.RecheckSmoke -Path (Join-Path $proof 'source') -Function Get-Value
Set-Content (Join-Path $fixture.Path 'src/Public/Get-Value.ps1') 'function Get-Value {param([int]$Value) if($Value -gt 0){42}else{0}}'
$tests=Join-Path $fixture.Path 'test/Unit/Value.Tests.ps1'
$code='BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) "Fixture.RecheckSmoke.PoSh.psd1") -Force};Describe value {It positive {Get-Value 2|Should -Be 42}}'
Set-Content $tests $code
$null=New-MutatorConfiguration -ModulePath $fixture.Path
$run=Invoke-MutatorRun -ModulePath $fixture.Path -SourceRoot (Split-Path $fixture.Path) -RunRoot (Join-Path $proof 'runs') -Workers 1 -WorkerBudget 1 -ThrottleLimit 1 -MemoryBudgetMiB 2048 -SkipStryker
$baseline=Join-Path $run.Path 'packages/p0000/mutation.json'
$detail=Get-Content -LiteralPath $baseline -Raw|ConvertFrom-Json
if($run.Outcome -ne 'Failed' -or !@($detail.survivors).Count){throw 'The deliberately incomplete smoke test did not leave a detected baseline failure.'}
$code+=';Describe boundary {It zero {Get-Value 0|Should -Be 0};It one {Get-Value 1|Should -Be 42}}'
Set-Content $tests $code
$result=Invoke-MutatorRecheck -ModulePath $fixture.Path -ReportPath $baseline -OutputDirectory (Join-Path $proof 'recheck')
if($result.Outcome -ne 'Success' -or $result.Rechecked -ne @($detail.survivors).Count -or $result.FullGateSatisfied -or $result.Score){throw 'Real survivor recheck did not preserve the diagnostic-only contract.'}
@{Outcome='Success';Proof=$proof;BaselineSurvivors=@($detail.survivors).Count;Rechecked=$result.Rechecked;NowKilled=$result.NowKilled;FullGateSatisfied=$result.FullGateSatisfied}|ConvertTo-Json -Compress
