function Test-MutatorPowerShellGate {
    <#
    .SYNOPSIS
    Accept consistent, nonempty, complete raw mutation evidence.

    .DESCRIPTION
    Requires exact counters, zero survivors/exclusions/skips, valid associations and tool success.
    Partial reports and rounded scores cannot satisfy it.
    #>

    param([AllowNull()][Collections.IDictionary]$Detail,[AllowNull()][object]$Result)
    if(!$Detail -or !$Result){return $false}
    foreach($field in @('total','killed','survived','mutationScore','declaredEquivalent','skippedAsUncovered','staleEquivalents','filesWithoutTestMapping')){
        if(!$Detail.Contains($field)){return $false}
    }
    if($Detail.Contains('mode') -and $Detail.mode -cne 'Full'){return $false}
    # Stryker/PSMutant scores can be rounded. A displayed 100 must never hide a survivor.
    $Result.Total -gt 0 -and $Result.ExitCode -eq 0 -and $Result.Score -eq 100 -and
        $Detail.mutationScore -eq 100 -and $Detail.survived -eq 0 -and $Detail.declaredEquivalent -eq 0 -and $Detail.killed -eq $Detail.total -and
        $Result.Total -eq $Detail.total -and $Result.Killed -eq $Detail.killed -and
        $Detail.skippedAsUncovered -eq 0 -and !@($Detail.staleEquivalents).Count -and !@($Detail.filesWithoutTestMapping).Count
}
