function ConvertTo-MutatorContainerJson {
    <#
    .SYNOPSIS
    Serialize container metadata with canonical key order and LF formatting.

    .DESCRIPTION
    Recursively sorts mapping keys while preserving array order and data values. Returns JSON text for
    reproducible cross-platform fingerprints.
    #>

    param([object]$Data)
    $normalize={
        param($Value)
        if($Value -is [Collections.IDictionary]){
            $ordered=[ordered]@{}
            foreach($key in @($Value.Keys|Sort-Object -CaseSensitive)){$ordered[$key]=& $normalize $Value[$key]}
            return ,$ordered
        }
        if($Value -is [array]){
            $items=[Collections.Generic.List[object]]::new()
            foreach($item in $Value){$items.Add((& $normalize $item))}
            return ,($items.ToArray())
        }
        return $Value
    }
    $normalized=& $normalize $Data
    (ConvertTo-Json -InputObject $normalized -Depth 30).Replace("`r`n", "`n")
}
