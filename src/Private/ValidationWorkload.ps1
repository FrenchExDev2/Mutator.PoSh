function Invoke-MutatorValidationChild {
    <#
    .SYNOPSIS
    Run a child with retained logs and its last JSON summary.

    .DESCRIPTION
    Forwards cancellation and separates native outcome from semantic summary. A successful process alone
    does not establish test success.
    #>

    param([string[]]$Arguments,[string]$Directory,[string]$Proof,[int]$TimeoutSeconds=3600,[string]$StopPath)
    [void][IO.Directory]::CreateDirectory($Proof)
    $native=Invoke-MutatorNative (Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})) $Arguments $Directory $TimeoutSeconds -StopPath $StopPath
    [IO.File]::WriteAllText((Join-Path $Proof 'stdout.log'),$native.Stdout)
    [IO.File]::WriteAllText((Join-Path $Proof 'stderr.log'),$native.Stderr)
    Write-MutatorJson (Join-Path $Proof 'native.json') @{Outcome=$native.Outcome;ExitCode=$native.ExitCode;Failure=$native.Failure}
    $lines=@($native.Stdout -split "`r?`n"|Where-Object {$_ -like '{*'})
    $summary=if($lines.Count){$lines[-1]|ConvertFrom-Json -AsHashtable -DateKind String}else{$null}
    @{NativeOutcome=$native.Outcome;ExitCode=$native.ExitCode;Summary=$summary}
}

function Copy-MutatorValidationMutationProof {
    <#
    .SYNOPSIS
    Mirror run/package evidence without mutation sandboxes.

    .DESCRIPTION
    Preserves relative paths and publishes completed files atomically. Source readers permit concurrent
    replacement.
    #>

    param([string]$RunPath,[string]$Destination)
    $folders=@($RunPath)
    $packages=Join-Path $RunPath 'packages'
    if(Test-Path -LiteralPath $packages){$folders+=@(Get-ChildItem -LiteralPath $packages -Directory|ForEach-Object FullName)}
    foreach($folder in $folders){
        foreach($file in Get-ChildItem -LiteralPath $folder -File){
            $target=Join-Path $Destination ([IO.Path]::GetRelativePath($RunPath,$file.FullName))
            [void][IO.Directory]::CreateDirectory((Split-Path $target))
            $temporary=$target+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
            $reader=$null
            try{
                $reader=[IO.FileStream]::new($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                $writer=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
                try{$reader.CopyTo($writer)}finally{$writer.Dispose()}
                Complete-MutatorAtomicWrite $temporary $target
            }finally{
                if($reader){$reader.Dispose()}
                if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
            }
        }
        $stryker=Join-Path $folder 'stryker/reports'
        if(Test-Path -LiteralPath $stryker){Copy-MutatorTree $stryker (Join-Path $Destination ([IO.Path]::GetRelativePath($RunPath,$stryker)))}
    }
}

function Invoke-MutatorValidationWorkload {
    <#
    .SYNOPSIS
    Run semantic suites, coverage and mutations against frozen inputs.

    .DESCRIPTION
    Checks OS/source identity, retains evidence and blocks mutation after failed prerequisites. Honors
    stopping; partial selections never become a full gate.
    #>

    param([string]$Root,[string]$ReportRoot)
    $request=Read-MutatorJson (Join-Path $Root 'request.json')
    $actual=Get-MutatorHostPlatform
    $modules=Join-Path $Root 'modules'
    $before=Get-MutatorSourceSnapshot $modules
    $result=@{SchemaVersion=1;RunId=$request.RunId;OS=$actual;SourceSha256=$before.Sha256;OriginalModuleSha256=$request['OriginalModuleSha256'];Outcome='Running';Suites=@{};Modules=@{};Runtime=$PSVersionTable.PSVersion.ToString();FullGateSatisfied=$false;RetainSandbox=$false}
    [void][IO.Directory]::CreateDirectory($ReportRoot)
    try{
        if($request.SchemaVersion -ne 1 -or $request.OS -cne $actual -or $before.Sha256 -cne $request.SourceSha256){throw 'The validation request OS, version or source fingerprint differs.'}
        if(!$request.Modules.Count -or !$request.Test.Count -or @($request.Test|Where-Object {$_ -cnotin @('Unit','Integration','Mutations')}).Count){throw 'Invalid validation selection.'}
        foreach($name in $request.Modules){
            Assert-MutatorValidationActive $ReportRoot $request.RunId
            if($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]+$' -or $name -in @('.','..')){throw 'Invalid validation module name.'}
            $subject=Join-Path $modules $name
            $entry=@{Suites=@{};Coverage=$null;Outcome='Running'};$result.Modules[$name]=$entry
            $coverage=@();$baselineFailed=$false
            foreach($suite in @('Unit','Integration'|Where-Object {$_ -in $request.Test})){
                Assert-MutatorValidationActive $ReportRoot $request.RunId
                $proof=Join-Path $ReportRoot ($suite.ToLowerInvariant()+'/'+$name)
                $progress=@{Module=$name;Suite=$suite;Phase='Pester';CompletionPercent=$null;Errors=0;MemoryBytes=[Environment]::WorkingSet}
                Write-MutatorJson (Join-Path $ReportRoot 'progress.json') $progress
                try{
                    $run=Invoke-MutatorValidationChild -Arguments @('-NoProfile','-File',(Join-Path $script:MutatorRoot 'test/Invoke-Tests.ps1'),'-Path',(Join-Path $subject ('test/'+$suite)),'-CoverageModulePath',$subject,'-CoverageBreakpoints') -Directory $modules -Proof $proof -StopPath (Join-Path $ReportRoot 'stop.json')
                    if($run.NativeOutcome -eq 'Cancelled'){Assert-MutatorValidationActive $ReportRoot $request.RunId}
                    $s=$run.Summary
                    if($s -and $s['Report'] -and (Test-Path -LiteralPath $s.Report)){Copy-MutatorTree (Split-Path $s.Report) $proof}
                    if(!$s -or !$s['Passed'] -or $s['Failed'] -or $s['Skipped'] -or $s['DiscoveryErrors'] -or !$s['SourceUnchanged'] -or $run.NativeOutcome -notin @('Success','Failed')){throw 'Pester failed, returned no tests, or produced an invalid source-bound report.'}
                    $report=Join-Path $proof 'coverage.json'
                    if(!(Test-Path $report) -or !(Test-Path (Join-Path $proof 'tests.xml'))){throw 'Required Pester or coverage report is missing.'}
                    $coverage+=$report
                    $entry.Suites[$suite]=@{Outcome='Success';Passed=$s.Passed;Failed=0;Skipped=0;Report=($suite.ToLowerInvariant()+'/'+$name+'/tests.xml')}
                }catch{
                    if($_.Exception -is [OperationCanceledException]){
                        $entry.Suites[$suite]=@{Outcome='Interrupted';Error=$_.Exception.Message};$entry.Outcome='Interrupted'
                        throw
                    }
                    $baselineFailed=$true;$entry.Suites[$suite]=@{Outcome='Failed';Error=$_.Exception.Message}
                }
            }
            Assert-MutatorValidationActive $ReportRoot $request.RunId
            if($coverage.Count){
                $proof=Join-Path $ReportRoot ('coverage/'+$name)
                Write-MutatorJson (Join-Path $ReportRoot 'progress.json') @{Module=$name;Suite='Coverage';Phase='Branches';CompletionPercent=$null;Errors=0;MemoryBytes=[Environment]::WorkingSet}
                try{
                    $scope=if('Unit' -in $request.Test -and 'Integration' -in $request.Test){'All'}elseif('Unit' -in $request.Test){'Unit'}else{'Integration'}
                    $branch=Invoke-MutatorValidationChild -Arguments @('-NoProfile','-File',(Join-Path $script:MutatorRoot 'test/Fixtures/DevPoShBranchCoverage.ps1'),'-Module',$name,'-TestScope',$scope) -Directory $modules -Proof $proof -StopPath (Join-Path $ReportRoot 'stop.json')
                    if($branch.NativeOutcome -eq 'Cancelled'){Assert-MutatorValidationActive $ReportRoot $request.RunId}
                    if($branch.Summary -and $branch.Summary['Proof']){
                        foreach($file in Get-ChildItem -LiteralPath $branch.Summary.Proof -File){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $proof ('branch-'+$file.Name))}
                    }
                    if($branch.NativeOutcome -cne 'Success' -or !$branch.Summary -or !$branch.Summary['Proof']){throw 'Branch qualification failed or returned no report.'}
                    $rawBranch=Join-Path $proof 'branches.raw.json'
                    Copy-Item -LiteralPath (Join-Path $branch.Summary.Proof 'coverage.json') -Destination $rawBranch
                    foreach($file in @('manifest.json','tests.json')){Copy-Item -LiteralPath (Join-Path $branch.Summary.Proof $file) -Destination (Join-Path $proof $file)}
                    $branchFile=Join-Path $proof 'branches.json'
                    $null=Merge-MutatorBranchCoverage -Path @($rawBranch) -OutputPath $branchFile
                    $merged=Merge-MutatorCoverage -Path $coverage -BranchPath $branchFile -OutputPath (Join-Path $proof 'coverage.json')
                    $entry.Coverage=@{Outcome=$(if($merged.FullGateSatisfied){'Success'}else{'CoverageIncomplete'});Report=('coverage/'+$name+'/coverage.json')}
                }catch{
                    if($_.Exception -is [OperationCanceledException]){$entry.Coverage=@{Outcome='Interrupted';Error=$_.Exception.Message};$entry.Outcome='Interrupted';throw}
                    $entry.Coverage=@{Outcome='Failed';Error=$_.Exception.Message}
                }
            }
            Assert-MutatorValidationActive $ReportRoot $request.RunId
            if('Mutations' -in $request.Test){
                $proof=Join-Path $ReportRoot ('mutations/'+$name)
                Write-MutatorJson (Join-Path $ReportRoot 'progress.json') @{Module=$name;Suite='Mutations';Phase='Baseline';CompletionPercent=$null;Errors=0;MemoryBytes=[Environment]::WorkingSet}
                if($baselineFailed){$entry.Suites.Mutations=@{Outcome='Blocked';Reason='The selected semantic baseline failed.'}}
                else{
                    $mutation=$null
                    try{
                        # PSMutant sandboxes stay on the guest filesystem, never on its SMB/9p share.
                        $mutation=Invoke-MutatorRun -ModulePath $subject -RunRoot (Join-Path $Root ('validation-runs/'+$name)) -Workers $request.Workers -WorkerBudget $request.WorkerBudget -MemoryBudgetMiB $request.MemoryBudgetMiB -StrykerRuntime Host -Background
                        do{
                            Assert-MutatorValidationActive $ReportRoot $request.RunId
                            $progress=Get-MutatorProgress -Path $mutation.Path
                            Copy-MutatorValidationMutationProof -RunPath $mutation.Path -Destination (Join-Path $proof 'runs')
                            $percent=if($progress.PlannedMutants -gt 0){[math]::Round(100.0*$progress.EvaluatedMutants/$progress.PlannedMutants,1)}else{$null}
                            Write-MutatorJson (Join-Path $ReportRoot 'progress.json') @{Module=$name;Suite='Mutations';Phase='Mutation';CompletionPercent=$percent;Errors=$progress.FailedPackages;EvaluatedMutants=$progress.EvaluatedMutants;PlannedMutants=$progress.PlannedMutants;MemoryBytes=[Environment]::WorkingSet}
                            if($progress.Outcome -notin @('Starting','Running')){break}
                            Start-Sleep -Seconds 2
                        }while($true)
                        $mutation=Get-MutatorRun -Path $mutation.Path
                        Copy-MutatorValidationMutationProof -RunPath $mutation.Path -Destination (Join-Path $proof 'runs')
                        $null=Export-MutatorReport -Path $mutation.Path -RunId $request.RunId
                        if($mutation.Outcome -cne 'Success' -or !$mutation.PlannedMutants -or $mutation.EvaluatedMutants -ne $mutation.PlannedMutants -or $mutation.SurvivedMutants){throw 'The complete raw mutation gate did not pass.'}
                        $stryker=@{Outcome='NotApplicable';Reason='No engine/dotnet-tools.json for this module.'}
                        if(Test-Path (Join-Path $subject 'engine/dotnet-tools.json')){
                            $package=@($mutation.Packages|Where-Object {$_['Stryker']})
                            if($package.Count -ne 1){throw 'A completed Stryker result is required for this module.'}
                            $reportPath=Join-Path $mutation.Path ('packages/'+$package[0].Id+'/stryker/reports/mutation-report.json')
                            $report=Read-MutatorJson $reportPath
                            $summary=Get-MutatorStrykerSummary $report
                            if(!$summary.Detected -or $summary.Undetected -or (Get-FileHash $reportPath).Hash -cne $package[0].Stryker.ReportSha256){throw 'The retained Stryker report is incomplete or its fingerprint differs.'}
                            $stryker=@{Outcome='Success';Report=('mutations/'+$name+'/runs/packages/'+$package[0].Id+'/stryker/reports');Summary=$summary}
                        }
                        $entry.Suites.Mutations=@{Outcome='Success';Total=$mutation.PlannedMutants;Score=100;Report=('mutations/'+$name+'/runs');Stryker=$stryker}
                    }catch{
                        $originalError=$_
                        $interrupted=$_.Exception -is [OperationCanceledException]
                        $entry.Suites.Mutations=@{Outcome=$(if($interrupted){'Interrupted'}else{'Failed'});Error=$originalError.Exception.Message}
                        if($mutation -and $mutation.Path){
                            $stop=Stop-MutatorValidationMutation -RunPath $mutation.Path -Destination (Join-Path $proof 'runs') -ValidationRunId $request.RunId
                            $entry.Suites.Mutations.Stop=$stop
                        }
                        $result.RetainSandbox=$true
                        if($interrupted){$entry.Outcome='Interrupted';throw $originalError}
                    }
                }
            }
            $entry.Outcome=if(@($entry.Suites.Values|Where-Object Outcome -NE 'Success').Count -or ($entry.Coverage -and $entry.Coverage.Outcome -ne 'Success')){'Failed'}else{'Success'}
        }
        foreach($suite in $request.Test){
            $outcomes=@($result.Modules.Values|ForEach-Object {$_.Suites[$suite].Outcome})
            $result.Suites[$suite]=@{Outcome=$(if(@($outcomes|Where-Object {$_ -eq 'Failed'}).Count){'Failed'}elseif(@($outcomes|Where-Object {$_ -eq 'Blocked'}).Count){'Blocked'}else{'Success'})}
        }
        $result.SourceUnchanged=((Get-MutatorSourceSnapshot $modules).Sha256 -ceq $before.Sha256)
        $result.Outcome=if(!$result.SourceUnchanged -or @($result.Modules.Values|Where-Object Outcome -NE 'Success').Count){'Failed'}else{'Success'}
        $result.FullGateSatisfied=($result.Outcome -ceq 'Success' -and $request.Test.Count -eq 3)
    }catch{
        $result.Outcome=$(if($_.Exception -is [OperationCanceledException]){'Interrupted'}else{'Failed'})
        $result.Error=$_.Exception.Message
        $result.RetainSandbox=$true
        if($result.Outcome -eq 'Interrupted'){
            foreach($name in $request.Modules){
                if(!$result.Modules.ContainsKey($name)){$result.Modules[$name]=@{Suites=@{};Coverage=$null;Outcome='Interrupted'}}
                elseif($result.Modules[$name].Outcome -eq 'Running'){$result.Modules[$name].Outcome='Interrupted'}
            }
        }
    }
    finally{
        if($result.Outcome -ne 'Success'){$result.RetainSandbox=$true}
        $result.CompletedUtc=[datetime]::UtcNow.ToString('O')
        $errors=@($result.Modules.Values|Where-Object Outcome -NE 'Success').Count
        Write-MutatorJson (Join-Path $ReportRoot 'progress.json') @{Phase=$(if($result.Outcome -eq 'Success'){'Completed'}else{$result.Outcome});Outcome=$result.Outcome;CompletionPercent=$(if($result.Outcome -eq 'Success'){100}else{$null});Errors=$errors;ErrorPercent=$(if($result.Modules.Count){100.0*$errors/$result.Modules.Count}else{100});MemoryBytes=[Environment]::WorkingSet}
        Write-MutatorJson (Join-Path $ReportRoot 'result.json') $result
    }
    $result
}
