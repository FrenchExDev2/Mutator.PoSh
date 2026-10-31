BeforeAll {
    $script:BaseRuntimeValidator=Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'resources/containers/definitions/guest/Test-WindowsBase.ps1'
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    $script:AvailableSdk=(Get-Command dotnet -CommandType Application -ErrorAction Stop).Source
    $script:AvailableSdkVersion=& (Get-Module FrenchExDev.Mutator.PoSh) {
        param($Directory,$Executable)
        $result=Invoke-MutatorNative $Executable @('--version') $Directory 30
        $version=$result.Stdout.Trim()
        if($result.Outcome -ne 'Success' -or $version -notmatch '^\d+\.\d+\.\d+[-.\w]*$'){throw 'The runtime validator tests require an available SDK with a readable version.'}
        $version
    } $TestDrive $script:AvailableSdk
}
Describe 'Verifying a Windows base runtime against its pinned metadata' {
    BeforeEach {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=(Join-Path $TestDrive ([guid]::NewGuid().ToString('N')));Script=$script:BaseRuntimeValidator;Sdk=$script:AvailableSdk;Version=$script:AvailableSdkVersion} {
            param($Root,$Script,$Sdk,$Version)
            [void][IO.Directory]::CreateDirectory($Root)
            $script:BaseRuntimeRoot=$Root;$script:BaseRuntimeScript=$Script;$script:BaseRuntimeSdk=$Sdk;$script:BaseRuntimeVersion=$Version
            $script:BaseRuntimeTool=@{Source=$Sdk}
            $script:BaseRuntimeDirectory=[Environment]::CurrentDirectory
            [Environment]::CurrentDirectory=$Root
            $script:BaseRuntimeMetadata=@{Runtime=@{Version=$PSVersionTable.PSVersion.ToString()};BaseFingerprint='fixture-runtime-fingerprint';Platforms=@{Windows=@{Packages=@('dotnet-sdk='+$Version)}}}
            Write-MutatorJson (Join-Path $Root 'image.json') $script:BaseRuntimeMetadata
            Mock Import-Module {}
            $tool=$script:BaseRuntimeTool
            $baseRuntimeGetCommand=Get-Command Get-Command -CommandType Cmdlet
            Mock Get-Command -MockWith ({param($Name,$CommandType) & $baseRuntimeGetCommand -Name $Name -CommandType $CommandType -ErrorAction Ignore}.GetNewClosure())
            Mock Get-Command -MockWith ({[pscustomobject]@{Source=$tool.Source}}.GetNewClosure()) -ParameterFilter {$Name -eq 'dotnet' -and $CommandType -eq 'Application'}
        }
    }
    AfterEach {InModuleScope FrenchExDev.Mutator.PoSh {[Environment]::CurrentDirectory=$script:BaseRuntimeDirectory}}
    It 'records the exact PowerShell SDK and tool pins only after native verification succeeds' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            & $script:BaseRuntimeScript -Root $script:BaseRuntimeRoot
            $proof=Read-MutatorJson (Join-Path $script:BaseRuntimeRoot 'base-runtime.json')
            $proof.Outcome|Should -BeExactly Success
            $proof.PowerShell|Should -BeExactly $PSVersionTable.PSVersion.ToString()
            $proof.DotnetSdk|Should -BeExactly $script:BaseRuntimeVersion
            $proof.Fingerprint|Should -BeExactly fixture-runtime-fingerprint
            $proof.Tools.Name|Should -BeExactly @('Pester','PSMutant','PSScriptAnalyzer','powershell-yaml')
            $proof.Tools.Version|Should -BeExactly @('6.2.0','0.6.0','1.25.0','0.4.12')
            $proof.VerifiedUtc|Should -Not -BeNullOrEmpty
            Test-Path (Join-Path $script:BaseRuntimeRoot 'sdk-check.stderr.log')|Should -BeTrue
            Should -Invoke Import-Module -Times 4
            Should -Invoke Get-Command -Times 1 -ParameterFilter {$Name -eq 'dotnet' -and $CommandType -eq 'Application'}
        }
    }
    It 'refuses the wrong PowerShell before importing any tools' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $script:BaseRuntimeMetadata.Runtime.Version='0.0.0'
            Write-MutatorJson (Join-Path $script:BaseRuntimeRoot 'image.json') $script:BaseRuntimeMetadata
            {& $script:BaseRuntimeScript -Root $script:BaseRuntimeRoot}|Should -Throw '*PowerShell version differs*'
            Should -Invoke Import-Module -Times 0
            Should -Invoke Get-Command -Times 0 -ParameterFilter {$Name -eq 'dotnet' -and $CommandType -eq 'Application'}
            Test-Path (Join-Path $script:BaseRuntimeRoot 'base-runtime.json')|Should -BeFalse
        }
    }
    It 'requires exactly one SDK pin before launching anything: <Count>' -ForEach @(@{Count=0},@{Count=2}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Count=$Count} {
            param($Count)
            $script:BaseRuntimeMetadata.Platforms.Windows.Packages=if($Count){@('dotnet-sdk=10.0.402','dotnet-sdk=11.0.100')}else{@()}
            Write-MutatorJson (Join-Path $script:BaseRuntimeRoot 'image.json') $script:BaseRuntimeMetadata
            {& $script:BaseRuntimeScript -Root $script:BaseRuntimeRoot}|Should -Throw '*pin exactly one .NET SDK*'
            Should -Invoke Get-Command -Times 0 -ParameterFilter {$Name -eq 'dotnet' -and $CommandType -eq 'Application'}
            Test-Path (Join-Path $script:BaseRuntimeRoot 'base-runtime.json')|Should -BeFalse
        }
    }
    It 'refuses a missing executable or native version mismatch: <Fault>' -ForEach @(@{Fault='missing executable'},@{Fault='mismatched version'},@{Fault='failed SDK'}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Fault=$Fault} {
            param($Fault)
            switch($Fault){
                'missing executable' {$script:BaseRuntimeTool.Source=Join-Path $script:BaseRuntimeRoot 'absent-sdk'}
                'mismatched version' {$script:BaseRuntimeMetadata.Platforms.Windows.Packages=@('dotnet-sdk=99.0.999')}
                'failed SDK' {Write-MutatorJson (Join-Path $script:BaseRuntimeRoot 'global.json') @{sdk=@{version='99.0.999';rollForward='disable';allowPrerelease=$false}}}
            }
            Write-MutatorJson (Join-Path $script:BaseRuntimeRoot 'image.json') $script:BaseRuntimeMetadata
            {& $script:BaseRuntimeScript -Root $script:BaseRuntimeRoot}|Should -Throw
            Test-Path (Join-Path $script:BaseRuntimeRoot 'base-runtime.json')|Should -BeFalse
            if($Fault -ne 'missing executable'){Test-Path (Join-Path $script:BaseRuntimeRoot 'sdk-check.stderr.log')|Should -BeTrue}
        }
    }
}
