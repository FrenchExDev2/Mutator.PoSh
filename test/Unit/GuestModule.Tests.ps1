BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Windows module guest provisioning and jobs' {
    It 'rejects a nonempty custom share before starting any guest' {
        $share=Join-Path $TestDrive 'occupied'
        [void][IO.Directory]::CreateDirectory($share)
        Set-Content (Join-Path $share 'keep.txt') 'existing data'
        {Start-MutatorGuestModule -Image image -OutputDirectory (Join-Path $TestDrive 'new-guest') -ShareDirectory $share}|Should -Throw '*empty guest share*'
        (Get-Content (Join-Path $share 'keep.txt') -Raw).Trim()|Should -BeExactly 'existing data'
    }
    BeforeEach {
        $script:ModuleGuestRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:ModuleGuestRoot} {
            param($Root)
            [void][IO.Directory]::CreateDirectory((Join-Path $Root 'share/mutator/modules/FrenchExDev.Mutator.PoSh/resources/containers/probes'))
            Set-Content (Join-Path $Root 'share/mutator/modules/FrenchExDev.Mutator.PoSh/resources/containers/probes/Test-WindowsAgImage.ps1') 'fixture'
            $script:ModuleRun=@{Kind='WindowsModule';RunId='owner';Module='FrenchExDev.Tools.Ag.PoSh';ContainerId=('c'*64);ImageId=('a'*64);Connection='fixture';Path=$Root
                Share=(Join-Path $Root 'share');Fingerprint='fp';PayloadIdentity='payload';Outcome='Running';StartedUtc=[datetimeoffset]::UtcNow.ToString('O')}
            Write-MutatorJson (Join-Path $Root 'guest.json') $script:ModuleRun
            $script:ModuleProof=@{Module=$script:ModuleRun.Module;Outcome='Success';Identity='payload';BaseFingerprint='fp'}
            $script:JobReport=@{Passed=37;Failed=0;Skipped=0;DiscoveryErrors=0;AgVersion='2.2.7';Measurement='SourceMeasured'}
            $script:JobForeign=$false;$script:JobFailed=$false
            Mock Invoke-MutatorContainerCommand {
                @{Outcome='Success';Stdout=('[{"Id":"'+('c'*64)+'","State":{"Running":true},"Config":{"Labels":{"org.frenchexdev.mutator.guest-run":"owner"}}}]');Stderr=''}
            }
        }
    }
    It 'accepts only the expected module, base and payload identity' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:ModuleGuestRoot} {
            param($Root)
            Write-MutatorJson (Join-Path $Root 'share/mutator/module-ready.json') $script:ModuleProof
            (Get-MutatorGuestBase $Root).Ready|Should -BeTrue
            $script:ModuleProof.Identity='other'
            Write-MutatorJson (Join-Path $Root 'share/mutator/module-ready.json') $script:ModuleProof
            (Get-MutatorGuestBase $Root).Outcome|Should -BeExactly Failed
        }
    }
    It 'preserves a module failure instead of accepting a late green receipt' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:ModuleGuestRoot} {
            param($Root)
            Write-MutatorJson (Join-Path $Root 'share/mutator/module-failed.json') @{Error='install failed'}
            Write-MutatorJson (Join-Path $Root 'share/mutator/module-ready.json') $script:ModuleProof
            $result=Get-MutatorGuestBase $Root
            $result.Outcome|Should -BeExactly Failed
            $result.Error|Should -BeExactly 'install failed'
        }
    }
    It 'restarts the verified module without reusing a foreign payload or recreating its volume' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:ModuleGuestRoot} {
            param($Root)
            $script:ModuleRun.MemoryMiB=6144;$script:ModuleRun.DiskGiB=64;$script:ModuleRun.Volume='module-volume'
            Write-MutatorJson (Join-Path $Root 'guest.json') $script:ModuleRun
            Write-MutatorJson (Join-Path $Root 'share/mutator/module-ready.json') $script:ModuleProof
            Mock Test-MutatorGuestHost { @{Outcome='Success'} }
            Mock Invoke-MutatorContainerCommand {
                param($Arguments)
                if($Arguments[0] -eq 'inspect'){return @{Outcome='Success';Stdout=('[{"Id":"'+('c'*64)+'","State":{"Running":false},"Config":{"Labels":{"org.frenchexdev.mutator.guest-run":"owner"}}}]')}}
                @{Outcome='Success';Stdout=$(if($Arguments[0] -eq 'ps'){'[]'}else{''})}
            }
            $result=Restart-MutatorGuestBase $Root
            $result.Outcome|Should -BeExactly Running
            $result.Volume|Should -BeExactly 'module-volume'
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'start'}
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -in @('create','volume')}
        }
    }
    It 'stages the adapter while preserving the original installer and uses a fresh bounded overlay' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:ModuleGuestRoot} {
            param($Root)
            Mock Test-MutatorGuestHost { @{Outcome='Success'} }
            Mock Copy-MutatorTree {param($Source,$Destination);if(!$Source){throw 'Missing source'};[void][IO.Directory]::CreateDirectory($Destination)}
            Mock Get-MutatorSourceSnapshot { @{Sha256='staged'} }
            Mock Invoke-MutatorContainerCommand {
                param($Arguments)
                if($Arguments[0] -eq 'image'){return @{Outcome='Success';Stdout=('[{"Os":"linux","Id":"'+('a'*64)+'","Config":{"Labels":{"org.frenchexdev.mutator.module":"FrenchExDev.Tools.Ag.PoSh","org.frenchexdev.mutator.guest-os":"windows","org.frenchexdev.mutator.fingerprint":"fp"}}}]')}}
                if($Arguments[0] -eq 'run'){
                    $mount=@($Arguments|Where-Object {$_ -like '*:/out'})[0];$target=$mount.Substring(0,$mount.Length-':/out'.Length)
                    [void][IO.Directory]::CreateDirectory((Join-Path $target 'mutator/bootstrap'))
                    Write-MutatorJson (Join-Path $target 'mutator/image.json') @{Module='FrenchExDev.Tools.Ag.PoSh';BaseFingerprint='fp'}
                    Set-Content (Join-Path $target 'mutator/tool-inputs.txt') "`n`n"
                    Set-Content (Join-Path $target 'mutator/bootstrap/Install-ImageTool.ps1') 'original installer'
                }
                @{Outcome='Success';Stdout=('c'*64);Stderr=''}
            }
            $result=Start-MutatorGuestModule -Image tag -OutputDirectory (Join-Path $Root 'new') -ShareDirectory (Join-Path $Root 'compact-share') -Connection fixture
            $result.Kind|Should -BeExactly WindowsModule
            $result.Share|Should -BeExactly (Join-Path $Root 'compact-share')
            (Get-Content (Join-Path $result.Share 'mutator/bootstrap/Install-ImageTool.Original.ps1') -Raw).Trim()|Should -BeExactly 'original installer'
            Test-Path (Join-Path $result.Share 'mutator/bootstrap/Invoke-GuestJobs.ps1')|Should -BeTrue
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'create' -and $Arguments -contains ('a'*64) -and $Arguments -contains '6144m' -and $Arguments -contains 'RAM_SIZE=4096M'}
        }
    }
    It 'retains the failed provisioning stage without deleting evidence: <Fault>' -ForEach @(
        @{Fault='image';Message='*image is unavailable*'},@{Fault='ImageOs';Message='*dockurr FrenchExDev module image is required*'},
        @{Fault='ImageId';Message='*dockurr FrenchExDev module image is required*'},@{Fault='GuestOs';Message='*dockurr FrenchExDev module image is required*'},
        @{Fault='Module';Message='*dockurr FrenchExDev module image is required*'},@{Fault='run';Message='*payload could not be staged*'},
        @{Fault='Metadata';Message='*metadata differs*'},@{Fault='volume';Message='*overlay volume could not be created*'},
        @{Fault='create';Message='*guest could not be created*'},@{Fault='ContainerId';Message='*guest could not be created*'},
        @{Fault='start';Message='*guest could not start*'},@{Fault='control';Message='*cancellation endpoint could not start*'},
        @{Fault='health';Message='*owner/runtime health check*'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:ModuleGuestRoot;Fault=$Fault;Expected=$Message} {
            param($Root,$Fault,$Expected)
            $script:ProvisionFault=$Fault
            Mock Test-MutatorGuestHost {@{Outcome='Success'}}
            Mock Copy-MutatorTree {param($Destination) [void][IO.Directory]::CreateDirectory($Destination)}
            Mock Get-MutatorSourceSnapshot {@{Sha256='frozen'}}
            Mock Invoke-MutatorContainerCommand {
                param($Arguments)
                $stage=if($Arguments[0] -eq 'exec'){if($Arguments -contains '--detach'){'control'}else{'health'}}else{$Arguments[0]}
                if($stage -eq $script:ProvisionFault){return @{Outcome='Failed';Stdout='';Stderr='retained failure'}}
                if($stage -eq 'image'){
                    $image=@{Os='linux';Id=('a'*64);Config=@{Labels=@{'org.frenchexdev.mutator.module'='FrenchExDev.Tools.Ag.PoSh';'org.frenchexdev.mutator.guest-os'='windows';'org.frenchexdev.mutator.fingerprint'='fp'}}}
                    switch($script:ProvisionFault){'ImageOs' {$image.Os='windows'};'ImageId' {$image.Id='invalid'};'GuestOs' {$image.Config.Labels['org.frenchexdev.mutator.guest-os']='linux'};'Module' {$image.Config.Labels['org.frenchexdev.mutator.module']='Foreign'}}
                    return @{Outcome='Success';Stdout=(ConvertTo-Json -InputObject @($image) -Depth 5 -Compress);Stderr=''}
                }
                if($stage -eq 'run'){
                    $mount=@($Arguments|Where-Object {$_ -like '*:/out'})[0];$share=$mount.Substring(0,$mount.Length-5)
                    [void][IO.Directory]::CreateDirectory((Join-Path $share 'mutator/bootstrap'))
                    Write-MutatorJson (Join-Path $share 'mutator/image.json') @{Module=$(if($script:ProvisionFault -eq 'Metadata'){'Foreign'}else{'FrenchExDev.Tools.Ag.PoSh'});BaseFingerprint='fp'}
                    [IO.File]::WriteAllText((Join-Path $share 'mutator/tool-inputs.txt'),'pinned inputs')
                    [IO.File]::WriteAllText((Join-Path $share 'mutator/bootstrap/Install-ImageTool.ps1'),'original installer')
                }
                @{Outcome='Success';Stdout=$(if($stage -eq 'create' -and $script:ProvisionFault -eq 'ContainerId'){'invalid'}else{'c'*64});Stderr=''}
            }
            $output=Join-Path $Root 'failed-provision'
            {Start-MutatorGuestModule -Image fixture -OutputDirectory $output -Connection selected}|Should -Throw $Expected
            $receipt=Read-MutatorJson (Join-Path $output 'guest.json')
            $receipt.Outcome|Should -BeExactly Failed;$receipt.Error|Should -BeLike $Expected
            $receipt.Share|Should -BeExactly (Join-Path $output 'share')
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -in @('rm','rmi')}
        }
    }
    It 'refuses insufficient wrapper RAM and existing receipts before starting any container' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:ModuleGuestRoot} {
            param($Root)
            {Start-MutatorGuestModule -Image fixture -OutputDirectory $Root -MemoryMiB 4096}|Should -Throw '*Reserve at least 1024*'
            {Start-MutatorGuestModule -Image fixture -OutputDirectory $Root}|Should -Throw '*new module guest directory*'
            $null=Start-MutatorGuestModule -Image fixture -OutputDirectory (Join-Path $Root 'whatif') -WhatIf
            Test-Path (Join-Path $Root 'whatif')|Should -BeFalse
            Should -Invoke Invoke-MutatorContainerCommand -Times 0
        }
    }
    Context 'Validated job results' {
        BeforeEach {
            InModuleScope FrenchExDev.Mutator.PoSh {
                Mock Get-MutatorGuestBase { [pscustomobject]@{Outcome='Running';Ready=$true;Running=$true} }
                Mock Read-MutatorJson {
                    param($Path)
                    if((Split-Path $Path -Leaf) -eq 'result.json'){
                        $request=Get-Content (Join-Path (Split-Path $Path) 'request.json') -Raw|ConvertFrom-Json -AsHashtable
                        return @{RunId=$request.RunId;JobId=$(if($script:JobForeign){'foreign'}else{$request.JobId});Outcome=$(if($script:JobFailed){'Failed'}else{'Success'});ExitCode=$(if($script:JobFailed){1}else{0})}
                    }
                    if((Split-Path $Path -Leaf) -eq 'qualification.json'){return $script:JobReport}
                    if(Test-Path $Path){Get-Content $Path -Raw|ConvertFrom-Json -AsHashtable -DateKind String}
                }
            }
        }
        It 'binds the job to its owner and staged fixture hash' {
            InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:ModuleGuestRoot} {
                param($Root)
                $result=Invoke-MutatorGuestValidation $Root
                $result.Outcome|Should -BeExactly Success
                $result.Passed|Should -Be 37
                $request=Get-Content (Join-Path $result.Path 'request.json') -Raw|ConvertFrom-Json
                $request.RunId|Should -BeExactly owner
                $request.Type|Should -BeExactly AgQualification
                $request.FixtureSha256|Should -BeExactly (Get-FileHash (Join-Path $Root 'share/mutator/modules/FrenchExDev.Mutator.PoSh/resources/containers/probes/Test-WindowsAgImage.ps1')).Hash
            }
        }
        It 'rejects a failed or foreign job' -ForEach @(@{Fault='failed'},@{Fault='foreign'}) {
            InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:ModuleGuestRoot;Fault=$Fault} {
                param($Root,$Fault)
                $validationPath=$Root
                if($Fault -eq 'failed'){$script:JobFailed=$true}else{$script:JobForeign=$true}
                {Invoke-MutatorGuestValidation $validationPath}|Should -Throw '*job failed or returned a foreign*'
            }
        }
        It 'fails the gate for invalid <Field>' -ForEach @(
            @{Field='Passed';Value=0},@{Field='Passed';Value='unknown'},@{Field='Failed';Value=1},@{Field='Skipped';Value=1},@{Field='DiscoveryErrors';Value=1}
        ) {
            InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:ModuleGuestRoot;Field=$Field;Value=$Value} {
                param($Root,$Field,$Value)
                $validationPath=$Root
                $script:JobReport[$Field]=$Value
                {Invoke-MutatorGuestValidation $validationPath}|Should -Throw
            }
        }
    }
    It 'honors WhatIf before staging a payload or submitting jobs' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:ModuleGuestRoot} {
            param($Root)
            $null=Start-MutatorGuestModule -Image tag -OutputDirectory (Join-Path $Root 'preview') -WhatIf
            $null=Invoke-MutatorGuestValidation $Root -WhatIf
            Test-Path (Join-Path $Root 'preview')|Should -BeFalse
            Should -Invoke Invoke-MutatorContainerCommand -Times 0
        }
    }
}
