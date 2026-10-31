function Move-MutatorEngineConfiguration {
    <#
    .SYNOPSIS
    Migrate legacy engine sections into dedicated YAML.

    .DESCRIPTION
    Preserves unrelated source settings and a backup. Validates paths/data before writing under
    ShouldProcess.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$From,[string]$Path=(Get-MutatorEngineConfigurationPath))
    $source=(Resolve-Path -LiteralPath $From -ErrorAction Stop).ProviderPath
    $target=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if($source.Equals($target,$comparison)){throw 'Source and destination configuration paths must differ.'}
    $original=Read-MutatorYamlDocument $source
    if($original -isnot [Collections.IDictionary]){throw 'The source configuration must be a mapping.'}
    $engines=@('docker','podman'|Where-Object {$original.Contains($_)})
    if(!$engines.Count){return [pscustomobject]@{Outcome='Unchanged';ConfigurationPath=$target;SourcePath=$source;Engines=@();SourceBackup=$null}}
    $destination=Read-MutatorEngineConfiguration $target
    foreach($engine in $engines){
        $incoming=ConvertTo-MutatorEngineSetting $engine $original[$engine]
        if($destination.Contains($engine)){
            $existing=ConvertTo-MutatorEngineSetting $engine $destination[$engine]
            if($incoming.Pipe -cne $existing.Pipe -or $incoming.Enabled -ne $existing.Enabled -or $incoming.Default -ne $existing.Default){throw "The destination already has different $engine settings; neither file was changed."}
        }
        $destination[$engine]=$original[$engine]
    }
    Assert-MutatorEngineDefault @(foreach($engine in @('docker','podman')){ConvertTo-MutatorEngineSetting $engine $destination[$engine]})
    if(!$PSCmdlet.ShouldProcess($target,'Move container settings to Mutator and remove only those sections from the source configuration')){return}
    $suffix='.mutator-backup-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $backup=$source+$suffix
    Copy-Item -LiteralPath $source -Destination $backup -ErrorAction Stop
    if(Test-Path -LiteralPath $target){Copy-Item -LiteralPath $target -Destination ($target+$suffix) -ErrorAction Stop}
    Write-MutatorEngineConfiguration -Path $target -Document $destination
    foreach($engine in $engines){[void]$original.Remove($engine)}
    Write-MutatorEngineConfiguration -Path $source -Document $original
    [pscustomobject]@{Outcome='Moved';ConfigurationPath=$target;SourcePath=$source;Engines=$engines;SourceBackup=$backup}
}
