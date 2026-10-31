function Invoke-MutatorPackage {
    <#
    .SYNOPSIS
    Prepare, execute and retain one mutation or recheck package.

    .DESCRIPTION
    Dispatches required isolation before local execution, validates context identity and enforces full
    mutation gates. Retains final state and available partial or failure evidence.
    #>

    param([string]$RunDirectory, [string]$Package)
    $run = Read-MutatorJson (Join-Path $RunDirectory 'run.json')
    $script:MutatorIsolationBoundary=$run['IsolationBoundary']
    if($run['Isolation'] -ne 'WindowsSandbox' -and $run['IsolationBoundary'] -ne 'WindowsSandbox'){Restore-MutatorContainerContext $run}
    $entry = @($run.Packages | Where-Object Id -CEQ $Package)[0]
    $artifacts = Join-Path $RunDirectory ('packages/' + $Package)
    [void][IO.Directory]::CreateDirectory($artifacts)
    $statePath = Join-Path $artifacts 'state.json'
    $state = @{ Id=$Package; Name=$entry.Name; Outcome='Running'; Phase='Baseline'; StartedUtc=[datetime]::UtcNow.ToString('O'); Process=@{Id=$PID;StartedUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('O')}; PSMutant=$null; Stryker=$null; Error=$null }
    Write-MutatorJson $statePath $state
    $stage = Join-Path $artifacts 'stage'
    $context = $null
    $stopPath = if ($run['StopPath']) { $run.StopPath } else { Join-Path $RunDirectory 'stop.json' }
    try {
        if($run['Isolation'] -eq 'WindowsSandbox'){
            Invoke-MutatorWindowsSandboxPackage $RunDirectory $run $entry $state $statePath
            return
        }
        if ($run['WindowsGuestImage']) {
            throw 'Windows PSMutant campaigns require Windows Sandbox; the legacy KVM guest adapter is not a campaign runtime.'
        }
        if ($entry['ContainerRecipe']) {
            Invoke-MutatorContainerPackage $RunDirectory $run $entry $state $statePath
            return
        }
        if($run['Isolation']){throw 'The required isolation adapter is absent; execution on the host is prohibited.'}
        if($entry['RecheckFrom']){
            if(!$script:MutatorIsolationBoundary){throw 'Recheck execution requires an isolated worker.'}
            if((Get-FileHash -LiteralPath $entry.RecheckFrom).Hash -cne $entry.RecheckSha256){throw 'The selected recheck baseline changed since scheduling.'}
            $state.Phase='Recheck';Write-MutatorJson $statePath $state
            $checked=Invoke-MutatorRecheckCore -ModulePath $entry.ModulePath -ReportPath $entry.RecheckFrom -SourceRoot $run.SourceRoot -OutputDirectory (Join-Path $artifacts 'recheck') -StopPath $stopPath -ToolCacheRoot $run['ToolCacheRoot']
            $state.Recheck=@{Outcome=$checked.Outcome;Mode='Recheck';Score=$null;FullGateSatisfied=$false;Report='mutation.recheck.json'
                BaselineSha256=$checked.BaselineSha256;SourceSha256=$checked.SourceSha256;Rechecked=$checked.Rechecked;NowKilled=$checked.NowKilled;Survived=$checked.Survived}
            $state.Outcome=switch($checked.Outcome){'Success'{'Success'};'Interrupted'{'Interrupted'};default{'Failed'}}
            $state.Phase=if($state.Outcome -eq 'Success'){'Completed'}else{$state.Outcome}
            $state.Error=if($checked.Outcome -eq 'SurvivorsRemain'){[string]$checked.Survived+' rechecked mutants still survive.'}else{$checked.Error}
            return
        }
        $configuration = Read-MutatorJson $entry.Configuration
        Confirm-MutatorEquivalence -ModulePath $entry.ModulePath -Configuration $configuration
        if ($configuration.coveredLinesOnly -ne $false) { throw 'Complete mutation scope requires coveredLinesOnly: false.' }
        $subtrees = @(Get-MutatorSubtree $run.SourceRoot $configuration)
        $before = Get-MutatorSourceSnapshot $entry.ModulePath
        $sourceIdentities=@{}
        foreach($subtree in $subtrees){$sourceIdentities[$subtree]=(Get-MutatorSourceSnapshot (Join-Path $run.SourceRoot $subtree)).Sha256}
        if($configuration.reportPath -isnot [string] -or [string]::IsNullOrWhiteSpace($configuration.reportPath) -or [IO.Path]::IsPathRooted($configuration.reportPath)){throw 'Mutation reportPath must be a nonempty relative path inside the sandbox.'}
        $reportPath=[IO.Path]::GetFullPath($configuration.reportPath,$stage)
        $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
        if(!$reportPath.StartsWith(([IO.Path]::GetFullPath($stage)+[IO.Path]::DirectorySeparatorChar),$comparison)){throw 'Mutation reportPath escapes the sandbox.'}
        $clock = [Diagnostics.Stopwatch]::StartNew()
        foreach ($subtree in $subtrees) { Copy-MutatorTree (Join-Path $run.SourceRoot $subtree) (Join-Path $stage $subtree) }
        $relativeConfig = [IO.Path]::GetRelativePath($run.SourceRoot, $entry.Configuration)
        $stagedConfig = Join-Path $stage $relativeConfig
        $configuration.workers = $run.Schedule.Workers
        $state.TestOrder = Set-MutatorTestOrder $configuration $run.TestOrder
        Write-MutatorJson $stagedConfig $configuration
        Import-Module Pester -RequiredVersion 6.2.0 -ErrorAction Stop
        $toolArguments = @{ProgressPath=(Join-Path $artifacts 'mutants.jsonl');StopPath=$stopPath}
        if ($run['ToolCacheRoot']) { $toolArguments.CacheRoot=$run.ToolCacheRoot }
        $tool = Import-MutatorTool @toolArguments
        $context = New-MutatorContext $run.SourceRoot $subtrees $stagedConfig $tool -ContainerImageId $run['ContainerImageId']
        Write-MutatorJson (Join-Path $artifacts 'context.json') $context
        if ($entry.ResumeFrom) { Confirm-MutatorResume $entry.ResumeFrom $context }
        $state.PreparationMs = $clock.Elapsed.TotalMilliseconds
        $state.StagedSubtrees = $subtrees
        $state.ContextSha256 = $context.Sha256
        Write-MutatorJson $statePath $state
        $invoke = @{ ConfigFile=$stagedConfig; SourceRoot=$stage; Quiet=$true }
        if ($entry.ResumeFrom) { $invoke.ResumeFrom=$entry.ResumeFrom }
        $result = Invoke-PSMutation @invoke
        $reportPath = Join-Path $stage $configuration.reportPath
        $detail = Read-MutatorJson $reportPath
        if($detail -and $detail['mode'] -ne 'Partial'){$state.PSMutant=@{Score=$result.Score;Killed=$result.Killed;Total=$result.Total;Survived=$detail.survived;TimedOut=$detail.timedOut;Equivalent=$detail.declaredEquivalent;Workers=$run.Schedule.Workers;Tool=$tool}}
        if (!(Test-MutatorPowerShellGate -Detail $detail -Result $result)) { throw 'PSMutant failed, discovery was empty, or the complete mutation gate was not satisfied.' }
        if(Test-Path -LiteralPath $stopPath){throw 'Package was interrupted before the remaining mutation gates.'}
        if ($entry.Stryker) {
            Save-MutatorArtifact (Split-Path $reportPath) $artifacts $context
            $state.Phase='Stryker'; Write-MutatorJson $statePath $state
            $strykerModule = Join-Path $stage ([IO.Path]::GetRelativePath($run.SourceRoot,$entry.ModulePath))
            $state.Stryker = Invoke-MutatorStrykerCore $strykerModule $artifacts $run.Schedule.Workers $run.StrykerRuntime -StopPath $stopPath
        }
        if ((Get-MutatorSourceSnapshot $entry.ModulePath).Sha256 -cne $before.Sha256) { throw 'Module source changed during mutation.' }
        foreach($subtree in $subtrees){if((Get-MutatorSourceSnapshot (Join-Path $run.SourceRoot $subtree)).Sha256 -cne $sourceIdentities[$subtree]){throw "Dependency source changed during mutation: $subtree"}}
        if(Test-Path -LiteralPath $stopPath){throw 'Package was interrupted before completion.'}
        $state.SourceSha256=$before.Sha256
        $state.Outcome='Success'; $state.Phase='Completed'
    } catch {
        if(!$state.Contains('FailedPhase')){$state.FailedPhase=$state.Phase}
        $state.Outcome = if (Test-Path $stopPath) { 'Interrupted' } else { 'Failed' }
        $state.Phase=$state.Outcome
        $state.Error=$_.Exception.Message
    } finally {
        try {
            if ($context) { Save-MutatorArtifact (Split-Path (Join-Path $stage $configuration.reportPath)) $artifacts $context }
            if (Test-Path -LiteralPath $stage) {
                $owned = [IO.Path]::GetFullPath($artifacts) + [IO.Path]::DirectorySeparatorChar
                if (![IO.Path]::GetFullPath($stage).StartsWith($owned,[StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing mutation cleanup outside the run directory.' }
                Remove-Item -LiteralPath $stage -Recurse -Force
            }
        } catch { $state.Outcome='Failed'; $state.Error=([string]$state.Error+' Artifact retention or sandbox cleanup failed: ' + $_.Exception.Message).Trim() }
        $state.CompletedUtc=[datetime]::UtcNow.ToString('O')
        Write-MutatorJson $statePath $state
    }
}

function Invoke-MutatorStrykerCore {
    <#
    .SYNOPSIS
    Run the configured C# gate and retain captured evidence.

    .DESCRIPTION
    Requires project settings, restores local tools and forwards cancellation. Rejects empty discovery,
    native failures and undetected or excluded mutants.
    #>

    [CmdletBinding()]
    param([string]$ModulePath, [string]$Artifacts, [int]$Workers,[ValidateSet('Auto','Host')][string]$Runtime='Auto',[string]$StopPath)
    [void][IO.Directory]::CreateDirectory($Artifacts)
    $engine = Join-Path $ModulePath 'engine'
    $settings = Read-MutatorJson (Join-Path $engine 'mutator.json')
    if (!$settings) { throw "Stryker requires engine/mutator.json with Project and TestProject: $engine" }
    foreach($key in @('Project','TestProject')){
        if($settings[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($settings[$key])){throw "Stryker requires a nonempty $key in engine/mutator.json."}
    }
    if($Runtime -eq 'Auto' -and !(Get-Command dotnet -CommandType Application -ErrorAction Ignore)){throw 'Stryker requires the dotnet SDK on this host; no SDK container adapter is configured.'}
    $output = Join-Path $Artifacts 'stryker'
    $progressPath=Join-Path $Artifacts 'stryker.jsonl'
    $restore=Invoke-MutatorNative dotnet @('tool','restore') $engine 600 -ProgressPath $progressPath -StopPath $StopPath
    if($restore.Outcome -ne 'Success'){
        $exception=[InvalidOperationException]::new('Stryker tool restore failed. The local tool cache must be prepared before this run.')
        $PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new($exception,'Mutator.ToolRestoreFailed',[Management.Automation.ErrorCategory]::InvalidOperation,$ModulePath))
    }
    if($StopPath -and (Test-Path -LiteralPath $StopPath)){throw 'Stryker was interrupted after tool restore.'}
    $result = Invoke-MutatorNative dotnet @('stryker','--project',$settings.Project,'--test-project',$settings.TestProject,'--threshold-high','100','--threshold-low','100','--break-at','100','--concurrency',[string]$Workers,'--reporter','json','--reporter','progress','--output',$output) $engine -ProgressPath $progressPath -StopPath $StopPath
    foreach($stream in @('Stdout','Stderr')){if($result -is [Collections.IDictionary] -and $result.Contains($stream)){[IO.File]::WriteAllText((Join-Path $Artifacts ('stryker.'+$stream.ToLowerInvariant()+'.log')),[string]$result[$stream])}}
    $report = Read-MutatorJson (Join-Path $output 'reports/mutation-report.json')
    $summary=Get-MutatorStrykerSummary $report
    $progressEvent=@{Engine='Stryker';Evaluated=$summary.Total;Planned=$summary.Total;Survived=$summary.Survived;Utc=[datetime]::UtcNow.ToString('O')}
    [IO.File]::AppendAllText($progressPath,(($progressEvent|ConvertTo-Json -Compress)+[Environment]::NewLine))
    if ($result.Outcome -ne 'Success' -or !$summary.Detected -or $summary.Undetected) { throw 'Stryker failed, discovery was empty, or undetected mutants remain.' }
    $summary.Workers=$Workers;$summary.Runtime='Host'
    $summary.Report=Join-Path $Artifacts 'stryker/reports/mutation-report.json'
    $summary.ReportSha256=(Get-FileHash $summary.Report).Hash
    $summary
}

function Invoke-MutatorRunCore {
    <#
    .SYNOPSIS
    Supervise package workers until completion or cooperative stopping.

    .DESCRIPTION
    Uses shared leases, detects workers exiting without final state and refreshes the dashboard.
    Computes aggregate outcome after active owned workers finish.
    #>

    param([string]$RunDirectory)
    $path = Join-Path $RunDirectory 'run.json'
    $run = Read-MutatorJson $path
    if($run['Isolation'] -ne 'WindowsSandbox' -and $run['IsolationBoundary'] -ne 'WindowsSandbox'){Restore-MutatorContainerContext $run}
    $run.Outcome='Running'; $run.Process=@{Id=$PID;StartedUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('O')}
    Write-MutatorJson $path $run
    $pending = [Collections.Generic.Queue[object]]::new()
    foreach ($entry in $run.Packages) { $pending.Enqueue($entry) }
    $active = @{}
    try {
        do {
            $stopped = Test-Path (Join-Path $RunDirectory 'stop.json')
            while (!$stopped -and $pending.Count -and $active.Count -lt $run.Schedule.Slots) {
                $entry = $pending.Peek()
                $lease=Start-MutatorLeasedWorker $RunDirectory $entry.Id $run.Schedule
                if(!$lease){break}
                [void]$pending.Dequeue()
                $active[$entry.Id] = $lease
            }
            foreach ($id in @($active.Keys)) {
                if (!(Test-MutatorProcess $active[$id])) {
                    $statePath = Join-Path $RunDirectory ('packages/'+$id+'/state.json')
                    $state = Read-MutatorJson $statePath
                    if (!$state -or $state.Outcome -eq 'Running') {
                        $entry=@($run.Packages|Where-Object Id -CEQ $id)[0]
                        if(!$state){$state=@{Id=$id;Name=$entry.Name}}
                        $state.Outcome='Interrupted';$state.Phase='ProcessExited';$state.Error='Package worker exited without a final report.'
                        Write-MutatorJson $statePath $state
                    }
                    $active.Remove($id)
                }
            }
            Update-MutatorSupervisionDashboard $RunDirectory $run
            if (($stopped -or !$pending.Count) -and !$active.Count) { break }
            Start-Sleep -Seconds 2
        } while ($true)
        $view = Get-MutatorRun -Path $RunDirectory
        $run.Outcome = if ($stopped) { 'Interrupted' } elseif ($view.FailedPackages -or $view.CompletedPackages -ne $view.TotalPackages) { 'Failed' } else { 'Success' }
    } catch { $run.Outcome='Failed'; $run.Error=$_.Exception.Message }
    finally {
        $run.CompletedUtc=[datetime]::UtcNow.ToString('O'); Write-MutatorJson $path $run
        Update-MutatorSupervisionDashboard $RunDirectory $run
    }
}
