BeforeAll {
    $script:RecipeTestPathCommand=Get-Command Test-Path -CommandType Cmdlet
    $script:RecipeInstaller=Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'resources/containers/definitions/bootstrap/Install-ImageTool.ps1'
    $script:RecipeAssets=Join-Path $TestDrive 'offline-assets'
    [void][IO.Directory]::CreateDirectory($script:RecipeAssets)
    $payload=Join-Path $script:RecipeAssets 'payload';[void][IO.Directory]::CreateDirectory($payload)
    [IO.File]::WriteAllText((Join-Path $payload 'tool-fixture.exe'),'verified fixture executable')
    $script:RecipeZip=Join-Path $script:RecipeAssets 'tool.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($payload,$script:RecipeZip)
    $script:RecipeZipSha=(Get-FileHash $script:RecipeZip).Hash
    $ag=Join-Path $script:RecipeAssets 'ag/WIN64';[void][IO.Directory]::CreateDirectory($ag)
    [IO.File]::WriteAllText((Join-Path $ag 'ag.exe'),'verified ag fixture executable')
    $script:RecipeAgBinarySha=(Get-FileHash (Join-Path $ag 'ag.exe')).Hash
    $script:RecipeAgZip=Join-Path $script:RecipeAssets 'ag.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $ag),$script:RecipeAgZip)
    $script:RecipeAgZipSha=(Get-FileHash $script:RecipeAgZip).Hash
    $tar=Join-Path $script:RecipeAssets 'node.tar';$script:RecipeTar=Join-Path $script:RecipeAssets 'node.tar.gz'
    [System.Formats.Tar.TarFile]::CreateFromDirectory($payload,$tar,$false)
    $input=[IO.File]::OpenRead($tar);$output=[IO.File]::Create($script:RecipeTar)
    $gzip=[IO.Compression.GZipStream]::new($output,[IO.Compression.CompressionMode]::Compress)
    try{$input.CopyTo($gzip)}finally{$input.Dispose();$gzip.Dispose();$output.Dispose()}
    $script:RecipeTarSha=(Get-FileHash $script:RecipeTar).Hash
    $shim=Join-Path $script:RecipeAssets 'native-fixture.ps1'
    [IO.File]::WriteAllText($shim,@'
$ErrorActionPreference='Stop'
if($args[0] -eq 'create-project' -and $env:MUTATOR_FIXTURE_SKIP_ARTISAN -ne '1'){
    [IO.File]::WriteAllText((Join-Path $args[-1] 'artisan'),'fixture artisan')
}
@{Arguments=@($args)}|ConvertTo-Json -Compress
'@)
    $script:RecipeCli=Join-Path $script:RecipeAssets $(if($IsWindows){'native-fixture.cmd'}else{'native-fixture'})
    if($IsWindows){
        $content='@echo off'+"`r`n"+'"'+(Join-Path $PSHOME 'pwsh.exe')+'" -NoProfile -File "'+$shim+'" %*'+"`r`n"+'exit /b %errorlevel%'+"`r`n"
        [IO.File]::WriteAllText($script:RecipeCli,$content)
    }else{
        $binary=(Join-Path $PSHOME 'pwsh').Replace("'","'\''")
        $scriptPath=$shim.Replace("'","'\''")
        [IO.File]::WriteAllText($script:RecipeCli,"#!/bin/sh`nexec '$binary' -NoProfile -File '$scriptPath' "+'"$@"'+"`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::SetUnixFileMode($script:RecipeCli,[IO.UnixFileMode]493)
    }
    function Invoke-OfflineImageRecipe {
        param([object]$Profile,[string]$Platform='Windows')
        @{Module='Fixture.Recipe';Platforms=@{$Platform=$Profile}}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $script:RecipeRoot 'image.json')
        InModuleScope MutatorImageRecipeRuntime -Parameters @{Installer=$script:RecipeInstaller;Destination=$script:RecipeRoot;SelectedPlatform=$Platform} {
            param($Installer,$Destination,$SelectedPlatform)
            . $Installer -Platform $SelectedPlatform -Root $Destination
        }
    }
}

Describe 'Offline execution of complete image tool recipes' {
    BeforeEach {
        $script:RecipeEnvironment=@{}
        foreach($name in @('PATH','COMPOSER_HOME','GEM_HOME','GOBIN','NPM_CONFIG_PREFIX','TOOL_VERSION','TOOL_URL','TOOL_SHA256','CGO_ENABLED','COMPOSER_ALLOW_SUPERUSER','NONINTERACTIVE','MUTATOR_FIXTURE_SKIP_ARTISAN')){
            $script:RecipeEnvironment[$name]=[Environment]::GetEnvironmentVariable($name)
        }
        foreach($name in @('TOOL_VERSION','TOOL_URL','TOOL_SHA256','MUTATOR_FIXTURE_SKIP_ARTISAN')){[Environment]::SetEnvironmentVariable($name,$null)}
        $script:RecipeRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:RecipeRoot)
        [IO.File]::WriteAllText((Join-Path $script:RecipeRoot 'image.json'),'{"Module":"Fixture.Recipe","Platforms":{"Windows":{"Method":"LoadFixture"}}}')
        $script:RecipeModule=New-Module -Name MutatorImageRecipeRuntime -ArgumentList @($script:RecipeInstaller,$script:RecipeRoot) -ScriptBlock {
            param($Installer,$Root)
            try{. $Installer -Platform Windows -Root $Root}catch{if($_.Exception.Message -cne 'Unknown image tool installer: LoadFixture'){throw}}
            Export-ModuleMember -Function *
        }
        Import-Module $script:RecipeModule -Global -Force
        InModuleScope MutatorImageRecipeRuntime -Parameters @{Cli=$script:RecipeCli;Zip=$script:RecipeZip;ZipSha=$script:RecipeZipSha;Tar=$script:RecipeTar;TarSha=$script:RecipeTarSha;Ag=$script:RecipeAgZip} {
            param($Cli,$Zip,$ZipSha,$Tar,$TarSha,$Ag)
            $script:OfflineCli=$Cli;$script:OfflineZip=$Zip;$script:OfflineZipSha=$ZipSha;$script:OfflineTar=$Tar;$script:OfflineTarSha=$TarSha;$script:OfflineAg=$Ag
            Mock Get-Command {param($Name) [pscustomobject]@{Source=$script:OfflineCli;Name=$Name}}
            Mock Get-Item {}
            Mock Invoke-WebRequest {
                param($Uri,$OutFile)
                if(!$OutFile){
                    if($Uri -like '*SHASUMS256.txt'){@{Content=($script:OfflineTarSha+'  node-v22.11.0-linux-x64.tar.gz')}}
                    else{@{Content=($script:OfflineZipSha+' *terraform_1.2.3_linux_amd64.zip')}}
                }elseif($Uri -like '*ag.zip'){Copy-Item -LiteralPath $script:OfflineAg -Destination $OutFile}
                elseif($Uri -like '*.tar.gz'){Copy-Item -LiteralPath $script:OfflineTar -Destination $OutFile}
                elseif($Uri -like '*run-tests.php' -or $Uri -like '*/LICENSE'){[IO.File]::WriteAllText($OutFile,'verified PHP source fixture')}
                else{Copy-Item -LiteralPath $script:OfflineZip -Destination $OutFile}
            }
            Mock Invoke-RestMethod {@{assets=@(@{name='tool.zip';digest=('sha256:'+$script:OfflineZipSha);browser_download_url='https://example.invalid/tool.zip'})}}
        }
    }
    AfterEach {
        Remove-Module MutatorImageRecipeRuntime -Force -ErrorAction Ignore
        foreach($name in $script:RecipeEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$script:RecipeEnvironment[$name])}
    }

    It 'executes the selected recipe and preserves the pinned command: <Method>/<Version>' -ForEach @(
        @{Method='None';Version='1.2.3';Calls=0;Token=$null},
        @{Method='Apk';Version='1.2.3';Calls=0;Token=$null},
        @{Method='Apt';Version='1.2.3';Calls=0;Token=$null},
        @{Method='Chocolatey';Version='1.2.3';Calls=0;Token=$null},
        @{Method='ImageCopy';Version='1.2.3';Calls=0;Token=$null},
        @{Method='Brew';Version='1.2.3';Calls=0;Token=$null},
        @{Method='BrewCask';Version='1.2.3';Calls=0;Token=$null},
        @{Method='Npm';Version='1.2.3';Calls=1;Token='vendor/tool@1.2.3'},
        @{Method='Npm';Version='';Calls=1;Token='vendor/tool'},
        @{Method='Pip';Version='1.2.3';Calls=2;Token='vendor/tool==1.2.3'},
        @{Method='Pip';Version='';Calls=2;Token='vendor/tool'},
        @{Method='Gem';Version='1.2.3';Calls=1;Token='--version'},
        @{Method='Gem';Version='';Calls=1;Token='--no-document'},
        @{Method='Composer';Version='1.2.3';Calls=1;Token='vendor/tool:1.2.3'},
        @{Method='Composer';Version='';Calls=1;Token='vendor/tool'},
        @{Method='Artisan';Version='';Calls=1;Token='laravel/laravel'},
        @{Method='Phpt';Version='';Calls=1;Token='phpgt/phpt'},
        @{Method='Go';Version='1.2.3';Calls=1;Token='vendor/tool@1.2.3'},
        @{Method='Go';Version='';Calls=1;Token='vendor/tool@latest'},
        @{Method='Release';Version='1.2.3';Calls=0;Token=$null},
        @{Method='Release';Version='';Calls=0;Token=$null},
        @{Method='Artifact';Version='';Calls=0;Token=$null},
        @{Method='Hashicorp';Version='1.2.3';Calls=0;Token=$null}
    ) {
        $profile=@{Method=$Method;Package='vendor/tool';Version=$Version;Binary='tool-fixture';Repository='owner/project';AssetPattern='^tool\.zip$';Format='zip';PhpSourceRef='frozen-php-ref'}
        if($Method -eq 'Artifact'){$env:TOOL_URL='https://example.invalid/tool.zip';$env:TOOL_SHA256=$script:RecipeZipSha}
        @{Module='Fixture.Recipe';Platforms=@{Windows=$profile}}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $script:RecipeRoot 'image.json')
        InModuleScope MutatorImageRecipeRuntime -Parameters @{Installer=$script:RecipeInstaller;Destination=$script:RecipeRoot} {
            param($Installer,$Destination)
            . $Installer -Platform Windows -Root $Destination
        }
        $receipt=Get-Content (Join-Path $script:RecipeRoot 'installed-tool.json') -Raw|ConvertFrom-Json
        $receipt.Module|Should -BeExactly Fixture.Recipe
        $receipt.Platform|Should -BeExactly Windows
        $receipt.Method|Should -BeExactly $Method
        $receipt.Executable|Should -BeExactly $script:RecipeCli
        $logs=@(Get-ChildItem $script:RecipeRoot -File -Filter 'install-*.log')
        $logs.Count|Should -Be $Calls
        if($Token){
            $arguments=@(foreach($log in $logs){(Get-Content $log.FullName -Raw|ConvertFrom-Json).Arguments})
            $arguments|Should -Contain $Token
        }
        if($Method -eq 'Phpt'){
            [IO.File]::ReadAllText((Join-Path $script:RecipeRoot 'workload/LICENSE-PHP.txt'))|Should -BeExactly 'verified PHP source fixture'
        }
        if($Method -eq 'Artisan'){Test-Path (Join-Path $script:RecipeRoot 'workload/artisan')|Should -BeTrue}
    }

    It 'refuses invalid recipe schemas before invoking an installer: <Fault>' -ForEach @(
        @{Fault='document array'},@{Fault='missing platforms'},@{Fault='platforms array'},@{Fault='missing platform'},
        @{Fault='platform array'},@{Fault='missing method'},@{Fault='numeric method'},@{Fault='blank method'}
    ) {
        $definition=switch($Fault){
            'document array' {@(@{Module='a'},@{Module='b'})}
            'missing platforms' {@{Module='Fixture'}}
            'platforms array' {@{Platforms=@('Windows')}}
            'missing platform' {@{Platforms=@{Linux=@{Method='None'}}}}
            'platform array' {@{Platforms=@{Windows=@('None')}}}
            'missing method' {@{Platforms=@{Windows=@{}}}}
            'numeric method' {@{Platforms=@{Windows=@{Method=42}}}}
            'blank method' {@{Platforms=@{Windows=@{Method=' '}}}}
        }
        ConvertTo-Json -InputObject $definition -Depth 8|Set-Content (Join-Path $script:RecipeRoot 'image.json')
        InModuleScope MutatorImageRecipeRuntime -Parameters @{Installer=$script:RecipeInstaller;Destination=$script:RecipeRoot} {
            param($Installer,$Destination)
            {. $Installer -Platform Windows -Root $Destination}|Should -Throw '*Invalid Windows image profile*'
        }
        Test-Path (Join-Path $script:RecipeRoot 'installed-tool.json')|Should -BeFalse
        @(Get-ChildItem $script:RecipeRoot -Filter 'install-*.log').Count|Should -Be 0
    }

    It 'preserves an explicit incompatibility reason' {
        {Invoke-OfflineImageRecipe @{Method='Unsupported';Reason='fixture platform incompatibility'}}|Should -Throw '*fixture platform incompatibility*'
        Test-Path (Join-Path $script:RecipeRoot 'installed-tool.json')|Should -BeFalse
    }

    It 'uses the requested version override rather than the default profile version' {
        $env:TOOL_VERSION='4.5.6'
        Invoke-OfflineImageRecipe @{Method='Npm';Package='fixture';Version='1.2.3'}
        $log=Get-ChildItem $script:RecipeRoot -Filter 'install-*.log'
        (Get-Content $log.FullName -Raw|ConvertFrom-Json).Arguments|Should -Contain 'fixture@4.5.6'
    }

    It 'installs Node only after finding its exact archive in the published checksum list' {
        Invoke-OfflineImageRecipe @{Method='Npm';Package='fixture';NodeVersion='22.11.0'}
        Test-Path (Join-Path $script:RecipeRoot 'tool/tool-fixture.exe')|Should -BeTrue
        InModuleScope MutatorImageRecipeRuntime {
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {$Uri -ceq 'https://nodejs.org/dist/v22.11.0/SHASUMS256.txt'}
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {$Uri -ceq 'https://nodejs.org/dist/v22.11.0/node-v22.11.0-linux-x64.tar.gz'}
        }
    }

    It 'refuses a Node or Terraform archive missing from its published sums: <Method>' -ForEach @(@{Method='Npm'},@{Method='Hashicorp'}) {
        InModuleScope MutatorImageRecipeRuntime {Mock Invoke-WebRequest {@{Content='no matching artifact'}} -ParameterFilter {!$OutFile}}
        $profile=@{Method=$Method;Package='fixture';NodeVersion='22.11.0';Version='1.2.3'}
        {Invoke-OfflineImageRecipe $profile}|Should -Throw '*absent from*'
        Test-Path (Join-Path $script:RecipeRoot 'installed-tool.json')|Should -BeFalse
        @(Get-ChildItem $script:RecipeRoot -Filter 'install-*.log').Count|Should -Be 0
    }

    It 'uses an explicit verified release artifact without querying GitHub' {
        $env:TOOL_URL='https://example.invalid/tool.zip';$env:TOOL_SHA256=$script:RecipeZipSha
        Invoke-OfflineImageRecipe @{Method='Release';Format='zip';Binary='tool-fixture'}
        InModuleScope MutatorImageRecipeRuntime {Should -Invoke Invoke-RestMethod -Times 0}
        Test-Path (Join-Path $script:RecipeRoot 'tool/tool-fixture.exe')|Should -BeTrue
    }

    It 'refuses ambiguous releases or unsigned assets: <Fault>' -ForEach @(@{Fault='none'},@{Fault='duplicate'},@{Fault='digest'}) {
        InModuleScope MutatorImageRecipeRuntime -Parameters @{Fault=$Fault} {
            param($Fault)
            $script:ReleaseFault=$Fault
            Mock Invoke-RestMethod {
                $asset=@{name='tool.zip';digest=('sha256:'+$script:OfflineZipSha);browser_download_url='https://example.invalid/tool.zip'}
                if($script:ReleaseFault -eq 'none'){@{assets=@()}}
                elseif($script:ReleaseFault -eq 'duplicate'){@{assets=@($asset,$asset)}}
                else{$asset.digest=$null;@{assets=@($asset)}}
            }
        }
        {Invoke-OfflineImageRecipe @{Method='Release';Repository='owner/project';AssetPattern='^tool\.zip$';Format='zip'}}|Should -Throw
        Test-Path (Join-Path $script:RecipeRoot 'tool')|Should -BeFalse
        Test-Path (Join-Path $script:RecipeRoot 'installed-tool.json')|Should -BeFalse
    }

    It 'installs Ag only after verifying both the archive and the executable' {
        Invoke-OfflineImageRecipe @{Method='AgWindows';Uri='https://example.invalid/ag.zip';Sha256=$script:RecipeAgZipSha;BinarySha256=$script:RecipeAgBinarySha;Binary='ag'}
        (Get-FileHash (Join-Path $script:RecipeRoot 'bin/ag.exe')).Hash|Should -BeExactly $script:RecipeAgBinarySha
        Test-Path (Join-Path $script:RecipeRoot 'bin/LICENSE-Ag.txt')|Should -BeTrue
        Test-Path (Join-Path $script:RecipeRoot 'ag.zip')|Should -BeFalse
    }

    It 'refuses corrupt or incomplete Ag artifacts: <Fault>' -ForEach @(@{Fault='archive'},@{Fault='entry'},@{Fault='executable'}) {
        $profile=@{Method='AgWindows';Uri='https://example.invalid/ag.zip';Sha256=$script:RecipeAgZipSha;BinarySha256=$script:RecipeAgBinarySha}
        if($Fault -eq 'archive'){$profile.Sha256='0'*64}
        elseif($Fault -eq 'executable'){$profile.BinarySha256='0'*64}
        else{
            $profile.Sha256=$script:RecipeZipSha
            InModuleScope MutatorImageRecipeRuntime {Mock Invoke-WebRequest {param($OutFile) Copy-Item $script:OfflineZip $OutFile} -ParameterFilter {$Uri -like '*ag.zip'}}
        }
        {Invoke-OfflineImageRecipe $profile}|Should -Throw
        Test-Path (Join-Path $script:RecipeRoot 'installed-tool.json')|Should -BeFalse
        Test-Path (Join-Path $script:RecipeRoot 'ag.zip')|Should -BeTrue
    }

    It 'requires composer to have produced the artisan entry point' {
        $env:MUTATOR_FIXTURE_SKIP_ARTISAN='1'
        {Invoke-OfflineImageRecipe @{Method='Artisan'}}|Should -Throw '*artisan script was not installed*'
        Test-Path (Join-Path $script:RecipeRoot 'installed-tool.json')|Should -BeFalse
    }

    It 'records additional tool paths and recipes without a binary: <Platform>' -ForEach @(@{Platform='Windows'},@{Platform='Linux'},@{Platform='MacOS'}) {
        $extra=@((Join-Path $script:RecipeRoot 'vendor/bin'),(Join-Path $script:RecipeRoot 'other/bin'))
        Invoke-OfflineImageRecipe @{Method='None';ExtraPath=$extra} -Platform $Platform
        @(Get-Content (Join-Path $script:RecipeRoot 'tool-path.json') -Raw|ConvertFrom-Json)|Should -Be $extra
        $receipt=Get-Content (Join-Path $script:RecipeRoot 'installed-tool.json') -Raw|ConvertFrom-Json
        $receipt.Platform|Should -BeExactly $Platform
        $receipt.Executable|Should -BeNullOrEmpty
    }
    It 'verifies the Homebrew bootstrap before creating its account and installation links: <Valid>' -ForEach @(@{Valid=$true},@{Valid=$false}) {
        InModuleScope MutatorImageRecipeRuntime {Mock New-ImageToolSymbolicLink {}}
        $profile=@{Method='Homebrew';BootstrapSha256=$(if($Valid){$script:RecipeZipSha}else{'0'*64})}
        if($Valid){
            Invoke-OfflineImageRecipe $profile -Platform Linux
            $env:NONINTERACTIVE|Should -BeExactly '1'
            $calls=@(Get-ChildItem $script:RecipeRoot -Filter 'install-*.log'|ForEach-Object {(Get-Content $_.FullName -Raw|ConvertFrom-Json).Arguments})
            $calls|Should -Contain linuxbrew
            $calls|Should -Contain '/bin/bash'
            $calls|Should -Contain (Join-Path $script:RecipeRoot 'homebrew-install.sh')
            $calls|Should -Contain (Join-Path $script:RecipeRoot 'workload')
            InModuleScope MutatorImageRecipeRuntime {
                Should -Invoke New-ImageToolSymbolicLink -Times 1 -Exactly -ParameterFilter {$Target -ceq '/home/linuxbrew/.linuxbrew/bin/brew' -and (Split-Path $Path -Leaf) -ceq 'brew'}
                Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {$Uri -ceq 'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh'}
            }
        }else{
            {Invoke-OfflineImageRecipe $profile -Platform Linux}|Should -Throw '*Homebrew bootstrap SHA256 changed*'
            InModuleScope MutatorImageRecipeRuntime {Should -Invoke New-ImageToolSymbolicLink -Times 0}
            @(Get-ChildItem $script:RecipeRoot -Filter 'install-*.log').Count|Should -Be 1
        }
    }
    It 'accepts an existing full Xcode installation and refuses its absence: <Present>' -ForEach @(@{Present=$true},@{Present=$false}) {
        InModuleScope MutatorImageRecipeRuntime -Parameters @{Present=$Present;RealTestPath=$script:RecipeTestPathCommand} {
            param($Present,$RealTestPath)
            $script:FullXcodeAvailable=$Present
            $realTestPath=$RealTestPath
            Mock Test-Path -MockWith ({param($Path,$LiteralPath) if($PSBoundParameters.ContainsKey('LiteralPath')){& $realTestPath -LiteralPath $LiteralPath}else{& $realTestPath -Path $Path}}.GetNewClosure())
            Mock Test-Path {$script:FullXcodeAvailable} -ParameterFilter {$Path -ceq '/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild'}
        }
        if($Present){
            Invoke-OfflineImageRecipe @{Method='Xcode'} -Platform MacOS
            (Get-Content (Join-Path $script:RecipeRoot 'installed-tool.json') -Raw|ConvertFrom-Json).Method|Should -BeExactly Xcode
        }else{{Invoke-OfflineImageRecipe @{Method='Xcode'} -Platform MacOS}|Should -Throw '*Install full Xcode*'}
    }
    It 'links only installed versioned aliases on Unix: <Platform>' -ForEach @(@{Platform='Linux'},@{Platform='MacOS'}) {
        InModuleScope MutatorImageRecipeRuntime {
            $script:AliasLinks=[Collections.Generic.List[object]]::new()
            Mock Get-Command {$null} -ParameterFilter {$Name -in @('php','python','pip','pip3')}
            Mock Get-Command {param($Name) @{Source=('/versioned/'+$Name)}} -ParameterFilter {$Name -in @('php85','python3')}
            Mock New-ImageToolSymbolicLink {param($Path,$Target) $script:AliasLinks.Add(@{Path=$Path;Target=$Target})}
        }
        Invoke-OfflineImageRecipe @{Method='None'} -Platform $Platform
        InModuleScope MutatorImageRecipeRuntime {
            $script:AliasLinks.Count|Should -Be 2
            @($script:AliasLinks.Target)|Should -Be @('/versioned/php85','/versioned/python3')
            @($script:AliasLinks.Path|ForEach-Object {Split-Path $_ -Leaf})|Should -Be @('php','python')
        }
    }
    It 'selects the newest GNU compiler and refuses a missing compiler: <Present>' -ForEach @(@{Present=$true},@{Present=$false}) {
        InModuleScope MutatorImageRecipeRuntime -Parameters @{Present=$Present} {
            param($Present)
            $script:GnuCompilerAvailable=$Present
            Mock Get-ChildItem {
                param($Path)
                if($script:GnuCompilerAvailable){
                    $compiler=if($Path -like '*g++*'){'g++'}else{'gcc'}
                    [pscustomobject]@{Name=($compiler+'-14');FullName=('/installed/'+$compiler+'-14')}
                    [pscustomobject]@{Name=($compiler+'-15');FullName=('/installed/'+$compiler+'-15')}
                }
            } -ParameterFilter {$Path -like '/usr/local/opt/gcc/bin/*'}
            Mock New-ImageToolSymbolicLink {}
        }
        if($Present){
            Invoke-OfflineImageRecipe @{Method='Brew';GnuCompiler=$true} -Platform MacOS
            InModuleScope MutatorImageRecipeRuntime {
                Should -Invoke New-ImageToolSymbolicLink -Times 1 -Exactly -ParameterFilter {$Target -ceq '/installed/gcc-15' -and (Split-Path $Path -Leaf) -ceq 'gcc'}
                Should -Invoke New-ImageToolSymbolicLink -Times 1 -Exactly -ParameterFilter {$Target -ceq '/installed/g++-15' -and (Split-Path $Path -Leaf) -ceq 'g++'}
            }
        }else{{Invoke-OfflineImageRecipe @{Method='Brew';GnuCompiler=$true} -Platform MacOS}|Should -Throw '*GNU compiler was not installed*'}
    }
    It 'discovers a unique nested binary and leaves ambiguous payloads unresolved: <Platform>/<Count>' -ForEach @(
        @{Platform='Windows';Count=1},@{Platform='Linux';Count=1},@{Platform='Windows';Count=2},@{Platform='Linux';Count=0}
    ) {
        for($i=0;$i -lt $Count;$i++){
            $path=Join-Path $script:RecipeRoot ('tool/release'+$i+'/tool-fixture'+$(if($Platform -eq 'Windows'){'.exe'}else{''}))
            [void][IO.Directory]::CreateDirectory((Split-Path $path));[IO.File]::WriteAllText($path,'payload')
        }
        if(!$Count){[void][IO.Directory]::CreateDirectory((Join-Path $script:RecipeRoot 'tool'))}
        InModuleScope MutatorImageRecipeRuntime {
            $script:BinaryDiscoveryQueries=0
            Mock Get-Command {
                $script:BinaryDiscoveryQueries++
                if($script:BinaryDiscoveryQueries -gt 1){@{Source=$script:OfflineCli}}
            } -ParameterFilter {$Name -ceq 'tool-fixture'}
        }
        Invoke-OfflineImageRecipe @{Method='None';Binary='tool-fixture'} -Platform $Platform
        if($Count -eq 1){
            @(Get-Content (Join-Path $script:RecipeRoot 'tool-path.json') -Raw|ConvertFrom-Json)|Should -Be @((Join-Path $script:RecipeRoot 'tool/release0'))
        }else{Test-Path (Join-Path $script:RecipeRoot 'tool-path.json')|Should -BeFalse}
    }
    It 'uses a Unix venv and applies execute permissions only to the extracted binary' {
        InModuleScope MutatorImageRecipeRuntime {Mock Set-ImageToolExecutable {}}
        Invoke-OfflineImageRecipe @{Method='Pip';Package='fixture';Version='3.2.1'} -Platform Linux
        $arguments=@(Get-ChildItem $script:RecipeRoot -Filter 'install-*.log'|ForEach-Object {(Get-Content $_.FullName -Raw|ConvertFrom-Json).Arguments})
        $arguments|Should -Contain (Join-Path $script:RecipeRoot 'python')
        $arguments|Should -Contain 'fixture==3.2.1'
        $payload=Join-Path $script:RecipeRoot 'permissions-source';[void][IO.Directory]::CreateDirectory($payload)
        [IO.File]::WriteAllText((Join-Path $payload 'tool'),'executable');[IO.File]::WriteAllText((Join-Path $payload 'LICENSE'),'attribution')
        $archive=Join-Path $script:RecipeRoot 'permissions.zip';[IO.Compression.ZipFile]::CreateFromDirectory($payload,$archive)
        InModuleScope MutatorImageRecipeRuntime -Parameters @{Archive=$archive;Digest=(Get-FileHash $archive).Hash;Destination=$script:RecipeRoot} {
            param($Archive,$Digest,$Destination)
            $script:Root=$Destination;$script:Platform='Linux'
            $offlinePermissionsArchive=$Archive
            Mock Invoke-WebRequest -MockWith ({param($OutFile) Copy-Item -LiteralPath $offlinePermissionsArchive -Destination $OutFile}.GetNewClosure())
            Install-ImageArchive 'https://example.invalid/permissions.zip' $Digest zip tool
            Should -Invoke Set-ImageToolExecutable -Times 1 -Exactly -ParameterFilter {(Split-Path $Path -Leaf) -ceq 'tool'}
        }
    }
}
