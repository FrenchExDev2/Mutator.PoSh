#requires -Version 7.6
param([Parameter(Mandatory)][string]$Connection,[switch]$RequireEmptyStore,[ValidateSet('Ag','Journalctl')][string]$Profile='Ag')
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
$modules=Split-Path $root
$proof=Join-Path $root ('test/Artifacts/development/generated-linux-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
$source=Join-Path $proof 'source'
$name='FrenchExDev.Tools.Fixture.PoSh'
$fixture=Join-Path $source $name
$template='FrenchExDev.Tools.'+$Profile+'.PoSh'
$binary=if($Profile -eq 'Ag'){'ag'}else{'journalctl'}
$initial=& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Connection,$Root)
    $result=Invoke-MutatorContainerCommand -Arguments @('images','--format','json') -Directory $Root -Connection $Connection
    if($result.Outcome -ne 'Success'){throw 'Cannot inspect the fixture image store.'}
    @($result.Stdout|ConvertFrom-Json -AsHashtable).Count
} $Connection $root
if($RequireEmptyStore -and $initial -ne 0){throw 'The cold-store fixture requires a genuinely empty, separately provisioned store.'}
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Modules,$Source)
    foreach($dependency in @('FrenchExDev.Mutator.PoSh','QuietCliEcosystem/FrenchExDev.QuietCli.PoSh','QuietCliEcosystem/FrenchExDev.QuietCli.PoSh')){
        Copy-MutatorTree (Join-Path $Modules $dependency) (Join-Path $Source $dependency)
    }
} $modules $source
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'containers/linux'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'test'))
foreach($file in @('containers/image.json','containers/linux/Dockerfile','containers/linux/Dockerfile.dockerignore')){
    $text=[IO.File]::ReadAllText((Join-Path $modules ($template+'/'+$file))).Replace($template,$name)
    [IO.File]::WriteAllText((Join-Path $fixture $file),$text)
}
[IO.File]::WriteAllText((Join-Path $fixture 'Value.ps1'),'function Get-ContainerValue { param([bool]$Enabled) if ($Enabled) { 1 } else { 2 } }')
$testText=@'
BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'Value.ps1') }
Describe 'Generated Linux worker' {
    It 'executes the contract with PowerShell Core and the requested binary' {
        Get-ContainerValue $true | Should -Be 1
        Get-ContainerValue $false | Should -Be 2
        (Get-Command __BINARY__ -CommandType Application).Source | Should -Not -BeNullOrEmpty
        $IsLinux | Should -BeTrue
        $PSVersionTable.PSEdition | Should -BeExactly Core
        $PSVersionTable.PSVersion | Should -BeGreaterOrEqual ([version]'7.6')
    }
}
'@
[IO.File]::WriteAllText((Join-Path $fixture 'test/Value.Tests.ps1'),$testText.Replace('__BINARY__',$binary))
$configuration=@{workers=1;coveredLinesOnly=$false;mutate=@($name+'/Value.ps1');tests=@{($name+'/Value.ps1')=@($name+'/test/Value.Tests.ps1')}
    thresholds=@{high=100;low=100;break=100};sandboxSubtrees=@($name);reportPath=($name+'/test/Artifacts/mutation.json')}
$configuration|ConvertTo-Json -Depth 6|Set-Content (Join-Path $fixture 'test/psmutant.config.json')
# Only force the platform; the generated definition owns the actual package recipe.
Set-Content (Join-Path $fixture 'test/mutator.container.psd1') ("@{Binary='"+$binary+"';UseWhen='Always'}")
$receipts=@(foreach($iteration in 1..2){
    $run=Invoke-MutatorRun -ModulePath $fixture -SourceRoot $source -RunRoot (Join-Path $proof 'runs') -ContainerConnection $Connection `
        -Workers 1 -WorkerBudget 1 -ThrottleLimit 1 -MemoryBudgetMiB 2048 -SkipStryker
    $package=$run.Packages[0]
    $build=Get-Content -LiteralPath $package.Container.BuildReceipt -Raw|ConvertFrom-Json -AsHashtable -DateKind String
    $receipt=@{Iteration=$iteration;Outcome=$run.Outcome;Path=$run.Path;PSMutant=$package.PSMutant;Container=$package.Container;Build=$build;Error=$package.Error}
    $receipt|ConvertTo-Json -Depth 12|Set-Content (Join-Path $proof ('run-'+$iteration+'.json'))
    if($run.Outcome -ne 'Success' -or $package.PSMutant.Score -ne 100 -or $package.Container.BuildKind -cne 'Generated'){throw ('Generated Linux run failed; proof: '+$proof)}
    if($iteration -eq 2 -and !$build.Reused){throw 'The unchanged generated image was not reused.'}
    $receipt
})
if($RequireEmptyStore -and !@($receipts[0].Build.Dependencies|Where-Object Built -EQ $true).Count){throw 'The cold store did not cause the declared base to be built.'}
$summary=@{Outcome='Success';Profile=$Profile;InitialImages=$initial;EmptyStoreRequired=[bool]$RequireEmptyStore;Connection=$Connection
    Runs=@($receipts|ForEach-Object {@{Path=$_.Path;Score=$_.PSMutant.Score;Total=$_.PSMutant.Total;Reused=$_.Build.Reused;ImageId=$_.Build.ImageId}});Proof=$proof}
$summary|ConvertTo-Json -Depth 6|Set-Content (Join-Path $proof 'receipt.json')
$summary|ConvertTo-Json -Depth 6 -Compress
