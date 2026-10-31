function Add-MutatorHostPowerShell {
    <#
    .SYNOPSIS
    Add the pinned controller runtime to a VM-host Dockerfile.

    .DESCRIPTION
    Returns rewritten text with a PowerShell stage and controller fingerprint. Requires an explicit
    base-image argument; does not build an image.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Pure Dockerfile text factory; does not allocate resources or change the environment.')]
    [CmdletBinding()]
    param([string]$Dockerfile,[Collections.IDictionary]$Definition)
    $match=[regex]::Match($Dockerfile,'(?m)^ARG BASE_IMAGE=(.+)\r?$')
    if(!$match.Success){throw 'A VM host base image argument is required.'}
    $base=$match.Groups[1].Value.Trim()
    $body=[regex]::Replace($Dockerfile,'(?m)^ARG BASE_IMAGE=.+\r?\n','')
    $body=[regex]::Replace($body,'(?m)^FROM \$\{BASE_IMAGE\}\r?\n','')
    $prefix='ARG POWERSHELL_IMAGE='+$Definition.Images.Debian+"`n"+'ARG BASE_IMAGE='+$base+"`n"+'FROM ${POWERSHELL_IMAGE} AS mutator-pwsh'+"`n"+'FROM ${BASE_IMAGE}'+"`n"
    $block=[IO.File]::ReadAllText((Join-Path $script:MutatorRoot 'resources/containers/definitions/Dockerfile.host-powershell.template')).Replace('__PWSH_VERSION__',$Definition.Runtime.Version).Replace('__CONTROLLER_FINGERPRINT__',$Definition.ControllerFingerprint)
    $prefix+$body+"`n"+$block
}
