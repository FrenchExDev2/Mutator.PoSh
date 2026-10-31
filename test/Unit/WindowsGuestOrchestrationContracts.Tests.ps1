<#
.SYNOPSIS
Expected behavior for the WindowsGuestOrchestrationContracts tests.

.DESCRIPTION
Always attempt owned cleanup while preserving the primary preparation/execution error. Keep resume
fingerprints, configured Stryker evidence and cooperative-stop forwarding intact.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Windows package lifecycle keeps business evidence independent of VM transport' {
    BeforeEach {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $script:LifecycleRoot=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $script:LifecycleModule=Join-Path $script:LifecycleRoot 'source/Fixture'
            $configuration=Join-Path $script:LifecycleModule 'test/psmutant.config.json'
            Write-MutatorJson $configuration @{coveredLinesOnly=$false;sandboxSubtrees=@('Fixture');mutate=@('Fixture/Value.ps1');tests=@{'Fixture/Value.ps1'=@('Fixture/test/Value.Tests.ps1')}}
            $script:LifecycleEntry=@{Id='p0000';Name='Fixture';ModulePath=$script:LifecycleModule;Configuration=$configuration;Stryker=$false}
            $script:LifecycleRun=@{SourceRoot=(Split-Path $script:LifecycleModule);WindowsGuestImage='owned-image';WindowsGuestTimeoutMinutes=5;WindowsGuestJobTimeoutSeconds=30;ContainerConnection='selected';TestOrder='Configured'}
            $script:LifecycleState=@{Outcome='Running';Phase='Baseline'}
            $script:LifecycleStatePath=Join-Path $script:LifecycleRoot 'packages/p0000/state.json'
            $script:LifecycleMode='Success';$script:LifecyclePolls=0;$script:LifecycleProvisionPolls=0
            $script:LifecycleNow=[datetimeoffset]'2026-01-01T00:00:00Z'
            Mock Get-MutatorUtcNow {$script:LifecycleNow}
            Mock Start-Sleep {if($script:LifecycleMode -eq 'NoReceipt'){$script:LifecycleNow=$script:LifecycleNow.AddMinutes(3)}}
            Mock Start-MutatorGuestModule {
                param($OutputDirectory)
                $share=Join-Path $script:LifecycleRoot 'share'
                $guest=@{Kind='WindowsModule';RunId='owner';Share=$share;Container='owned';ImageId=('a'*64)}
                Write-MutatorJson (Join-Path $OutputDirectory 'guest.json') $guest
                $job=Join-Path $share 'mutator/modules/FrenchExDev.Mutator.PoSh/resources/containers/jobs/Invoke-GuestMutation.ps1'
                [void][IO.Directory]::CreateDirectory((Split-Path $job));[IO.File]::WriteAllText($job,'fixture')
                if($script:LifecycleMode -eq 'StoppedProvisioning'){Write-MutatorJson (Join-Path $script:LifecycleRoot 'stop.json') @{}}
                $guest
            }
            Mock Get-MutatorGuestBase {
                $script:LifecycleProvisionPolls++
                switch($script:LifecycleMode){
                    'ProvisionFailure' {return @{Ready=$false;Running=$true;Outcome='Failed';Error='installer failed'}}
                    'ProvisionExited' {return @{Ready=$false;Running=$false;Outcome='Running'}}
                    'ProvisionTimeout' {$script:LifecycleNow=$script:LifecycleNow.AddMinutes(6);return @{Ready=$false;Running=$true;Outcome='Running'}}
                    'ProvisionWait' {if($script:LifecycleProvisionPolls -eq 1){return @{Ready=$false;Running=$true;Outcome='Running'}}}
                }
                @{Ready=$true;Running=$true;Outcome='Running'}
            }
            Mock Stop-MutatorGuestBase {if($script:LifecycleMode -like 'Cleanup*'){throw 'shutdown refused'}}
            Mock Get-MutatorOwnedGuest {@{State=@{Running=($script:LifecycleMode -ne 'MutationExited')}}}
            Mock Get-MutatorSourceSnapshot {
                param($Root)
                @{Sha256=$(if($script:LifecycleMode -eq 'ChangedSource' -and $Root -eq $script:LifecycleModule -and $script:LifecyclePolls -gt 1){'changed'}else{'frozen'})}
            }
            Mock Read-MutatorJson {
                param($Path)
                if((Split-Path $Path -Leaf) -eq 'result.json'){
                    $script:LifecyclePolls++
                    if($script:LifecycleMode -eq 'NoReceipt'){return}
                    if($script:LifecyclePolls -eq 1){
                        if($script:LifecycleMode -eq 'UserStop'){Write-MutatorJson (Join-Path $script:LifecycleRoot 'stop.json') @{}}
                        return
                    }
                    $job=Split-Path $Path;$request=Get-Content (Join-Path $job 'request.json') -Raw|ConvertFrom-Json -AsHashtable
                    $inner=@{Outcome='Success';Phase='Completed';ContextSha256='context';SourceSha256='source';PSMutant=@{Total=2;Score=100};TestOrder='Configured';PreparationMs=4;StagedSubtrees=@('Fixture')}
                    if($script:LifecycleEntry.Stryker){
                        $report=Join-Path $job 'run/packages/p0000/stryker/reports/mutation-report.json'
                        Write-MutatorJson $report @{files=@{};schemaVersion='1'}
                        $inner.Stryker=@{Score=100;Detected=2;Undetected=0;ReportSha256=(Get-FileHash $report).Hash}
                        if($script:LifecycleMode -eq 'MissingStryker'){Remove-Item -LiteralPath $report}
                        if($script:LifecycleMode -eq 'CorruptStryker'){$inner.Stryker.ReportSha256='different'}
                    }
                    if($script:LifecycleMode -eq 'Survivor'){$inner.PSMutant.Score=50}
                    if($script:LifecycleMode -eq 'CleanupFailed'){$inner.Outcome='Failed';$inner.Error='business failure'}
                    if($script:LifecycleMode -ne 'MissingState'){Write-MutatorJson (Join-Path $job 'run/packages/p0000/state.json') $inner}
                    Write-MutatorJson (Join-Path $job 'run/packages/p0000/mutation.json') @{mutants=@(@{Id=1;Status='Killed'})}
                    if($script:LifecycleMode -eq 'CompletedLate'){$script:LifecycleNow=$script:LifecycleNow.AddMinutes(6)}
                    return @{RunId='owner';JobId=$request.JobId;Outcome='Success';ExitCode=0}
                }
                if(Test-Path -LiteralPath $Path){Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json -AsHashtable -DateKind String}
            }
        }
    }
    It 'keeps the primary failure and always attempts owned guest cleanup: <Mode>' -ForEach @(
        @{Mode='StoppedProvisioning';Error='*stopped during provisioning*'},
        @{Mode='ProvisionFailure';Error='*installer failed*'},
        @{Mode='ProvisionExited';Error='*provisioning timed out or the guest exited*'},
        @{Mode='ProvisionTimeout';Error='*provisioning timed out or the guest exited*'},
        @{Mode='MutationExited';Error='*guest exited during mutation*'},
        @{Mode='NoReceipt';Error='*timed out without returning its final receipt*'},
        @{Mode='MissingState';Error='*Missing package state*'},
        @{Mode='Survivor';Error='*empty or below 100*'},
        @{Mode='ChangedSource';Error='*source changed*'},
        @{Mode='CompletedLate';Error='*exceeded its allotted time*'},
        @{Mode='CleanupSuccess';Error='*could not be shut down*'},
        @{Mode='CleanupFailed';Error='*business failure*'},
        @{Mode='MissingStryker';Error='*report fingerprint differs or its report is absent*'},
        @{Mode='CorruptStryker';Error='*report fingerprint differs or its report is absent*'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Mode=$Mode;Expected=$Error} {
            param($Mode,$Expected)
            $script:LifecycleMode=$Mode
            $script:LifecycleEntry.Stryker=$Mode -in @('MissingStryker','CorruptStryker')
            {Invoke-MutatorWindowsGuestPackage $script:LifecycleRoot $script:LifecycleRun $script:LifecycleEntry $script:LifecycleState $script:LifecycleStatePath}|Should -Throw $Expected
            Should -Invoke Stop-MutatorGuestBase -Times 1 -Exactly
            if($Mode -like 'Cleanup*'){$script:LifecycleState.Container.CleanupError|Should -BeExactly 'shutdown refused'}
            if($Mode -eq 'NoReceipt'){
                $stop=Read-MutatorJson (Join-Path $script:LifecycleState.Container.JobPath 'stop.json')
                $stop.Reason|Should -BeExactly TimedOut
            }
        }
    }
    It 'preserves resume fingerprints, Stryker evidence and cooperative stop requests: <Mode>' -ForEach @(
        @{Mode='Success'},@{Mode='ProvisionWait'},@{Mode='UserStop'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Mode=$Mode} {
            param($Mode)
            $script:LifecycleMode=$Mode;$script:LifecycleEntry.Stryker=$true
            $resume=Join-Path $script:LifecycleRoot 'previous/mutation.json'
            Write-MutatorJson $resume @{mutants=@(@{Id=1})};Write-MutatorJson ($resume+'.context.json') @{SourceSha256='frozen'}
            $script:LifecycleEntry.ResumeFrom=$resume
            Invoke-MutatorWindowsGuestPackage $script:LifecycleRoot $script:LifecycleRun $script:LifecycleEntry $script:LifecycleState $script:LifecycleStatePath
            $script:LifecycleState.Outcome|Should -BeExactly Success
            Test-Path $script:LifecycleState.Stryker.Report|Should -BeTrue
            $descriptor=Read-MutatorJson (Join-Path $script:LifecycleState.Container.JobPath 'mutation.json')
            $descriptor.ResumeReportSha256|Should -BeExactly (Get-FileHash $resume).Hash
            $descriptor.ResumeContextSha256|Should -BeExactly (Get-FileHash ($resume+'.context.json')).Hash
            if($Mode -eq 'UserStop'){(Read-MutatorJson (Join-Path $script:LifecycleState.Container.JobPath 'stop.json')).Reason|Should -BeExactly UserRequested}
            if($Mode -eq 'ProvisionWait'){Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter {$Seconds -eq 3}}
            Should -Invoke Stop-MutatorGuestBase -Times 1 -Exactly
        }
    }
}
