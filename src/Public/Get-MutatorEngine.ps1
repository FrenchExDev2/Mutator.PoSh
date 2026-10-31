function Get-MutatorEngine {
    [CmdletBinding()]
    param([ValidateSet('Docker','Podman')][string[]]$Name=@('Docker','Podman'),[string]$Path=(Get-MutatorEngineConfigurationPath),[switch]$Default)
    $document=if(Test-Path -LiteralPath $Path){Read-MutatorEngineConfiguration $Path}else{@{}}
    if($document -isnot [Collections.IDictionary]){throw 'Configuration must be a mapping of sections.'}
    $settings=@(foreach($engine in @('Docker','Podman')){
        $key=$engine.ToLowerInvariant()
        $setting=ConvertTo-MutatorEngineSetting $key $document[$key]
        [pscustomobject]@{Name=$engine;Pipe=$setting.Pipe;Enabled=$setting.Enabled;Default=$setting.Default;ConfigurationPath=$Path}
    })
    Assert-MutatorEngineDefault $settings
    if($Default){
        $selected=@($settings|Where-Object Default)
        if(!$selected.Count){$selected=@($settings|Where-Object Enabled|Sort-Object @{Expression={$_.Name -eq 'Podman'};Descending=$true}|Select-Object -First 1)}
        if(!$selected.Count){throw 'No container engine is enabled.'}
        return $selected[0]
    }
    $settings|Where-Object {$_.Name -in $Name}
}

