function Get-MutatorSubtree {
    <#
    .SYNOPSIS
    Validate sources/tests against declared sandbox subtrees.

    .DESCRIPTION
    Requires relative contained existing trees. Rejects escaping paths and associations outside the
    allowed scope.
    #>

    param([string]$SourceRoot, [Collections.IDictionary]$Configuration)
    $root = [IO.Path]::GetFullPath($SourceRoot)
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($Configuration.sandboxSubtrees)) {
        if ([string]::IsNullOrWhiteSpace($entry) -or [IO.Path]::IsPathRooted($entry)) { throw 'Mutation sandbox subtree must be relative.' }
        $full = [IO.Path]::GetFullPath((Join-Path $root $entry))
        $relative = [IO.Path]::GetRelativePath($root, $full).Replace('\', '/')
        if ($relative -eq '.' -or $relative -eq '..' -or $relative.StartsWith('../') -or !(Test-Path -LiteralPath $full -PathType Container)) {
            throw "Invalid mutation sandbox subtree: $entry"
        }
        if ((Get-Item -LiteralPath $full).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Mutation subtrees cannot be links.' }
        [void]$paths.Add($relative)
    }
    if (!$paths.Count) { throw 'Mutation sandboxSubtrees must explicitly name its dependencies.' }
    $entries=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($entry in @($Configuration.mutate)+@($Configuration.tests.Values|ForEach-Object {$_})){
        if($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)){throw 'Mutation source/test entries must be nonempty relative paths.'}
        [void]$entries.Add($entry)
    }
    foreach ($entry in $entries) {
        $full = [IO.Path]::GetFullPath((Join-Path $root $entry))
        $relative = [IO.Path]::GetRelativePath($root, $full).Replace('\', '/')
        $covered=$false
        foreach($prefix in $paths){if($relative.StartsWith($prefix+'/',[StringComparison]::Ordinal)){$covered=$true;break}}
        if (!$covered) {
            throw "Mutation source/test is outside sandboxSubtrees: $entry"
        }
    }
    @($paths | Sort-Object -CaseSensitive)
}
