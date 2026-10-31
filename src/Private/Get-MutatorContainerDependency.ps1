function Get-MutatorContainerDependency {
    param([Parameter(Mandatory)][string]$ModulePath)
    $root=(Resolve-Path -LiteralPath $ModulePath -ErrorAction Stop).ProviderPath
    $parent=Get-MutatorModuleRoot $root
    $common=@('FrenchExDev.QuietCli.PoSh')
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($name in $common){[void]$names.Add($name)}
    $visited=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pending=[Collections.Generic.Queue[string]]::new()
    $pending.Enqueue((Split-Path $root -Leaf))
    while($pending.Count){
        $name=$pending.Dequeue()
        if(!$visited.Add($name)){continue}
        $module=Resolve-MutatorModuleDirectory $parent $name
        $manifest=Import-PowerShellDataFile -LiteralPath (Join-Path $module ($name+'.psd1')) -ErrorAction Stop
        [void]$names.Add($name)
        $dependencies=@()
        if($manifest.ContainsKey('PrivateData') -and $manifest.PrivateData.ContainsKey('Mutator')){
            $metadata=$manifest.PrivateData.Mutator
            if($metadata.ContainsKey('Dependencies')){$dependencies+=@($metadata.Dependencies)}
        }
        foreach($required in @($manifest['RequiredModules'])){
            $requiredName=if($required -is [string]){$required}elseif($required -is [Collections.IDictionary]){$required['ModuleName']}else{$null}
            if($requiredName -and $requiredName -cmatch '^FrenchExDev\.[A-Za-z0-9_.-]+\.PoSh$' -and $requiredName -cnotin $common){$dependencies+=@($requiredName)}
        }
        foreach($dependency in $dependencies){
            if($dependency -isnot [string] -or $dependency -cnotmatch '^FrenchExDev\.[A-Za-z0-9_.-]+\.PoSh$'){
                throw 'Container dependencies must name FrenchExDev modules.'
            }
            $pending.Enqueue($dependency)
        }
    }
    @($names|Sort-Object -CaseSensitive)
}
