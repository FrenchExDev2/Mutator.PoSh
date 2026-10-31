function Initialize-MutatorGitImageReports {
    <#
    .SYNOPSIS
    Create the shared Git report layout before guest execution.

    .DESCRIPTION
    Prepares unit, integration and coverage paths, plus mutation paths unless baseline-only. Avoids
    guest SMB directory-creation failures.
    #>

    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,[switch]$BaselineOnly)
    # The host owns the shared report layout. Guest SMB creates can materialize
    # a directory and still return NOT_FOUND through the Windows/WSL bridge.
    $module='FrenchExDev.QuietCli.Git.PoSh'
    $directories=@("unit/$module","integration/$module","coverage/$module")
    if(!$BaselineOnly){$directories+=@('mutations/'+$module+'/runs/packages/p0000')}
    foreach($directory in $directories){[void][IO.Directory]::CreateDirectory((Join-Path $Path $directory))}
}
