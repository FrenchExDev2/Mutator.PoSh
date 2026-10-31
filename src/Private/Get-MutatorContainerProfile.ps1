function Get-MutatorContainerProfile {
    param([string]$Key,[string]$Binary)
    $directory=Join-Path $script:MutatorRoot 'resources/containers/definitions'
    $plans=Import-PowerShellDataFile (Join-Path $directory 'ToolPlans.psd1')
    $versions=Read-MutatorJson (Join-Path $directory 'package-versions.json')
    $profiles=@{Linux=@{Method='Unconfigured';Binary=$Binary};Windows=@{Method='Unconfigured';Binary=$Binary}}
    $pin={param($names,$platform) @(foreach($package in @($names -split ' '|Where-Object{$_})){
        $version=$versions[$platform][$package]
        if(!$version){throw "No verified $platform package version for $package ($Key)."}
        $package+'='+$version
    })}
    foreach($pair in @(@('Apk','Linux'),@('Chocolatey','Windows'))){
        if($plans[$pair[0]].ContainsKey($Key)){$profiles[$pair[1]].Method=$pair[0];$profiles[$pair[1]].Packages=@(& $pin $plans[$pair[0]][$Key] $pair[1])}
    }
    if($Key -in $plans.GitWindows){$profiles.Windows.Method='Chocolatey';$profiles.Windows.Packages=@(& $pin 'git' 'Windows')}
    $prerequisites=@{
        Npm=@{Linux='nodejs npm python3 build-base';Windows='nodejs-lts'}
        Pip=@{Linux='python3 py3-pip python3-dev build-base libffi-dev openssl-dev cargo';Windows='python'}
        Gem=@{Linux='ruby ruby-dev build-base libffi-dev yaml-dev zlib-dev';Windows='ruby'}
        Composer=@{Linux='composer php85 php85-curl php85-dom php85-mbstring php85-xml php85-xmlwriter php85-zip php85-tokenizer php85-pdo php85-pdo_sqlite';Windows='php composer'}
        Go=@{Linux='go git';Windows='golang git'}
    }
    foreach($kind in @('Npm','Pip','Gem','Composer','Go')){
        if($plans[$kind].ContainsKey($Key)){foreach($platform in @('Linux','Windows')){
            $profiles[$platform].Method=$kind;$profiles[$platform].Package=$plans[$kind][$Key]
            $profiles[$platform].Packages=@(& $pin $prerequisites[$kind][$platform] $platform)
        }}
    }
    if($Key -in $plans.Infrastructure){foreach($platform in @('Linux','Windows')){$profiles[$platform]=@{Method='None';Binary=$null}}}
    switch($Key){
        'Ag' {$profiles.Windows=@{Method='AgWindows';Binary='ag';Uri='https://github.com/JFLarvoire/the_silver_searcher/releases/download/2.2.7-Windows/ag.zip';Sha256='02EAA63C03A291E391415705A463D6A4E1D5D99C8E3C8A2E5BD050616425E1BC';BinarySha256='6AA8F7AEAAD158841462119727EC7FAD287624D826913AC7EC0199B89074CD0D'}}
        'Artisan' {foreach($platform in @('Linux','Windows')){$profiles[$platform].Method='Artisan';$profiles[$platform].Binary='php';$profiles[$platform].Packages=@(& $pin $prerequisites.Composer[$platform] $platform)}}
        'Phpt' {foreach($platform in @('Linux','Windows')){$profiles[$platform].Method='Phpt';$profiles[$platform].Binary='php';$profiles[$platform].Packages=@(& $pin $prerequisites.Composer[$platform] $platform);$phpVersion=if($platform -eq 'Linux'){$versions.Linux.php85 -replace '-r\d+$',''}else{$versions.Windows.php};$profiles[$platform].PhpSourceRef='php-'+$phpVersion}}
        'Tree' {$profiles.Windows=@{Method='None';Binary='tree'}}
        'Ping' {$profiles.Windows=@{Method='None';Binary='ping'}}
        'Psql' {$profiles.Windows=@{Method='Artifact';Binary='psql';Format='zip';Reason='Provide a verified portable PostgreSQL Windows archive with TOOL_URL and TOOL_SHA256; no database server is installed as a service.'}}
        'Swift' {$profiles.Windows=@{Method='Artifact';Binary='swift';Format='zip';Reason='Provide a verified Windows Swift toolchain archive and required SDK/runtime dependencies; TOOL_URL and TOOL_SHA256 are mandatory.'}}
        'Gcloud' {$profiles.Linux=@{Method='Artifact';Binary='gcloud';Format='tar.gz';Packages=@(& $pin 'python3' 'Linux');Reason='Provide the official Google Cloud CLI Linux archive and its published SHA256 as TOOL_URL and TOOL_SHA256.'}}
        'Bun' {$profiles.Linux=@{Method='Release';Binary='bun';Repository='oven-sh/bun';AssetPattern='^bun-linux-x64-musl\.zip$';Format='zip'}}
        'Jj' {$profiles.Windows=@{Method='Release';Binary='jj';Repository='jj-vcs/jj';AssetPattern='x86_64-pc-windows-msvc\.zip$';Format='zip'}}
        'Trunk' {$profiles.Windows=@{Method='Release';Binary='trunk';Repository='trunk-rs/trunk';AssetPattern='x86_64-pc-windows-msvc\.zip$';Format='zip'}}
        'Sbt' {$profiles.Linux=@{Method='Release';Binary='sbt';Repository='sbt/sbt';AssetPattern='^sbt-[0-9.]+\.tgz$';Format='tar.gz';Packages=@(& $pin 'openjdk21-jdk bash' 'Linux')}}
        'Liquibase' {$profiles.Linux=@{Method='Release';Binary='liquibase';Repository='liquibase/liquibase';AssetPattern='^liquibase-[0-9.]+\.tar\.gz$';Format='tar.gz';Packages=@(& $pin 'openjdk21-jdk bash' 'Linux')}}
        'Hadolint' {$profiles.Linux=@{Method='ImageCopy';Binary='hadolint';SourceImage=('docker.io/hadolint/hadolint:'+$versions.Windows.hadolint+'-alpine');SourcePath='/bin/hadolint'}}
        'Terraform' {$profiles.Linux=@{Method='Hashicorp';Binary='terraform';Version=$versions.Windows.terraform;Format='zip'}}
    }
    if($plans.Unsupported.ContainsKey($Key)){foreach($platform in $plans.Unsupported[$Key].Keys){$profiles[$platform]=@{Method='Unsupported';Binary=$Binary;Reason=$plans.Unsupported[$Key][$platform]}}}
    switch($Key){
        'Brew' {$profiles.Linux=@{Method='Homebrew';Binary='brew';Distribution='Debian';Packages=@('build-essential','procps','curl','file','git','bash','util-linux');User='linuxbrew';BootstrapSha256=$versions.Sources.HomebrewBootstrapSHA256;Reason='Homebrew requires glibc and an unprivileged installation.'}}
        {$_ -in @('Journalctl','Systemctl')} {$profiles.Linux=@{Method='Apt';Binary=$Binary;Distribution='Debian';Packages=@('systemd');Constraints='Client binaries only; no systemd PID 1 is started. systemctl needs a systemd host/service; journalctl can read mounted journals.'}}
        'Swift' {$profiles.Linux=@{Method='None';Binary='swift';Distribution='Debian';BaseImage='docker.io/library/swift:6.4.1-bookworm';Reason='Official Swift Debian 12 toolchain image, published by swift.org.'}}
        'Quarto' {$profiles.Linux=@{Method='Release';Binary='quarto';Distribution='Debian';Repository='quarto-dev/quarto-cli';AssetPattern='^quarto-[0-9.]+-linux-amd64\.tar\.gz$';Format='tar.gz';Packages=@('python3','libglib2.0-0','libnss3','libasound2');Reason='The Quarto Linux distribution requires glibc.'}}
        {$_ -in @('Playwright','Gt')} {$profiles.Linux.Distribution='Debian';$profiles.Linux.Packages=@('python3','build-essential','git');$profiles.Linux.NodeVersion=$versions.Linux.nodejs -replace '-r\d+$','';$profiles.Linux.Reason='Use Debian/glibc for bundled native tooling and browser compatibility.'}
    }
    foreach($platform in @('Linux','Windows')){
        if($platform -eq 'Linux' -and !$profiles.Linux.ContainsKey('Distribution')){$profiles.Linux.Distribution='Alpine'}
        if($profiles[$platform].Method -eq 'Unconfigured'){throw "Missing explicit $platform installer for $Key."}
        $profiles[$platform].Status=switch($profiles[$platform].Method){'Unsupported'{'Unsupported'};'Artifact'{'NeedsArtifact'};default{'Prepared'}}
        $profiles[$platform].BuildValidated=$false
        if($plans.Constraints.ContainsKey($Key) -and !$profiles[$platform].ContainsKey('Constraints')){$profiles[$platform].Constraints=$plans.Constraints[$Key]}
        if($Key -eq 'Playwright' -and $platform -eq 'Linux'){$profiles.Linux.Constraints='CLI installed on Debian; browser downloads remain a separate explicit build/run step.'}
    }
    $profiles
}
