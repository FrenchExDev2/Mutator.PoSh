function Resolve-MutatorModuleDirectory {
    <#
    .SYNOPSIS
    Find a real declared module under the active root.

    .DESCRIPTION
    Accepts canonical names at the root or in QuietCliEcosystem. Refuses missing and linked
    module/parent directories.
    #>

    param([Parameter(Mandatory)][string]$ModuleRoot,[Parameter(Mandatory)][string]$Name)
    if($Name -cnotmatch '^FrenchExDev\.[A-Za-z0-9_.-]+\.PoSh$'){throw 'Container dependencies must name FrenchExDev modules.'}
    $root=[IO.Path]::GetFullPath($ModuleRoot)
    foreach($relative in @($Name,('QuietCliEcosystem/'+$Name))){
        $path=Join-Path $root $relative
        if(!(Test-Path -LiteralPath $path)){continue}
        $item=Get-Item -LiteralPath $path -ErrorAction Stop
        $parent=Get-Item -LiteralPath (Split-Path $path) -ErrorAction Stop
        if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)){
            throw 'Container dependencies require real module directories.'
        }
        return $item.FullName
    }
    throw "Required module directory is missing: $Name in $root."
}

function Get-MutatorModuleRoot {
    <#
    .SYNOPSIS
    Resolve the common root for direct and ecosystem modules.

    .DESCRIPTION
    Returns the ecosystem's parent for modules inside QuietCliEcosystem, otherwise the module's parent.
    #>

    param([Parameter(Mandatory)][string]$ModulePath)
    $parent=Split-Path ([IO.Path]::GetFullPath($ModulePath))
    if((Split-Path $parent -Leaf) -ceq 'QuietCliEcosystem'){return Split-Path $parent}
    $parent
}
