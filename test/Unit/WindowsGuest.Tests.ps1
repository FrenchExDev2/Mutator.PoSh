BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Windows mutation scheduling and evidence' {
    It 'reserves a whole VM for each parallel package' {
        $plan=New-MutatorSchedule -Packages @('a','b','c') -Workers 1 -WorkerBudget 4 -ThrottleLimit 4 -MemoryBudgetMiB 12288 -MemoryPerWorkerMiB 6144
        $plan.Slots|Should -Be 2
        $plan.Workers|Should -Be 1
        $plan.ReservedMemoryMiB|Should -Be 12288
    }
    It 'refuses unsupported requests before allocating a run or VM' {
        {Invoke-MutatorRun -ModulePath absent -WindowsGuestImage image}|Should -Throw '*require Windows Sandbox*'
        {Invoke-MutatorRun -ModulePath absent -WindowsGuestImage image -Workers 2 -MemoryBudgetMiB 6144}|Should -Throw '*require Windows Sandbox*'
        {Invoke-MutatorRun -ModulePath absent -WindowsGuestImage image -ResumeFrom partial}|Should -Throw '*require Windows Sandbox*'
    }
    It 'selects configured Stryker projects without a Windows-specific omission' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $module=Join-Path $Root 'Configured'
            Write-MutatorJson (Join-Path $module 'test/psmutant.config.json') @{coveredLinesOnly=$false;sandboxSubtrees=@('Configured');mutate=@('Configured/Value.ps1');tests=@{'Configured/Value.ps1'=@('Configured/test/Value.Tests.ps1')}}
            Write-MutatorJson (Join-Path $module 'engine/dotnet-tools.json') @{}
            $script:WindowsStrykerSelection=$null
            Mock Invoke-MutatorRunCore {param($RunDirectory);$script:WindowsStrykerSelection=(Read-MutatorJson (Join-Path $RunDirectory 'run.json')).Packages[0].Stryker}
            $null=Invoke-MutatorRun -ModulePath $module -OS Linux -SourceRoot $Root -RunRoot (Join-Path $Root 'runs') -MemoryBudgetMiB 6144
            $script:WindowsStrykerSelection|Should -BeTrue
        }
    }
    Context 'Transport is not a mutation gate' {
        BeforeEach {
            InModuleScope FrenchExDev.Mutator.PoSh {
                $script:GuestResult=@{RunId='run';JobId='job';Outcome='Success';ExitCode=0}
                $script:GuestState=@{Outcome='Success';Phase='Completed';ContextSha256='context';SourceSha256='source';PSMutant=@{Total=3;Score=100}}
            }
        }
        It 'accepts a complete matching package' {
            InModuleScope FrenchExDev.Mutator.PoSh {Confirm-MutatorGuestMutationResult $script:GuestResult $script:GuestState run job}
        }
        It 'rejects a foreign result even with exit zero' {
            InModuleScope FrenchExDev.Mutator.PoSh {$script:GuestResult.JobId='other';{Confirm-MutatorGuestMutationResult $script:GuestResult $script:GuestState run job}|Should -Throw '*another job*'}
        }
        It 'rejects failed transport and failed or partial packages' {
            InModuleScope FrenchExDev.Mutator.PoSh {
                $script:GuestResult.ExitCode=1
                {Confirm-MutatorGuestMutationResult $script:GuestResult $script:GuestState run job}|Should -Throw '*job failed*'
                $script:GuestResult.ExitCode=0;$script:GuestState.Outcome='Interrupted'
                {Confirm-MutatorGuestMutationResult $script:GuestResult $script:GuestState run job}|Should -Throw '*evidence gate*'
            }
        }
        It 'rejects empty, invalid and surviving mutation results' {
            InModuleScope FrenchExDev.Mutator.PoSh {
                foreach($value in @(0,-1,'garbage')){
                    $script:GuestState.PSMutant.Total=$value
                    {Confirm-MutatorGuestMutationResult $script:GuestResult $script:GuestState run job}|Should -Throw '*empty or below*'
                }
                $script:GuestState.PSMutant.Total=3;$script:GuestState.PSMutant.Score=99
                {Confirm-MutatorGuestMutationResult $script:GuestResult $script:GuestState run job}|Should -Throw '*empty or below*'
            }
        }
        It 'rejects missing runtime/source provenance' {
            InModuleScope FrenchExDev.Mutator.PoSh {$script:GuestState.Remove('ContextSha256');{Confirm-MutatorGuestMutationResult $script:GuestResult $script:GuestState run job}|Should -Throw '*evidence gate*'}
        }
        It 'requires the configured C# gate in addition to the PowerShell gate' {
            InModuleScope FrenchExDev.Mutator.PoSh {
                {Confirm-MutatorGuestMutationResult $script:GuestResult $script:GuestState run job -RequireStryker}|Should -Throw '*Stryker gate*'
                $script:GuestState.Stryker=@{Score=100;Detected=2;Undetected=0;ReportSha256='hash'}
                Confirm-MutatorGuestMutationResult $script:GuestResult $script:GuestState run job -RequireStryker
                $script:GuestState.Stryker.Undetected=1
                {Confirm-MutatorGuestMutationResult $script:GuestResult $script:GuestState run job -RequireStryker}|Should -Throw '*Stryker gate*'
            }
        }
        It 'keeps a transport timeout distinct from mutation survivors or empty discovery' {
            InModuleScope FrenchExDev.Mutator.PoSh {
                $script:GuestResult.Outcome='TimedOut'
                {Confirm-MutatorGuestMutationResult $script:GuestResult $script:GuestState run job}|Should -Throw '*timed out*'
            }
        }
    }
}
Describe 'Windows mutation transport cleanup and report retention' {
    BeforeEach {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $script:TransportRoot=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $source=Join-Path $script:TransportRoot 'source'
            $module=Join-Path $source 'Fixture'
            Write-MutatorJson (Join-Path $module 'test/psmutant.config.json') @{coveredLinesOnly=$false;sandboxSubtrees=@('Fixture');mutate=@('Fixture/Value.ps1');tests=@{'Fixture/Value.ps1'=@('Fixture/test/Value.Tests.ps1')}}
            $script:TransportEntry=@{Id='p0000';Name='Fixture';ModulePath=$module;Configuration=(Join-Path $module 'test/psmutant.config.json')}
            $script:TransportRun=@{SourceRoot=$source;WindowsGuestImage='image';WindowsGuestTimeoutMinutes=5;ContainerConnection='connection';TestOrder='Configured'}
            $script:TransportState=@{Outcome='Running';Phase='Baseline'}
            $script:TransportStatePath=Join-Path $script:TransportRoot 'packages/p0000/state.json'
            $script:TransportFailure=$false;$script:TransportPolls=0
            Mock Start-MutatorGuestModule {
                param($OutputDirectory)
                $share=Join-Path $OutputDirectory 'share'
                Write-MutatorJson (Join-Path $OutputDirectory 'guest.json') @{Kind='WindowsModule';RunId='owner';Share=$share;Container='owned';ImageId=('a'*64)}
                $script=Join-Path $share 'mutator/modules/FrenchExDev.Mutator.PoSh/resources/containers/jobs/Invoke-GuestMutation.ps1'
                [void][IO.Directory]::CreateDirectory((Split-Path $script));Set-Content $script 'fixture'
                [pscustomobject]@{RunId='owner';Share=$share;Container='owned';ImageId=('a'*64)}
            }
            Mock Get-MutatorGuestBase { @{Ready=$true;Running=$true;Outcome='Running'} }
            Mock Stop-MutatorGuestBase { @{Outcome='Success'} }
            Mock Start-Sleep {}
            Mock Get-MutatorOwnedGuest {
                param([Collections.IDictionary]$Run)
                if($Run.RunId -cne 'owner'){throw 'Foreign owner'}
                @{State=@{Running=$true}}
            }
            Mock Read-MutatorJson {
                param($Path)
                if((Split-Path $Path -Leaf) -eq 'result.json'){
                    $script:TransportPolls++
                    if($script:TransportPolls -eq 1){return}
                    $directory=Split-Path $Path
                    $request=Get-Content (Join-Path $directory 'request.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
                    if(!(Test-Path (Join-Path $directory 'run/packages/p0000') -PathType Container)){throw 'The host must prepare the SMB report directory before submitting a job.'}
                    Write-MutatorJson (Join-Path $directory 'run/packages/p0000/state.json') @{Outcome=$(if($script:TransportFailure){'Failed'}else{'Success'});Phase='Completed';ContextSha256='context';SourceSha256='source';Error='Business failure';PSMutant=@{Total=3;Score=100}}
                    Write-MutatorJson (Join-Path $directory 'run/packages/p0000/mutation.json') @{mode='Complete';mutants=@(@{Status='Survived';Id=42;File='Value.ps1';Line=1;Operator='Condition';Description='negated'})}
                    return @{RunId=$request.RunId;JobId=$request.JobId;Outcome='Success';ExitCode=0}
                }
                if(Test-Path $Path){Get-Content $Path -Raw|ConvertFrom-Json -AsHashtable -DateKind String}
            }
        }
    }
    It 'retains canonical reports and progress paths and shuts down the owned guest' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Invoke-MutatorWindowsGuestPackage $script:TransportRoot $script:TransportRun $script:TransportEntry $script:TransportState $script:TransportStatePath
            $script:TransportState.Outcome|Should -BeExactly Success
            $script:TransportState.Platform|Should -BeExactly Windows
            $script:TransportState.PSMutant.Total|Should -Be 3
            $script:TransportState.Container.ProgressPath|Should -BeLike '*mutants.jsonl'
            (Read-MutatorJson (Join-Path (Split-Path $script:TransportStatePath) 'mutation.json')).mutants[0].Id|Should -Be 42
            Should -Invoke Stop-MutatorGuestBase -Times 1 -ParameterFilter {$Path -eq (Join-Path (Split-Path $script:TransportStatePath) 'windows-guest')}
            Should -Invoke Get-MutatorOwnedGuest -Times 1
            Should -Invoke Start-MutatorGuestModule -Times 1 -ParameterFilter {$ShareDirectory -like '*guest-shares*'}
        }
    }
    It 'preserves failed package evidence and its business cause before shutdown' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $script:TransportFailure=$true
            {Invoke-MutatorWindowsGuestPackage $script:TransportRoot $script:TransportRun $script:TransportEntry $script:TransportState $script:TransportStatePath}|Should -Throw '*Business failure*'
            Test-Path (Join-Path (Split-Path $script:TransportStatePath) 'mutation.json')|Should -BeTrue
            Should -Invoke Stop-MutatorGuestBase -Times 1
        }
    }
    It 'cleans up a partially provisioned guest while preserving the preparation error' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Mock Start-MutatorGuestModule {param($OutputDirectory);Write-MutatorJson (Join-Path $OutputDirectory 'guest.json') @{RunId='owner'};throw 'Provisioning failed'}
            {Invoke-MutatorWindowsGuestPackage $script:TransportRoot $script:TransportRun $script:TransportEntry $script:TransportState $script:TransportStatePath}|Should -Throw '*Provisioning failed*'
            Should -Invoke Stop-MutatorGuestBase -Times 1
        }
    }
}
Describe 'Force stop owns Windows guest cleanup' {
    It 'signals the guest job and shuts down its VM before dropping the host worker' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $path=Join-Path $Root 'force-guest'
            $script:ForceJob=Join-Path $path 'job'
            Write-MutatorJson (Join-Path $path 'run.json') @{Outcome='Running'}
            Mock Get-MutatorRun {param($Path);[pscustomobject]@{Id='test';Path=$Path;Outcome='Running';Process=$null;Packages=@(@{Container=@{GuestPath='owned-guest';JobPath=$script:ForceJob};Process=$null})}}
            Mock Stop-MutatorGuestBase {param($Path);if($Path -cne 'owned-guest'){throw 'Unexpected guest'};if(!(Test-Path (Join-Path $script:ForceJob 'stop.json'))){throw 'Stop signal must precede guest shutdown'}}
            Mock Get-MutatorRunWorkerIdentity { @() }
            $null=Stop-MutatorRun $path -Force
            Should -Invoke Stop-MutatorGuestBase -Times 1 -ParameterFilter {$Path -eq 'owned-guest'}
            (Read-MutatorJson (Join-Path $path 'run.json')).Outcome|Should -BeExactly Interrupted
        }
    }
}
