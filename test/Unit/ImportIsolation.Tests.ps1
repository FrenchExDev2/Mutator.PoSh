BeforeAll {
    $script:Root=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:Root 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    Import-Module (Join-Path (Split-Path $script:Root) 'FrenchExDev.DevPoSh.PoSh/FrenchExDev.DevPoSh.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Import reuse stays inside a single mutant' {
    BeforeEach {
        $script:SavedEpoch=Get-Variable MutatorEpoch -Scope Global -ValueOnly -ErrorAction Ignore
        $script:SavedCache=Get-Variable MutatorImports -Scope Global -ValueOnly -ErrorAction Ignore
        $global:MutatorEpoch=[guid]::NewGuid().ToString('N')
        $global:MutatorImports=$null
        $script:Fixture=New-DevPoShModule -Name ('Fixture.Import'+[guid]::NewGuid().ToString('N')) -Path $TestDrive -Function Get-Sample
        [IO.File]::WriteAllText((Join-Path $script:Fixture.Path 'src/Public/Get-Sample.ps1'),'function Get-Sample { 1 }')
        [IO.File]::WriteAllText((Join-Path $script:Fixture.Path 'src/Private/State.ps1'),'$script:State = @{Items=[Collections.Generic.List[object]]::new();Lookup=[ordered]@{Name="initial"}}')
    }
    AfterEach {
        Get-Module $script:Fixture.Name -All | Remove-Module -Force
        $global:MutatorEpoch=$script:SavedEpoch
        $global:MutatorImports=$script:SavedCache
    }
    It 'restores nested mutable state and removes added variables without reimporting the same mutant' {
        Import-MutatorTestModule @($script:Fixture.Manifest)
        $first=Get-Module $script:Fixture.Name
        & $first {$script:State.Items.Add('leak');$script:State.Lookup.Name='changed';$script:Added='leak'}
        Import-MutatorTestModule @($script:Fixture.Manifest)
        [object]::ReferenceEquals($first,(Get-Module $script:Fixture.Name)) | Should -BeTrue
        $state=& $first {@{Items=$script:State.Items.Count;Name=$script:State.Lookup.Name;Added=[bool](Get-Variable Added -Scope Script -ErrorAction Ignore)}}
        $state.Items | Should -Be 0
        $state.Name | Should -BeExactly initial
        $state.Added | Should -BeFalse
        $global:MutatorImports.Restores | Should -Be 1
    }
    It 'reloads the changed implementation when the next mutant epoch begins' {
        Import-MutatorTestModule @($script:Fixture.Manifest)
        Get-Sample | Should -Be 1
        [IO.File]::WriteAllText((Join-Path $script:Fixture.Path 'src/Public/Get-Sample.ps1'),'function Get-Sample { 2 }')
        $global:MutatorEpoch=[guid]::NewGuid().ToString('N')
        Import-MutatorTestModule @($script:Fixture.Manifest)
        Get-Sample | Should -Be 2
        $global:MutatorImports.Loads | Should -Be 2
    }
    It 'reloads after a test replaced function code or removed the module' {
        Import-MutatorTestModule @($script:Fixture.Manifest)
        $first=Get-Module $script:Fixture.Name
        & $first {Set-Item Function:script:Get-Sample {99}}
        Import-MutatorTestModule @($script:Fixture.Manifest)
        Get-Sample | Should -Be 1
        $global:MutatorImports.Fallbacks | Should -Be 1
        Remove-Module $script:Fixture.Name -Force
        Import-MutatorTestModule @($script:Fixture.Manifest)
        Get-Sample | Should -Be 1
    }
    It 'falls back to fresh imports for opaque state and stays cold outside mutation runs' {
        [IO.File]::WriteAllText((Join-Path $script:Fixture.Path 'src/Private/State.ps1'),'$script:Opaque = [IO.MemoryStream]::new()')
        Import-MutatorTestModule @($script:Fixture.Manifest)
        $global:MutatorImports.Reusable | Should -BeFalse
        $first=Get-Module $script:Fixture.Name
        Import-MutatorTestModule @($script:Fixture.Manifest)
        [object]::ReferenceEquals($first,(Get-Module $script:Fixture.Name)) | Should -BeFalse
        Remove-Variable MutatorEpoch -Scope Global
        Import-MutatorTestModule @($script:Fixture.Manifest)
        $global:MutatorImports.Reusable | Should -BeFalse
    }
}
