function Export-MutatorWindowsBase {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Container,[Parameter(Mandatory)][string]$ModuleRoot,[string]$Connection,[string]$Destination)
    if($PSCmdlet.ShouldProcess($Container,'Export the prepared Windows base')){Export-MutatorGuestBase -Container $Container -ModuleRoot $ModuleRoot -Connection $Connection -Destination $Destination -Platform Windows -Confirm:$false}
}