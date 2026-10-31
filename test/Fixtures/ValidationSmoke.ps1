#requires -Version 7.6
param([ValidateSet('Linux','Windows')][string]$OS='Linux',[string]$Connection='podman-frenchexdev-root',
    [ValidateSet('None','Assertion','Survivor')][string]$FailureMode='None')
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($OS,$Connection,$FailureMode)
    $proof=Join-Path $script:MutatorRoot ('test/Artifacts/development/validation-smoke-'+$OS.ToLowerInvariant()+'-'+$FailureMode.ToLowerInvariant()+'-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $source=Join-Path $proof 'source';$parent=Split-Path $script:MutatorRoot
    $dependencies=@('FrenchExDev.Mutator.PoSh','FrenchExDev.DevPoSh.PoSh','QuietCliEcosystem/FrenchExDev.QuietCli.PoSh','QuietCliEcosystem/FrenchExDev.QuietCli.PoSh')
    foreach($name in $dependencies){Copy-MutatorTree (Join-Path $parent $name) (Join-Path $source $name)}
    $name='Fixture.Validation';$subject=Join-Path $source $name
    foreach($folder in @('src','test/Unit','test/Integration')){[void][IO.Directory]::CreateDirectory((Join-Path $subject $folder))}
    [IO.File]::WriteAllText((Join-Path $subject ($name+'.psd1')),"@{RootModule='Fixture.Validation.psm1';ModuleVersion='1.0.0';GUID='bfa0ce20-013e-4d4b-bd21-9a6f0f38342f';FunctionsToExport=@('Get-ValidationValue')}")
    [IO.File]::WriteAllText((Join-Path $subject ($name+'.psm1')),'. (Join-Path $PSScriptRoot ''src/Value.ps1'')')
    [IO.File]::WriteAllText((Join-Path $subject 'src/Value.ps1'),"function Get-ValidationValue {`n    param([bool]`$Enabled)`n    if (`$Enabled) { 42 } else { 7 }`n}`n")
    $assertion=if($FailureMode -eq 'Assertion'){'43'}else{'42'}
    $unit=@'
BeforeAll {
    $root=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $root 'Fixture.Validation.psd1') -Force
}
Describe 'Validation fixture' {
    It 'checks the enabled value' { Get-ValidationValue -Enabled $true | Should -Be __EXPECTED__ }
    It 'checks the disabled value' { Get-ValidationValue -Enabled $false | Should -Be 7 }
}
'@
    if($FailureMode -eq 'Survivor'){$unit=$unit.Replace('Should -Be __EXPECTED__','Should -BeGreaterThan 0').Replace('Should -Be 7','Should -BeGreaterThan 0')}
    [IO.File]::WriteAllText((Join-Path $subject 'test/Unit/Value.Tests.ps1'),$unit.Replace('__EXPECTED__',$assertion))
    [IO.File]::WriteAllText((Join-Path $subject 'test/Integration/Value.Tests.ps1'),$unit.Replace('__EXPECTED__',$assertion).Replace("Describe 'Validation fixture'","Describe 'Validation integration'"))
    $null=New-MutatorConfiguration -ModulePath $subject -Dependency $dependencies
    $run=@{Id=[guid]::NewGuid().ToString('N');Path=$proof;Outcome='Running';Platforms=@{Linux=@{Outcome='NotSelected'};Windows=@{Outcome='NotSelected'};MacOS=@{Outcome='NotSelected'}}}
    $run.Platforms[$OS]=@{Outcome='Running';Phase='Preparing';Suites=@{}}
    $request=@{SchemaVersion=1;RunId=$run.Id;OS=$OS;Test=@('Unit','Integration','Mutations');Modules=@($name);Workers=1;WorkerBudget=2;MemoryBudgetMiB=6144;SourceSha256=(Get-MutatorSourceSnapshot $source).Sha256}
    try{
        $r=Invoke-MutatorValidationContainer -Platform $OS -Source $source -Request $request -OutputDirectory (Join-Path $proof $OS.ToLowerInvariant()) -Connection $Connection -Run $run
        $run.Platforms[$OS]=$r;$run.Outcome=$r.Outcome
    }catch{$run.Outcome='Failed';$run.Error=$_.Exception.Message}
    Write-MutatorValidationReport $run
    @{Outcome=$run.Outcome;Proof=$proof;FailureMode=$FailureMode;Error=$run['Error'];State=$run.Platforms[$OS]}|ConvertTo-Json -Depth 10 -Compress
    if($run.Outcome -cne 'Success'){exit 1}
} $OS $Connection $FailureMode
