BeforeAll {
    $script:MacDefinitions=Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'resources/containers/definitions/macos'
    function Write-MacFixtureJson {param($Path,$Value) [void][IO.Directory]::CreateDirectory((Split-Path $Path));[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 8))}
}
Describe 'macOS bootstrap contracts run without a macOS guest' {
    BeforeEach {
        $script:MacEnvironmentPath=$env:PATH
        $script:MacRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:MacShare=Join-Path $script:MacRoot 'shared/mutator'
        $script:MacInstall=Join-Path $script:MacRoot 'installed'
        foreach($p in @($script:MacShare,$script:MacInstall,(Join-Path $script:MacShare 'bootstrap'),(Join-Path $script:MacShare 'modules'))){[void][IO.Directory]::CreateDirectory($p)}
        Copy-Item (Join-Path $script:MacDefinitions 'Initialize-MacOSModule.ps1') $script:MacShare
        Copy-Item (Join-Path $script:MacDefinitions 'Invoke-MacOSBootstrapCommand.ps1') $script:MacShare
        [IO.File]::WriteAllText((Join-Path $script:MacShare 'bootstrap/Initialize-Image.ps1'),"'offline initialization' | Out-Null")
        [IO.File]::WriteAllText((Join-Path $script:MacShare 'bootstrap/Install-ImageTool.ps1'),'param($Platform,$Root)')
        [IO.File]::WriteAllText((Join-Path $script:MacShare 'modules/marker.txt'),'module payload')
        [IO.File]::WriteAllLines((Join-Path $script:MacShare 'tool-inputs.txt'),[string[]]@('1.2.3','https://example.invalid/tool','abc123'))
        Write-MacFixtureJson (Join-Path $script:MacShare 'runtime.json') @{PowerShell=@{Version=$PSVersionTable.PSVersion.ToString()};Fingerprint='mac-base'}
        Write-MacFixtureJson (Join-Path $script:MacShare 'image.json') @{Module='Fixture.Mac';MacBaseFingerprint='mac-base'}
        Write-MacFixtureJson (Join-Path $script:MacInstall 'base-ready.json') @{Fingerprint='mac-base';ProvisioningUser='test-user'}
        $script:MacContractModule=New-Module -Name MutatorMacContracts -ScriptBlock {
            function Invoke-MacOSBootstrapCommand {param($FilePath,$Arguments,$LogPath) throw 'All OS commands must be mocked.'}
            Export-ModuleMember -Function @()
        }
        Import-Module $script:MacContractModule -Global -Force
        InModuleScope MutatorMacContracts {
            $script:MacCalls=[Collections.Generic.List[object]]::new()
            $script:MacFailCommand=$null
            $script:MacGetCommand=Get-Command Get-Command -CommandType Cmdlet
            Mock Invoke-MacOSBootstrapCommand {
                param($FilePath,$Arguments,$LogPath)
                $script:MacCalls.Add(@{FilePath=$FilePath;Arguments=$Arguments;LogPath=$LogPath})
                if($FilePath -eq $script:MacFailCommand){return 9}
                0
            }
            Mock Get-Command {param($Name,$CommandType) & $script:MacGetCommand -Name $Name -CommandType $CommandType -ErrorAction Ignore}
            Mock Get-Command { [pscustomobject]@{Source='dotnet'} } -ParameterFilter {$Name -eq 'dotnet'}
        }
    }
    AfterEach {$env:PATH=$script:MacEnvironmentPath;Remove-Module MutatorMacContracts -Force -ErrorAction Ignore}

    It 'prepares a common base, its launch daemon and the retained readiness receipt' {
        InModuleScope MutatorMacContracts -Parameters @{Script=(Join-Path $script:MacDefinitions 'Initialize-MacOSBase.ps1');Share=$script:MacShare;Root=$script:MacInstall;Protected=(Join-Path $script:MacRoot 'protected & private');Launch=(Join-Path $script:MacRoot 'daemons')} {
            param($Script,$Share,$Root,$Protected,$Launch)
            . $Script -ProvisioningUser test-user -SharedRoot $Share -Root $Root -ProtectedRoot $Protected -LaunchDaemonDirectory $Launch
            $proof=Get-Content (Join-Path (Split-Path $Share) 'base-ready.json') -Raw|ConvertFrom-Json -AsHashtable
            $proof.Outcome|Should -BeExactly Success
            $proof.Fingerprint|Should -BeExactly mac-base
            $proof.ProvisioningUser|Should -BeExactly test-user
            Test-Path (Join-Path $Protected 'Invoke-MacOSBootstrapCommand.ps1')|Should -BeTrue
            [xml]$plist=Get-Content (Join-Path $Launch 'com.frenchexdev.mutator.module.plist') -Raw
            $plist.SelectSingleNode('//array/string[last()]').InnerText|Should -BeExactly (Join-Path $Protected 'Initialize-MacOSModule.ps1')
            $script:MacCalls.Count|Should -Be 1
            $script:MacCalls[0].Arguments|Should -Contain 'test-user:staff'
        }
    }
    It 'refuses the wrong PowerShell version before native setup' {
        Write-MacFixtureJson (Join-Path $script:MacShare 'runtime.json') @{PowerShell=@{Version='0.0.0'};Fingerprint='mac-base'}
        InModuleScope MutatorMacContracts -Parameters @{Script=(Join-Path $script:MacDefinitions 'Initialize-MacOSBase.ps1');Share=$script:MacShare;Root=$script:MacInstall} {
            param($Script,$Share,$Root)
            {. $Script -ProvisioningUser test-user -SharedRoot $Share -Root $Root}|Should -Throw '*version*'
            Should -Invoke Invoke-MacOSBootstrapCommand -Times 0 -Exactly
        }
    }
    It 'refuses a failed ownership change after common setup' {
        InModuleScope MutatorMacContracts -Parameters @{Script=(Join-Path $script:MacDefinitions 'Initialize-MacOSBase.ps1');Share=$script:MacShare;Root=$script:MacInstall;Protected=(Join-Path $script:MacRoot 'protected');Launch=(Join-Path $script:MacRoot 'daemons')} {
            param($Script,$Share,$Root,$Protected,$Launch)
            $script:MacFailCommand='/usr/sbin/chown'
            {. $Script -ProvisioningUser test-user -SharedRoot $Share -Root $Root -ProtectedRoot $Protected -LaunchDaemonDirectory $Launch}|Should -Throw '*workspace owner*'
            Test-Path (Join-Path (Split-Path $Share) 'base-ready.json')|Should -BeFalse
        }
    }
    It 'installs the module with three separate environment arguments and preserves provenance' {
        InModuleScope MutatorMacContracts -Parameters @{Script=(Join-Path $script:MacDefinitions 'Initialize-MacOSModule.ps1');Share=$script:MacShare;Root=$script:MacInstall} {
            param($Script,$Share,$Root)
            . $Script -Root $Root -Share $Share -SharedVolume (Split-Path $Share)
            $proof=Get-Content (Join-Path $Share 'module-ready.json') -Raw|ConvertFrom-Json -AsHashtable
            $proof.Module|Should -BeExactly Fixture.Mac
            $proof.BaseFingerprint|Should -BeExactly mac-base
            $proof.Identity|Should -BeExactly ((Get-FileHash (Join-Path $Share 'image.json')).Hash+'-'+(Get-FileHash (Join-Path $Share 'tool-inputs.txt')).Hash)
            Test-Path (Join-Path $Root 'modules/marker.txt')|Should -BeTrue
            $install=@($script:MacCalls|Where-Object FilePath -EQ '/usr/bin/sudo')[0]
            $install.Arguments|Should -Contain 'TOOL_VERSION=1.2.3'
            $install.Arguments|Should -Contain 'TOOL_URL=https://example.invalid/tool'
            $install.Arguments|Should -Contain 'TOOL_SHA256=abc123'
            $install.Arguments|Should -Contain 'test-user'
            $install.LogPath|Should -BeExactly (Join-Path $Root 'module-install.log')
            . $Script -Root $Root -Share $Share -SharedVolume (Split-Path $Share)
            @($script:MacCalls|Where-Object FilePath -EQ '/usr/bin/sudo').Count|Should -Be 1
        }
    }
    It 'records installation failures without publishing readiness: <Fault>' -ForEach @(@{Fault='inputs'},@{Fault='ownership'},@{Fault='install'}) {
        if($Fault -eq 'inputs'){[IO.File]::WriteAllLines((Join-Path $script:MacShare 'tool-inputs.txt'),[string[]]@('one'))}
        InModuleScope MutatorMacContracts -Parameters @{Script=(Join-Path $script:MacDefinitions 'Initialize-MacOSModule.ps1');Share=$script:MacShare;Root=$script:MacInstall;Fault=$Fault} {
            param($Script,$Share,$Root,$Fault)
            if($Fault -eq 'ownership'){$script:MacFailCommand='/usr/sbin/chown'}
            if($Fault -eq 'install'){$script:MacFailCommand='/usr/bin/sudo'}
            {. $Script -Root $Root -Share $Share -SharedVolume (Split-Path $Share)}|Should -Throw
            $proof=Get-Content (Join-Path $Share 'module-failed.json') -Raw|ConvertFrom-Json -AsHashtable
            $proof.Outcome|Should -BeExactly Failed
            $proof.Error|Should -Not -BeNullOrEmpty
            Test-Path (Join-Path $Share 'module-ready.json')|Should -BeFalse
        }
    }
    It 'refuses a foreign prepared base' {
        Write-MacFixtureJson (Join-Path $script:MacShare 'image.json') @{MacBaseFingerprint='foreign'}
        InModuleScope MutatorMacContracts -Parameters @{Script=(Join-Path $script:MacDefinitions 'Initialize-MacOSModule.ps1');Share=$script:MacShare;Root=$script:MacInstall} {
            param($Script,$Share,$Root)
            {. $Script -Root $Root -Share $Share -SharedVolume (Split-Path $Share)}|Should -Throw '*fingerprint*'
            Should -Invoke Invoke-MacOSBootstrapCommand -Times 0 -Exactly
        }
    }
    It 'fails mounting a missing shared volume without attempting installation' {
        InModuleScope MutatorMacContracts -Parameters @{Script=(Join-Path $script:MacDefinitions 'Initialize-MacOSModule.ps1');Share=$script:MacShare;Root=$script:MacInstall;Volume=(Join-Path $script:MacRoot 'missing')} {
            param($Script,$Share,$Root,$Volume)
            $script:MacFailCommand='/sbin/mount_9p'
            {. $Script -Root $Root -Share $Share -SharedVolume $Volume}|Should -Throw '*mount*'
        }
    }
    It 'times out when a mounted share never provides the payload' {
        Remove-Item -LiteralPath (Join-Path $script:MacShare 'image.json')
        InModuleScope MutatorMacContracts -Parameters @{Script=(Join-Path $script:MacDefinitions 'Initialize-MacOSModule.ps1');Share=$script:MacShare;Root=$script:MacInstall} {
            param($Script,$Share,$Root)
            {. $Script -Root $Root -Share $Share -SharedVolume (Split-Path $Share) -WaitTimeoutSeconds 0}|Should -Throw '*No module payload*'
        }
    }
    It 'waits for a payload that becomes available and mounts the share once' {
        $metadata=Get-Content (Join-Path $script:MacShare 'image.json') -Raw
        Remove-Item -LiteralPath (Join-Path $script:MacShare 'image.json')
        InModuleScope MutatorMacContracts -Parameters @{Script=(Join-Path $script:MacDefinitions 'Initialize-MacOSModule.ps1');Share=$script:MacShare;Root=$script:MacInstall;Volume=(Join-Path $script:MacRoot 'initially-unmounted');Metadata=$metadata} {
            param($Script,$Share,$Root,$Volume,$Metadata)
            $script:PendingMacMetadata=$Metadata;$script:PendingMacPath=Join-Path $Share 'image.json'
            Mock Start-Sleep {[IO.File]::WriteAllText($script:PendingMacPath,$script:PendingMacMetadata)}
            . $Script -Root $Root -Share $Share -SharedVolume $Volume
            @($script:MacCalls|Where-Object FilePath -EQ '/sbin/mount_9p').Count|Should -Be 1
            Test-Path (Join-Path $Share 'module-ready.json')|Should -BeTrue
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter {$Seconds -eq 3}
        }
    }
    It 'reinstalls a changed module instead of accepting an unrelated readiness identity' {
        Write-MacFixtureJson (Join-Path $script:MacInstall 'module-ready.json') @{Identity='old-module'}
        InModuleScope MutatorMacContracts -Parameters @{Script=(Join-Path $script:MacDefinitions 'Initialize-MacOSModule.ps1');Share=$script:MacShare;Root=$script:MacInstall} {
            param($Script,$Share,$Root)
            . $Script -Root $Root -Share $Share -SharedVolume (Split-Path $Share)
            @($script:MacCalls|Where-Object FilePath -EQ '/usr/bin/sudo').Count|Should -Be 1
            (Get-Content (Join-Path $Root 'module-ready.json') -Raw|ConvertFrom-Json -AsHashtable).Identity|Should -Not -BeExactly old-module
        }
    }
}
Describe 'The macOS native boundary retains argv, logs and exit codes' {
    BeforeEach {
        $script:SavedMacExit=$global:LASTEXITCODE
        $script:MacNativeModule=New-Module -Name MutatorMacNative -ArgumentList (Join-Path $script:MacDefinitions 'Invoke-MacOSBootstrapCommand.ps1') -ScriptBlock {
            param($Helper)
            . $Helper
            function Invoke-MacTestExecutable {param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) $script:ReceivedMacArguments=$Arguments;'native fixture output';if($null -ne $script:FixtureMacExit){$global:LASTEXITCODE=$script:FixtureMacExit}}
            Export-ModuleMember -Function @()
        }
        Import-Module $script:MacNativeModule -Global -Force
    }
    AfterEach {$global:LASTEXITCODE=$script:SavedMacExit;Remove-Module MutatorMacNative -Force -ErrorAction Ignore}
    It 'resets a stale exit code and does not leak successful stdout' {
        InModuleScope MutatorMacNative {
            $script:FixtureMacExit=$null;$global:LASTEXITCODE=77
            $r=@(Invoke-MacOSBootstrapCommand -FilePath Invoke-MacTestExecutable -Arguments @('literal value','$unchanged'))
            $r.Count|Should -Be 1
            $r[0]|Should -Be 0
            $script:ReceivedMacArguments|Should -Be @('literal value','$unchanged')
        }
    }
    It 'retains a failing exit and redirects native output to its local log' {
        InModuleScope MutatorMacNative -Parameters @{Log=(Join-Path $TestDrive 'native.log')} {
            param($Log)
            $script:FixtureMacExit=19
            Invoke-MacOSBootstrapCommand -FilePath Invoke-MacTestExecutable -LogPath $Log|Should -Be 19
            Get-Content $Log -Raw|Should -Match 'native fixture output'
        }
    }
}
