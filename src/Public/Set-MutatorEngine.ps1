function Set-MutatorEngine {
    <#
    .SYNOPSIS
    Update endpoints, enablement and the unique default.

    .DESCRIPTION
    Preserves unspecified settings and clears empty endpoints. Writes dedicated YAML atomically; WhatIf
    writes nothing.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([AllowNull()][string]$Docker,[bool]$DockerEnabled,[AllowNull()][string]$Podman,[bool]$PodmanEnabled,
        [ValidateSet('Docker','Podman')][string]$DefaultEngine,[string]$Path=(Get-MutatorEngineConfigurationPath))
    $target=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $document=[ordered]@{}
    if(Test-Path -LiteralPath $target){
        $existing=Read-MutatorEngineConfiguration $target
        if($existing -isnot [Collections.IDictionary]){throw 'Configuration must be a mapping of sections.'}
        foreach($key in $existing.get_Keys()){$document[$key]=$existing[$key]}
    }
    foreach($name in @('Docker','Podman')){
        $key=$name.ToLowerInvariant();$current=ConvertTo-MutatorEngineSetting $key $document[$key]
        $pipe=if($PSBoundParameters.ContainsKey($name)){$PSBoundParameters[$name]}else{$current.Pipe}
        if($PSBoundParameters.ContainsKey($name) -and [string]::IsNullOrEmpty($pipe)){$pipe=$null}
        $enabled=if($PSBoundParameters.ContainsKey($name+'Enabled')){$PSBoundParameters[$name+'Enabled']}else{$current.Enabled}
        $default=if($DefaultEngine){$name -eq $DefaultEngine}else{$current.Default}
        $validated=ConvertTo-MutatorEngineSetting $key @{pipe=$pipe;enabled=$enabled;default=$default}
        $document[$key]=[ordered]@{pipe=$validated.Pipe;enabled=$validated.Enabled;default=$validated.Default}
    }
    Assert-MutatorEngineDefault @(foreach($name in @('docker','podman')){ConvertTo-MutatorEngineSetting $name $document[$name]})
    if(!$PSCmdlet.ShouldProcess($target,'Save independent Docker and Podman endpoints and enabled states')){return}
    Write-MutatorEngineConfiguration -Path $target -Document $document
    Get-MutatorEngine -Path $target
}
