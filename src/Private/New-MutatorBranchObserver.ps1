function New-MutatorBranchObserver {
    <#
    .SYNOPSIS
    Create an independently namespaced branch recorder copy.

    .DESCRIPTION
    Rewrites exact identifiers and environment names without corrupting an enclosing observer. Returns
    code and identity without writing files.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Pure observer source factory; returns code and fingerprints without writing files or changing the environment.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')][string]$Namespace)
    $text=[IO.File]::ReadAllText($Path)
    # Exact identifiers preserve an enclosing observer when the probe under test
    # has already been instrumented. A prefix replacement would corrupt its calls.
    $text=[regex]::Replace($text,'\bMutatorBranch(Enumerator|Enumerable|State|ProbeReady)\b',{
        param($match) 'MutatorBranch'+$Namespace+$match.Groups[1].Value
    })
    $text=[regex]::Replace($text,'\bWrite-MutatorBranch\b',('Write-MutatorBranch'+$Namespace))
    $text=[regex]::Replace($text,'\bGet-MutatorBranchEnumerable\b',('Get-MutatorBranch'+$Namespace+'Enumerable'))
    $text=[regex]::Replace($text,'\bMUTATOR_BRANCH_(RUN|DIRECTORY)\b',{
        param($match) 'MUTATOR_BRANCH_'+$match.Groups[1].Value+$Namespace
    })
    @{Code=$text;SourceSha256=(Get-FileHash -LiteralPath $Path).Hash;Namespace=$Namespace}
}
