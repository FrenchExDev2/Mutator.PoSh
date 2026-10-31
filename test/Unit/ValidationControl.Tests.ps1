<#
.SYNOPSIS
Expected behavior for the ValidationControl tests.

.DESCRIPTION
Accept only owner-matched stop signals, wait for every child worker and then export partial proof.
Copy failures remain secondary and WhatIf must not write stop files.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll { Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking }
Describe 'Identity-bound validation stop and proof preservation' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        It 'accepts only the stop signal belonging to this validation run' {
            $id='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            Test-MutatorValidationStop $TestDrive $id|Should -BeFalse
            Write-MutatorJson (Join-Path $TestDrive 'stop.json') @{RunId='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}
            Test-MutatorValidationStop $TestDrive $id|Should -BeFalse
            Write-MutatorJson (Join-Path $TestDrive 'stop.json') @{RunId=$id}
            Test-MutatorValidationStop $TestDrive $id|Should -BeTrue
            {Assert-MutatorValidationActive $TestDrive $id}|Should -Throw '*stopped by its owner*'
        }
        It 'reads only the last two progress records and closes its shared reader' {
            $path=Join-Path $TestDrive 'progress.jsonl'
            [IO.File]::WriteAllText($path,(@('first','é 🧪','third')-join [Environment]::NewLine)+[Environment]::NewLine)
            @(Read-MutatorProgressTail $path)|Should -Be @('é 🧪','third')
            $exclusive=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $exclusive.Dispose()
        }
        It 'forwards a public cooperative stop without issuing native container commands' {
            $directory=Join-Path $TestDrive 'public-stop'
            $reports=Join-Path $directory 'linux/reports'
            [void][IO.Directory]::CreateDirectory($directory)
            $id='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            Write-MutatorJson (Join-Path $directory 'summary.json') @{Id=$id;Path=$directory;Outcome='Running';Platforms=@{Linux=@{Outcome='Running';Reports=$reports};Windows=@{Outcome='NotSelected'}}}
            Mock Invoke-MutatorContainerCommand {throw 'native command must not run for a cooperative request'}
            $r=Stop-MutatorGitImageValidation -Path $directory
            $r.Outcome|Should -BeExactly StopRequested
            (Read-MutatorJson (Join-Path $directory 'stop.json')).RunId|Should -BeExactly $id
            (Read-MutatorJson (Join-Path $reports 'stop.json')).RunId|Should -BeExactly $id
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -Exactly
        }
        It 'honors WhatIf without creating stop files' {
            $directory=Join-Path $TestDrive 'whatif-stop'
            [void][IO.Directory]::CreateDirectory($directory)
            Write-MutatorJson (Join-Path $directory 'summary.json') @{Id=('a'*32);Path=$directory;Outcome='Running';Platforms=@{Linux=@{Outcome='Running'}}}
            Stop-MutatorGitImageValidation -Path $directory -WhatIf
            Test-Path (Join-Path $directory 'stop.json')|Should -BeFalse
        }
        Context 'mutation child shutdown' {
            BeforeEach {
                $script:StopSteps=[Collections.Generic.List[string]]::new()
                $script:StopReads=0
                $script:StopSource=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
                $script:StopDestination=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
                [void][IO.Directory]::CreateDirectory($script:StopSource)
                Mock Stop-MutatorRun {$script:StopSteps.Add('request')}
                Mock Get-MutatorRun {
                    $script:StopReads++
                    [pscustomobject]@{Outcome=$(if($script:StopReads -eq 1){'Running'}else{'Interrupted'});Process=$null;Packages=@()}
                }
                Mock Get-MutatorRunWorkerIdentity {}
                Mock Test-MutatorProcess {$false}
                Mock Start-Sleep {$script:StopSteps.Add('wait')}
                Mock Export-MutatorReport {$script:StopSteps.Add('export')}
                Mock Copy-MutatorValidationMutationProof {
                    param($RunPath,$Destination)
                    $script:StopSteps.Add('copy')
                    [void][IO.Directory]::CreateDirectory((Join-Path $Destination 'packages/p0000'))
                    [IO.File]::WriteAllText((Join-Path $Destination 'packages/p0000/mutation.json'),'{"Outcome":"Interrupted"}')
                }
            }
            It 'waits for shutdown before exporting and copying the retained partial result' {
                $r=Stop-MutatorValidationMutation $script:StopSource $script:StopDestination -ValidationRunId 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                $r.Stopped|Should -BeTrue
                $r.ReportsCopied|Should -BeTrue
                $r.PartialReportAvailable|Should -BeTrue
                $script:StopSteps -join ','|Should -BeExactly 'request,wait,export,copy'
                Should -Invoke Stop-MutatorRun -Times 1 -Exactly
            }
            It 'does not copy a still-running child and returns a retention reason after the grace period' {
                Mock Get-MutatorRun {[pscustomobject]@{Outcome='Running';Process=$null;Packages=@()}}
                $r=Stop-MutatorValidationMutation $script:StopSource $script:StopDestination -ValidationRunId 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -TimeoutSeconds 0
                $r.Stopped|Should -BeFalse
                $r.ReportsCopied|Should -BeFalse
                $r.Error|Should -Match 'sandbox is retained'
                Should -Invoke Copy-MutatorValidationMutationProof -Times 0 -Exactly
                Should -Invoke Export-MutatorReport -Times 0 -Exactly
            }
            It 'does not trust a terminal state while an owned worker is still alive' {
                Mock Get-MutatorRun {[pscustomobject]@{Outcome='Interrupted';Process=@{Id=123;StartedUtc='x'};Packages=@()}}
                Mock Test-MutatorProcess {$true}
                $r=Stop-MutatorValidationMutation $script:StopSource $script:StopDestination -ValidationRunId 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -TimeoutSeconds 0
                $r.Stopped|Should -BeFalse
                Should -Invoke Copy-MutatorValidationMutationProof -Times 0 -Exactly
            }
            It 'preserves stopped state and reports a secondary proof-copy failure without forcing the child' {
                Mock Copy-MutatorValidationMutationProof {throw 'proof replacement remains unavailable'}
                $r=Stop-MutatorValidationMutation $script:StopSource $script:StopDestination -ValidationRunId 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                $r.Stopped|Should -BeTrue
                $r.ReportsCopied|Should -BeFalse
                $r.Error|Should -BeExactly 'proof replacement remains unavailable'
                Should -Invoke Stop-MutatorRun -Times 1 -Exactly -ParameterFilter {!$Force}
            }
        }
    }
}