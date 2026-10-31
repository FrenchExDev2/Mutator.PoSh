function Get-MutatorEquivalence {
    <#
    .SYNOPSIS
    Validate legacy equivalence declarations against current mutation candidates.

    .DESCRIPTION
    Requires exact source hashes, in-scope tests and one matching pinned-tool candidate. Returns
    diagnostics; strict callers still reject exclusions.
    #>

    param([string]$Root,[string[]]$Paths)
    $map=[ordered]@{}
    $declaration=Join-Path $Root 'test/mutation-equivalents.json'
    if(!(Test-Path -LiteralPath $declaration)){return $map}
    $data=Read-MutatorJson $declaration
    if($data.SchemaVersion -ne 1 -or !@($data.Entries).Count){throw 'Equivalence declarations must have a versioned, nonempty entry list.'}
    $installed=Get-Module -ListAvailable PSMutant|Where-Object Version -EQ '0.6.0'|Select-Object -First 1
    if(!$installed){throw 'Pinned PSMutant 0.6.0 is required to validate equivalences.'}
    $reader=New-Module -Name MutatorCandidateReader -ScriptBlock {param($Operators) . $Operators} -ArgumentList (Join-Path $installed.ModuleBase 'src/PSMutation.Operators.ps1')
    foreach($entry in $data.Entries){
        if($entry.File -cnotin $Paths -or [string]::IsNullOrWhiteSpace($entry.Reason) -or !@($entry.Evidence).Count){throw 'Equivalence requires an in-scope source, a reason and test evidence.'}
        $file=Join-Path (Split-Path $Root) $entry.File
        if((Get-FileHash -LiteralPath $file).Hash -cne $entry.Sha256){throw 'Equivalence source fingerprint is stale.'}
        foreach($evidence in $entry.Evidence){
            $testPath=Join-Path $Root $evidence
            $relative=[IO.Path]::GetRelativePath($Root,[IO.Path]::GetFullPath($testPath)).Replace('\','/')
            if(!$relative.StartsWith('test/',[StringComparison]::Ordinal) -or !($relative.EndsWith('.Tests.ps1',[StringComparison]::Ordinal)) -or !(Test-Path -LiteralPath $testPath -PathType Leaf)){throw 'Equivalence test evidence must identify an existing test inside the module.'}
        }
        $candidates=@(& $reader {param($File) $WhatIfPreference=$false;Get-PSMutationCandidate $File} $file)
        $matched=@($candidates|Where-Object {$_.StartOffset -eq $entry.StartOffset -and $_.EndOffset -eq $entry.EndOffset -and
            $_.Function -ceq $entry.Function -and $_.Operator -ceq $entry.Operator -and $_.Original -ceq $entry.Original -and $_.Mutated -ceq $entry.Mutated -and $_.Line -eq $entry.Line})
        if($matched.Count -ne 1){throw 'Equivalence does not identify one exact current mutation candidate.'}
        $key=$entry.File+':'+$entry.Line+':'+$matched[0].Description
        if($map.Contains($key)){throw 'Duplicate equivalence declaration.'}
        $map[$key]=$entry.Reason
    }
    $map
}

function Confirm-MutatorEquivalence {
    <#
    .SYNOPSIS
    Reject equivalence exclusions from a strict mutation campaign.

    .DESCRIPTION
    Checks declarations and configured exclusions. Any nonempty set throws rather than improving the raw
    score.
    #>

    param([string]$ModulePath,[Collections.IDictionary]$Configuration)
    $current=Get-MutatorEquivalence -Root $ModulePath -Paths $Configuration.mutate
    $configured=if($Configuration.Contains('equivalents')){$Configuration.equivalents}else{[ordered]@{}}
    if($current.Count -or $configured.Count){throw 'Strict 100% mutation requires zero excluded equivalences.'}
}
