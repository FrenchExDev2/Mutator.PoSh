function Confirm-MutatorGuestMutationResult {
    param([Collections.IDictionary]$Result,[Collections.IDictionary]$State,[string]$RunId,[string]$JobId,[switch]$RequireStryker)
    if(!$Result -or $Result.RunId -cne $RunId -or $Result.JobId -cne $JobId){throw 'The Windows mutation result is missing or belongs to another job.'}
    if($Result.Outcome -ceq 'TimedOut'){throw [TimeoutException]::new('The Windows mutation job timed out; available state, logs and reports are retained.')}
    if($Result.Outcome -cne 'Success' -or $Result.ExitCode -ne 0){throw ('The Windows mutation job failed; retained guest logs contain the details. '+[string]$Result['Error'])}
    if(!$State -or $State['Outcome'] -cne 'Success' -or $State['Phase'] -cne 'Completed' -or !$State['ContextSha256'] -or !$State['SourceSha256']){
        $detail=if($State){[string]$State['Error']}else{'Missing package state.'}
        throw ('The Windows mutation package did not complete its evidence gate. '+$detail)
    }
    $mutation=$State['PSMutant']
    [long]$total=0;[double]$score=0
    if(!$mutation -or ![long]::TryParse([string]$mutation['Total'],[ref]$total) -or $total -le 0 -or ![double]::TryParse([string]$mutation['Score'],[ref]$score) -or $score -ne 100){throw 'The Windows mutation gate is empty or below 100 percent.'}
    if($RequireStryker){
        $cs=$State['Stryker']
        if(!$cs -or $cs['Score'] -ne 100 -or [long]$cs['Detected'] -le 0 -or [long]$cs['Undetected'] -ne 0 -or !$cs['ReportSha256']){throw 'The required Windows Stryker gate is missing, empty or failed.'}
    }
}

function Invoke-MutatorWindowsGuestPackage {
    param([string]$RunDirectory,[Collections.IDictionary]$Run,[Collections.IDictionary]$Entry,[Collections.IDictionary]$State,[string]$StatePath)
    $artifacts=Split-Path $StatePath
    $guestPath=Join-Path $artifacts 'windows-guest'
    $deadline=(Get-MutatorUtcNow).AddMinutes($Run.WindowsGuestTimeoutMinutes)
    $stopPath=Join-Path $RunDirectory 'stop.json'
    $guest=$null
    try{
        $State.Platform='Windows';$State.Phase='Starting Guest'
        $State.Container=@{Engine=$script:MutatorContainerEngine;GuestPath=$guestPath;Image=$Run.WindowsGuestImage;Connection=$Run.ContainerConnection;ResourceLimits=@{Memory=$true;MemoryMiB=6144;Cpus=2};ResourceWarning=$null}
        Write-MutatorJson $StatePath $State
        # Keep SMB writes short even when the caller stores its run under a deeply nested path.
        $share=Join-Path $script:MutatorRoot ('test/Artifacts/guest-shares/'+[guid]::NewGuid().ToString('N'))
        $null=Start-MutatorGuestModule -Image $Run.WindowsGuestImage -OutputDirectory $guestPath -ShareDirectory $share -Connection $Run.ContainerConnection
        $guest=(Read-MutatorGuestRun $guestPath).Run
        $State.Container.Name=$guest.Container;$State.Container.ImageId=$guest.ImageId
        $State.Phase='Provisioning Guest';Write-MutatorJson $StatePath $State
        do{
            if(Test-Path $stopPath){throw [OperationCanceledException]::new('Windows mutation stopped during provisioning.')}
            $status=Get-MutatorGuestBase $guestPath
            if($status.Outcome -eq 'Failed'){throw ('Windows module provisioning failed: '+$status.Error)}
            if($status.Ready){break}
            if(!$status.Running -or (Get-MutatorUtcNow) -ge $deadline){throw 'Windows mutation provisioning timed out or the guest exited.'}
            Start-Sleep -Seconds 3
        }while($true)
        $configuration=Read-MutatorJson $Entry.Configuration
        $subtrees=@(Get-MutatorSubtree $Run.SourceRoot $configuration)
        $before=Get-MutatorSourceSnapshot $Entry.ModulePath
        $id=[guid]::NewGuid().ToString('N')
        $directory=Join-Path $guest.Share ('jobs/'+$id)
        $source=Join-Path $directory 'source'
        foreach($subtree in $subtrees){Copy-MutatorTree (Join-Path $Run.SourceRoot $subtree) (Join-Path $source $subtree)}
        $descriptor=@{Module=[IO.Path]::GetRelativePath($Run.SourceRoot,$Entry.ModulePath);Configuration=[IO.Path]::GetRelativePath($Run.SourceRoot,$Entry.Configuration)
            Name=$Entry.Name;SourceSha256=(Get-MutatorSourceSnapshot $source).Sha256;ImageId=$guest.ImageId;TestOrder=$Run.TestOrder;Stryker=[bool]$Entry['Stryker']}
        if($Entry['ResumeFrom']){
            $resume=Join-Path $directory 'resume/mutation.json'
            [void][IO.Directory]::CreateDirectory((Split-Path $resume))
            Copy-Item -LiteralPath $Entry.ResumeFrom -Destination $resume
            Copy-Item -LiteralPath ($Entry.ResumeFrom+'.context.json') -Destination ($resume+'.context.json')
            $descriptor.ResumeReportSha256=(Get-FileHash $resume).Hash
            $descriptor.ResumeContextSha256=(Get-FileHash ($resume+'.context.json')).Hash
        }
        $descriptorPath=Join-Path $directory 'mutation.json';Write-MutatorJson $descriptorPath $descriptor
        $innerPath=Join-Path $directory 'run/packages/p0000'
        # The host owns directory creation: nested CreateDirectory over this SMB mount can
        # create a directory and nevertheless return FILE_NOT_FOUND to the Windows client.
        [void][IO.Directory]::CreateDirectory($innerPath)
        # Stryker's report paths are fixed and also prepared on the host for SMB compatibility.
        [void][IO.Directory]::CreateDirectory((Join-Path $innerPath 'stryker/reports'))
        $State.Container.StatePath=Join-Path $innerPath 'state.json';$State.Container.ProgressPath=Join-Path $innerPath 'mutants.jsonl'
        $State.Container.JobPath=$directory;$State.Phase='Baseline'
        $State.Container.StrykerProgressPath=Join-Path $innerPath 'stryker.jsonl'
        Write-MutatorJson $StatePath $State
        $scriptFile=Join-Path $guest.Share 'mutator/modules/FrenchExDev.Mutator.PoSh/resources/containers/jobs/Invoke-GuestMutation.ps1'
        if($Run['WindowsGuestJobTimeoutSeconds']){
            $jobDeadline=(Get-MutatorUtcNow).AddSeconds($Run.WindowsGuestJobTimeoutSeconds)
            if($jobDeadline -lt $deadline){$deadline=$jobDeadline}
        }
        Write-MutatorJson (Join-Path $directory 'request.json') @{RunId=$guest.RunId;JobId=$id;Type='PSMutantPackage';FixtureSha256=(Get-FileHash $scriptFile).Hash
            DescriptorSha256=(Get-FileHash $descriptorPath).Hash;TimeoutSeconds=([int][math]::Max(1,($deadline-(Get-MutatorUtcNow)).TotalSeconds))}
        do{
            $result=Read-MutatorJson (Join-Path $directory 'result.json')
            if($result){break}
            if(Test-Path $stopPath){Write-MutatorJson (Join-Path $directory 'stop.json') @{Reason='UserRequested'}}
            if((Get-MutatorUtcNow) -ge $deadline){
                Write-MutatorJson (Join-Path $directory 'stop.json') @{Reason='TimedOut'}
                # Give the guest runner time to publish its timeout and partial report before shutdown.
                if((Get-MutatorUtcNow) -ge $deadline.AddMinutes(2)){throw 'The Windows mutation job timed out without returning its final receipt.'}
            }
            if(!(Get-MutatorOwnedGuest $guest).State.Running){throw 'The Windows guest exited during mutation.'}
            Start-Sleep -Seconds 2
        }while($true)
        $inner=Read-MutatorJson $State.Container.StatePath
        # Preserve even failed/partial reports and runtime provenance; transport success is insufficient.
        if(Test-Path $innerPath){
            Copy-MutatorTree $innerPath (Join-Path $artifacts 'windows-reports')
            # Existing failure readers/exporters consume the canonical package report locations.
            Get-ChildItem $innerPath -File -Filter 'mutation*.json' | ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination $artifacts -Force}
            if(Test-Path (Join-Path $innerPath 'stryker')){Copy-MutatorTree (Join-Path $innerPath 'stryker') (Join-Path $artifacts 'stryker')}
        }
        if($inner){foreach($key in @('PSMutant','Stryker','ContextSha256','SourceSha256','PreparationMs','StagedSubtrees','TestOrder','FailedPhase')){if($inner.Contains($key)){$State[$key]=$inner[$key]}}}
        Confirm-MutatorGuestMutationResult $result $inner $guest.RunId $id -RequireStryker:([bool]$Entry['Stryker'])
        if($Entry['Stryker']){
            $report=Join-Path $artifacts 'stryker/reports/mutation-report.json'
            if(!(Test-Path $report) -or (Get-FileHash $report).Hash -cne $State.Stryker.ReportSha256){throw 'The Windows Stryker report fingerprint differs or its report is absent.'}
            $State.Stryker.Report=$report
        }
        if((Get-MutatorUtcNow) -ge $deadline){throw 'The Windows mutation job exceeded its allotted time.'}
        if((Get-MutatorSourceSnapshot $Entry.ModulePath).Sha256 -cne $before.Sha256){throw 'Module source changed during Windows mutation.'}
        $State.Outcome='Success';$State.Phase='Completed'
    }finally{
        # Provisioning may throw after creating a container; its owned guest receipt still permits cleanup.
        if(Test-Path (Join-Path $guestPath 'guest.json')){
            try{$null=Stop-MutatorGuestBase $guestPath}
            catch{
                $State.Container.CleanupError=$_.Exception.Message
                if($State.Outcome -eq 'Success'){throw 'The Windows mutation completed but its guest could not be shut down.'}
            }
        }
    }
}
