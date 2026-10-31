<#
.SYNOPSIS
Expected behavior for the GuestSeed tests.

.DESCRIPTION
Independent overlay volumes must share only the immutable seed, with verified backing identity.
Native probe failure or stale/foreign proof cannot pass; WhatIf creates no volumes.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Offline prepared Windows seed isolation gate' {
    BeforeEach {
        $script:SeedOutput=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        InModuleScope FrenchExDev.Mutator.PoSh {
            $script:SeedRunOutcome='Success';$script:SeedForeignId=$false;$script:SeedBacking='/seed/storage/data.qcow2'
            Mock Invoke-MutatorContainerCommand {
                param($Arguments)
                if($Arguments[0] -eq 'image'){return @{Outcome='Success';Stdout=('[{"Os":"linux","Id":"'+('a'*64)+'","Config":{"Labels":{"org.frenchexdev.mutator.base":"windows-seed"}}}]')}}
                if($Arguments[0] -eq 'volume'){return @{Outcome='Success';Stdout=$Arguments[-1]}}
                $mount=@($Arguments|Where-Object {$_ -like '*:/shared'})[0]
                $share=$mount.Substring(0,$mount.Length-':/shared'.Length)
                $mode=@($Arguments|Where-Object {$_ -like 'MUTATOR_OVERLAY_PROBE=*'})[0].Substring('MUTATOR_OVERLAY_PROBE='.Length)
                $id=@($Arguments|Where-Object {$_ -like 'MUTATOR_OVERLAY_RUN=*'})[0].Substring('MUTATOR_OVERLAY_RUN='.Length)
                if($script:SeedForeignId){$id='stale'}
                Write-MutatorJson (Join-Path $share 'overlay-proof.json') @{Outcome='Success';Mode=$mode;RunId=$id;OverlayBytes=196608;WindowsBooted=$false}
                Write-MutatorJson (Join-Path $share 'disk-info.json') @{format='qcow2';'backing-filename'=$script:SeedBacking}
                @{Outcome=$script:SeedRunOutcome;Stdout='retained isolation log';Stderr=''}
            }
        }
    }
    It 'runs two isolated volumes against an immutable seed without Windows startup' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Output=$script:SeedOutput} {
            param($Output)
            $result=Test-MutatorGuestSeed -Image 'mutable-tag' -OutputDirectory $Output -Connection fixture
            $result.Outcome|Should -BeExactly Success
            $result.WindowsBooted|Should -BeFalse
            $result.Clones.Count|Should -Be 2
            $result.Clones[0].Volume|Should -Not -BeExactly $result.Clones[1].Volume
            Should -Invoke Invoke-MutatorContainerCommand -Times 2 -ParameterFilter {$Arguments[0] -eq 'run' -and $Arguments -contains ('a'*64) -and $Arguments -contains '512m' -and $Arguments -notcontains 'mutable-tag'}
        }
    }
    It 'refuses a green file from a failed native isolation probe' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Output=$script:SeedOutput} {
            param($Output)
            $script:SeedRunOutcome='Failed'
            {Test-MutatorGuestSeed -Image fixture -OutputDirectory $Output}|Should -Throw '*isolation probe failed*'
            (Read-MutatorJson (Join-Path $Output 'seed-test.json')).Outcome|Should -BeExactly Failed
        }
    }
    It 'rejects a stale probe receipt or a foreign backing chain' -ForEach @(@{Fault='identity'},@{Fault='backing'}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Output=$script:SeedOutput;Fault=$Fault} {
            param($Output,$Fault)
            if($Fault -eq 'identity'){$script:SeedForeignId=$true}else{$script:SeedBacking='/foreign/disk.qcow2'}
            {Test-MutatorGuestSeed -Image fixture -OutputDirectory $Output}|Should -Throw '*backing chain was not proven*'
            (Read-MutatorJson (Join-Path $Output 'seed-test.json')).Outcome|Should -BeExactly Failed
        }
    }
    It 'honors WhatIf without creating probe volumes' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Output=$script:SeedOutput} {
            param($Output)
            $null=Test-MutatorGuestSeed -Image fixture -OutputDirectory $Output -WhatIf
            Test-Path $Output|Should -BeFalse
            Should -Invoke Invoke-MutatorContainerCommand -Times 0
        }
    }
}
