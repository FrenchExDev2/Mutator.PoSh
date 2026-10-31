function Import-MutatorQuietCli {
    <#
    .SYNOPSIS
    Load QuietCli from the expected sibling ecosystem.

    .DESCRIPTION
    Reuses the correctly loaded engine and refuses copies from another path. Missing engines fail
    without archived-provider fallback.
    #>

    # A host, a sandbox and an image all keep QuietCli at this same location beside Mutator.
    $directory=[IO.Path]::GetFullPath((Join-Path (Split-Path $script:MutatorRoot) 'QuietCliEcosystem/FrenchExDev.QuietCli.PoSh'))
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    $loaded=@(Get-Module FrenchExDev.QuietCli.PoSh)
    foreach($module in $loaded){
        if(![string]::Equals([IO.Path]::GetFullPath($module.ModuleBase),$directory,$comparison)){throw "QuietCli is already loaded from another location: $($module.ModuleBase); Mutator requires $directory."}
    }
    if($loaded.Count){return}
    $manifest=Join-Path $directory 'FrenchExDev.QuietCli.PoSh.psd1'
    if(!(Test-Path -LiteralPath $manifest -PathType Leaf)){throw "QuietCli engine is missing: $manifest."}
    Import-Module $manifest -DisableNameChecking -ErrorAction Stop
}
function Invoke-MutatorQuietOperation {
    <#
    .SYNOPSIS
    Run an operation under scoped Mutator QuietCli settings.

    .DESCRIPTION
    Passes inherited configuration to the operation and restores the caller's environment even on
    failure.
    #>

    param([Parameter(Mandatory)][scriptblock]$Operation)
    Import-MutatorQuietCli
    # The configuration path has no parameter. Restoring it keeps a host session's own pump settings intact.
    $inherited=$env:QUIETCLI_CONFIG_PATH
    $env:QUIETCLI_CONFIG_PATH=Join-Path $script:MutatorRoot 'resources/quietcli/mutator.yaml'
    try{& $Operation $inherited}finally{$env:QUIETCLI_CONFIG_PATH=$inherited}
}
