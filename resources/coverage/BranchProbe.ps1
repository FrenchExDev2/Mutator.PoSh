#requires -Version 7.6
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars','',Justification='Recorder state and readiness must survive forced imports of the instrumented module in a Pester runspace; the explicit run ID and per-process/runspace files isolate each recording.')]
param()
function global:Write-MutatorBranch {
    <#
    .SYNOPSIS
    Record a branch outcome once per isolated run/process/runspace.

    .DESCRIPTION
    Requires explicit context, writes unique outcomes and returns expression Boolean values. Hit probes
    produce no replacement value.
    #>

    param([string]$Id,[object]$Value,[switch]$Hit)
    $outcome=if($Hit){'hit'}elseif([bool]$Value){'true'}else{'false'}
    $run=$env:MUTATOR_BRANCH_RUN
    if(!$run -or !$env:MUTATOR_BRANCH_DIRECTORY){throw 'Branch recording requires an explicit isolated coverage context.'}
    $variable=Get-Variable MutatorBranchState -Scope Global -ErrorAction Ignore
    if(!$variable -or $variable.Value.Run -cne $run){
        $global:MutatorBranchState=@{Run=$run;Seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)}
    }
    if($global:MutatorBranchState.Seen.Add($Id+'|'+$outcome)){
        [void][IO.Directory]::CreateDirectory($env:MUTATOR_BRANCH_DIRECTORY)
        $record=@{Run=$run;Id=$Id;Outcome=$outcome;Process=$PID}|ConvertTo-Json -Compress
        $file=Join-Path $env:MUTATOR_BRANCH_DIRECTORY ($PID.ToString()+'-'+[runspace]::DefaultRunspace.InstanceId.ToString('N')+'.jsonl')
        [IO.File]::AppendAllText($file,($record+"`n"),[Text.UTF8Encoding]::new($false))
    }
    if(!$Hit){[bool]$Value}
}

class MutatorBranchEnumerator : System.Collections.IEnumerator, System.IDisposable {
    [System.Collections.IEnumerator]$Inner
    [string]$Id
    [object]$Current
    MutatorBranchEnumerator([string]$Id,[System.Collections.IEnumerator]$Inner){
        <#
        .SYNOPSIS
        Wrap an iterator with its branch identity.

        .DESCRIPTION
        Stores without enumeration to preserve lazy loops and early-break behavior.
        #>
        $this.Id=$Id;$this.Inner=$Inner}
    [bool]MoveNext(){
        <#
        .SYNOPSIS
        Advance the wrapped iterator and observe availability.

        .DESCRIPTION
        Updates Current only for yielded items and returns the original continuation result.
        #>

        $more=$this.Inner.MoveNext()
        [void](Write-MutatorBranch -Id $this.Id -Value $more)
        if($more){$this.Current=$this.Inner.Current}
        return $more
    }
    [void]Reset(){
        <#
        .SYNOPSIS
        Reset using the wrapped iterator's own contract.

        .DESCRIPTION
        Delegates unsupported-reset exceptions without inventing a new enumeration.
        #>
        $this.Inner.Reset()}
    [void]Dispose(){
        <#
        .SYNOPSIS
        Dispose the wrapped iterator when supported.

        .DESCRIPTION
        Checks IDisposable first and leaves nondisposable iterators untouched.
        #>
        if($this.Inner -is [IDisposable]){$this.Inner.Dispose()}}
}

class MutatorBranchEnumerable : System.Collections.IEnumerable {
    [object]$Value
    [string]$Id
    MutatorBranchEnumerable([string]$Id,[object]$Value){
        <#
        .SYNOPSIS
        Retain a loop value and branch ID without enumerating.

        .DESCRIPTION
        Defers selection to GetEnumerator to preserve iteration order and lazy stopping.
        #>
        $this.Id=$Id;$this.Value=$Value}
    [System.Collections.IEnumerator]GetEnumerator(){
        <#
        .SYNOPSIS
        Create an observing collection, scalar or null iterator.

        .DESCRIPTION
        Reuses supplied iterators or PowerShell enumeration rules, including scalar and empty-null
        fallbacks.
        #>

        [System.Collections.IEnumerator]$iterator=$null
        if($this.Value -is [System.Collections.IEnumerator]){$iterator=$this.Value}else{$iterator=[Management.Automation.LanguagePrimitives]::GetEnumerator($this.Value)}
        if($null -eq $iterator){
            [object[]]$items=@()
            if($null -ne $this.Value){$items=@($this.Value)}
            $iterator=$items.GetEnumerator()
        }
        return [MutatorBranchEnumerator]::new($this.Id,$iterator)
    }
}
function global:Get-MutatorBranchEnumerable {
    <#
    .SYNOPSIS
    Wrap loop input without unrolling the wrapper.

    .DESCRIPTION
    Returns one enumerable object with NoEnumerate to preserve lazy instrumentation.
    #>

    param([string]$Id,[AllowNull()][object]$Value)
    Write-Output -InputObject ([MutatorBranchEnumerable]::new($Id,$Value)) -NoEnumerate
}
$global:MutatorBranchProbeReady=$true
