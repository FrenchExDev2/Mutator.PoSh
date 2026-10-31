<#
.SYNOPSIS
Expected behavior for the GuestBase tests.

.DESCRIPTION
Provisioning requires owned storage, verified KVM/resources and matching readiness pins.
Cancellation, OOM, abnormal exits and installation failures cannot be overridden by late green
proof; restart/stop must preserve ownership.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Managed Windows base lifecycle' {
    BeforeEach {
        $script:GuestFixture=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            [void][IO.Directory]::CreateDirectory((Join-Path $Root 'share'))
            $script:GuestRoot=$Root
            $script:GuestRun=@{Kind='WindowsBase';RunId='fixture';ContainerId=('c'*64);Container='owned';Volume='owned-volume';Fingerprint='fp';ModuleRoot=$Root;Path=$Root
                Connection='fixture';Share=(Join-Path $Root 'share');Outcome='Running';Phase='InstallingWindows';StartedUtc=[datetimeoffset]::UtcNow.AddSeconds(-3).ToString('O')
                ExpectedPowerShell='7.6.7';ExpectedDotnetSdk='10.0.402';ImageId=('a'*64);MemoryMiB=6144;GuestMemoryMiB=4096;DiskGiB=64}
            Write-MutatorJson (Join-Path $Root 'guest.json') $script:GuestRun
            $script:GuestIdentity=@{Id=('c'*64);State=@{Running=$true;ExitCode=0;OOMKilled=$false};Config=@{Labels=@{'org.frenchexdev.mutator.guest-run'='fixture'}}}
            $script:GuestReady=@{Outcome='Success';Fingerprint='fp';PowerShell='7.6.7';DotnetSdk='10.0.402';Tools=@(
                @{Name='Pester';Version='6.2.0'},@{Name='PSMutant';Version='0.6.0'},@{Name='PSScriptAnalyzer';Version='1.25.0'},@{Name='powershell-yaml';Version='0.4.12'})}
            $script:GuestProbe="MemoryMaxBytes=536870912`r`nDiskFreeKiB=100000000`r`nVMAvailableKiB=12000000`r`n"+'{"return":{"enabled":true,"present":true},"id":"mutator-kvm"}'+"`r`n"
            $script:GuestVolumeOwner='fixture'
            $script:GuestActive='[]'
            Mock Get-MutatorContainerRuntime { @{Fingerprint='fp';Runtime=@{Version='7.6.7'};Versions=@{Windows=@{'dotnet-sdk'='10.0.402'}}} }
            Mock Invoke-MutatorContainerCommand {
                param($Arguments)
                $text=switch($Arguments[0]){
                    'info' {'{"host":{"cgroupControllers":["memory","cpu"]}}'}
                    'image' {ConvertTo-Json -InputObject @(@{Id=('a'*64);Os='linux';Config=@{Labels=@{'org.frenchexdev.mutator.base'='windows';'org.frenchexdev.mutator.fingerprint'='fp'}}}) -Depth 5 -Compress}
                    'run' {$script:GuestProbe}
                    'inspect' {ConvertTo-Json -InputObject @($script:GuestIdentity) -Depth 6 -Compress}
                    'logs' {'Booting Windows'}
                    'ps' {$script:GuestActive}
                    'volume' {if($Arguments[1] -eq 'inspect'){ConvertTo-Json -InputObject @(@{Labels=@{'org.frenchexdev.mutator.guest-run'=$script:GuestVolumeOwner}}) -Depth 4 -Compress}else{$Arguments[-1]}}
                    'create' {
                        $label=@($Arguments|Where-Object {$_ -like 'org.frenchexdev.mutator.guest-run=*'})[0]
                        $script:GuestIdentity.Config.Labels['org.frenchexdev.mutator.guest-run']=$label.Substring('org.frenchexdev.mutator.guest-run='.Length)
                        'c'*64
                    }
                    'start' {'c'*64}
                    'exec' {$script:GuestIdentity.State.Running=$false;'{}'}
                    'stop' {$script:GuestIdentity.State.Running=$false;'c'*64}
                    default {throw 'Unexpected Podman command in guest test.'}
                }
                @{Outcome='Success';ExitCode=0;Stdout=$text;Stderr=''}
            }
        }
    }
    It 'parses actual KVM and memory evidence with Windows CRLF capture framing' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            $proof=Test-MutatorGuestHost -Image fixture -OutputDirectory (Join-Path $Root 'probe') -Connection fixture
            $proof.Outcome|Should -BeExactly Success
            $proof.KvmEnabled|Should -BeTrue
            $proof.MemoryMaxBytes|Should -Be 536870912
        }
    }
    It 'refuses insufficient <Metric> before guest creation' -ForEach @(
        @{Metric='DiskFreeKiB';Original='100000000';Value='1'}
        @{Metric='VMAvailableKiB';Original='12000000';Value='1'}
        @{Metric='MemoryMaxBytes';Original='536870912';Value='1073741824'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture;Original=$Original;Value=$Value} {
            param($Root,$Original,$Value)
            $script:GuestProbe=$script:GuestProbe.Replace($Original,$Value)
            {Test-MutatorGuestHost -Image fixture -OutputDirectory (Join-Path $Root 'probe')}|Should -Throw
            (Read-MutatorJson (Join-Path $Root 'probe/preflight.json')).Outcome|Should -BeExactly Failed
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'create'}
        }
    }
    It 'creates a new bounded guest after independent KVM checks' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            $run=Start-MutatorGuestBase -Image fixture -ModuleRoot $Root -OutputDirectory (Join-Path $Root 'new') -Connection fixture
            $run.Phase|Should -BeExactly InstallingWindows
            $run.GuestMemoryMiB|Should -Be 4096
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'create' -and $Arguments -contains 'RAM_CHECK=N' -and $Arguments -contains 'RAM_SIZE=4096M' -and $Arguments -contains '6144m' -and $Arguments -contains '127.0.0.1::8006' -and $Arguments -contains ('a'*64)}
        }
    }
    It 'rejects a second active managed base instead of starting another VM' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            $script:GuestActive='[{"Id":"other"}]'
            {Start-MutatorGuestBase -Image fixture -ModuleRoot $Root -OutputDirectory (Join-Path $Root 'new')}|Should -Throw '*Another managed*'
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'create'}
        }
    }
    It 'reuses retained media only through explicit resume of stopped owned storage' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            $script:GuestIdentity.State.Running=$false
            $run=Start-MutatorGuestBase -Image fixture -ModuleRoot $Root -OutputDirectory (Join-Path $Root 'resume') -Connection fixture -ResumeFrom $Root
            $run.Volume|Should -BeExactly 'owned-volume'
            $run.VolumeOwnerRunId|Should -BeExactly fixture
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'volume' -and $Arguments[1] -eq 'create'}
        }
    }
    It 'refuses resuming storage with a foreign owner' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            $script:GuestIdentity.State.Running=$false;$script:GuestVolumeOwner='foreign'
            {Start-MutatorGuestBase -Image fixture -ModuleRoot $Root -OutputDirectory (Join-Path $Root 'resume') -Connection fixture -ResumeFrom $Root}|Should -Throw '*does not belong*'
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'create'}
        }
    }
    It 'refuses to rerun preparation of a base that already has a readiness proof' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            $script:GuestIdentity.State.Running=$false
            Write-MutatorJson (Join-Path $Root 'share/base-ready.json') $script:GuestReady
            {Start-MutatorGuestBase -Image fixture -ModuleRoot $Root -OutputDirectory (Join-Path $Root 'resume') -Connection fixture -ResumeFrom $Root}|Should -Throw '*must be exported*'
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'create'}
        }
    }
    It 'calculates elapsed time using the UTC instant' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            $result=Get-MutatorGuestBase $Root
            $result.ElapsedSeconds|Should -BeGreaterOrEqual 0
            $result.ElapsedSeconds|Should -BeLessThan 60
            $result.Ready|Should -BeFalse
        }
    }
    It 'accepts verified readiness but requires a clean stop for success' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            Write-MutatorJson (Join-Path $Root 'share/base-ready.json') $script:GuestReady
            $running=Get-MutatorGuestBase $Root
            $running.Ready|Should -BeTrue
            $running.Outcome|Should -BeExactly Running
            $stopped=Stop-MutatorGuestBase $Root
            $stopped.Outcome|Should -BeExactly Success
            $stopped.Running|Should -BeFalse
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'exec' -and $Arguments -contains ('c'*64)}
        }
    }
    It 'lets the wait controller stop a ready guest without polling again' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            Write-MutatorJson (Join-Path $Root 'share/base-ready.json') $script:GuestReady
            $result=Wait-MutatorGuestBase $Root -StopWhenReady
            $result.Outcome|Should -BeExactly Success
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'exec'}
        }
    }
    It 'rejects the wrong <Field> in the readiness proof' -ForEach @(
        @{Field='Fingerprint';Value='other'}
        @{Field='PowerShell';Value='7.5.0'}
        @{Field='DotnetSdk';Value='10.0.100'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture;Field=$Field;Value=$Value} {
            param($Root,$Field,$Value)
            $script:GuestReady[$Field]=$Value
            Write-MutatorJson (Join-Path $Root 'share/base-ready.json') $script:GuestReady
            (Get-MutatorGuestBase $Root).Outcome|Should -BeExactly Failed
        }
    }
    It 'refuses duplicate tools and preserves a prior guest installation failure' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            $script:GuestReady.Tools=@($script:GuestReady.Tools[0]) * 4
            Write-MutatorJson (Join-Path $Root 'share/base-ready.json') $script:GuestReady
            (Get-MutatorGuestBase $Root).Ready|Should -BeFalse
            Write-MutatorJson (Join-Path $Root 'share/guest-failed.json') @{Error='original install failure'}
            $result=Get-MutatorGuestBase $Root
            $result.Error|Should -BeExactly 'original install failure'
            $result.Outcome|Should -BeExactly Failed
        }
    }
    It 'does not promote an OOM-killed guest to success' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            Write-MutatorJson (Join-Path $Root 'share/base-ready.json') $script:GuestReady
            $script:GuestIdentity.State.Running=$false;$script:GuestIdentity.State.OOMKilled=$true;$script:GuestIdentity.State.ExitCode=137
            (Get-MutatorGuestBase $Root).Outcome|Should -BeExactly Failed
        }
    }
    It 'does not label a ready guest with exit 143 as a successful stop or cancellation' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            $script:GuestRun.CancelRequested=$true;Write-MutatorJson (Join-Path $Root 'guest.json') $script:GuestRun
            Write-MutatorJson (Join-Path $Root 'share/base-ready.json') $script:GuestReady
            $script:GuestIdentity.State.Running=$false;$script:GuestIdentity.State.ExitCode=143
            $result=Get-MutatorGuestBase $Root
            $result.Outcome|Should -BeExactly Failed
            $result.Phase|Should -BeExactly ShutdownUnverified
        }
    }
    It 'restarts a verified stopped base without recreating its volume or reinstalling' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            Write-MutatorJson (Join-Path $Root 'share/base-ready.json') $script:GuestReady
            $script:GuestIdentity.State.Running=$false
            $result=Restart-MutatorGuestBase $Root
            $result.Outcome|Should -BeExactly Running
            $result.Volume|Should -BeExactly 'owned-volume'
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'start'}
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -in @('volume','create')}
        }
    }
    It 'refuses restarting an unverified base' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            $script:GuestIdentity.State.Running=$false
            {Restart-MutatorGuestBase $Root}|Should -Throw '*verified prepared base*'
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'start'}
        }
    }
    It 'keeps cancellation terminal even if a late proof arrives' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            (Stop-MutatorGuestBase $Root).Outcome|Should -BeExactly Cancelled
            Write-MutatorJson (Join-Path $Root 'share/base-ready.json') $script:GuestReady
            (Get-MutatorGuestBase $Root).Outcome|Should -BeExactly Cancelled
        }
    }
    It 'refuses to stop a container whose ownership label changed' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            $script:GuestIdentity.Config.Labels['org.frenchexdev.mutator.guest-run']='foreign'
            {Stop-MutatorGuestBase $Root}|Should -Throw '*no longer belongs*'
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'stop'}
        }
    }
    It 'honors WhatIf without creating a guest or a volume' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            $null=Start-MutatorGuestBase -Image fixture -ModuleRoot $Root -OutputDirectory (Join-Path $Root 'preview') -WhatIf
            Test-Path (Join-Path $Root 'preview')|Should -BeFalse
            Should -Invoke Invoke-MutatorContainerCommand -Times 0
        }
    }
    It 'retains bootstrap failures at their original stage: <Stage>' -ForEach @(
        @{Stage='image';Expected='*not available locally*'},@{Stage='create';Expected='*container could not be created*'},
        @{Stage='volume';Expected='*storage volume could not be created*'},@{Stage='start';Expected='*startup failed*'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture;Stage=$Stage;Expected=$Expected} {
            param($Root,$Stage,$Expected)
            $script:GuestStartupFault=$Stage
            Mock Test-MutatorGuestHost {@{Outcome='Success'}}
            Mock Invoke-MutatorContainerCommand {@{Outcome='Failed';Stdout='';Stderr='retained cause'}} -ParameterFilter {$Arguments[0] -ceq $script:GuestStartupFault}
            $output=Join-Path $Root 'failed-start'
            {Start-MutatorGuestBase -ModuleRoot $Root -Image image -OutputDirectory $output}|Should -Throw $Expected
            $receipt=Read-MutatorJson (Join-Path $output 'guest.json')
            $receipt.Outcome|Should -BeExactly Failed;$receipt.Error|Should -BeLike $Expected
            $receipt.ContainerEngine|Should -BeExactly Podman
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'rm'}
        }
    }
    It 'rejects a wrong base identity and insufficient wrapper memory before booting' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            {Start-MutatorGuestBase -ModuleRoot $Root -Image image -OutputDirectory (Join-Path $Root 'ram') -MemoryMiB 4096}|Should -Throw '*Reserve at least 1024*'
            Mock Invoke-MutatorContainerCommand {@{Outcome='Success';Stdout='[{"Os":"windows","Id":"invalid","Config":{"Labels":{}}}]'}} -ParameterFilter {$Arguments[0] -eq 'image'}
            {Start-MutatorGuestBase -ModuleRoot $Root -Image image -OutputDirectory (Join-Path $Root 'wrong-base')}|Should -Throw '*does not match*'
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -in @('create','start')}
        }
    }
    It 'reports Windows download, extraction and boot phases without treating logs as readiness: <Text>' -ForEach @(
        @{Text='Downloading Windows';Phase='DownloadingWindows'},@{Text='Extracting Windows';Phase='ExtractingWindows'},@{Text='Booting Windows';Phase='InstallingWindows'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture;Text=$Text;Phase=$Phase} {
            param($Root,$Text,$Phase)
            $script:GuestLogText=$Text
            Mock Invoke-MutatorContainerCommand {@{Outcome='Success';Stdout=$script:GuestLogText;Stderr=''}} -ParameterFilter {$Arguments[0] -eq 'logs'}
            $r=Get-MutatorGuestBase $Root
            $r.Phase|Should -BeExactly $Phase;$r.Ready|Should -BeFalse
            [IO.File]::ReadAllText((Join-Path $Root 'container-tail.log'))|Should -BeExactly $Text
        }
    }
    It 'ignores incomplete and non-object readiness publications: <Content>' -ForEach @(@{Content='{incomplete'},@{Content='[1,2]'}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture;Content=$Content} {
            param($Root,$Content)
            [IO.File]::WriteAllText((Join-Path $Root 'share/base-ready.json'),$Content)
            $r=Get-MutatorGuestBase $Root
            $r.Ready|Should -BeFalse;$r.Outcome|Should -BeExactly Running
        }
    }
    It 'returns a retained guest that never acquired a container without invoking the runtime' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture} {
            param($Root)
            $script:GuestRun.ContainerId=$null;Write-MutatorJson (Join-Path $Root 'guest.json') $script:GuestRun
            (Get-MutatorGuestBase $Root).Running|Should -BeFalse
            Should -Invoke Invoke-MutatorContainerCommand -Times 0
        }
    }
    It 'polls readiness, updates UI and preserves a terminal timeout: <Mode>' -ForEach @(
        @{Mode='Ready'},@{Mode='StopReady'},@{Mode='Wait'},@{Mode='Failed'},@{Mode='Cancelled'},@{Mode='TimedOut'},@{Mode='Timeout'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:GuestFixture;Mode=$Mode} {
            param($Root,$Mode)
            $script:WaitMode=$Mode;$script:WaitCalls=0;$script:WaitClock=[datetimeoffset]'2026-01-01T00:00:00Z'
            Mock Get-MutatorUtcNow {$script:WaitClock}
            Mock Start-Sleep {$script:WaitClock=$script:WaitClock.AddMinutes(2)}
            Mock Write-Progress {}
            Mock Stop-MutatorGuestBase {[pscustomobject]@{Outcome='Success';Phase='Stopped';Ready=$true;Running=$false}}
            Mock Get-MutatorGuestBase {
                $script:WaitCalls++
                [pscustomobject]@{Kind='WindowsBase';RunId='fixture';Outcome=$(if($script:WaitMode -in @('Failed','Cancelled','TimedOut')){$script:WaitMode}else{'Running'});Error='retained installer cause';Phase='Provisioning';ElapsedSeconds=1;Running=$true
                    Ready=($script:WaitMode -in @('Ready','StopReady') -or ($script:WaitMode -eq 'Wait' -and $script:WaitCalls -gt 1))}
            }
            if($Mode -eq 'Failed'){
                {Wait-MutatorGuestBase $Root -UI -StopWhenReady}|Should -Throw '*retained installer cause*'
                Should -Invoke Stop-MutatorGuestBase -Times 1 -Exactly
            }elseif($Mode -eq 'Timeout'){
                {Wait-MutatorGuestBase $Root -TimeoutMinutes 1 -UI}|Should -Throw '*timed out*retained*'
                (Read-MutatorJson (Join-Path $Root 'guest.json')).Outcome|Should -BeExactly TimedOut
            }else{
                $r=Wait-MutatorGuestBase $Root -UI -StopWhenReady:($Mode -eq 'StopReady')
                if($Mode -in @('Cancelled','TimedOut')){$r.Outcome|Should -BeExactly $Mode}
                else{$r.Ready|Should -BeTrue;Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter {$Completed}}
                if($Mode -eq 'Wait'){Should -Invoke Start-Sleep -Times 1 -Exactly}
                if($Mode -eq 'StopReady'){Should -Invoke Stop-MutatorGuestBase -Times 1 -Exactly}
            }
        }
    }
}
