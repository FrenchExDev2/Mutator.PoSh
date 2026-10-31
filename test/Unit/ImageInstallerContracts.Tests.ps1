<#
.SYNOPSIS
Expected behavior for the ImageInstallerContracts tests.

.DESCRIPTION
Installers must preserve pins, verify hashes before extraction/execution and use the selected
platform manager. Empty inputs do no work; native/reboot/failure exits, executable permissions and
alias failures stay explicit.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:Installer=Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'resources/containers/definitions/bootstrap/Install-ImageTool.ps1'
}
Describe 'Isolated image bootstrap helpers' {
BeforeEach {
    $script:InstallerEnvironment=@{}
    foreach($name in @('PATH','COMPOSER_HOME','GEM_HOME','GOBIN','NPM_CONFIG_PREFIX','chocolateyVersion','chocolateyUseWindowsCompression')){
        $script:InstallerEnvironment[$name]=[Environment]::GetEnvironmentVariable($name)
    }
    $script:InstallRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:InstallRoot)
    @{Module='Fixture';Platforms=@{Windows=@{Method='ContractFixture'}}} | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $script:InstallRoot 'image.json')
    # Load the real bootstrap functions and refuse the deliberately unsupported recipe.
    # No native install or network access takes place during this initialization.
    $script:InstallerModule=New-Module -Name MutatorImageInstallerContracts -ArgumentList @($script:Installer,$script:InstallRoot) -ScriptBlock {
        param($Installer,$Root)
        try{. $Installer -Platform Windows -Root $Root}
        catch{if($_.Exception.Message -cne 'Unknown image tool installer: ContractFixture'){throw}}
        Export-ModuleMember -Function *
    }
    Import-Module $script:InstallerModule -Global -Force
}
AfterEach {
    Remove-Module MutatorImageInstallerContracts -Force -ErrorAction SilentlyContinue
    foreach($name in $script:InstallerEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$script:InstallerEnvironment[$name])}
}

Describe 'Image installer package-manager boundaries' {
    It 'does not launch a package manager for empty or blank prerequisites' {
        InModuleScope MutatorImageInstallerContracts {
            Mock Invoke-ImageInstallCommand {throw 'No installation was requested.'}
            Install-ImagePrerequisite @()
            Install-ImagePrerequisite @('',' ',[string]$null)
            Should -Invoke Invoke-ImageInstallCommand -Times 0
        }
    }
    It 'uses the selected Linux distribution for prerequisites: <Distribution>' -ForEach @(
        @{Distribution='Alpine';Executable='apk';Expected=@('add','--no-cache','git=1','jq=2');Calls=1}
        @{Distribution='Debian';Executable='apt-get';Expected=@('install','-y','--no-install-recommends','git=1','jq=2');Calls=2}
    ) {
        InModuleScope MutatorImageInstallerContracts -Parameters @{Distribution=$Distribution;Executable=$Executable;Expected=$Expected;Calls=$Calls} {
            param($Distribution,$Executable,$Expected,$Calls)
            $script:Platform='Linux';$script:toolProfile=@{Distribution=$Distribution}
            $script:InstallCalls=[Collections.Generic.List[object]]::new()
            Mock Invoke-ImageInstallCommand {param($Name,$Arguments) $script:InstallCalls.Add(@{Name=$Name;Arguments=$Arguments})}
            Install-ImagePrerequisite @('git=1',' ','jq=2')
            $script:InstallCalls.Count | Should -Be $Calls
            $script:InstallCalls[-1].Name | Should -BeExactly $Executable
            $script:InstallCalls[-1].Arguments | Should -Be $Expected
            if($Distribution -eq 'Debian'){$script:InstallCalls[0].Arguments | Should -Be @('update')}
        }
    }
    It 'installs macOS packages with the correct formula or cask mode: <Method>' -ForEach @(
        @{Method='Brew';Expected=@('install','jq')},@{Method='BrewCask';Expected=@('install','--cask','jq')}
    ) {
        InModuleScope MutatorImageInstallerContracts -Parameters @{Method=$Method;Expected=$Expected} {
            param($Method,$Expected)
            $script:Platform='MacOS';$script:toolProfile=@{Method=$Method}
            Mock Invoke-ImageInstallCommand {param($Name,$Arguments) $Name | Should -BeExactly brew; $Arguments | Should -Be $Expected}
            Install-ImagePrerequisite @('jq')
            Should -Invoke Invoke-ImageInstallCommand -Times 1
        }
    }
    It 'keeps Chocolatey versions separate from package names and preserves unpinned prerequisites' {
        InModuleScope MutatorImageInstallerContracts {
            $script:Platform='Windows'
            Mock Install-ImageChocolatey {}
            $script:InstallCalls=[Collections.Generic.List[object]]::new()
            Mock Invoke-ImageInstallCommand {param($Name,$Arguments) $script:InstallCalls.Add(@{Name=$Name;Arguments=$Arguments})}
            Install-ImagePrerequisite @('git=2.4','jq')
            Should -Invoke Install-ImageChocolatey -Times 1
            $script:InstallCalls.Count | Should -Be 2
            $script:InstallCalls[0].Name | Should -BeExactly choco.exe
            $script:InstallCalls[0].Arguments | Should -Be @('install','git','--yes','--no-progress','--limit-output','--version','2.4')
            $script:InstallCalls[1].Arguments | Should -Be @('install','jq','--yes','--no-progress','--limit-output')
        }
    }
}

Describe 'Verified tool archives' {
    It 'refuses unverified input before a download: <Reason>' -ForEach @(
        @{Reason='insecure URL';Uri='http://example.invalid/tool.zip';Digest=('a'*64)}
        @{Reason='short SHA';Uri='https://example.invalid/tool.zip';Digest=('a'*63)}
        @{Reason='non-hex SHA';Uri='https://example.invalid/tool.zip';Digest=('z'*64)}
    ) {
        InModuleScope MutatorImageInstallerContracts -Parameters @{Uri=$Uri;Digest=$Digest} {
            param($Uri,$Digest)
            Mock Invoke-WebRequest {throw 'Unverified input must not be downloaded.'}
            {Install-ImageArchive $Uri $Digest zip tool} | Should -Throw '*HTTPS TOOL_URL and its exact TOOL_SHA256*'
            Should -Invoke Invoke-WebRequest -Times 0
        }
    }
    It 'retains a corrupt download for diagnosis and never extracts it' {
        InModuleScope MutatorImageInstallerContracts {
            Mock Invoke-WebRequest {param($OutFile) [IO.File]::WriteAllText($OutFile,'corrupt payload')}
            Mock Expand-Archive {throw 'Unverified archives must not be extracted.'}
            {Install-ImageArchive 'https://example.invalid/tool.zip' ('a'*64) zip tool} | Should -Throw '*SHA256 mismatch*'
            Should -Invoke Expand-Archive -Times 0
            Test-Path -LiteralPath (Join-Path $Root 'tool-download.zip') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Root 'tool') | Should -BeFalse
        }
    }
    It 'extracts a verified zip, flattens its single wrapper and removes the downloaded archive' {
        $payload=Join-Path $TestDrive 'payload';[void][IO.Directory]::CreateDirectory((Join-Path $payload 'release'))
        [IO.File]::WriteAllText((Join-Path $payload 'release/tool.exe'),'verified executable fixture')
        [IO.File]::WriteAllText((Join-Path $payload 'release/LICENSE'),'attribution fixture')
        $zip=Join-Path $TestDrive 'source.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($payload,$zip)
        $digest=(Get-FileHash -LiteralPath $zip).Hash
        InModuleScope MutatorImageInstallerContracts -Parameters @{Zip=$zip;Digest=$digest} {
            param($Zip,$Digest)
            Mock Invoke-WebRequest {param($OutFile) Copy-Item -LiteralPath $Zip -Destination $OutFile}
            Mock Set-ImageToolEnvironment {}
            Install-ImageArchive 'https://example.invalid/tool.zip' $Digest zip tool
            [IO.File]::ReadAllText((Join-Path $Root 'tool/tool.exe')) | Should -BeExactly 'verified executable fixture'
            [IO.File]::ReadAllText((Join-Path $Root 'tool/LICENSE')) | Should -BeExactly 'attribution fixture'
            Test-Path -LiteralPath (Join-Path $Root 'tool/release') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $Root 'tool-download.zip') | Should -BeFalse
            Should -Invoke Set-ImageToolEnvironment -Times 1
        }
    }
    It 'rejects an unknown archive format after verifying the download' {
        InModuleScope MutatorImageInstallerContracts {
            Mock Invoke-WebRequest {param($OutFile) [IO.File]::WriteAllText($OutFile,'payload')}
            $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('payload')))
            {Install-ImageArchive 'https://example.invalid/tool.rar' $digest rar tool} | Should -Throw '*Unsupported artifact format: rar*'
            Test-Path -LiteralPath (Join-Path $Root 'installed-tool.json') | Should -BeFalse
        }
    }

    It 'publishes a verified standalone binary under its target executable name: <Target>' -ForEach @(@{Target='Windows'},@{Target='Linux'}) {
        InModuleScope MutatorImageInstallerContracts -Parameters @{Target=$Target} {
            param($Target)
            $script:Platform=$Target
            Mock Invoke-WebRequest {param($OutFile) [IO.File]::WriteAllText($OutFile,'standalone payload')}
            Mock Set-ImageToolEnvironment {}
            Mock Set-ImageToolExecutable {}
            $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('standalone payload')))
            Install-ImageArchive 'https://example.invalid/tool' $digest binary tool
            $file=Join-Path $Root $(if($Target -eq 'Windows'){'tool/tool.exe'}else{'tool/tool'})
            [IO.File]::ReadAllText($file) | Should -BeExactly 'standalone payload'
            Test-Path -LiteralPath (Join-Path $Root 'tool-download.binary') | Should -BeFalse
            Should -Invoke Set-ImageToolEnvironment -Times 1
            Should -Invoke Set-ImageToolExecutable -Times ([int]($Target -eq 'Linux')) -Exactly
        }
    }

    It 'extracts a verified compressed tar while preserving sibling files' {
        $payload=Join-Path $TestDrive 'tar-payload';[void][IO.Directory]::CreateDirectory($payload)
        [IO.File]::WriteAllText((Join-Path $payload 'tool'),'tar executable fixture')
        [IO.File]::WriteAllText((Join-Path $payload 'LICENSE'),'tar attribution fixture')
        $tar=Join-Path $TestDrive 'source.tar';$archive=Join-Path $TestDrive 'source.tar.gz'
        [System.Formats.Tar.TarFile]::CreateFromDirectory($payload,$tar,$false)
        $input=[IO.File]::OpenRead($tar);$output=[IO.File]::Create($archive)
        $gzip=[IO.Compression.GZipStream]::new($output,[IO.Compression.CompressionMode]::Compress)
        try{$input.CopyTo($gzip)}finally{$input.Dispose();$gzip.Dispose();$output.Dispose()}
        $digest=(Get-FileHash -LiteralPath $archive).Hash
        InModuleScope MutatorImageInstallerContracts -Parameters @{ArchiveSource=$archive;Digest=$digest} {
            param($ArchiveSource,$Digest)
            Mock Invoke-WebRequest {param($OutFile) Copy-Item -LiteralPath $ArchiveSource -Destination $OutFile}
            Mock Set-ImageToolEnvironment {}
            Install-ImageArchive 'https://example.invalid/tool.tar.gz' $Digest tar.gz tool
            [IO.File]::ReadAllText((Join-Path $Root 'tool/tool')) | Should -BeExactly 'tar executable fixture'
            [IO.File]::ReadAllText((Join-Path $Root 'tool/LICENSE')) | Should -BeExactly 'tar attribution fixture'
            Test-Path -LiteralPath (Join-Path $Root 'tool-download.tar.gz') | Should -BeFalse
        }
    }
}

Describe 'Native installer results and retained diagnostics' {
    It 'drains both streams and distinguishes successful, reboot-required and failed exits: <ExitCode>' -ForEach @(
        @{ExitCode=0;Accepted=$true},@{ExitCode=3010;Accepted=$true},@{ExitCode=7;Accepted=$false}
    ) {
        InModuleScope MutatorImageInstallerContracts -Parameters @{ExitCode=$ExitCode;Accepted=$Accepted} {
            param($ExitCode,$Accepted)
            Mock Set-ImageToolEnvironment {}
            $application=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
            $code="[Console]::Out.Write('installer stdout');[Console]::Error.Write('installer stderr');exit $ExitCode"
            # POSIX exit codes are eight bits; Windows retains the reboot-required code.
            $acceptedHere=$Accepted -and ($ExitCode -ne 3010 -or $IsWindows)
            if($acceptedHere){Invoke-ImageInstallCommand $application @('-NoProfile','-Command',$code)}
            else{{Invoke-ImageInstallCommand $application @('-NoProfile','-Command',$code)} | Should -Throw '*Installer*failed with exit*retained log:*'}
            $logs=@(Get-ChildItem -LiteralPath $Root -File -Filter 'install-*.log')
            $logs.Count | Should -Be 1
            [IO.File]::ReadAllText($logs[0].FullName) | Should -BeExactly ('installer stdout'+[Environment]::NewLine+'installer stderr')
            if($acceptedHere){Should -Invoke Set-ImageToolEnvironment -Times 1}
            else{Should -Invoke Set-ImageToolEnvironment -Times 0}
        }
    }

    It 'does not download Chocolatey when it is already installed' {
        InModuleScope MutatorImageInstallerContracts {
            Mock Get-Command { @{Source='existing-choco.exe'} } -ParameterFilter {$Name -eq 'choco.exe'}
            Mock Invoke-WebRequest {throw 'Existing installation must be reused.'}
            Install-ImageChocolatey
            Should -Invoke Invoke-WebRequest -Times 0
        }
    }

    It 'refuses a changed Chocolatey bootstrap before executing it' {
        InModuleScope MutatorImageInstallerContracts {
            Mock Get-Command { $null } -ParameterFilter {$Name -eq 'choco.exe'}
            Mock Invoke-WebRequest {param($OutFile) [IO.File]::WriteAllText($OutFile,'throw ''unverified script executed''')}
            $originalVersion=$env:chocolateyVersion
            {Install-ImageChocolatey} | Should -Throw '*Chocolatey bootstrap SHA256 changed*'
            $env:chocolateyVersion | Should -BeExactly $originalVersion
        }
    }
    It 'executes only the reviewed Chocolatey bootstrap and verifies the installed command' {
        InModuleScope MutatorImageInstallerContracts {
            $script:ChocolateyQueries=0
            Mock Get-Command {
                $script:ChocolateyQueries++
                if($script:ChocolateyQueries -gt 1){@{Source='verified-choco.exe'}}
            } -ParameterFilter {$Name -eq 'choco.exe'}
            Mock Invoke-WebRequest {param($OutFile) [IO.File]::WriteAllText($OutFile,'[IO.File]::WriteAllText((Join-Path $Root "choco-proof.txt"),$env:chocolateyVersion+":"+$env:chocolateyUseWindowsCompression)')}
            Mock Get-FileHash {@{Hash='44E045ED5350758616D664C5AF631E7F2CD10165F5BF2BD82CBF3A0BB8F63462'}}
            Mock Set-ImageToolEnvironment {}
            Install-ImageChocolatey
            [IO.File]::ReadAllText((Join-Path $Root 'choco-proof.txt'))|Should -BeExactly '2.5.1:true'
            Should -Invoke Get-Command -Times 2 -Exactly -ParameterFilter {$Name -eq 'choco.exe'}
            Should -Invoke Set-ImageToolEnvironment -Times 1 -Exactly
        }
    }
    It 'sets executable bits on Unix and fails explicitly for an unsupported host' {
        InModuleScope MutatorImageInstallerContracts {
            $file=Join-Path $Root 'executable';[IO.File]::WriteAllText($file,'fixture')
            if($IsWindows){{Set-ImageToolExecutable $file}|Should -Throw '*not supported*'}
            else{
                [IO.File]::SetUnixFileMode($file,[IO.UnixFileMode]::UserRead)
                Set-ImageToolExecutable $file
                $mode=[IO.File]::GetUnixFileMode($file)
                foreach($permission in @('UserRead','UserExecute','GroupExecute','OtherExecute')){($mode -band [IO.UnixFileMode]::$permission)|Should -Be ([IO.UnixFileMode]::$permission)}
                ($mode -band [IO.UnixFileMode]::OtherWrite)|Should -Be 0
            }
        }
    }
    It 'creates a file alias or reports the host privilege failure without altering the target' {
        InModuleScope MutatorImageInstallerContracts {
            $target=Join-Path $Root 'target';$link=Join-Path $Root 'alias'
            [IO.File]::WriteAllText($target,'unchanged fixture')
            try{
                New-ImageToolSymbolicLink $link $target
                [IO.File]::ReadAllText($link)|Should -BeExactly 'unchanged fixture'
                (Get-Item -LiteralPath $link).LinkTarget|Should -BeExactly $target
            }catch{
                if(!$IsWindows -or $_.Exception.ToString() -notmatch 'privilege|privilège'){throw}
            }finally{if(Test-Path -LiteralPath $link){[IO.File]::Delete($link)}}
            [IO.File]::ReadAllText($target)|Should -BeExactly 'unchanged fixture'
        }
    }
}
}
