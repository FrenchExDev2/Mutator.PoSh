function Invoke-MacOSBootstrapCommand {
    <#
    .SYNOPSIS
    Run bootstrap and return the actual native exit.

    .DESCRIPTION
    Clears stale exit state and logs or drains output without leaking successful stdout into structured
    results.
    #>

    param([Parameter(Mandatory)][string]$FilePath,[string[]]$Arguments=@(),[string]$LogPath)
    $global:LASTEXITCODE=0
    if($LogPath){& $FilePath @Arguments *> $LogPath}
    else{& $FilePath @Arguments | Out-Null}
    [int]$global:LASTEXITCODE
}
