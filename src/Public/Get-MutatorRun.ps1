function Get-MutatorRun {
    <#
    .SYNOPSIS
    Aggregate retained run/package observations without execution.

    .DESCRIPTION
    Distinguishes startup failure, interruption and remote identity. Partial/recheck evidence gains no
    final score and unknown discovery stays unknown.
    #>

    [CmdletBinding()]
    param([string]$Path, [string]$RunRoot,[ValidateRange(1,10000)][int]$Limit=10000)
    $directories = if ($Path) { @((Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath) } else {
        $root=Get-MutatorRunRoot $RunRoot
        @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Ignore | Where-Object { Test-Path (Join-Path $_.FullName 'run.json') } | Sort-Object Name -Descending | Select-Object -First $Limit | ForEach-Object FullName)
    }
    foreach ($directory in $directories) {
        $run=Read-MutatorJson (Join-Path $directory 'run.json')
        if (!$run) { throw "No mutation run at $directory" }
        $packages=@(foreach($entry in $run.Packages){
            $state=Read-MutatorJson (Join-Path $directory ('packages/'+$entry.Id+'/state.json'))
            if (!$state) { $state=@{Id=$entry.Id;Name=$entry.Name;Outcome='Pending';Phase='Pending'} }
            $state.RequiredRuntime=$entry['IsolationRuntime']
            $state.ExecutionRuntime=if($state['Container'] -and $state.Container['Engine']){
                $started=!$state.Container.Contains('Started') -or $state.Container.Started -or ($state.Container['StatePath'] -and (Test-Path -LiteralPath $state.Container.StatePath))
                if($started){[string]$state.Container.Engine}else{'Pending'}
            }elseif($run['IsolationBoundary']){[string]$run.IsolationBoundary}elseif($run['Isolation']){'Pending'}else{'Host'}
            if(!$state['Platform'] -and $entry['Platform']){$state.Platform=$entry.Platform}
            $progressPath=Join-Path $directory ('packages/'+$entry.Id+'/mutants.jsonl')
            if ($state['Container']) {
                if ($state.Container['ProgressPath']) { $progressPath=$state.Container.ProgressPath }
                if ($state.Outcome -eq 'Running' -and $state.Container['StatePath']) {
                    $inner=Read-MutatorJson $state.Container.StatePath
                    if ($inner) { $state.Phase=$inner.Phase }
                }
            }
            $progress=$null
            if(Test-Path $progressPath){foreach($line in @(Read-MutatorProgressTail -Path $progressPath)){try{$progress=$line|ConvertFrom-Json -AsHashtable -DateKind String}catch{$state.ProgressReadError='A progress event is still being written or is invalid.'}}}
            if($progress){$state.EvaluatedMutants=$progress.Evaluated;$state.PlannedMutants=$progress.Planned;$state.SurvivedMutants=[long]$progress['Survived'];if($state.Outcome -eq 'Running' -and $state.Phase -in @('Baseline','Preparation','PSMutant')){$state.Phase='PSMutant'}}
            if($state['PSMutant']){
                $state.EquivalentMutants=[long]$state.PSMutant['Equivalent']
                $state.EvaluatedMutants=[long]$state.PSMutant.Total+$state.EquivalentMutants
                $state.PlannedMutants=$state.EvaluatedMutants;$state.SurvivedMutants=[long]$state.PSMutant['Survived']
            }
            $csProgressPath=Join-Path $directory ('packages/'+$entry.Id+'/stryker.jsonl')
            if($state['Container'] -and $state.Container['StrykerProgressPath']){$csProgressPath=$state.Container.StrykerProgressPath}
            $cs=$null
            if(Test-Path $csProgressPath){foreach($line in @(Read-MutatorProgressTail -Path $csProgressPath)){try{$cs=$line|ConvertFrom-Json -AsHashtable -DateKind String}catch{$state.ProgressReadError='A C# progress event is still being written or is invalid.'}}}
            if($state['Stryker']){$cs=@{Evaluated=$state.Stryker.Total;Planned=$state.Stryker.Total;Survived=$state.Stryker.Survived}}
            if($cs){
                $state.CSharpEvaluatedMutants=[long]$cs.Evaluated;$state.CSharpPlannedMutants=[long]$cs.Planned
                $state.EvaluatedMutants=[long]$state['EvaluatedMutants']+[long]$cs.Evaluated
                $state.PlannedMutants=[long]$state['PlannedMutants']+[long]$cs.Planned
                $state.SurvivedMutants=[long]$state['SurvivedMutants']+[long]$cs['Survived']
            }
            if($state['Error']){$state.Error=Protect-MutatorDiagnostic $state.Error}
            $state
        })
        $completed=@($packages|Where-Object Outcome -EQ Success).Count
        $failed=@($packages|Where-Object Outcome -EQ Failed).Count
        $interrupted=@($packages|Where-Object Outcome -EQ Interrupted).Count
        $processed=$completed+$failed+$interrupted
        $evaluated=0L;$planned=0L;$survived=0L;$equivalent=0L
        foreach($package in $packages){$evaluated+=[long]$package['EvaluatedMutants'];$planned+=[long]$package['PlannedMutants'];$survived+=[long]$package['SurvivedMutants'];$equivalent+=[long]$package['EquivalentMutants']}
        $rechecks=@($packages|Where-Object {$_['Recheck'] -and $null -ne $_.Recheck['Rechecked']})
        $rechecked=$null;$recheckKilled=$null;$recheckSurvived=$null
        if($rechecks.Count){
            $rechecked=0L;$recheckKilled=0L;$recheckSurvived=0L
            foreach($package in $rechecks){$rechecked+=[long]$package.Recheck.Rechecked;$recheckKilled+=[long]$package.Recheck.NowKilled;$recheckSurvived+=[long]$package.Recheck.Survived}
        }
        $identity=$run['Process'];if(!$identity){$identity=Read-MutatorJson (Join-Path $directory 'supervisor.json')}
        $outcome=$run.Outcome
        $localPlatform=if($IsWindows){'windows'}elseif($IsMacOS){'macos'}else{'linux'}
        $localObserver=$run.Platform -ceq $localPlatform -and (!$run['HostName'] -or $run.HostName -ceq [Environment]::MachineName)
        if($outcome -in @('Running','Starting') -and $localObserver){
            $startupFailure=Read-MutatorJson (Join-Path $directory 'supervisor-failure.json')
            if($startupFailure){$outcome='Failed';$run.Error=$startupFailure.Error}
            elseif($identity -and !(Test-MutatorProcess $identity)){$outcome='Interrupted'}
        }
        $hostMemory=$null
        $watchdogPath=if($run['MemoryWatchdogPath']){$run.MemoryWatchdogPath}else{Join-Path $script:MutatorRoot 'test/Artifacts/memory-watchdog'}
        if(Test-Path (Join-Path $watchdogPath 'watchdog.json')){$hostMemory=Get-MutatorMemoryWatchdog $watchdogPath|Select-Object Running,LimitGB,TriggerGB,UsedGB,Outcome,LastSampleUtc,Error}
        [pscustomobject]@{Id=$run.Id;Path=$directory;Outcome=$outcome;Mode=$(if($run['Mode']){$run.Mode}else{'Full'});Platform=$run.Platform;TargetOS=$run['TargetOS'];Isolation=$run['Isolation'];Runtime=$run.Runtime;CreatedUtc=$run.CreatedUtc;ContainerEngine=$run['ContainerEngine']
            RecheckedMutants=$rechecked;RecheckKilledMutants=$recheckKilled;RecheckSurvivedMutants=$recheckSurvived;RecheckScopeComplete=($rechecks.Count -gt 0 -and $rechecks.Count -eq $packages.Count)
            ContainerEndpoint=$(if($run['ContainerSetting']){Protect-MutatorDiagnostic $run.ContainerSetting['Pipe']}else{$null})
            CompletedUtc=$run['CompletedUtc'];TotalPackages=$run.Packages.Count;CompletedPackages=$completed;FailedPackages=$failed;InterruptedPackages=$interrupted;ProcessedPackages=$processed
            CompletionPercent=$(if($run.Packages.Count){[math]::Round(100*$processed/$run.Packages.Count,1)}else{0});ErrorPercent=$(if($processed){[math]::Round(100*$failed/$processed,1)}else{0})
            EvaluatedMutants=$evaluated;PlannedMutants=$planned;SurvivedMutants=$survived;EquivalentMutants=$equivalent;ObserverLocal=$localObserver;SurvivalPercent=$(if($evaluated){[math]::Round(100*$survived/$evaluated,1)}else{0})
            Packages=$packages;Schedule=$run['Schedule'];ActivePackages=@($packages|Where-Object Outcome -EQ Running).Count;Process=$identity;Error=(Protect-MutatorDiagnostic $run['Error']);Origin=$run['Origin'];Report=(Join-Path $directory 'run.json');HostMemory=$hostMemory}
    }
}
