function Set-MutatorTestOrder {
    <#
    .SYNOPSIS
    Reorder associations without removing tests or mutants.

    .DESCRIPTION
    FocusedFirst prioritizes nearby unit tests; Configured keeps original order. Returns association
    counts and Removed zero.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Reorders only the caller-owned staged configuration object; performs no I/O or execution.')]
    [CmdletBinding()]
    param([Collections.IDictionary]$Configuration, [ValidateSet('Configured','FocusedFirst')][string]$Order = 'FocusedFirst')
    $associations = 0
    foreach ($source in @($Configuration.tests.Keys)) {
        $tests = @($Configuration.tests[$source])
        $associations += $tests.Count
        if ($Order -eq 'Configured') { continue }
        $stem = [IO.Path]::GetFileNameWithoutExtension($source)
        $related = ($stem -split '\.')[0..([math]::Min(1, ($stem -split '\.').Length - 1))] -join '.'
        $ranked = for ($i = 0; $i -lt $tests.Count; $i++) {
            $name = [IO.Path]::GetFileName($tests[$i])
            $weight = if ($name.StartsWith($stem + '.', [StringComparison]::OrdinalIgnoreCase)) { 0 }
                elseif ($name.StartsWith($related + '.', [StringComparison]::OrdinalIgnoreCase) -and $tests[$i] -match '[/\\]Unit[/\\]') { 1 }
                elseif ($tests[$i] -match '[/\\]Unit[/\\]') { 2 } else { 3 }
            [pscustomobject]@{ Path = $tests[$i]; Weight = $weight; Index = $i }
        }
        # No test is removed. Unknown/parameterized tests remain in the complete covering suite.
        $Configuration.tests[$source] = @($ranked | Sort-Object Weight, Index | ForEach-Object Path)
    }
    @{ Strategy = $Order; Associations = $associations; Removed = 0; SourceFiles = @($Configuration.mutate).Count }
}
