function Invoke-MutatorStryker {
    <#
    .SYNOPSIS
    Run the configured host adapter with an artifact destination.

    .DESCRIPTION
    Delegates project checks, captured execution and strict nonempty mutation gating using the requested
    workers.
    #>

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModulePath,[Parameter(Mandatory)][string]$Artifacts,[ValidateRange(1,64)][int]$Workers=2,[ValidateSet('Auto','Host')][string]$Runtime='Auto')
    Invoke-MutatorStrykerCore $ModulePath $Artifacts $Workers $Runtime
}
