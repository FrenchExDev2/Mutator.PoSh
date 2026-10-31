function Initialize-MutatorGitImageReports {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,[switch]$BaselineOnly)
    # The host owns the shared report layout. Guest SMB creates can materialize
    # a directory and still return NOT_FOUND through the Windows/WSL bridge.
    $module='FrenchExDev.QuietCli.Git.PoSh'
    $directories=@("unit/$module","integration/$module","coverage/$module")
    if(!$BaselineOnly){$directories+=@('mutations/'+$module+'/runs/packages/p0000')}
    foreach($directory in $directories){[void][IO.Directory]::CreateDirectory((Join-Path $Path $directory))}
}
