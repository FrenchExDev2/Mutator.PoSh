<#
.SYNOPSIS
Expected behavior for the ValidationContainer tests.

.DESCRIPTION
Run only an owned source-bound payload with explicit budgets and matching module/suite manifests.
Native exit contradictions, missing reports and stale identities fail; retain containers when proof
recovery fails.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Owned validation container lifecycle' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            $script:TransportProof=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:TransportID='b'*64
            $script:TransportOS='Linux'
            $script:TransportAlive=$false
            $script:TransportCalls=[Collections.Generic.List[object]]::new()
            $script:TransportRequest=@{RunId='owned-run';OS='Linux';Modules=@('Fixture.Validation');Test=@('Unit');MemoryBudgetMiB=4096}
            $script:TransportRun=@{Id='owned-run';Path=$script:TransportProof;Outcome='Running';Platforms=@{Linux=@{Outcome='Running';Phase='Preparing'};Windows=@{Outcome='NotSelected'};MacOS=@{Outcome='NotSelected'}}}
            Mock Get-MutatorValidationImage { @{ImageId=('a'*64);Fingerprint='runtime';Reused=$true} }
            $script:TransportOriginalCopy=(Get-Command Copy-MutatorTree).ScriptBlock
            Mock Copy-MutatorTree {
                param($Source,$Destination)
                if($Source.Replace('\','/') -like '*definitions/bootstrap'){& $script:TransportOriginalCopy $Source $Destination}
                else{[void][IO.Directory]::CreateDirectory($Destination)}
            }
            Mock Get-MutatorSourceSnapshot { @{Sha256='fixed'} }
            Mock Test-MutatorGuestHost {}
            Mock Invoke-MutatorValidationContainerCommand {
                param($Arguments)
                $script:TransportCalls.Add($Arguments)
                switch($Arguments[0]){
                    create {@{Outcome='Success';Stdout=$script:TransportID}}
                    wait {@{Outcome='Success';Stdout='0'}}
                    inspect {@{Outcome='Success';Stdout=(@(@{Id=$script:TransportID;State=@{Running=$script:TransportAlive;ExitCode=0};Config=@{Labels=@{'org.frenchexdev.mutator.validation'='owned-run'}}})|ConvertTo-Json -Depth 6 -Compress)}}
                    cp {
                        if($Arguments[1] -like '*:/opt/validation/reports/*' -or $Arguments[1] -like '*:/shared/mutator/reports/*'){
                            Write-MutatorJson (Join-Path $Arguments[2] 'result.json') @{RunId='owned-run';OS=$script:TransportOS;SourceSha256='fixed';Outcome='Success';Suites=@{Unit=@{Outcome='Success'}};Modules=@{'Fixture.Validation'=@{Outcome='Success'}}}
                        }
                        @{Outcome='Success';Stdout=''}
                    }
                    default {@{Outcome='Success';Stdout=''}}
                }
            }
            Mock Invoke-MutatorContainerCommand {
                param($Arguments)
                $script:TransportCalls.Add($Arguments)
                if($Arguments[0] -eq 'inspect'){@{Outcome='Success';Stdout=(@(@{Id=$script:TransportID;State=@{Running=$script:TransportAlive};Config=@{Labels=@{'org.frenchexdev.mutator.validation'='owned-run'}}})|ConvertTo-Json -Depth 6 -Compress)}}
                elseif($Arguments[0] -eq 'exec'){
                    @{Outcome='Success';Stdout=$(if($Arguments[-1] -like '*progress.json*'){'{"Phase":"Pester","CompletionPercent":50}'}else{'complete'});Stderr=''}
                }
                else{@{Outcome='Success';Stdout='';Stderr=''}}
            }
        }
        It 'copies payload and reports without host bind mounts and removes only its owned container' {
            $r=Invoke-MutatorValidationContainer Linux 'frozen' $script:TransportRequest $script:TransportProof 'remote' $script:TransportRun
            $r.Outcome|Should -BeExactly Success
            @($script:TransportCalls|Where-Object {$_[0] -eq 'create'})[0]|Should -Contain '--network=none'
            @($script:TransportCalls|Where-Object {$_ -contains '--mount' -or $_ -contains '--volume'}).Count|Should -Be 0
            @($script:TransportCalls|Where-Object {$_[0] -eq 'rm'})[0]|Should -Contain $script:TransportID
            Test-Path (Join-Path $script:TransportProof 'reports/result.json')|Should -BeTrue
        }
        It 'refuses a foreign ownership label and never removes that container' {
            Mock Invoke-MutatorValidationContainerCommand { @{Outcome='Success';Stdout=(@(@{Id=$script:TransportID;State=@{Running=$false};Config=@{Labels=@{'org.frenchexdev.mutator.validation'='foreign'}}})|ConvertTo-Json -Depth 6 -Compress)} } -ParameterFilter {$Arguments[0] -eq 'inspect'}
            Mock Invoke-MutatorContainerCommand { @{Outcome='Success';Stdout=(@(@{Id=$script:TransportID;State=@{Running=$false};Config=@{Labels=@{'org.frenchexdev.mutator.validation'='foreign'}}})|ConvertTo-Json -Depth 6 -Compress)} } -ParameterFilter {$Arguments[0] -eq 'inspect'}
            {Invoke-MutatorValidationContainer Linux 'frozen' $script:TransportRequest $script:TransportProof 'remote' $script:TransportRun}|Should -Throw '*ownership*'
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -Exactly -ParameterFilter {$Arguments[0] -eq 'rm'}
        }
        It 'rejects a success receipt contradicted by the process exit code' {
            Mock Invoke-MutatorValidationContainerCommand { @{Outcome='Success';Stdout='7'} } -ParameterFilter {$Arguments[0] -eq 'wait'}
            {Invoke-MutatorValidationContainer Linux 'frozen' $script:TransportRequest $script:TransportProof 'remote' $script:TransportRun}|Should -Throw '*exit code*'
        }
        It 'rejects an absent result instead of interpreting container exit zero as test success' {
            Mock Invoke-MutatorValidationContainerCommand { @{Outcome='Success';Stdout=''} } -ParameterFilter {$Arguments[0] -eq 'cp' -and $Arguments[1] -like '*:/opt/validation/reports/*'}
            {Invoke-MutatorValidationContainer Linux 'frozen' $script:TransportRequest $script:TransportProof 'remote' $script:TransportRun}|Should -Throw '*source-bound*'
        }
        It 'retains a stopped container when its reports cannot be recovered' {
            Mock Invoke-MutatorContainerCommand { @{Outcome='Failed';Stdout='';Stderr=''} } -ParameterFilter {$Arguments[0] -eq 'cp'}
            $null=Invoke-MutatorValidationContainer Linux 'frozen' $script:TransportRequest $script:TransportProof 'remote' $script:TransportRun
            Test-Path (Join-Path $script:TransportProof 'retained-container.json')|Should -BeTrue
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -Exactly -ParameterFilter {$Arguments[0] -eq 'rm'}
        }
        It 'stages a guest bootstrap and copies its OS-bound reports: <Platform>' -ForEach @(@{Platform='Windows'},@{Platform='MacOS'}) {
            $script:TransportOS=$Platform;$script:TransportRequest.OS=$Platform;$script:TransportRequest.MemoryBudgetMiB=6144
            $script:TransportRun.Platforms[$Platform]=@{Outcome='Running';Phase='Preparing'}
            $r=Invoke-MutatorValidationContainer $Platform 'frozen' $script:TransportRequest $script:TransportProof 'remote' $script:TransportRun
            $r.Outcome|Should -BeExactly Success
            Test-Path (Join-Path $script:TransportProof 'payload/bootstrap/Install-ImageTool.Original.ps1')|Should -BeTrue
            [IO.File]::ReadAllText((Join-Path $script:TransportProof 'payload/bootstrap/Install-ImageTool.Original.ps1'))|Should -BeExactly ([IO.File]::ReadAllText((Join-Path $script:MutatorRoot 'resources/containers/definitions/bootstrap/Install-ImageTool.ps1')))
            @($script:TransportCalls|Where-Object {$_[0] -eq 'create'})[0]|Should -Contain '/dev/kvm'
            Should -Invoke Test-MutatorGuestHost -Times 1 -Exactly -ParameterFilter {$MemoryMiB -eq 6144}
        }
        It 'reads bounded progress and stops only the owned running guest' {
            $script:TransportOS='Windows';$script:TransportRequest.OS='Windows';$script:TransportRequest.MemoryBudgetMiB=6144;$script:TransportAlive=$true
            $script:TransportRun.Platforms.Windows=@{Outcome='Running';Phase='Preparing'}
            $r=Invoke-MutatorValidationContainer Windows 'frozen' $script:TransportRequest $script:TransportProof remote $script:TransportRun
            $r.Progress.CompletionPercent|Should -Be 50
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -Exactly -ParameterFilter {$Arguments[0] -eq 'stop' -and $TimeoutSeconds -eq 150}
        }
        It 'waits without retrying the command when its completion marker is not yet available' {
            $script:TransportAlive=$true
            Mock Invoke-MutatorContainerCommand { @{Outcome='Success';Stdout='';Stderr=''} } -ParameterFilter {$Arguments[0] -eq 'exec'}
            Mock Start-Sleep {$script:TransportAlive=$false}
            $r=Invoke-MutatorValidationContainer Linux 'frozen' $script:TransportRequest $script:TransportProof remote $script:TransportRun
            $r.Outcome|Should -BeExactly Success
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter {$Seconds -eq 3}
            @($script:TransportCalls|Where-Object {$_[0] -eq 'start'}).Count|Should -Be 1
        }
        It 'enforces the 24 hour deadline and retains the owned container evidence' {
            $script:TransportAlive=$true
            $script:TransportClock=[Collections.Generic.Queue[datetimeoffset]]::new()
            $script:TransportClock.Enqueue([datetimeoffset]'2026-10-27T00:00:00Z');$script:TransportClock.Enqueue([datetimeoffset]'2026-10-28T00:00:00Z')
            Mock Get-MutatorUtcNow {$script:TransportClock.Dequeue()}
            Mock Invoke-MutatorContainerCommand { @{Outcome='Success';Stdout='';Stderr=''} } -ParameterFilter {$Arguments[0] -eq 'exec'}
            {Invoke-MutatorValidationContainer Linux 'frozen' $script:TransportRequest $script:TransportProof remote $script:TransportRun}|Should -Throw '*24 hour timeout*'
        }
        It 'refuses incomplete module manifests even when the receipt says Success' {
            Mock Invoke-MutatorValidationContainerCommand {
                param($Arguments)
                Write-MutatorJson (Join-Path $Arguments[2] 'result.json') @{RunId='owned-run';OS='Linux';SourceSha256='fixed';Outcome='Success';Modules=@{};Suites=@{}}
                @{Outcome='Success';Stdout=''}
            } -ParameterFilter {$Arguments[0] -eq 'cp' -and $Arguments[1] -like '*:/opt/validation/reports/*'}
            {Invoke-MutatorValidationContainer Linux 'frozen' $script:TransportRequest $script:TransportProof remote $script:TransportRun}|Should -Throw '*incomplete*manifest*'
        }
    }
}
Describe 'Validation image identity and bounded transport' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            $script:ImageProof=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:ImageIdentity='a'*64
            Mock Export-MutatorContainerBaseDefinition { @{Images=@{Alpine='pinned-alpine';Windows='pinned-windows';MacOS='pinned-macos'}} }
            Mock Get-MutatorContainerRuntime { @{Fingerprint='runtime';MacFingerprint='mac-runtime'} }
            Mock Invoke-MutatorContainerCommand { @{Outcome='Success';Stdout=(@(@{Id=$script:ImageIdentity;Os='linux';Config=@{Labels=@{'org.frenchexdev.mutator.fingerprint'='runtime'}}})|ConvertTo-Json -Depth 6 -Compress)} }
            Mock New-MutatorContainerImage { @{ImageId=$script:ImageIdentity;Reused=$false} }
        }
        It 'reuses only an immutable image carrying the expected runtime identity' {
            $image=Get-MutatorValidationImage Linux 'source' $script:ImageProof 'connection'
            $image.ImageId|Should -BeExactly $script:ImageIdentity
            $image.Reused|Should -BeTrue
            Should -Invoke New-MutatorContainerImage -Times 0 -Exactly
        }
        It 'refuses a stale image rather than silently accepting another runtime' {
            Mock Get-MutatorContainerRuntime { @{Fingerprint='new-runtime';MacFingerprint='mac-runtime'} }
            {Get-MutatorValidationImage Linux 'source' $script:ImageProof 'connection'}|Should -Throw '*fingerprint*'
        }
        It 'builds the Linux base automatically when it is absent' {
            Mock Invoke-MutatorContainerCommand { @{Outcome='Failed'} }
            $image=Get-MutatorValidationImage Linux 'source' $script:ImageProof 'connection'
            $image.Reused|Should -BeFalse
            Should -Invoke New-MutatorContainerImage -Times 1 -Exactly -ParameterFilter {$BaseVariant -eq 'Alpine' -and $Connection -eq 'connection'}
        }
        It 'returns a useful preparation error for an unavailable macOS seed' {
            Mock Invoke-MutatorContainerCommand { @{Outcome='Failed'} }
            Mock Test-Path {$false}
            {Get-MutatorValidationImage MacOS 'source' $script:ImageProof 'apple'}|Should -Throw '*Prepare and export*MacOS*'
            Should -Invoke New-MutatorContainerImage -Times 0 -Exactly
        }
        It 'does not accept a Linux runtime fingerprint for macOS' {
            {Get-MutatorValidationImage MacOS 'source' $script:ImageProof 'apple'}|Should -Throw '*fingerprint*'
        }
        It 'uses a contributors pinned image so Debian dependencies and its binary are installed' {
            $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            Write-MutatorJson (Join-Path $root 'FrenchExDev.Tools.Npm.PoSh/containers/image.json') @{Platforms=@{Linux=@{Binary='npm';Distribution='Debian'}}}
            $image=Get-MutatorValidationImage Linux $root $script:ImageProof 'connection' @('FrenchExDev.Tools.Npm.PoSh')
            $image.ToolModule|Should -BeExactly FrenchExDev.Tools.Npm.PoSh
            Should -Invoke New-MutatorContainerImage -Times 1 -Exactly -ParameterFilter {$Platform -eq 'Linux' -and $Reuse -and !$BaseVariant}
        }
        It 'rejects competing binary images rather than running without one of the selected tools' {
            $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            foreach($name in @('Npm','Pnpm')){Write-MutatorJson (Join-Path $root ('FrenchExDev.Tools.'+$name+'.PoSh/containers/image.json')) @{Platforms=@{Linux=@{Binary=$name.ToLowerInvariant()}}}}
            {Get-MutatorValidationImage Linux $root $script:ImageProof 'connection' @('FrenchExDev.Tools.Npm.PoSh','FrenchExDev.Tools.Pnpm.PoSh')}|Should -Throw '*one binary contributor*'
            Should -Invoke New-MutatorContainerImage -Times 0 -Exactly
        }
        It 'turns a native timeout into an explicit transport failure' {
            Mock Invoke-MutatorContainerCommand { @{Outcome='Timeout';Failure='deadline'} }
            {Invoke-MutatorValidationContainerCommand @('cp','source','destination') $script:ImageProof 'connection' 12}|Should -Throw '*cp*deadline*'
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -Exactly -ParameterFilter {$TimeoutSeconds -eq 12}
        }
        It 'does not start a guest whose memory reservation exceeds the budget' {
            Mock Get-MutatorValidationImage { @{ImageId=$script:ImageIdentity;Fingerprint='runtime';Reused=$true} }
            Mock Test-MutatorGuestHost {throw 'must not probe'}
            $request=@{MemoryBudgetMiB=2048;Modules=@('Fixture.Validation')}
            {Invoke-MutatorValidationContainer Windows 'source' $request $script:ImageProof 'connection' @{}}|Should -Throw '*6144*'
            Should -Invoke Test-MutatorGuestHost -Times 0 -Exactly
        }
    }
}
