<#
.SYNOPSIS
Expected behavior for the ToolIdentity tests.

.DESCRIPTION
Fresh processes using different private caches must produce identical adapter identity and
executable hashes. Tests require the installed pinned tool, not an arbitrary compatible replacement.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Portable mutation tool identity' {
    It 'has identical adapted bytes in two fresh processes and separate cache roots' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $identities=@(foreach($cache in @('first','second')){
                # The script and module paths are absolute. Use the short fixture
                # working directory: nested proof copies can exceed Windows' cwd limit.
                $result=Invoke-MutatorNative (Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})) @('-NoProfile','-File',(Join-Path $script:MutatorRoot 'test/Fixtures/ToolIdentity.ps1'),'-CacheRoot',(Join-Path $Root $cache)) $Root 120
                $result.Outcome|Should -BeExactly Success -Because ($result.Failure|ConvertTo-Json -Depth 8 -Compress)
                $result.Stdout|ConvertFrom-Json -AsHashtable -DateKind String
            })
            $identities[0].Sha256|Should -BeExactly $identities[1].Sha256
            $identities[0].Adapter|Should -BeExactly $identities[1].Adapter
        }
    }
}
