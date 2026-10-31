function Invoke-MacOSBootstrapCommand {
    param([Parameter(Mandatory)][string]$FilePath,[string[]]$Arguments=@(),[string]$LogPath)
    $global:LASTEXITCODE=0
    if($LogPath){& $FilePath @Arguments *> $LogPath}
    else{& $FilePath @Arguments | Out-Null}
    [int]$global:LASTEXITCODE
}
