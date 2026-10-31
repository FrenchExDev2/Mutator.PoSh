<#
.SYNOPSIS
Expected behavior for the RecheckIsolation tests.

.DESCRIPTION
Route each target to its mandatory runtime with a frozen read-only baseline and one worker. Host
execution, changed inputs and missing summaries fail; retained survivors remain diagnostic rather
than a full score.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Public recheck uses the required isolated scheduler' {
    It 'routes <Target> to <Runtime> and preserves diagnostic-only semantics' -ForEach @(
        @{Target='Windows';Runtime='WindowsSandbox'},@{Target='Linux';Runtime='Podman'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=(Join-Path $TestDrive $Target);Target=$Target;Runtime=$Runtime} {
            param($Root,$Target,$Runtime)
            $baseline=Join-Path $Root 'baseline.json'
            Write-MutatorJson $baseline @{survivors=@(@{Id=1})}
            $before=(Get-FileHash $baseline).Hash
            Mock Invoke-MutatorRecheckCore {throw 'Public recheck must never execute the mutation tool on the host.'}
            Mock Invoke-MutatorRun {
                param($ModulePath,$RecheckFrom,$RunRoot,$OS,$ContainerBaseImage,$Workers,$WorkerBudget,$SkipStryker,$Background)
                $OS|Should -BeExactly $Target
                $RecheckFrom|Should -BeExactly $baseline
                $Workers|Should -Be 1
                $WorkerBudget|Should -Be 1
                $SkipStryker|Should -BeTrue
                $ContainerBaseImage|Should -BeExactly 'local-runtime'
                $runPath=Join-Path $RunRoot 'owned'
                Write-MutatorJson (Join-Path $runPath 'packages/p0/mutation.recheck.json') @{mode='Recheck';rechecked=1;nowKilled=1;survivors=@()}
                [pscustomobject]@{Path=$runPath;Outcome='Success';Mode='Recheck';Isolation=$Runtime;Packages=@(@{Id='p0';Error=$null;Recheck=@{Outcome='Success';BaselineSha256=$before;SourceSha256='source';Rechecked=1;NowKilled=1;Survived=0}})}
            }
            $result=Invoke-MutatorRecheck -ModulePath $script:MutatorRoot -ReportPath $baseline -OS $Target -ContainerBaseImage local-runtime -OutputDirectory (Join-Path $Root 'reports')
            $result.Mode|Should -BeExactly Recheck
            $result.Isolation|Should -BeExactly $Runtime
            $result.Rechecked|Should -Be 1
            $result.Score|Should -BeNullOrEmpty
            $result.FullGateSatisfied|Should -BeFalse
            $result.Report|Should -BeExactly (Join-Path $result.Proof 'mutation.recheck.json')
            (Get-FileHash $baseline).Hash|Should -BeExactly $before
            Should -Invoke Invoke-MutatorRun -Times 1
            Should -Invoke Invoke-MutatorRecheckCore -Times 0
        }
    }
    It 'does not schedule a run under WhatIf or without recorded survivors' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $baseline=Join-Path $Root 'baseline.json'
            Write-MutatorJson $baseline @{survivors=@(@{Id=1})}
            Mock Invoke-MutatorRun {throw 'Must not launch'}
            $null=Invoke-MutatorRecheck -ModulePath $script:MutatorRoot -ReportPath $baseline -WhatIf
            Write-MutatorJson $baseline @{survivors=@()}
            {Invoke-MutatorRecheck -ModulePath $script:MutatorRoot -ReportPath $baseline}|Should -Throw '*recorded survivors*'
            Should -Invoke Invoke-MutatorRun -Times 0
        }
    }
    It 'fails explicitly if a completed worker returns no recheck summary' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $baseline=Join-Path $Root 'baseline.json'
            Write-MutatorJson $baseline @{survivors=@(@{Id=1})}
            Mock Invoke-MutatorRun {[pscustomobject]@{Outcome='Success';Path=$Root;Isolation='Podman';Packages=@(@{Id='p0';Error='Missing receipt'})}}
            $result=Invoke-MutatorRecheck -ModulePath $script:MutatorRoot -ReportPath $baseline -OutputDirectory (Join-Path $Root 'new')
            $result.Outcome|Should -BeExactly Failed
            $result.Rechecked|Should -BeNullOrEmpty
            $result.Score|Should -BeNullOrEmpty
        }
    }
}
Describe 'Isolated recheck worker retains its boundary and reports' {
    It 'passes a frozen read-only baseline into Windows Sandbox and copies recheck reports' -Skip:(!$IsWindows) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $baseline=Join-Path $Root 'baseline.json'
            Write-MutatorJson $baseline @{survivors=@(@{Id=1})}
            $entry=@{Id='p0';Name='Fixture';ModulePath=$script:MutatorRoot;Configuration=(Join-Path $script:MutatorRoot 'test/psmutant.config.json');ResumeFrom=$null;Stryker=$false;RecheckFrom=$baseline;RecheckSha256=(Get-FileHash $baseline).Hash}
            $run=@{SourceRoot=(Split-Path $script:MutatorRoot);Schedule=@{Workers=1;Slots=1;ReservedMemoryMiB=2048};TestOrder='FocusedFirst'}
            $state=@{Outcome='Running'}
            $artifacts=Join-Path $Root 'packages/p0'
            [void][IO.Directory]::CreateDirectory($artifacts)
            Mock Get-Command {@{Name='wsb'}} -ParameterFilter {$Name -eq 'wsb'}
            Mock Copy-MutatorSandboxRuntime {}
            Mock Invoke-MutatorSandboxCommand {
                param($Arguments,$Directory)
                if($Arguments[0] -eq 'start'){
                    $folders=@(([xml]$Arguments[4]).Configuration.MappedFolders.MappedFolder)
                    ($folders|Where-Object SandboxFolder -EQ 'C:\MutatorPayload').ReadOnly|Should -BeExactly true
                }
                if($Arguments[0] -eq 'exec'){
                    $inner=Read-MutatorJson (Join-Path $Directory 'sandbox-run/run.json')
                    $inner.Packages[0].RecheckFrom|Should -BeExactly 'C:\MutatorPayload\recheck-input.json'
                    (Get-FileHash (Join-Path $Directory 'sandbox-payload/recheck-input.json')).Hash|Should -BeExactly $entry.RecheckSha256
                    $reports=Join-Path $Directory 'sandbox-run/packages/p0'
                    Write-MutatorJson (Join-Path $reports 'state.json') @{Outcome='Success';Phase='Completed';Recheck=@{Rechecked=1;NowKilled=1;Survived=0;Score=$null;FullGateSatisfied=$false}}
                    Write-MutatorJson (Join-Path $reports 'recheck/mutation.recheck.json') @{mode='Recheck';rechecked=1;nowKilled=1;survivors=@()}
                    Write-MutatorJson (Join-Path $reports 'recheck/recheck.json') @{Mode='Recheck';Score=$null}
                }
                @{Outcome='Success';Stdout='';Stderr=''}
            }
            Invoke-MutatorWindowsSandboxPackage $Root $run $entry $state (Join-Path $artifacts 'state.json')
            $state.Recheck.Rechecked|Should -Be 1
            $state.Container.Stopped|Should -BeTrue
            Test-Path (Join-Path $artifacts 'mutation.recheck.json')|Should -BeTrue
            (Get-FileHash $baseline).Hash|Should -BeExactly $entry.RecheckSha256
        }
    }
    It 'passes the baseline read-only to an offline Podman recheck without building or pulling an image' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            Set-MutatorContainerContext -Engine Podman
            $baseline=Join-Path $Root 'baseline.json'
            Write-MutatorJson $baseline @{survivors=@(@{Id=1})}
            $manifest=Join-Path $Root 'runtime.psd1'
            Set-Content $manifest '@{}'
            $entry=@{Id='p0';Name='Fixture';ModulePath=(Join-Path $Root 'Fixture');Configuration=(Join-Path $Root 'Fixture/test/config.json');Stryker=$false;ResumeFrom=$null
                RecheckFrom=$baseline;RecheckSha256=(Get-FileHash $baseline).Hash;ContainerRecipe=@{Kind='Runtime';Path=$manifest;Sha256=(Get-FileHash $manifest).Hash}}
            $run=@{SourceRoot=$Root;Schedule=@{Workers=1;Slots=1;ReservedMemoryMiB=2048};TestOrder='FocusedFirst';Isolation='Podman';ContainerBaseImage='local-runtime';ContainerConnection=$null}
            $state=@{Outcome='Running'}
            $artifacts=Join-Path $Root 'packages/p0'
            [void][IO.Directory]::CreateDirectory($artifacts)
            Mock Resolve-MutatorContainerConnection {@{Connection=$null;Controllers=@('memory','cpu');Rootless=$true}}
            Mock Invoke-MutatorContainerCommand {
                param($Arguments,$Directory)
                if($Arguments[0] -eq 'image'){return @{Outcome='Success';Stdout=('[{"Id":"'+('a'*64)+'","Os":"linux"}]');Stderr=''}}
                $Arguments[0]|Should -BeExactly run
                $Arguments|Should -Contain '--pull=never'
                $Arguments|Should -Contain '--network=none'
                @($Arguments|Where-Object {$_ -like '*target=/mutator/recheck-input.json,readonly'}).Count|Should -Be 1
                $inner=Read-MutatorJson (Join-Path $Directory 'container-run/run.json')
                $inner.Packages[0].RecheckFrom|Should -BeExactly '/mutator/recheck-input.json'
                $inner.Packages[0].RecheckSha256|Should -BeExactly $entry.RecheckSha256
                $reports=Join-Path $Directory 'container-run/packages/p0'
                Write-MutatorJson (Join-Path $reports 'state.json') @{Outcome='Success';Phase='Completed';Recheck=@{Rechecked=1;NowKilled=1;Survived=0;Score=$null;FullGateSatisfied=$false}}
                Write-MutatorJson (Join-Path $reports 'recheck/mutation.recheck.json') @{mode='Recheck';rechecked=1;nowKilled=1;survivors=@()}
                Write-MutatorJson (Join-Path $reports 'recheck/recheck.json') @{Mode='Recheck';Score=$null}
                @{Outcome='Success';Stdout='';Stderr=''}
            }
            Invoke-MutatorContainerPackage $Root $run $entry $state (Join-Path $artifacts 'state.json')
            $state.Recheck.Rechecked|Should -Be 1
            Test-Path (Join-Path $artifacts 'mutation.recheck.json')|Should -BeTrue
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -in @('build','pull')}
        }
    }
    It 'dispatches a frozen recheck on <Boundary> without running the full mutation gate' -ForEach @(
        @{Boundary='WindowsSandbox'},@{Boundary='Podman'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive;Boundary=$Boundary} {
            param($Root,$Boundary)
            $baseline=Join-Path $Root 'baseline.json'
            Write-MutatorJson $baseline @{survivors=@(@{Id=1})}
            $entry=@{Id='p0';Name='Fixture';ModulePath=$Root;RecheckFrom=$baseline;RecheckSha256=(Get-FileHash $baseline).Hash}
            $runPath=Join-Path $Root 'owned'
            Write-MutatorJson (Join-Path $runPath 'run.json') @{SourceRoot=$Root;Packages=@($entry);IsolationBoundary=$Boundary;StopPath=(Join-Path $runPath 'stop.json')}
            Mock Restore-MutatorContainerContext {}
            Mock Import-MutatorTool {throw 'The full mutation gate must not run.'}
            Mock Invoke-MutatorRecheckCore {
                param($ModulePath,$ReportPath,$OutputDirectory,$SourceRoot,$StopPath)
                $script:MutatorIsolationBoundary|Should -BeExactly $Boundary
                $ReportPath|Should -BeExactly $baseline
                $StopPath|Should -BeExactly (Join-Path $runPath 'stop.json')
                [pscustomobject]@{Outcome='Success';Error=$null;BaselineSha256=$entry.RecheckSha256;SourceSha256='source';Rechecked=1;NowKilled=1;Survived=0}
            }
            Invoke-MutatorPackage $runPath p0
            $state=Read-MutatorJson (Join-Path $runPath 'packages/p0/state.json')
            $state.Outcome|Should -BeExactly Success
            $state.Recheck.Rechecked|Should -Be 1
            $state.Recheck.FullGateSatisfied|Should -BeFalse
            $state.PSMutant|Should -BeNullOrEmpty
            Should -Invoke Invoke-MutatorRecheckCore -Times 1
            Should -Invoke Import-MutatorTool -Times 0
            $script:MutatorIsolationBoundary=$null
        }
    }
    It 'rejects host execution and a changed baseline before invoking the recheck core' -ForEach @(
        @{Boundary=$null;Expected='*isolated worker*'},@{Boundary='Podman';Expected='*changed since scheduling*'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive;Boundary=$Boundary;Expected=$Expected} {
            param($Root,$Boundary,$Expected)
            $baseline=Join-Path $Root 'baseline.json'
            Write-MutatorJson $baseline @{survivors=@(@{Id=1})}
            $entry=@{Id='p0';Name='Fixture';RecheckFrom=$baseline;RecheckSha256='not-the-scheduled-hash'}
            Write-MutatorJson (Join-Path $Root 'run.json') @{Packages=@($entry);IsolationBoundary=$Boundary}
            Mock Restore-MutatorContainerContext {}
            Mock Invoke-MutatorRecheckCore {throw 'must not execute'}
            Invoke-MutatorPackage $Root p0
            $state=Read-MutatorJson (Join-Path $Root 'packages/p0/state.json')
            $state.Outcome|Should -BeExactly Failed
            $state.Error|Should -BeLike $Expected
            Should -Invoke Invoke-MutatorRecheckCore -Times 0
            $script:MutatorIsolationBoundary=$null
        }
    }
    It 'copies recheck evidence and reports survivors without a full mutation score' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $source=Join-Path $Root 'guest'
            $destination=Join-Path $Root 'packages/p0'
            Write-MutatorJson (Join-Path $source 'recheck/recheck.json') @{Mode='Recheck';Score=$null;FullGateSatisfied=$false}
            Write-MutatorJson (Join-Path $source 'recheck/mutation.recheck.json') @{mode='Recheck';mutants=@(@{Status='Survived';Id=1;File='source.ps1';Line=2;Operator='Number';Description='7 to 0'})}
            Copy-MutatorIsolatedReport -Source $source -Destination $destination
            Test-Path (Join-Path $destination 'recheck.json')|Should -BeTrue
            Test-Path (Join-Path $destination 'mutation.recheck.json')|Should -BeTrue
            Test-Path (Join-Path $destination 'mutation.json')|Should -BeFalse
            Write-MutatorJson (Join-Path $Root 'run.json') @{Id='recheck';Platform='windows';Runtime='7.6.9';Mode='Recheck';Outcome='Failed';CreatedUtc=[datetime]::UtcNow.ToString('O');Packages=@(@{Id='p0';Name='Fixture'})}
            Write-MutatorJson (Join-Path $destination 'state.json') @{Id='p0';Name='Fixture';Phase='Completed';Outcome='Failed';Recheck=@{Rechecked=2;NowKilled=1;Survived=1;FullGateSatisfied=$false}}
            $view=Get-MutatorRun -Path $Root
            $view.RecheckedMutants|Should -Be 2
            $view.EvaluatedMutants|Should -Be 0
            (Format-MutatorTerminalFrame $view)|Should -Match 'RECHECK.*2.*1.*1'
            (Get-MutatorFailure -Path $Root).Items[0].Kind|Should -BeExactly PSMutantRecheck
        }
    }
}
