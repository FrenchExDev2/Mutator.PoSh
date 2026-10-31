<#
.SYNOPSIS
Expected behavior for the ProductionScope tests.

.DESCRIPTION
Include manifest entrypoint, root scripts and executable resources while excluding declarative data
and artifacts. Missing or escaping entrypoints fail before configuration generation.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Complete production scope' {
    It 'includes executable resources and root scripts while keeping declarative data and test artifacts separate' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $module=Join-Path $Root 'Fixture.Scope'
            foreach($path in @('src/Public','resources/jobs','test/Unit','test/Artifacts')){[void][IO.Directory]::CreateDirectory((Join-Path $module $path))}
            Set-Content (Join-Path $module 'Fixture.Scope.psd1') "@{RootModule='Fixture.Scope.psm1';ModuleVersion='1.0.0'}"
            foreach($path in @('Fixture.Scope.psm1','Setup.ps1','src/Public/A.ps1','resources/jobs/Worker.ps1','resources/Extra.psm1','test/Unit/A.Tests.ps1','test/Artifacts/Generated.ps1')){Set-Content (Join-Path $module $path) '# fixture'}
            Set-Content (Join-Path $module 'resources/catalogue.psd1') '@{}'
            $scope=@(Get-MutatorProductionFile $module|ForEach-Object {[IO.Path]::GetRelativePath($module,$_).Replace('\','/')})
            $scope|Should -Be @('Fixture.Scope.psm1','resources/Extra.psm1','resources/jobs/Worker.ps1','Setup.ps1','src/Public/A.ps1')
            $result=New-MutatorConfiguration -ModulePath $module
            $result.SourceFiles|Should -Be 5
            $configuration=Read-MutatorJson $result.Path
            $configuration.coveredLinesOnly|Should -BeFalse
            foreach($source in $configuration.mutate){@($configuration.tests[$source])|Should -Be @('Fixture.Scope/test/Unit/A.Tests.ps1')}
        }
    }
    It 'refuses a missing entry point or one outside the module before generating configuration' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $module=Join-Path $Root 'Fixture.Invalid';[void][IO.Directory]::CreateDirectory($module)
            Set-Content (Join-Path $module 'Fixture.Invalid.psd1') "@{RootModule='../outside.psm1'}"
            {Get-MutatorProductionFile $module}|Should -Throw '*inside*'
            Set-Content (Join-Path $module 'Fixture.Invalid.psd1') "@{RootModule='missing.psm1'}"
            {Get-MutatorProductionFile $module}|Should -Throw '*missing*'
        }
    }
}
