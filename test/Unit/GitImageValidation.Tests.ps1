BeforeDiscovery {
    $parent=Split-Path (Split-Path (Split-Path $PSScriptRoot))
    Import-Module (Join-Path $parent 'FrenchExDev.CliEnvironment.PoSh/FrenchExDev.CliEnvironment.PoSh.psd1') -Force -DisableNameChecking
    Import-Module (Join-Path $parent 'FrenchExDev.Mutator.PoSh/FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Git image validation orchestration' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            $workspace=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($workspace)
            Write-MutatorJson (Join-Path $workspace 'FrenchExDev.QuietCli.Git.PoSh/test/psmutant.config.json') @{sandboxSubtrees=@('FrenchExDev.QuietCli.Git.PoSh','FrenchExDev.Mutator.PoSh')}
            $output=Join-Path $workspace 'run'
            $script:GitImageFixtureRun=$null
            $script:GitImageFixtureHash='a'*64
            Mock Import-Module {} -ParameterFilter {$Name -like '*FrenchExDev.CliEnvironment.PoSh*'}
            Mock Set-MutatorContainerContext {}
            Mock Start-MutatorMemoryWatchdog {}
            Mock Write-MutatorValidationReport {$script:GitImageFixtureRun=$Run}
            Mock Get-MutatorSourceSnapshot {@{Sha256=$script:GitImageFixtureHash}}
            Mock Protect-MutatorDiagnostic {$Message}
            Mock New-CliEnvironmentGitImage {@{Outcome='Built';Image='fixture';ImageId=('b'*64)}}
            Mock Test-CliEnvironmentGitImage {@{Outcome='Success'}}
            Mock Get-CliEnvironmentSourceMount {@('--volume','source:/source:ro')}
            Mock Start-CliEnvironmentWindowsGuest {throw 'Windows must not be contacted.'}
            Mock Invoke-MutatorContainerCommand {
                if($Arguments[0] -eq 'run'){
                    $reports=Join-Path $script:GitImageFixtureRun.Path 'linux/reports'
                    Write-MutatorJson (Join-Path $reports 'result.json') @{RunId=$script:GitImageFixtureRun.Id;OS='Linux';OriginalModuleSha256=$script:GitImageFixtureHash;Outcome='Success';FullGateSatisfied=$true}
                    @{Outcome='Success';Stdout=('c'*64);Stderr=''}
                }elseif($Arguments[0] -eq 'inspect'){
                    @{Outcome='Success';Stdout=(@(@{Id=('c'*64);Config=@{Labels=@{'org.frenchexdev.mutator.validation'=$script:GitImageFixtureRun.Id}};State=@{Running=$false}})|ConvertTo-Json -AsArray -Depth 8);Stderr=''}
                }else{@{Outcome='Success';Stdout=$(if($Arguments[0] -eq 'wait'){'0'}else{''});Stderr=''}}
            }
        }
        It 'defaults to Linux without contacting another platform' {
            $r=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OutputDirectory $output
            $r.Outcome|Should -BeExactly Success
            $r.Platforms.Windows.Outcome|Should -BeExactly NotSelected
            Should -Invoke New-CliEnvironmentGitImage -Times 1 -Exactly -ParameterFilter {$Platform -eq 'Linux'}
            Should -Invoke Start-CliEnvironmentWindowsGuest -Times 0 -Exactly
        }
        It 'consumes a stop received during the build before qualifying or starting a workload' {
            Mock New-CliEnvironmentGitImage {
                Write-MutatorJson (Join-Path $script:GitImageFixtureRun.Path 'stop.json') @{RunId=$script:GitImageFixtureRun.Id}
                @{Outcome='Built';Image='fixture';ImageId=('b'*64)}
            }
            $r=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OutputDirectory $output
            $r.Outcome|Should -BeExactly Interrupted
            $r.Platforms.Linux.Qualified|Should -BeFalse
            Should -Invoke Test-CliEnvironmentGitImage -Times 0 -Exactly
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -Exactly
        }
        It 'forwards a live stop to the workload and retains its interrupted result and container' {
            Mock Start-Sleep {}
            Mock Invoke-MutatorContainerCommand {
                $reports=Join-Path $script:GitImageFixtureRun.Path 'linux/reports'
                if($Arguments[0] -eq 'run'){
                    Write-MutatorJson (Join-Path $script:GitImageFixtureRun.Path 'stop.json') @{RunId=$script:GitImageFixtureRun.Id}
                    return @{Outcome='Success';Stdout=('c'*64);Stderr=''}
                }
                if($Arguments[0] -eq 'inspect'){
                    if(Test-Path (Join-Path $reports 'stop.json')){
                        Write-MutatorJson (Join-Path $reports 'result.json') @{RunId=$script:GitImageFixtureRun.Id;OS='Linux';OriginalModuleSha256=$script:GitImageFixtureHash;Outcome='Interrupted';FullGateSatisfied=$false}
                    }
                    return @{Outcome='Success';Stdout=(@(@{Id=('c'*64);Config=@{Labels=@{'org.frenchexdev.mutator.validation'=$script:GitImageFixtureRun.Id}};State=@{Running=$false}})|ConvertTo-Json -AsArray -Depth 8);Stderr=''}
                }
                return @{Outcome='Success';Stdout=$(if($Arguments[0] -eq 'wait'){'1'}else{''});Stderr=''}
            }
            $r=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OutputDirectory $output
            $r.Outcome|Should -BeExactly Interrupted
            $r.Platforms.Linux.Phase|Should -BeExactly Interrupted
            $r.Platforms.Linux.RetainedContainer|Should -BeExactly ('c'*64)
            $signal=Read-MutatorJson (Join-Path $output 'linux/reports/stop.json')
            $signal.RunId|Should -BeExactly $script:GitImageFixtureRun.Id
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -Exactly -ParameterFilter {$Arguments[0] -eq 'rm'}
        }
        It 'selects only Linux, never contacts macOS or Windows and requires source-bound results' {
            $r=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OS Linux -OutputDirectory $output
            $r.Outcome|Should -Be Success
            $r.Platforms.Linux.Qualified|Should -BeTrue
            $r.Platforms.Windows.Outcome|Should -Be NotSelected
            $r.Platforms.MacOS.Outcome|Should -Be NotSelected
            Should -Invoke Start-CliEnvironmentWindowsGuest -Times 0 -Exactly
            Should -Invoke New-CliEnvironmentGitImage -Times 1 -ParameterFilter {$Platform -eq 'Linux'}
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'run' -and $Arguments -contains '-OriginalModuleSha256' -and $Arguments -contains '4096m'}
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'rm'}
        }
        It 'does no work for WhatIf and refuses empty selections or reused reports' {
            $null=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OS Linux -OutputDirectory $output -WhatIf
            Should -Invoke New-CliEnvironmentGitImage -Times 0 -Exactly
            {Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OS @() -OutputDirectory $output}|Should -Throw '*at least one*'
            [void][IO.Directory]::CreateDirectory($output);[IO.File]::WriteAllText((Join-Path $output 'summary.json'),'{}')
            {Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OS Linux -OutputDirectory $output}|Should -Throw '*fresh validation*'
        }
        It 'retains a detached request without starting work in the invoking terminal' {
            Mock Test-MutatorWindowsPlatform {$true}
            Mock Start-MutatorDetachedWorker {@{Id=98765;StartedUtc='2026-10-27T12:00:00Z';Role='git-validation';Launcher='CimDetached'}}
            $r=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OS Linux,Windows -OutputDirectory $output -Ram 40go -Background
            $r.Outcome|Should -Be Starting
            $request=Read-MutatorJson (Join-Path $output 'controller.request.json')
            $request.OS|Should -Be @('Linux','Windows')
            $request.BaselineOnly|Should -BeFalse
            $request.ModuleRoot|Should -Be $workspace
            $request.ContainsKey('Background')|Should -BeFalse
            Should -Invoke Start-MutatorDetachedWorker -Times 1 -ParameterFilter {$Kind -eq 'GitValidation' -and $RunDirectory -eq $output}
            Should -Invoke New-CliEnvironmentGitImage -Times 0 -Exactly
            Should -Invoke Start-MutatorMemoryWatchdog -Times 0 -Exactly
            {Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OutputDirectory $output -Background}|Should -Throw '*retained controller request*'
        }
        It 'does not run tests after a build failure' {
            Mock New-CliEnvironmentGitImage {@{Outcome='Failed';Error='fixture build failure'}}
            $r=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OS Linux -OutputDirectory $output
            $r.Outcome|Should -Be Failed
            $r.Platforms.Linux.Qualified|Should -BeFalse
            Should -Invoke Test-CliEnvironmentGitImage -Times 0 -Exactly
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -Exactly
        }
        It 'accepts a source-bound report becoming visible while the stopped state is inspected' {
            Mock Start-Sleep {}
            Mock Invoke-MutatorContainerCommand {@{Outcome='Success';Stdout=('c'*64);Stderr=''}} -ParameterFilter {$Arguments[0] -eq 'run'}
            Mock Invoke-MutatorContainerCommand {
                $reports=Join-Path $script:GitImageFixtureRun.Path 'linux/reports'
                Write-MutatorJson (Join-Path $reports 'result.json') @{RunId=$script:GitImageFixtureRun.Id;OS='Linux';OriginalModuleSha256=$script:GitImageFixtureHash;Outcome='Success';FullGateSatisfied=$true}
                @{Outcome='Success';Stdout=(@(@{Id=('c'*64);Config=@{Labels=@{'org.frenchexdev.mutator.validation'=$script:GitImageFixtureRun.Id}};State=@{Running=$false}})|ConvertTo-Json -AsArray -Depth 8);Stderr=''}
            } -ParameterFilter {$Arguments[0] -eq 'inspect'}
            $r=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OS Linux -OutputDirectory $output
            $r.Outcome|Should -Be Success
            $r.Platforms.Linux.Qualified|Should -BeTrue
        }
        It 'preserves the inspection failure and asks for a partial report before stopping an owned failed workload' {
            $script:GitImageInspectionCalls=0
            Mock Start-Sleep {}
            Mock Invoke-MutatorContainerCommand {
                $reports=Join-Path $script:GitImageFixtureRun.Path 'linux/reports'
                Write-MutatorJson (Join-Path $reports 'mutations/FrenchExDev.QuietCli.Git.PoSh/runs/run.json') @{Id='fixture'}
                @{Outcome='Success';Stdout=('c'*64);Stderr=''}
            } -ParameterFilter {$Arguments[0] -ceq 'run'}
            Mock Invoke-MutatorContainerCommand {
                $script:GitImageInspectionCalls++
                if($script:GitImageInspectionCalls -eq 1){return @{Outcome='TimedOut';ExitCode=$null;Stdout='';Stderr='fixture inspect timeout';Failure=@{Error=@{Code='Timeout'}}}}
                @{Outcome='Success';Stdout=(@(@{Id=('c'*64);Config=@{Labels=@{'org.frenchexdev.mutator.validation'=$script:GitImageFixtureRun.Id}};State=@{Running=$true}})|ConvertTo-Json -AsArray -Depth 8);Stderr=''}
            } -ParameterFilter {$Arguments[0] -ceq 'inspect'}
            Mock Invoke-MutatorContainerCommand {
                $reports=Join-Path $script:GitImageFixtureRun.Path 'linux/reports'
                Write-MutatorJson (Join-Path $reports 'result.json') @{Outcome='Failed'}
                Write-MutatorJson (Join-Path $reports 'mutations/FrenchExDev.QuietCli.Git.PoSh/runs/packages/p0000/mutation.json') @{mode='Partial'}
                @{Outcome='Success';Stdout='';Stderr=''}
            } -ParameterFilter {$Arguments[0] -ceq 'exec'}
            $r=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OS Linux -OutputDirectory $output
            $r.Outcome|Should -Be Failed
            $r.Platforms.Linux.Error|Should -Match 'could not be inspected \(TimedOut\)'
            $r.Platforms.Linux.RetainedContainer|Should -Be ('c'*64)
            $r.Platforms.Linux.PartialReportAvailable|Should -BeTrue
            $r.Platforms.Linux.StopRequest.Outcome|Should -Be Success
            (Read-MutatorJson (Join-Path $output 'linux/inspection.failure.json')).Outcome|Should -Be TimedOut
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -Exactly -ParameterFilter {$Arguments[0] -ceq 'exec' -and $Arguments -contains '/source/FrenchExDev.Mutator.PoSh/resources/validation/Stop-GitImageWorkload.ps1'}
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -Exactly -ParameterFilter {$Arguments[0] -ceq 'stop'}
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -Exactly -ParameterFilter {$Arguments[0] -ceq 'rm'}
        }
        It 'marks a selected OS pending while another environment is executing' {
            Mock New-CliEnvironmentGitImage {
                if($Platform -ceq 'Linux'){$script:GitImageFixtureRun.Platforms.Windows.Outcome|Should -Be Pending}
                @{Outcome='Failed';Error='fixture failed build'}
            }
            $seed=Join-Path $workspace 'FrenchExDev.CliEnvironment.PoSh/test/Artifacts/container-bases/windows/seed/base.json'
            Write-MutatorJson $seed @{}
            $r=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OS Linux,Windows -OutputDirectory $output
            $r.Outcome|Should -Be Failed
            $r.Platforms.MacOS.Outcome|Should -Be NotSelected
        }
        It 'supports a Windows baseline without requesting mutations or qualifying the complete gate' {
            $seed=Join-Path $workspace 'FrenchExDev.CliEnvironment.PoSh/test/Artifacts/container-bases/windows/seed/base.json'
            Write-MutatorJson $seed @{}
            Mock Copy-MutatorTree {}
            Mock Start-CliEnvironmentWindowsGuest {
                foreach($suite in @('unit','integration','coverage')){Test-Path (Join-Path $OutputDirectory ('share/reports/'+$suite+'/FrenchExDev.QuietCli.Git.PoSh')) -PathType Container|Should -BeTrue}
                $share=Join-Path $workspace 'guest-share'
                Write-MutatorJson (Join-Path $share 'reports/result.json') @{RunId=$WorkloadRequest.RunId;OS='Windows';OriginalModuleSha256=$WorkloadRequest.OriginalModuleSha256;Outcome='Success';FullGateSatisfied=$false}
                @{Outcome='Running';Path=(Join-Path $workspace 'guest');Share=$share}
            }
            $r=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OS Windows -OutputDirectory $output -BaselineOnly
            $r.Outcome|Should -Be Success
            $r.Platforms.Windows.Qualified|Should -BeFalse
            $r.Platforms.Linux.Outcome|Should -Be NotSelected
            Should -Invoke Start-CliEnvironmentWindowsGuest -Times 1 -ParameterFilter {$Kind -eq 'Git' -and $WorkloadRequest.BaselineOnly -eq $true}
            Should -Invoke Test-CliEnvironmentGitImage -Times 0 -Exactly
        }
        It 'rejects success when the original mounted sources changed during execution' {
            $script:GitImageFixtureReads=0
            Mock Get-MutatorSourceSnapshot {
                param($Root)
                if((Split-Path $Root -Leaf) -cne 'FrenchExDev.QuietCli.Git.PoSh'){return @{Sha256='a'*64}}
                $script:GitImageFixtureReads++
                @{Sha256=$(if($script:GitImageFixtureReads -le 2){'a'*64}else{'d'*64})}
            }
            $r=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OS Linux -OutputDirectory $output
            $r.Outcome|Should -Be Failed
            $r.Platforms.Linux.Error|Should -Match 'original Git module changed'
            $r.Platforms.Linux.Qualified|Should -BeFalse
        }
        It 'blocks execution when dependency <Dependency> changed after the initial snapshot' -ForEach @(@{Dependency='FrenchExDev.Mutator.PoSh'},@{Dependency='FrenchExDev.CliEnvironment.PoSh'}) {
            $script:GitDependencyReads=0
            $script:GitDependencyName=$Dependency
            Mock Get-MutatorSourceSnapshot {
                param($Root)
                if((Split-Path $Root -Leaf) -ceq $script:GitDependencyName){
                    $script:GitDependencyReads++
                    return @{Sha256=$(if($script:GitDependencyReads -eq 1){'a'*64}else{'e'*64})}
                }
                @{Sha256='a'*64}
            }
            $r=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OS Linux -OutputDirectory $output
            $r.Outcome|Should -Be Failed
            $r.Platforms.Linux.Error|Should -Match ([regex]::Escape('dependency '+$Dependency+' changed'))
            Should -Invoke Test-CliEnvironmentGitImage -Times 0 -Exactly
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -Exactly
        }
        It 'rejects stale run evidence even when it claims success' {
            Mock Invoke-MutatorContainerCommand {
                $reports=Join-Path $script:GitImageFixtureRun.Path 'linux/reports'
                Write-MutatorJson (Join-Path $reports 'result.json') @{RunId='foreign';OS='Linux';OriginalModuleSha256=$script:GitImageFixtureHash;Outcome='Success';FullGateSatisfied=$true}
                @{Outcome='Success';Stdout=('c'*64);Stderr=''}
            } -ParameterFilter {$Arguments[0] -eq 'run'}
            $r=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OS Linux -OutputDirectory $output
            $r.Outcome|Should -Be Failed
            $r.Platforms.Linux.Error|Should -Match 'another run'
            $r.Platforms.Linux.Qualified|Should -BeFalse
        }
        It 'rejects an incomplete gate and keeps semantic failures failed' {
            Mock Invoke-MutatorContainerCommand {
                $reports=Join-Path $script:GitImageFixtureRun.Path 'linux/reports'
                Write-MutatorJson (Join-Path $reports 'result.json') @{RunId=$script:GitImageFixtureRun.Id;OS='Linux';OriginalModuleSha256=$script:GitImageFixtureHash;Outcome='Success';FullGateSatisfied=$false}
                @{Outcome='Success';Stdout=('c'*64);Stderr=''}
            } -ParameterFilter {$Arguments[0] -eq 'run'}
            $r=Invoke-MutatorGitImageValidation -ModuleRoot $workspace -OS Linux -OutputDirectory $output
            $r.Outcome|Should -Be Failed
            $r.Platforms.Linux.Error|Should -Match 'complete validation gate'
        }
    }
}

Describe 'Host-owned Git guest report directories' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        It 'prepares the complete selected report layout before guest execution: baseline <BaselineOnly>' -ForEach @(@{BaselineOnly=$true},@{BaselineOnly=$false}) {
            $path=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            Initialize-MutatorGitImageReports -Path $path -BaselineOnly:$BaselineOnly
            foreach($suite in @('unit','integration','coverage')){Test-Path (Join-Path $path ($suite+'/FrenchExDev.QuietCli.Git.PoSh')) -PathType Container|Should -BeTrue}
            Test-Path (Join-Path $path 'mutations/FrenchExDev.QuietCli.Git.PoSh/runs/packages/p0000') -PathType Container|Should -Be (!$BaselineOnly)
            $marker=Join-Path $path 'unit/FrenchExDev.QuietCli.Git.PoSh/retained.json'
            [IO.File]::WriteAllText($marker,'retained proof')
            Initialize-MutatorGitImageReports -Path $path -BaselineOnly:$BaselineOnly
            [IO.File]::ReadAllText($marker)|Should -BeExactly 'retained proof'
        }
    }
}

Describe 'Git image build ownership' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            $workspace=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $git=Join-Path $workspace 'FrenchExDev.QuietCli.Git.PoSh'
            Write-MutatorJson (Join-Path $git 'containers/image.json') @{Git=@{Version='2.56.0'}}
            Mock Import-Module {} -ParameterFilter {$Name -like '*FrenchExDev.CliEnvironment.PoSh*'}
            Mock Resolve-MutatorEngineSelection {'Docker'}
            Mock New-CliEnvironmentGitImage {@{Outcome='Built';Image='pinned-git';ImageId=('b'*64);Fingerprint=('a'*64)}}
            Mock Invoke-MutatorContainerCommand {throw 'The legacy builder must not execute.'}
        }
        It 'delegates Git builds to CliEnvironment with the selected engine and budgets' {
            $r=New-MutatorContainerImage -ModulePath $git -Platform Windows -ContainerEngine Docker -Connection fixture-context -OutputDirectory (Join-Path $workspace 'reports') -MemoryMiB 3072 -Cpus 3 -TimeoutSeconds 120
            $r.Outcome|Should -Be Success
            $r.Owner|Should -Be CliEnvironment
            $r.ImageId|Should -Be ('b'*64)
            Should -Invoke New-CliEnvironmentGitImage -Times 1 -ParameterFilter {$ModuleRoot -eq $workspace -and $Platform -eq 'Windows' -and $Engine -eq 'Docker' -and $Connection -eq 'fixture-context' -and $MemoryMiB -eq 3072 -and $Cpus -eq 3 -and $TimeoutSeconds -eq 120}
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -Exactly
        }
        It 'propagates failed shared builds instead of falling back to an unpinned recipe' {
            Mock New-CliEnvironmentGitImage {@{Outcome='Blocked';Error='Windows base is not ready.'}}
            {New-MutatorContainerImage -ModulePath $git -OutputDirectory (Join-Path $workspace 'reports')}|Should -Throw '*Windows base is not ready*'
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -Exactly
        }
        It 'rejects arbitrary bases and performs no build with WhatIf' {
            {New-MutatorContainerImage -ModulePath $git -OutputDirectory $workspace -BaseImage arbitrary}|Should -Throw '*pinned CliEnvironment base*'
            $null=New-MutatorContainerImage -ModulePath $git -OutputDirectory $workspace -WhatIf
            Should -Invoke New-CliEnvironmentGitImage -Times 0 -Exactly
        }
    }
}
