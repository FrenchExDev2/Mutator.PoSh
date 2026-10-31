<#
.SYNOPSIS
Expected behavior for the ContainerQualification tests.

.DESCRIPTION
Qualification requires an immutable image, matching source/runtime identity, valid report and
successful native execution. WhatIf allocates nothing and existing evidence or source drift cannot
be overwritten or accepted.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Container qualification driver' {
BeforeEach {
    $script:QualificationOutput=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Output=$script:QualificationOutput} {
        param($Output)
        $script:ProofOutput=$Output
        $script:ProofImageOs='linux'
        $script:ProofImageLabel='FrenchExDev.Tools.Journalctl.PoSh'
        $script:ProofImageId='a'*64
        $script:ProofRunOutcome='Success'
        $script:ProofWriteReport=$true
        $script:ProofReport=@{Passed=4;Failed=0;Skipped=0;DiscoveryErrors=0;MemoryLimitBytes='2147483648';MemoryPeakBytes='100000000'}
        Mock Get-MutatorSourceSnapshot { @{Sha256=('b'*64)} }
        Mock Invoke-MutatorContainerCommand {
            param($Arguments)
            if($Arguments[0] -eq 'image'){
                $image=@{Os=$script:ProofImageOs;Id=$script:ProofImageId;Config=@{Labels=@{'org.frenchexdev.mutator.module'=$script:ProofImageLabel}}}
                return @{Outcome='Success';Stdout=(ConvertTo-Json -InputObject @($image) -Depth 5 -Compress)}
            }
            if($Arguments[0] -ne 'run'){throw 'Unexpected Podman invocation'}
            if($script:ProofWriteReport){Write-MutatorJson (Join-Path $script:ProofOutput 'qualification.json') $script:ProofReport}
            @{Outcome=$script:ProofRunOutcome;ExitCode=$(if($script:ProofRunOutcome -eq 'Success'){0}else{1});Stdout='retained stdout';Stderr='retained stderr'}
        }
    }
}
    It 'normalizes the profile and runs an immutable image with the requested limits and pinned SDK' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Output=$script:QualificationOutput} {
            param($Output)
            $script:ProofReport.MemoryLimitBytes='536870912'
            $result=Test-MutatorContainerImage -Image 'localhost/mutable:tag' -Profile jOuRnAlCtL -OutputDirectory $Output -Connection fixture -MemoryMiB 512 -Cpus 3
            $result.Outcome | Should -BeExactly Success
            $result.Profile | Should -BeExactly Journalctl
            $result.Passed | Should -Be 4
            $result.ImageId | Should -BeExactly ('a'*64)
            $result.MemoryLimitBytes | Should -Be 536870912
            $result.MemoryPeakBytes | Should -Be 100000000
            (Get-Content $result.StdoutLog -Raw) | Should -BeExactly 'retained stdout'
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -Exactly -ParameterFilter {
                $Arguments[0] -eq 'run' -and $Arguments -contains ('a'*64) -and $Arguments -notcontains 'localhost/mutable:tag' -and
                $Arguments[$Arguments.IndexOf('--memory')+1] -eq '512m' -and $Arguments[$Arguments.IndexOf('--memory-swap')+1] -eq '512m' -and
                $Arguments[$Arguments.IndexOf('--cpus')+1] -eq '3' -and
                $Arguments[$Arguments.IndexOf('-ExpectedDotnetVersion')+1] -eq '10.0.402' -and
                $Arguments -contains '/proof/Test-GeneratedJournalctlImage.ps1' -and $Connection -eq 'fixture'
            }
        }
    }
    It 'keeps the Ag profile available without passing Journalctl-only parameters' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Output=$script:QualificationOutput} {
            param($Output)
            $script:ProofImageLabel='FrenchExDev.Tools.Ag.PoSh'
            $result=Test-MutatorContainerImage -Image fixture -Profile ag -OutputDirectory $Output
            $result.Profile | Should -BeExactly Ag
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'run' -and $Arguments -contains '/proof/Test-GeneratedAgImage.ps1' -and $Arguments -notcontains '-ExpectedDotnetVersion'}
        }
    }
    It 'rejects a mismatched <Field> before starting a container' -ForEach @(
        @{Field='ProofImageOs';Value='windows'}
        @{Field='ProofImageId';Value='short-id'}
        @{Field='ProofImageLabel';Value='FrenchExDev.Tools.Ag.PoSh'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Output=$script:QualificationOutput;Field=$Field;Value=$Value} {
            param($Output,$Field,$Value)
            Set-Variable -Name $Field -Value $Value -Scope Script
            {Test-MutatorContainerImage -Image fixture -Profile Journalctl -OutputDirectory $Output} | Should -Throw '*does not match*'
            (Read-MutatorJson (Join-Path $Output 'qualification-run.json')).Outcome | Should -BeExactly Failed
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'run'}
        }
    }
    It 'rejects a process failure even if that process wrote a green report' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Output=$script:QualificationOutput} {
            param($Output)
            $script:ProofRunOutcome='TimedOut'
            {Test-MutatorContainerImage -Image fixture -Profile Journalctl -OutputDirectory $Output} | Should -Throw '*retained receipt*'
            $receipt=Read-MutatorJson (Join-Path $Output 'qualification-run.json')
            $receipt.Outcome | Should -BeExactly TimedOut
            $receipt.Contains('Passed') | Should -BeFalse
            (Get-Content $receipt.StderrLog -Raw) | Should -BeExactly 'retained stderr'
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'run'}
        }
    }
    It 'fails closed for an invalid <Field> result' -ForEach @(
        @{Field='Passed';Value=0}
        @{Field='Passed';Value='unknown'}
        @{Field='Passed';Value=0.5}
        @{Field='Failed';Value=1}
        @{Field='Failed';Value=-1}
        @{Field='Failed';Value='unknown'}
        @{Field='Skipped';Value=1}
        @{Field='DiscoveryErrors';Value=1}
        @{Field='MemoryLimitBytes';Value='max'}
        @{Field='MemoryLimitBytes';Value='1073741824'}
        @{Field='MemoryPeakBytes';Value='0'}
        @{Field='MemoryPeakBytes';Value='not measured'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Output=$script:QualificationOutput;Field=$Field;Value=$Value} {
            param($Output,$Field,$Value)
            $script:ProofReport[$Field]=$Value
            {Test-MutatorContainerImage -Image fixture -Profile Journalctl -OutputDirectory $Output} | Should -Throw
            $receipt=Read-MutatorJson (Join-Path $Output 'qualification-run.json')
            $receipt.Outcome | Should -BeExactly Failed
            $receipt.Contains('Passed') | Should -BeFalse
        }
    }
    It 'fails a successful process without a test report' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Output=$script:QualificationOutput} {
            param($Output)
            $script:ProofWriteReport=$false
            {Test-MutatorContainerImage -Image fixture -Profile Journalctl -OutputDirectory $Output} | Should -Throw '*empty, incomplete or failed*'
            (Read-MutatorJson (Join-Path $Output 'qualification-run.json')).Outcome | Should -BeExactly Failed
        }
    }
    It 'refuses source drift while the image runs' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Output=$script:QualificationOutput} {
            param($Output)
            $script:ProofSourceCalls=0
            Mock Get-MutatorSourceSnapshot {$script:ProofSourceCalls++;@{Sha256=$(if($script:ProofSourceCalls -eq 1){'before'}else{'after'})}}
            {Test-MutatorContainerImage -Image fixture -Profile Journalctl -OutputDirectory $Output} | Should -Throw '*sources changed*'
            (Read-MutatorJson (Join-Path $Output 'qualification-run.json')).Outcome | Should -BeExactly Failed
        }
    }
    It 'preserves existing evidence before making any Podman call' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Output=$script:QualificationOutput} {
            param($Output)
            $path=Join-Path $Output 'qualification.json'
            Write-MutatorJson $path @{Passed=4}
            {Test-MutatorContainerImage -Image fixture -Profile Journalctl -OutputDirectory $Output} | Should -Throw '*new output directory*'
            (Read-MutatorJson $path).Passed | Should -Be 4
            Should -Invoke Invoke-MutatorContainerCommand -Times 0
        }
    }
    It 'honors WhatIf without creating artifacts or inspecting an image' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Output=$script:QualificationOutput} {
            param($Output)
            $null=Test-MutatorContainerImage -Image fixture -Profile Journalctl -OutputDirectory $Output -WhatIf
            Test-Path $Output | Should -BeFalse
            Should -Invoke Invoke-MutatorContainerCommand -Times 0
        }
    }
}
