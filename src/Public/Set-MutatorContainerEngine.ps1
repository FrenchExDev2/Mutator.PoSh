function Set-MutatorContainerEngine {
    <#
    .SYNOPSIS
    Select the preferred engine/connection for this session.

    .DESCRIPTION
    Updates private state under ShouldProcess without changing saved configuration or CLI defaults.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateSet('Podman','Docker')][string]$Engine,[string]$Connection)
    if(!$PSCmdlet.ShouldProcess($Engine,'Select the container engine and connection for this module session')){return}
    Set-MutatorContainerContext -Engine $Engine -Connection $Connection
    $script:MutatorPreferredContainerEngine=$script:MutatorContainerEngine
    $script:MutatorPreferredContainerConnection=$Connection
    [pscustomobject]@{Engine=$script:MutatorContainerEngine;Connection=$script:MutatorContainerConnection}
}
