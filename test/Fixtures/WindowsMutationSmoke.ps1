#requires -Version 7.6
param([Parameter(Mandatory)][string]$Image,[Parameter(Mandatory)][string]$Connection,[switch]$WithStryker,
    [ValidateRange(0,60)][int]$DelaySeconds=0,[ValidateRange(1,20)][int]$Functions=1,[string]$ExistingModule,[string]$ResumeFrom,[ValidateRange(1,86400)][Nullable[int]]$JobTimeoutSeconds)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
$proof=Join-Path $root ('test/Artifacts/development/windows-mutation-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
$source=Join-Path $proof 'source';$fixture=Join-Path $source 'Fixture.Windows'
if($ExistingModule){$fixture=(Resolve-Path $ExistingModule).ProviderPath;$source=Split-Path $fixture}else{
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'test'))
[IO.File]::WriteAllText((Join-Path $fixture 'Value.ps1'),'function Get-GuestValue { param([bool]$Enabled) if ($Enabled) { 1 } else { 2 } }')
[IO.File]::WriteAllText((Join-Path $fixture 'test/Value.Tests.ps1'),@'
BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'Value.ps1') }
Describe 'Windows mutation worker' {
    It 'keeps both results in a Windows guest with Ag installed' {
        Get-GuestValue $true | Should -Be 1
        Get-GuestValue $false | Should -Be 2
        $IsWindows | Should -BeTrue
        (Get-Command ag -CommandType Application).Source | Should -Not -BeNullOrEmpty
    }
}
'@)
$config=@{workers=1;coveredLinesOnly=$false;mutate=@('Fixture.Windows/Value.ps1');tests=@{'Fixture.Windows/Value.ps1'=@('Fixture.Windows/test/Value.Tests.ps1')}
    thresholds=@{high=100;low=100;break=100};sandboxSubtrees=@('Fixture.Windows');reportPath='Fixture.Windows/test/Artifacts/mutation.json'}
$config|ConvertTo-Json -Depth 6|Set-Content (Join-Path $fixture 'test/psmutant.config.json')
if($DelaySeconds -or $Functions -gt 1){
    $definitions=for($i=0;$i -lt $Functions;$i++){'function Get-GuestValue'+$i+' { param([bool]$Enabled) if ($Enabled) { 1 } else { 2 } }'}
    Set-Content (Join-Path $fixture 'Value.ps1') ($definitions -join "`n")
    $assertions=for($i=0;$i -lt $Functions;$i++){'Get-GuestValue'+$i+' $true | Should -Be 1';'Get-GuestValue'+$i+' $false | Should -Be 2'}
    $test='BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) ''Value.ps1'') }'+"`n"+'Describe ''Windows worker interruption'' { It ''covers every branch'' { '+"`n"+'Start-Sleep -Seconds '+$DelaySeconds+"`n"+($assertions -join "`n")+"`n"+'$IsWindows | Should -BeTrue'+"`n"+'} }'
    Set-Content (Join-Path $fixture 'test/Value.Tests.ps1') $test
}
if($WithStryker){
    $engine=Join-Path $fixture 'engine';[void][IO.Directory]::CreateDirectory((Join-Path $engine 'Fixture.Tests'))
    Set-Content (Join-Path $engine 'Fixture.Engine.csproj') '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup><ItemGroup><Compile Remove="Fixture.Tests/**/*.cs" /></ItemGroup></Project>'
    Set-Content (Join-Path $engine 'Calculator.cs') 'namespace Fixture; public static class Calculator { public static int Value(bool enabled) => enabled ? 1 : 2; }'
    Set-Content (Join-Path $engine 'Fixture.Tests/Fixture.Tests.csproj') @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><IsTestProject>true</IsTestProject><IsPackable>false</IsPackable></PropertyGroup><ItemGroup>
<PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.12.0" /><PackageReference Include="xunit" Version="2.9.3" /><PackageReference Include="xunit.runner.visualstudio" Version="3.1.4" />
<ProjectReference Include="../Fixture.Engine.csproj" /></ItemGroup></Project>
'@
    Set-Content (Join-Path $engine 'Fixture.Tests/CalculatorTests.cs') 'using Xunit; public class CalculatorTests { [Theory] [InlineData(true, 1)] [InlineData(false, 2)] public void KeepsBothBranches(bool enabled, int expected) { Assert.Equal(expected, Fixture.Calculator.Value(enabled)); } }'
    Copy-Item (Join-Path (Split-Path $root) 'QuietCliEcosystem/FrenchExDev.QuietCli.PoSh/engine/dotnet-tools.json') (Join-Path $engine 'dotnet-tools.json')
    @{Project='Fixture.Engine.csproj';TestProject='Fixture.Tests/Fixture.Tests.csproj'}|ConvertTo-Json|Set-Content (Join-Path $engine 'mutator.json')
}
}
$parameters=@{ModulePath=$fixture;SourceRoot=$source;RunRoot=(Join-Path $proof 'runs');WindowsGuestImage=$Image;ContainerConnection=$Connection;MemoryBudgetMiB=6144;WorkerBudget=1;Workers=1;ThrottleLimit=1;SkipStryker=(!$WithStryker);Background=$true}
if($ResumeFrom){$parameters.ResumeFrom=$ResumeFrom}
if($JobTimeoutSeconds){$parameters.WindowsGuestJobTimeoutSeconds=$JobTimeoutSeconds}
$run=Invoke-MutatorRun @parameters
@{Path=$run.Path;Outcome=$run.Outcome;Proof=$proof}|ConvertTo-Json -Compress
