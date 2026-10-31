#requires -Version 7.6
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars','',Justification='Recorder state and readiness must survive forced imports of the instrumented module in a Pester runspace; the explicit run ID and per-process/runspace files isolate each recording.')]
param()
function global:Write-MutatorBranch {
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
    MutatorBranchEnumerator([string]$Id,[System.Collections.IEnumerator]$Inner){$this.Id=$Id;$this.Inner=$Inner}
    [bool]MoveNext(){
        $more=$this.Inner.MoveNext()
        [void](Write-MutatorBranch -Id $this.Id -Value $more)
        if($more){$this.Current=$this.Inner.Current}
        return $more
    }
    [void]Reset(){$this.Inner.Reset()}
    [void]Dispose(){if($this.Inner -is [IDisposable]){$this.Inner.Dispose()}}
}

class MutatorBranchEnumerable : System.Collections.IEnumerable {
    [object]$Value
    [string]$Id
    MutatorBranchEnumerable([string]$Id,[object]$Value){$this.Id=$Id;$this.Value=$Value}
    [System.Collections.IEnumerator]GetEnumerator(){
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
    param([string]$Id,[AllowNull()][object]$Value)
    Write-Output -InputObject ([MutatorBranchEnumerable]::new($Id,$Value)) -NoEnumerate
}
$global:MutatorBranchProbeReady=$true
