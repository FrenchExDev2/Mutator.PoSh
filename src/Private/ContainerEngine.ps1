function Set-MutatorContainerContext {
    <#
    .SYNOPSIS
    Select the engine, connection and settings for private container operations.

    .DESCRIPTION
    Updates module session state and clears cached pipe resolution without changing persistent CLI
    defaults.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private session state is selected inside the public engine, run or build ShouldProcess boundary.')]
    [CmdletBinding()]
    param([ValidateSet('Podman','Docker')][string]$Engine,[string]$Connection,[Collections.IDictionary]$Setting)
    $script:MutatorContainerEngine=if($Engine -eq 'Docker'){'Docker'}else{'Podman'}
    $script:MutatorContainerConnection=$Connection
    $script:MutatorContainerContextSelected=$true
    $script:MutatorContainerSetting=if($null -ne $Setting){@{}+$Setting}else{$null}
    $script:MutatorPipeConnectionCache=@{}
}

function Restore-MutatorContainerContext {
    <#
    .SYNOPSIS
    Restore the container context retained in a run receipt.

    .DESCRIPTION
    Accepts the legacy Connection field when ContainerConnection is absent and delegates session-state
    selection to Set-MutatorContainerContext.
    #>

    param([Collections.IDictionary]$Run)
    $engine=if($Run['ContainerEngine']){$Run.ContainerEngine}else{'Podman'}
    $connection=if($Run.Contains('ContainerConnection')){$Run.ContainerConnection}else{$Run['Connection']}
    Set-MutatorContainerContext -Engine $engine -Connection $connection -Setting $Run['ContainerSetting']
}

function ConvertFrom-MutatorDockerInfo {
    <#
    .SYNOPSIS
    Normalize Docker host capabilities to the container adapter schema.

    .DESCRIPTION
    Only reported memory and CPU controls become available controllers. Preserves rootless status, host
    resources and runtime identity.
    #>

    param([Collections.IDictionary]$Info)
    $controllers=@()
    if($Info['MemoryLimit'] -eq $true){$controllers+=@('memory')}
    if($Info['CpuCfsQuota'] -eq $true){$controllers+=@('cpu')}
    @{host=@{cgroupControllers=$controllers;security=@{rootless=(@($Info['SecurityOptions']|Where-Object {$_ -like '*rootless*'}).Count -gt 0)}
        cpus=$Info['NCPU'];memTotal=$Info['MemTotal']};runtime=@{Engine='Docker';ServerVersion=$Info['ServerVersion'];OSType=$Info['OSType']}}
}
