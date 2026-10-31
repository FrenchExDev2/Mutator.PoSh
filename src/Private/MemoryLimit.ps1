function ConvertTo-MutatorMemoryLimit {
    <#
    .SYNOPSIS
    Parse a host RAM threshold into bytes.

    .DESCRIPTION
    Accepts decimal GB/Go and binary GiB/Gio, including decimal commas. Rejects malformed, infinite and
    out-of-range thresholds.
    #>

    param([Parameter(Mandatory)][string]$Value)
    if($Value.Trim() -notmatch '^(?<number>\d+(?:[.,]\d+)?)\s*(?<unit>go|gb|gio|gib)?$'){throw 'Ram expects a host limit such as 40go, 40GB or 40GiB.'}
    $number=[double]::Parse($Matches.number.Replace(',','.'),[Globalization.CultureInfo]::InvariantCulture)
    $factor=if($Matches.unit -iin @('gio','gib')){1GB}else{1e9}
    $bytes=$number*$factor
    if([double]::IsInfinity($bytes) -or $bytes -lt 4e9 -or $bytes -gt 1048576e9){throw 'Ram must be between 4 Go and 1048576 Go.'}
    [long]$bytes
}
