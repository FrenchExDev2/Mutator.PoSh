<#
.SYNOPSIS
Expected behavior for the ContainerDependency tests.

.DESCRIPTION
Resolve transitive manifest dependencies exactly once without importing code. Include active
QuietCli dependencies and reject unsafe names, missing modules, foreign roots and linked paths.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:DependencyModules=Split-Path (Split-Path (Split-Path $PSScriptRoot))
    Import-Module (Join-Path $script:DependencyModules 'FrenchExDev.Mutator.PoSh/FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    function New-DependencyFixture {
        <#
        .SYNOPSIS
        Create a manifest-only dependency contributor that must never be imported.

        .DESCRIPTION
        Its module body throws deliberately. Successful dependency inventory must read metadata without
        executing contributor code.
        #>

        param([string]$Root,[string]$Name,[string]$Dependencies='@()',[string]$Required='@()')
        $directory=Join-Path $Root $Name
        [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllText((Join-Path $directory ($Name+'.psd1')),"@{RootModule='$Name.psm1';ModuleVersion='1.0.0';RequiredModules=$Required;PrivateData=@{Mutator=@{Dependencies=$Dependencies}}}")
        [IO.File]::WriteAllText((Join-Path $directory ($Name+'.psm1')),"throw 'Dependency inventory must never import the target.'")
        $directory
    }
}
Describe 'Container module dependency closure' {
    It 'packages QuietCli from the active ecosystem for Mutator' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Modules=$script:DependencyModules} {
            param($Modules)
            @(Get-MutatorContainerDependency (Join-Path $Modules 'FrenchExDev.Mutator.PoSh'))|Should -BeExactly @(
                'FrenchExDev.Mutator.PoSh','FrenchExDev.QuietCli.PoSh')
            Resolve-MutatorModuleDirectory $Modules 'FrenchExDev.QuietCli.PoSh'|Should -BeExactly (Join-Path $Modules 'QuietCliEcosystem/FrenchExDev.QuietCli.PoSh')
        }
    }
    It 'follows transitive manifest dependencies exactly once without importing their code' {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $a=New-DependencyFixture $root 'FrenchExDev.Tools.FixtureA.PoSh' "@('FrenchExDev.Tools.FixtureB.PoSh','FrenchExDev.Tools.FixtureB.PoSh')"
        $null=New-DependencyFixture $root 'FrenchExDev.Tools.FixtureB.PoSh' -Required "@(@{ModuleName='FrenchExDev.Tools.FixtureC.PoSh';ModuleVersion='1.0.0'},'Pester')"
        $null=New-DependencyFixture $root 'FrenchExDev.Tools.FixtureC.PoSh' -Required "@('FrenchExDev.Tools.FixtureA.PoSh',42)"
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Module=$a} {
            param($Module)
            @(Get-MutatorContainerDependency $Module)|Should -BeExactly @('FrenchExDev.QuietCli.PoSh','FrenchExDev.Tools.FixtureA.PoSh','FrenchExDev.Tools.FixtureB.PoSh','FrenchExDev.Tools.FixtureC.PoSh')
        }
    }
    It 'rejects an unsafe dependency before using it as a filesystem path: <Value>' -ForEach @(
        @{Value="@('../outside')"},@{Value="@('FrenchExDev.Tools../outside.PoSh')"},@{Value='@(42)'},@{Value='@($null)'},@{Value="@('')"}
    ) {
        $directory=New-DependencyFixture (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) 'FrenchExDev.Tools.Fixture.PoSh' $Value
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Module=$directory} {
            param($Module)
            {Get-MutatorContainerDependency $Module}|Should -Throw '*must name FrenchExDev modules*'
        }
    }
    It 'rejects a missing declared dependency instead of emitting an incomplete image recipe' {
        $directory=New-DependencyFixture (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) 'FrenchExDev.Tools.Fixture.PoSh' "@('FrenchExDev.Tools.Absent.PoSh')"
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Module=$directory} {param($Module);{Get-MutatorContainerDependency $Module}|Should -Throw}
    }
    It 'retains the default runtime dependencies when no contributor metadata exists' {
        $directory=New-DependencyFixture (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) 'FrenchExDev.Tools.Minimal.PoSh'
        $name=Split-Path $directory -Leaf
        [IO.File]::WriteAllText((Join-Path $directory ($name+'.psd1')),"@{RootModule='$name.psm1';ModuleVersion='1.0.0'}")
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Module=$directory} {
            param($Module)
            @(Get-MutatorContainerDependency $Module)|Should -BeExactly @('FrenchExDev.QuietCli.PoSh','FrenchExDev.Tools.Minimal.PoSh')
        }
    }
    It 'rejects foreign root modules and linked sibling dependencies' {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $foreign=New-DependencyFixture $root 'Foreign.Module'
        $directory=New-DependencyFixture $root 'FrenchExDev.Tools.Fixture.PoSh' "@('FrenchExDev.Tools.Linked.PoSh')"
        $external=Join-Path $root 'outside';[void][IO.Directory]::CreateDirectory($external)
        $link=Join-Path $root 'FrenchExDev.Tools.Linked.PoSh'
        $kind=if($IsWindows){'Junction'}else{'SymbolicLink'}
        $null=New-Item -ItemType $kind -Path $link -Target $external -ErrorAction Stop
        try {
            InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Module=$directory;Foreign=$foreign} {
                param($Module,$Foreign)
                {Get-MutatorContainerDependency $Foreign}|Should -Throw '*must name FrenchExDev modules*'
                {Get-MutatorContainerDependency $Module}|Should -Throw '*real module directories*'
            }
        } finally {Remove-Item -LiteralPath $link -Force}
    }
}
