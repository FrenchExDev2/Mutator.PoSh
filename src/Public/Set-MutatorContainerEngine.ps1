function Set-MutatorContainerEngine {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateSet('Podman','Docker')][string]$Engine,[string]$Connection)
    if(!$PSCmdlet.ShouldProcess($Engine,'Select the container engine and connection for this module session')){return}
    Set-MutatorContainerContext -Engine $Engine -Connection $Connection
    $script:MutatorPreferredContainerEngine=$script:MutatorContainerEngine
    $script:MutatorPreferredContainerConnection=$Connection
    [pscustomobject]@{Engine=$script:MutatorContainerEngine;Connection=$script:MutatorContainerConnection}
}
