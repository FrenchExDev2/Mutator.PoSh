function Export-MutatorWindowsBase {
    <#
    .SYNOPSIS
    Export Windows through the shared guest exporter.

    .DESCRIPTION
    Honors ShouldProcess and delegates readiness, shutdown and disk checks with Windows selected.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Container,[Parameter(Mandatory)][string]$ModuleRoot,[string]$Connection,[string]$Destination)
    if($PSCmdlet.ShouldProcess($Container,'Export the prepared Windows base')){Export-MutatorGuestBase -Container $Container -ModuleRoot $ModuleRoot -Connection $Connection -Destination $Destination -Platform Windows -Confirm:$false}
}