<#
.SYNOPSIS
Expected behavior for the PowerShellGate tests.

.DESCRIPTION
Accept only complete nonempty consistent raw detection. Partial, excluded, surviving, unmapped or
contradictory mutation evidence must fail even if the displayed score rounds to 100.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'A rounded one hundred is never a complete mutation gate' {
    It 'accepts complete, nonempty evidence with every non-equivalent mutant detected' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $detail=@{total=2;killed=2;survived=0;mutationScore=100;skippedAsUncovered=0;staleEquivalents=@();filesWithoutTestMapping=@();declaredEquivalent=0}
            $result=@{Total=2;Killed=2;Score=100;ExitCode=0}
            Test-MutatorPowerShellGate $detail $result|Should -BeTrue
        }
    }
    It 'rejects incomplete evidence: <Fault>' -ForEach @(
        @{Fault='rounded survivor'},@{Fault='partial'},@{Fault='recheck'},@{Fault='empty'},@{Fault='skipped'},@{Fault='stale'},@{Fault='unmapped'},
        @{Fault='tool'},@{Fault='score'},@{Fault='counter'},@{Fault='missing field'},@{Fault='missing report'},@{Fault='excluded equivalence'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Fault=$Fault} {
            param($Fault)
            $detail=@{total=2;killed=2;survived=0;mutationScore=100;skippedAsUncovered=0;staleEquivalents=@();filesWithoutTestMapping=@();declaredEquivalent=0}
            $result=@{Total=2;Killed=2;Score=100;ExitCode=0}
            switch($Fault){
                'rounded survivor' {$detail.total=2001;$detail.killed=2000;$detail.survived=1;$result.Total=2001;$result.Killed=2000}
                partial {$detail.mode='Partial'}
                recheck {$detail.mode='Recheck'}
                empty {$detail.total=0;$detail.killed=0;$result.Total=0;$result.Killed=0}
                skipped {$detail.skippedAsUncovered=1}
                stale {$detail.staleEquivalents=@('stale declaration')}
                unmapped {$detail.filesWithoutTestMapping=@('forgotten.ps1')}
                tool {$result.ExitCode=1}
                score {$result.Score=99.9}
                counter {$result.Killed=1}
                'missing field' {$detail.Remove('survived')}
                'missing report' {$detail=$null}
                'excluded equivalence' {$detail.declaredEquivalent=1}
            }
            Test-MutatorPowerShellGate $detail $result|Should -BeFalse
        }
    }
}
