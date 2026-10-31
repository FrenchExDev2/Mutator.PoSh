function Get-MutatorOwnedMemoryRun {
    <#
    .SYNOPSIS
    Verify a recovery candidate belongs to a registered run.

    .DESCRIPTION
    Requires a known script, absolute run path and live PID/creation-time receipt. Ordinary shells and
    command-string lookalikes are excluded.
    #>

    param([Collections.IDictionary]$Target,[string]$CommandLine)
    if(!$CommandLine){$CommandLine=$Target['CommandLine']}
    if(!$CommandLine -or $CommandLine -match '(?i)(?:^|\s)"?-(?:command|encodedcommand|c|ec|e)"?(?:\s|$)'){return}
    if($CommandLine -notmatch '(?i)(?:^|\s)(?:"-File"|-File)\s+(?:"(?<file>[^"]+)"|(?<file>\S+))'){return}
    $file=$Matches.file
    $allowed=@('Run-Worker.ps1','Run-DetachedWorker.ps1'|ForEach-Object {Join-Path $script:MutatorRoot ('resources/'+$_)})
    if($file -notin $allowed){return}
    if($CommandLine -notmatch '(?i)(?:^|\s)(?:"-RunDirectory"|-RunDirectory)\s+(?:"(?<run>[^"]+)"|(?<run>\S+))'){return}
    $path=$Matches.run
    if(![IO.Path]::IsPathRooted($path)){return}
    $run=Read-MutatorJson (Join-Path $path 'run.json')
    if(!$run -or !$run['Packages']){return}
    $identities=@($run['Process'],(Read-MutatorJson (Join-Path $path 'supervisor.json')))
    foreach($entry in $run.Packages){
        $state=Read-MutatorJson (Join-Path $path ('packages/'+$entry.Id+'/state.json'))
        if($state){$identities+=@($state['Process'])}
    }
    $identities=@($identities|Where-Object {$_ -and $_['Id'] -and $_['StartedUtc']})
    $match=@($identities|Where-Object {$_.Id -eq $Target.Id -and [math]::Abs(([datetime]::Parse($_.StartedUtc)-[datetime]::Parse($Target.StartedUtc)).TotalMilliseconds) -lt 1 -and (Test-MutatorProcess $_)})
    if(!$match.Count){return}
    @{Path=$path;Run=$run;Identities=$identities}
}

function Get-MutatorRestartOptions {
    <#
    .SYNOPSIS
    Reconstruct a package restart while preserving run policy.

    .DESCRIPTION
    Carries budgets, target OS, tools, container settings and timeouts forward. Refuses a changed
    recheck baseline.
    #>

    param([Collections.IDictionary]$Run,[Collections.IDictionary]$Entry,[string]$RunRoot)
    $options=@{ModulePath=$Entry.ModulePath;SourceRoot=$Run.SourceRoot;RunRoot=$RunRoot;Workers=$Run.Schedule.Workers
        WorkerBudget=$Run.Schedule.WorkerBudget;ThrottleLimit=1;MemoryBudgetMiB=$Run.Schedule.MemoryBudgetMiB
        TestOrder=$Run.TestOrder;SkipStryker=(!$Entry.Stryker);StrykerRuntime=$(if($Run['StrykerRuntime']){$Run.StrykerRuntime}else{'Auto'})}
    if($Run['TargetOS']){$options.OS=$Run.TargetOS}
    if($Entry['RecheckFrom']){
        if($Entry['RecheckSha256'] -and (Get-FileHash -LiteralPath $Entry.RecheckFrom).Hash -cne $Entry.RecheckSha256){throw 'Recheck baseline changed; refusing automatic recovery with different input.'}
        $options.RecheckFrom=$Entry.RecheckFrom
    }
    foreach($key in @('ContainerEngine','ContainerConnection','ContainerBaseImage','WindowsGuestImage','WindowsGuestTimeoutMinutes','WindowsGuestJobTimeoutSeconds')){
        if($Run[$key]){$options[$key]=$Run[$key]}
    }
    $options
}
