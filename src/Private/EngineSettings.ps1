function Get-MutatorEngineSetting {
    param([ValidateSet('Docker','Podman')][string]$Engine,[switch]$Default)
    $selection=if($Default){@{Default=$true}}else{@{Name=$Engine}}
    $setting=Get-MutatorEngine @selection
    @{Name=$setting.Name;Pipe=$setting.Pipe;Enabled=$setting.Enabled;Default=$setting.Default;ConfigurationPath=$setting.ConfigurationPath}
}

function Resolve-MutatorEngineSelection {
    param([string]$Engine,[switch]$UseContext)
    if($Engine){return $(if($Engine -eq 'Docker'){'Docker'}else{'Podman'})}
    if($UseContext -and $script:MutatorContainerContextSelected){return $script:MutatorContainerEngine}
    if($script:MutatorPreferredContainerEngine){return $script:MutatorPreferredContainerEngine}
    (Get-MutatorEngineSetting -Default).Name
}

function ConvertTo-MutatorDockerHost {
    param([string]$Endpoint)
    if($Endpoint -match '^(?:npipe:)?[/\\]{2,4}\.[/\\]pipe[/\\](?<name>.+)$'){
        return 'npipe:////./pipe/'+$Matches.name.Replace('\','/')
    }
    $Endpoint
}

function Resolve-MutatorPodmanEndpoint {
    param([string]$Endpoint,[string]$Directory)
    if(!$Endpoint.StartsWith('\\.\pipe\',[StringComparison]::OrdinalIgnoreCase) -and !$Endpoint.StartsWith('npipe:',[StringComparison]::OrdinalIgnoreCase)){
        if($Endpoint -notmatch '^(ssh|tcp|unix)://'){throw 'Podman requires a machine pipe, SSH, TCP or Unix endpoint.'}
        return @{Arguments=@('--url',$Endpoint);Endpoint=$Endpoint}
    }
    $canonical=ConvertTo-MutatorDockerHost $Endpoint
    if($script:MutatorPipeConnectionCache.ContainsKey($canonical)){return $script:MutatorPipeConnectionCache[$canonical]}
    $listed=Invoke-MutatorNative podman @('machine','list','--format','json') $Directory 30
    if($listed.Outcome -ne 'Success'){throw 'The Podman machines providing the configured pipe could not be listed.'}
    $names=@($listed.Stdout|ConvertFrom-Json -AsHashtable|ForEach-Object {$_['Name']})
    if(!$names.Count){throw 'No Podman machine provides the configured pipe.'}
    $inspection=Invoke-MutatorNative podman (@('machine','inspect')+$names) $Directory 30
    if($inspection.Outcome -ne 'Success'){throw 'The Podman machine providing the configured pipe could not be inspected.'}
    $machines=@($inspection.Stdout|ConvertFrom-Json -AsHashtable)
    $matching=@($machines|Where-Object {$_.Contains('ConnectionInfo') -and $_.ConnectionInfo['PodmanPipe'] -and (ConvertTo-MutatorDockerHost $_.ConnectionInfo.PodmanPipe.Path).Equals($canonical,[StringComparison]::OrdinalIgnoreCase)})
    if($matching.Count -ne 1){throw 'The configured Podman pipe must identify exactly one managed machine.'}
    $machine=$matching[0]
    $list=Invoke-MutatorNative podman @('system','connection','list','--format','json') $Directory 30
    if($list.Outcome -ne 'Success'){throw 'Podman connections for the configured machine pipe could not be read.'}
    $connections=@($list.Stdout|ConvertFrom-Json -AsHashtable)
    $selectedName=$machine.Name+$(if($machine.Rootful){'-root'}else{''})
    $selected=@($connections|Where-Object {$_['Name'] -ceq $selectedName})
    if($selected.Count -ne 1 -or !$selected[0]['URI'] -or !$selected[0]['Identity']){throw 'The Podman pipe has no unambiguous native connection and SSH identity.'}
    $result=@{Arguments=@('--url',$selected[0].URI,'--identity',$selected[0].Identity);Endpoint=$canonical;Connection=$selectedName}
    $script:MutatorPipeConnectionCache[$canonical]=$result
    $result
}

function Get-MutatorContainerPrefix {
    param([ValidateSet('Docker','Podman')][string]$Engine,[string]$Connection,[string]$Directory,[switch]$DefaultConnection)
    $setting=if($script:MutatorContainerSetting -and $script:MutatorContainerSetting.Name -eq $Engine){$script:MutatorContainerSetting}else{Get-MutatorEngineSetting $Engine}
    if(!$setting.Enabled){throw "The $Engine engine is disabled in $($setting.ConfigurationPath)."}
    if($DefaultConnection){return @()}
    if($Connection){return @($(if($Engine -eq 'Docker'){'--context'}else{'--connection'}),$Connection)}
    if($setting.Pipe){
        if($Engine -eq 'Docker'){return @('--host',(ConvertTo-MutatorDockerHost $setting.Pipe))}
        return (Resolve-MutatorPodmanEndpoint $setting.Pipe $Directory).Arguments
    }
    @()
}
