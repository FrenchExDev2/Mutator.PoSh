#requires -Version 7.6
param([Parameter(Mandatory)][ValidateSet('Linux','Windows','MacOS')][string]$Platform,[Parameter(Mandatory)][string]$Root)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'Environment.ps1')

function New-ImageToolSymbolicLink {
    <#
    .SYNOPSIS
    Create a platform file alias to an installed tool.

    .DESCRIPTION
    Preserves the target and surfaces privilege or unsupported-host failures during explicit image
    bootstrap.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private image bootstrap applies its reviewed recipe inside the outer image build ShouldProcess boundary.')]
    [CmdletBinding()]
    param([string]$Path,[string]$Target)
    [void][IO.File]::CreateSymbolicLink($Path,$Target)
}
function Set-ImageToolExecutable {
    <#
    .SYNOPSIS
    Apply executable permissions to an installed Unix tool.

    .DESCRIPTION
    Adds execute permission for user, group and others through the Unix file-mode API. Unsupported
    hosts surface the API error rather than silently claiming executable permissions.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private image bootstrap changes only the extracted tool inside the outer image build ShouldProcess boundary.')]
    [CmdletBinding()]
    param([string]$Path)
    [IO.File]::SetUnixFileMode($Path,([IO.File]::GetUnixFileMode($Path) -bor [IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherExecute))
}
function Invoke-ImageInstallCommand {
    <#
    .SYNOPSIS
    Run one installer command and require an accepted exit.

    .DESCRIPTION
    Drains both process streams into a retained local log and accepts exit codes 0 and 3010.
    Other exit codes throw before refreshing the image process environment.
    #>

    param([string]$Name,[string[]]$Arguments)
    $application=Get-Command $Name -CommandType Application -ErrorAction Stop|Select-Object -First 1
    $start=[Diagnostics.ProcessStartInfo]::new($application.Source)
    $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    if($IsWindows -and [IO.Path]::GetExtension($application.Source) -in @('.cmd','.bat')){
        $start.FileName=Join-Path $PSHOME 'pwsh.exe'
        $script='& '+((@($application.Source)+$Arguments|ForEach-Object{"'"+$_.Replace("'","''")+"'"}) -join ' ')+'; exit $LASTEXITCODE'
        foreach($arg in @('-NoLogo','-NoProfile','-Command',$script)){[void]$start.ArgumentList.Add($arg)}
    }else{foreach($arg in $Arguments){[void]$start.ArgumentList.Add($arg)}}
    $process=[Diagnostics.Process]::Start($start)
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    $process.WaitForExit();$out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
    $log=Join-Path $Root ('install-'+[guid]::NewGuid().ToString('N')+'.log')
    [IO.File]::WriteAllText($log,$out+[Environment]::NewLine+$err)
    if($process.ExitCode -notin @(0,3010)){throw "Installer $Name failed with exit $($process.ExitCode); retained log: $log"}
    Set-ImageToolEnvironment $Root
}
function Install-ImageChocolatey {
    <#
    .SYNOPSIS
    Install Chocolatey from verified bootstrap content.

    .DESCRIPTION
    Reuses an existing command, otherwise checks its bootstrap hash before execution and verifies
    command discovery.
    #>

    if(Get-Command choco.exe -CommandType Application -ErrorAction Ignore){return}
    $path=Join-Path $Root 'chocolatey-install.ps1'
    Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' -OutFile $path
    if((Get-FileHash $path).Hash -ne '44E045ED5350758616D664C5AF631E7F2CD10165F5BF2BD82CBF3A0BB8F63462'){throw 'Chocolatey bootstrap SHA256 changed; review and update the pinned bootstrap.'}
    $env:chocolateyVersion='2.5.1';$env:chocolateyUseWindowsCompression='true'
    & $path
    Set-ImageToolEnvironment $Root
    $null=Get-Command choco.exe -CommandType Application -ErrorAction Stop
}
function Install-ImagePrerequisite {
    <#
    .SYNOPSIS
    Install nonblank prerequisites with the selected package manager.

    .DESCRIPTION
    Preserves pins and chooses Linux distribution or macOS formula/cask mode. Empty lists launch no
    installer.
    #>

    param([string[]]$Packages)
    $Packages=@($Packages|Where-Object{![string]::IsNullOrWhiteSpace($_)})
    if(!$Packages.Count){return}
    if($Platform -eq 'MacOS'){
        foreach($package in $Packages){$installArguments=if($toolProfile.Method -eq 'BrewCask'){@('install','--cask',$package)}else{@('install',$package)};Invoke-ImageInstallCommand brew $installArguments}
    }
    elseif($Platform -eq 'Linux' -and $toolProfile['Distribution'] -eq 'Debian'){
        Invoke-ImageInstallCommand apt-get @('update')
        Invoke-ImageInstallCommand apt-get (@('install','-y','--no-install-recommends')+$Packages)
    }
    elseif($Platform -eq 'Linux'){Invoke-ImageInstallCommand apk (@('add','--no-cache')+$Packages)}
    else{
        Install-ImageChocolatey
        foreach($package in $Packages){
            $parts=$package.Split('=',2);$arguments=@('install',$parts[0],'--yes','--no-progress','--limit-output')
            if($parts.Count -eq 2){$arguments+=@('--version',$parts[1])}
            Invoke-ImageInstallCommand choco.exe $arguments
        }
    }
}
function Install-ImageArchive {
    <#
    .SYNOPSIS
    Download/extract an artifact only after SHA-256 verification.

    .DESCRIPTION
    Requires HTTPS and an exact digest and handles supported formats. Corrupt downloads stay available
    and are never executed.
    #>

    param([string]$Uri,[string]$Sha256,[string]$Format,[string]$Binary)
    if($Uri -notmatch '^https://' -or $Sha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'A tool artifact requires an HTTPS TOOL_URL and its exact TOOL_SHA256.'}
    $archive=Join-Path $Root ('tool-download.'+$Format)
    Invoke-WebRequest -Uri $Uri -OutFile $archive
    if((Get-FileHash $archive).Hash -ne $Sha256){throw 'Native tool artifact SHA256 mismatch.'}
    $destination=Join-Path $Root 'tool';[void][IO.Directory]::CreateDirectory($destination)
    switch($Format){
        'zip' {Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force}
        'tar.gz' {
            Add-Type -AssemblyName System.Formats.Tar
            $stream=[IO.File]::OpenRead($archive);$gzip=[IO.Compression.GZipStream]::new($stream,[IO.Compression.CompressionMode]::Decompress)
            try{[System.Formats.Tar.TarFile]::ExtractToDirectory($gzip,$destination,$false)}finally{$gzip.Dispose();$stream.Dispose()}
        }
        'binary' {Copy-Item -LiteralPath $archive -Destination (Join-Path $destination $(if($Platform -eq 'Windows'){$Binary+'.exe'}else{$Binary}))}
        default {throw "Unsupported artifact format: $Format"}
    }
    $children=@(Get-ChildItem -LiteralPath $destination -Force)
    if($children.Count -eq 1 -and $children[0].PSIsContainer){
        foreach($child in Get-ChildItem -LiteralPath $children[0].FullName -Force){Move-Item -LiteralPath $child.FullName -Destination $destination}
        Remove-Item -LiteralPath $children[0].FullName
    }
    if($Platform -eq 'Linux'){
        $candidates=@(Get-ChildItem -LiteralPath $destination -File -Recurse|Where-Object Name -EQ $Binary)
        foreach($file in $candidates){Set-ImageToolExecutable $file.FullName}
    }
    Remove-Item -LiteralPath $archive -Force
    Set-ImageToolEnvironment $Root
}

# ValidateSet accepts case variants; JSON dictionaries require the canonical key.
$Platform=switch($Platform){'Linux'{'Linux'};'Windows'{'Windows'};'MacOS'{'MacOS'}}
$definition=Get-Content (Join-Path $Root 'image.json') -Raw|ConvertFrom-Json -AsHashtable
if($definition -isnot [Collections.IDictionary] -or $definition['Platforms'] -isnot [Collections.IDictionary]){
    throw ('Invalid '+$Platform+' image profile: Platforms must be a JSON object.')
}
$toolProfile=$definition.Platforms[$Platform]
if($toolProfile -isnot [Collections.IDictionary]){
    throw ('Invalid '+$Platform+' image profile: the canonical platform key must contain a JSON object.')
}
if($toolProfile['Method'] -isnot [string] -or [string]::IsNullOrWhiteSpace($toolProfile.Method)){
    throw ('Invalid '+$Platform+' image profile: Method must be a nonempty string.')
}
if($toolProfile.Method -eq 'Unsupported'){throw ('Unsupported '+$Platform+' image: '+$toolProfile.Reason)}
foreach($part in @('bin','workload')){[void][IO.Directory]::CreateDirectory((Join-Path $Root $part))}
Set-ImageToolEnvironment $Root
$version=if($env:TOOL_VERSION){$env:TOOL_VERSION}else{$toolProfile['Version']}
$archiveUri=if($env:TOOL_URL){$env:TOOL_URL}else{$toolProfile['Uri']}
$archiveSha=if($env:TOOL_SHA256){$env:TOOL_SHA256}else{$toolProfile['Sha256']}
if($toolProfile.Method -in @('Release','Hashicorp','Go','Phpt','Artisan') -and (!$version -or $version -match '(?i)^(latest|\*)$')){throw 'Pinned TOOL_VERSION or profile Version is required before installation.'}
if($toolProfile.Method -in @('Release','Hashicorp','Artifact') -and $archiveSha -notmatch '^[a-fA-F0-9]{64}$'){throw 'Pinned TOOL_SHA256 or profile Sha256 is required before installation.'}
if($toolProfile.Method -eq 'Phpt' -and $toolProfile['RunTestsSha256'] -notmatch '^[a-fA-F0-9]{64}$'){throw 'Pinned RunTestsSha256 is required before installation.'}
Install-ImagePrerequisite @($toolProfile['Packages'])
switch($toolProfile.Method){
    {$_ -in @('None','Apk','Apt','Chocolatey','ImageCopy','Brew','BrewCask')} {}
    'Npm' {
        if($toolProfile['NodeVersion']){
            $nodeFile='node-v'+$toolProfile.NodeVersion+'-linux-x64.tar.gz'
            $nodeUri='https://nodejs.org/dist/v'+$toolProfile.NodeVersion+'/'
            $sums=(Invoke-WebRequest -Uri ($nodeUri+'SHASUMS256.txt')).Content
            $match=[regex]::Match($sums,'(?m)^([a-fA-F0-9]{64})\s+'+[regex]::Escape($nodeFile)+'\s*$')
            if(!$match.Success){throw 'Node archive is absent from its published SHA256 list.'}
            Install-ImageArchive ($nodeUri+$nodeFile) $match.Groups[1].Value 'tar.gz' 'node'
        }
        $package=$toolProfile.Package+$(if($version){'@'+$version}else{''})
        Invoke-ImageInstallCommand npm @('install','--global','--no-audit','--no-fund',$package)
    }
    'Pip' {
        $venv=Join-Path $Root 'python'
        Invoke-ImageInstallCommand $(if($Platform -eq 'Windows'){'python'}else{'python3'}) @('-m','venv',$venv)
        $python=if($Platform -eq 'Windows'){Join-Path $venv 'Scripts/python.exe'}else{Join-Path $venv 'bin/python'}
        $package=$toolProfile.Package+$(if($version){'=='+$version}else{''})
        Invoke-ImageInstallCommand $python @('-m','pip','install','--no-cache-dir',$package)
    }
    'Gem' {
        $arguments=@('install',$toolProfile.Package,'--no-document','--bindir',(Join-Path $Root 'gems/bin'))
        if($version){$arguments+=@('--version',$version)}
        Invoke-ImageInstallCommand gem $arguments
    }
    'Composer' {
        $package=$toolProfile.Package+$(if($version){':'+$version}else{''})
        $env:COMPOSER_ALLOW_SUPERUSER='1'
        Invoke-ImageInstallCommand composer @('global','require','--no-interaction','--prefer-dist',$package)
    }
    'Artisan' {
        $env:COMPOSER_ALLOW_SUPERUSER='1'
        Invoke-ImageInstallCommand composer @('create-project','--no-interaction','--prefer-dist','laravel/laravel',(Join-Path $Root 'workload'),$version)
        if(!(Test-Path (Join-Path $Root 'workload/artisan'))){throw 'Laravel artisan script was not installed.'}
    }
    'Phpt' {
        $env:COMPOSER_ALLOW_SUPERUSER='1'
        Invoke-ImageInstallCommand composer @('global','require','--no-interaction',('phpgt/phpt:'+$version))
        $uri='https://raw.githubusercontent.com/php/php-src/'+$toolProfile.PhpSourceRef+'/'
        Invoke-WebRequest -Uri ($uri+'run-tests.php') -OutFile (Join-Path $Root 'workload/run-tests.php')
        if((Get-FileHash (Join-Path $Root 'workload/run-tests.php')).Hash -ine $toolProfile.RunTestsSha256){throw 'PHP test runner SHA256 mismatch.'}
        Invoke-WebRequest -Uri ($uri+'LICENSE') -OutFile (Join-Path $Root 'workload/LICENSE-PHP.txt')
    }
    'Go' {
        $env:CGO_ENABLED='0'
        Invoke-ImageInstallCommand go @('install',($toolProfile.Package+'@'+$version))
    }
    'AgWindows' {
        $archive=Join-Path $Root 'ag.zip';Invoke-WebRequest -Uri $toolProfile.Uri -OutFile $archive
        if((Get-FileHash $archive).Hash -ne $toolProfile.Sha256){throw 'Ag archive SHA256 mismatch.'}
        $zip=[IO.Compression.ZipFile]::OpenRead($archive)
        try{$entry=$zip.GetEntry('WIN64/ag.exe');if(!$entry){throw 'Missing WIN64/ag.exe'};[IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $Root 'bin/ag.exe'),$true)}finally{$zip.Dispose()}
        if((Get-FileHash (Join-Path $Root 'bin/ag.exe')).Hash -ne $toolProfile.BinarySha256){throw 'Ag executable SHA256 mismatch.'}
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'LICENSE-Ag.txt') -Destination (Join-Path $Root 'bin/LICENSE-Ag.txt')
        Remove-Item -LiteralPath $archive
    }
    'Release' {
        if($archiveUri){Install-ImageArchive $archiveUri $archiveSha $toolProfile.Format $toolProfile.Binary}
        else{
            $release='tags/'+$version
            $metadata=Invoke-RestMethod -Uri ('https://api.github.com/repos/'+$toolProfile.Repository+'/releases/'+$release) -Headers @{'User-Agent'='FrenchExDev-Mutator-images'}
            $assets=@($metadata.assets|Where-Object name -Match $toolProfile.AssetPattern)
            if($assets.Count -ne 1){throw 'The release must contain exactly one asset matching the platform recipe.'}
            Install-ImageArchive $assets[0].browser_download_url $archiveSha $toolProfile.Format $toolProfile.Binary
        }
    }
    'Artifact' {Install-ImageArchive $archiveUri $archiveSha $toolProfile.Format $toolProfile.Binary}
    'Hashicorp' {
        $file='terraform_'+$version+'_linux_amd64.zip'
        $uri='https://releases.hashicorp.com/terraform/'+$version+'/'
        Install-ImageArchive ($uri+$file) $archiveSha 'zip' 'terraform'
    }
    'Homebrew' {
        Invoke-ImageInstallCommand useradd @('--create-home','--shell','/bin/bash','linuxbrew')
        $installer=Join-Path $Root 'homebrew-install.sh'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh' -OutFile $installer
        if((Get-FileHash $installer).Hash -ne $toolProfile.BootstrapSha256){throw 'Homebrew bootstrap SHA256 changed; review its pinned source.'}
        $env:NONINTERACTIVE='1'
        Invoke-ImageInstallCommand runuser @('-u','linuxbrew','--','/bin/bash',$installer)
        New-ImageToolSymbolicLink (Join-Path $Root 'bin/brew') '/home/linuxbrew/.linuxbrew/bin/brew'
        Invoke-ImageInstallCommand chown @('linuxbrew',(Join-Path $Root 'workload'))
    }
    'Xcode' {
        if(!(Test-Path '/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild')){throw 'Install full Xcode and select its Developer directory before running Xcode contributor tests.'}
    }
    default {throw ('Unknown image tool installer: '+$toolProfile.Method)}
}
Set-ImageToolEnvironment $Root
if($Platform -in @('Linux','MacOS')){
    foreach($pair in @(@('php','php85'),@('python','python3'),@('pip','pip3'))){
        if(!(Get-Command $pair[0] -CommandType Application -ErrorAction Ignore)){
            $actual=Get-Command $pair[1] -CommandType Application -ErrorAction Ignore|Select-Object -First 1
            if($actual){New-ImageToolSymbolicLink (Join-Path $Root ('bin/'+$pair[0])) $actual.Source}
        }
    }
}
if($toolProfile['ExtraPath']){@($toolProfile.ExtraPath)|ConvertTo-Json|Set-Content (Join-Path $Root 'tool-path.json');Set-ImageToolEnvironment $Root}
if($Platform -eq 'MacOS' -and $toolProfile['GnuCompiler']){
    foreach($compiler in @('gcc','g++')){
        $actual=Get-ChildItem -Path ('/usr/local/opt/gcc/bin/'+$compiler+'-[0-9]*') -File|Sort-Object Name -Descending|Select-Object -First 1
        if(!$actual){throw 'The Homebrew GNU compiler was not installed.'}
        New-ImageToolSymbolicLink (Join-Path $Root ('bin/'+$compiler)) $actual.FullName
    }
}
if($toolProfile['Binary'] -and !(Get-Command $toolProfile.Binary -CommandType Application -ErrorAction Ignore)){
    $payload=Join-Path $Root 'tool'
    if(Test-Path -LiteralPath $payload){
        $expected=$toolProfile.Binary+$(if($Platform -eq 'Windows'){'.exe'}else{''})
        $candidates=@(Get-ChildItem -LiteralPath $payload -File -Recurse|Where-Object Name -EQ $expected)
        if($candidates.Count -eq 1){@($candidates[0].DirectoryName)|ConvertTo-Json|Set-Content (Join-Path $Root 'tool-path.json');Set-ImageToolEnvironment $Root}
    }
}
$resolved=if($toolProfile['Binary']){(Get-Command -Name $toolProfile.Binary -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source}else{$null}
@{Module=$definition.Module;Platform=$Platform;Method=$toolProfile.Method;Executable=$resolved;PowerShell=$PSVersionTable.PSVersion.ToString()}|ConvertTo-Json|Set-Content (Join-Path $Root 'installed-tool.json')
