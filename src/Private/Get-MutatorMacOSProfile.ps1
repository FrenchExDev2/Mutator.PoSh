function Get-MutatorMacOSProfile {
    <#
    .SYNOPSIS
    Resolve an explicit macOS installation and launch profile.

    .DESCRIPTION
    Uses package plans, constraints and manual-setup requirements. Unknown recipes fail; prepared
    metadata does not prove qualification.
    #>

    param([string]$Key,[string]$Binary)
    $directory=Join-Path $script:MutatorRoot 'resources/containers/definitions'
    $plans=Import-PowerShellDataFile (Join-Path $directory 'MacOSPlans.psd1')
    $ecosystems=Import-PowerShellDataFile (Join-Path $directory 'ToolPlans.psd1')
    $data=@{Method='Unconfigured';Binary=$Binary;Backend='Dockurr';ContainerOS='Linux';GuestOS='macOS';Installation='OnCloneBoot';VirtualMachine=$true;HardwareRequirement='Apple hardware';BuildValidated=$false}
    if($plans.Brew.ContainsKey($Key)){$data.Method='Brew';$data.Packages=@($plans.Brew[$Key])}
    if($plans.Cask.ContainsKey($Key)){$data.Method='BrewCask';$data.Packages=@($plans.Cask[$Key])}
    foreach($kind in @('Npm','Pip','Gem','Composer','Go')){
        if($ecosystems[$kind].ContainsKey($Key)){$data.Method=$kind;$data.Package=$ecosystems[$kind][$Key];$data.Packages=$plans.Prerequisites[$kind]}
    }
    if($Key -in $plans.Builtin){$data.Method='None';$data.Packages=@()}
    if($Key -in $ecosystems.Infrastructure){$data.Method='None';$data.Binary=$null;$data.Packages=@()}
    switch($Key){
        'Dotnet' {$data.Method='None';$data.Packages=@()}
        'Psql' {$data.Binary='psql';$data.ExtraPath=@('/usr/local/opt/libpq/bin')}
        'Java' {$data.ExtraPath=@('/usr/local/opt/openjdk@21/bin')}
        'Gcc' {$data.Binary='gcc';$data.GnuCompiler=$true}
        'Gpp' {$data.Binary='g++';$data.GnuCompiler=$true}
        'Python' {$data.Packages=@('python@3.14')}
        'Pip' {$data.Packages=@('python@3.14')}
        'Artisan' {$data.Method='Artisan';$data.Binary='php';$data.Packages=@('php','composer')}
        'Phpt' {$data.Method='Phpt';$data.Binary='php';$data.Packages=@('php','composer');$data.PhpSourceRef='php-8.5.12'}
        'Fail2banClient' {$data.Method='Pip';$data.Package='fail2ban';$data.Packages=@('python')}
        'Oc' {$data.Method='Brew';$data.Packages=@('openshift-cli')}
        'Xcodebuild' {$data.Method='Xcode';$data.Packages=@();$data.Constraints='Install the full Xcode application and select its Developer directory; Command Line Tools alone are insufficient.'}
    }
    if($plans.Unsupported.ContainsKey($Key)){$data.Method='Unsupported';$data.Reason=$plans.Unsupported[$Key]}
    if($data.Method -eq 'Unconfigured'){throw "No explicit macOS installation recipe for $Key."}
    $data.Status=switch($data.Method){'Unsupported'{'Unsupported'};'Xcode'{'NeedsManualSetup'};default{'Prepared'}}
    $data
}
