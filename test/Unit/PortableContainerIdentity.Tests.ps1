<#
.SYNOPSIS
Expected behavior for the PortableContainerIdentity tests.

.DESCRIPTION
Canonical container JSON uses LF independent of host while preserving Unicode and newlines inside
data. Equivalent inputs must retain the same identity.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Portable container definition identities' {
    It 'uses canonical LF formatting while preserving data newlines and Unicode' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $value=[ordered]@{Z='last';A=@([ordered]@{Text="é`r`nsecond line";Number=42})}
            $text=ConvertTo-MutatorContainerJson $value
            $text.Contains("`r")|Should -BeFalse -Because 'Formatting bytes enter the image identity on both Windows and Linux.'
            $parsed=$text|ConvertFrom-Json -AsHashtable
            $parsed.A[0].Text|Should -BeExactly "é`r`nsecond line"
            $parsed.A[0].Number|Should -Be 42
            $text|Should -BeExactly (ConvertTo-MutatorContainerJson @{A=@(@{Number=42;Text="é`r`nsecond line"});Z='last'})
        }
    }
}
