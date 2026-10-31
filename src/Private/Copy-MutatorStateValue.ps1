function Copy-MutatorStateValue {
    param([AllowNull()][object]$Value, [int]$Depth = 0)
    if ($Depth -gt 24) { throw 'State graph is cyclic or too deep for import reuse.' }
    if ($null -eq $Value -or $Value -is [string] -or $Value.GetType().IsValueType -or
        $Value -is [version] -or $Value -is [uri] -or $Value -is [regex] -or $Value -is [StringComparer] -or $Value -is [Delegate]) { return @{ Value = $Value } }
    if ($Value -is [scriptblock]) {
        if ($Value.Module -and $Value.Module.Name -like '__DynamicModule*') { throw 'A closure requires a fresh module.' }
        return @{ Value = $Value }
    }
    if ($Value -is [Collections.IDictionary] -and $Value.GetType() -in @([hashtable], [Collections.Specialized.OrderedDictionary], [Collections.Generic.Dictionary[string,object]])) {
        if ($Value -is [Collections.Generic.Dictionary[string,object]]) { $copy = [Collections.Generic.Dictionary[string,object]]::new($Value.Comparer) }
        elseif ($Value -is [Collections.Specialized.OrderedDictionary]) {
            $field=$Value.GetType().GetField('_comparer',[Reflection.BindingFlags]'Instance,NonPublic')
            if(!$field -or $Value.IsReadOnly){throw 'Unknown ordered dictionary state requires a fresh module.'}
            $copy=[Collections.Specialized.OrderedDictionary]::new([Collections.IEqualityComparer]$field.GetValue($Value))
        } else { $copy = $Value.Clone() }
        $copy.Clear()
        foreach ($key in $Value.Keys) {
            if ($key -isnot [string]) { throw 'Non-string state keys require a fresh module.' }
            $copy[$key] = (Copy-MutatorStateValue $Value[$key] ($Depth + 1)).Value
        }
        return @{ Value = $copy }
    }
    if ($Value -is [Collections.Generic.HashSet[string]]) { return @{ Value = [Collections.Generic.HashSet[string]]::new($Value, $Value.Comparer) } }
    if ($Value -is [array]) {
        if ($Value.Rank -ne 1) { throw 'Multidimensional state requires a fresh module.' }
        $copy = $Value.Clone()
        for ($i = 0; $i -lt $Value.Length; $i++) { $copy[$i] = (Copy-MutatorStateValue $Value[$i] ($Depth + 1)).Value }
        return @{ Value = $copy }
    }
    if ($Value.GetType() -in @([Collections.ArrayList], [Collections.Generic.List[object]])) {
        $copy = [Activator]::CreateInstance($Value.GetType())
        foreach ($item in $Value) { [void]$copy.Add((Copy-MutatorStateValue $item ($Depth + 1)).Value) }
        return @{ Value = $copy }
    }
    if ($Value -is [pscustomobject]) {
        $copy = [pscustomobject]@{}
        foreach ($property in $Value.PSObject.Properties) {
            if ($property -isnot [Management.Automation.PSNoteProperty]) { throw 'Computed state requires a fresh module.' }
            $copy | Add-Member -NotePropertyName $property.Name -NotePropertyValue (Copy-MutatorStateValue $property.Value ($Depth + 1)).Value
        }
        return @{ Value = $copy }
    }
    throw "Unsupported state type requires a fresh module: $($Value.GetType().FullName)"
}
