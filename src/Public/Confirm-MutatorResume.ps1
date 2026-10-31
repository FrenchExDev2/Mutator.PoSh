function Confirm-MutatorResume {
    param([string]$Path, [object]$Context)
    if (!(Test-Path -LiteralPath $Path -PathType Leaf) -or !(Test-Path -LiteralPath ($Path + '.context.json') -PathType Leaf)) { throw 'Resume requires the retained partial report and its context receipt.' }
    $report = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $previous = Get-Content -LiteralPath ($Path + '.context.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($report.mode -cne 'Partial' -or $report.Contains('mutationScore')) { throw 'Only an explicitly partial mutation report can seed a resume.' }
    if ($previous.Sha256 -cne $Context.Sha256) { throw 'Resume refused: sources, tests, dependencies, configuration, runtime or tools differ.' }
    if ($previous.ReportSha256 -cne (Get-FileHash -LiteralPath $Path).Hash) { throw 'Resume refused: partial report changed.' }
}
