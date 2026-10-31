function Get-MutatorPowerShellExecutable {
    <#
    .SYNOPSIS
    Resolve the PowerShell Core application for workers.

    .DESCRIPTION
    Returns the discovered application path and fails when pwsh is unavailable. Does not start a
    process.
    #>

    $command=Get-Command pwsh -CommandType Application -ErrorAction Stop|Select-Object -First 1
    $command.Source
}
