function Test-MutatorWindowsPlatform {
    [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)
}

function Test-MutatorLinuxPlatform {
    [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)
}

function Get-MutatorHostPlatform {
    if(Test-MutatorWindowsPlatform){return 'Windows'}
    if(Test-MutatorLinuxPlatform){return 'Linux'}
    'MacOS'
}

function Get-MutatorHostMemorySample {
    $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $used=([long]$os.TotalVisibleMemorySize-[long]$os.FreePhysicalMemory)*1024
    if($used -le 0){throw 'The host memory sample is invalid.'}
    $processes=@(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction Stop | Where-Object {$_.ProcessId -ne $PID} | ForEach-Object {
        @{Id=[int]$_.ProcessId;ParentId=[int]$_.ParentProcessId;StartedUtc=$_.CreationDate.ToUniversalTime().ToString('O');WorkingSetBytes=[long]$_.WorkingSetSize
            Executable=$_.ExecutablePath;CommandLine=$_.CommandLine}
    })
    @{Utc=[datetime]::UtcNow.ToString('O');UsedBytes=$used;TotalBytes=[long]$os.TotalVisibleMemorySize*1024;Processes=$processes}
}

function Get-MutatorMemoryRecoveryTarget {
    param([Collections.IDictionary]$Sample,[Collections.IDictionary]$Settings)
    if($Sample.UsedBytes -lt $Settings.TriggerBytes){return}
    foreach($candidate in @($Sample.Processes|Where-Object {$_.Id -ne $PID -and $_.WorkingSetBytes -ge $Settings.MinimumProcessBytes}|Sort-Object WorkingSetBytes -Descending)){
        try{$owned=Get-MutatorOwnedMemoryRun $candidate}catch{$owned=$null}
        if($owned){return $candidate}
    }
}

function Invoke-MutatorMemoryRecovery {
    param([Collections.IDictionary]$Target,[string]$Directory)
    $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Target.Id) -ErrorAction Stop
    if(!$current -or $current.Name -ine 'pwsh.exe' -or $current.CreationDate.ToUniversalTime().ToString('O') -cne $Target.StartedUtc -or $current.ParentProcessId -ne $Target.ParentId){throw 'Memory recovery refused: the selected process identity changed.'}
    if($Target.Id -eq $PID){throw 'The watchdog cannot stop itself.'}
    $owned=Get-MutatorOwnedMemoryRun $Target $current.CommandLine
    if(!$owned){throw 'Memory recovery requires a registered owned Mutator worker; shells and editor sessions are excluded.'}
    $recoveryEvent=@{Utc=[datetime]::UtcNow.ToString('O');Id=$Target.Id;StartedUtc=$Target.StartedUtc;ParentId=$Target.ParentId;ReclaimedCandidateBytes=$Target.WorkingSetBytes
        Kind='Mutator';Outcome='Stopping'}
    $file=Join-Path $Directory ('events/'+[guid]::NewGuid().ToString('N')+'.json')
    Write-MutatorJson $file $recoveryEvent
    $recoveryLock=$null
    try{
            $runPath=$owned.Path
            $run=$owned.Run
            try{$recoveryLock=[IO.File]::Open((Join-Path $runPath 'memory-recovery.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
            catch [IO.IOException]{$recoveryEvent.Outcome='RecoveryAlreadyOwned';Write-MutatorJson $file $recoveryEvent;return $recoveryEvent}
            # Let partial evidence finish, then use the owned-run stop path if the worker remains alive.
            $null=Stop-MutatorRun $runPath
            $deadline=[datetimeoffset]::UtcNow.AddSeconds(20)
            while(@($owned.Identities|Where-Object {Test-MutatorProcess $_}).Count -and [datetimeoffset]::UtcNow -lt $deadline){Start-Sleep -Seconds 1}
            if(@($owned.Identities|Where-Object {Test-MutatorProcess $_}).Count){$null=Stop-MutatorRun $runPath -Force}
            $deadline=[datetimeoffset]::UtcNow.AddSeconds(20)
            while(@($owned.Identities|Where-Object {Test-MutatorProcess $_}).Count -and [datetimeoffset]::UtcNow -lt $deadline){Start-Sleep -Seconds 1}
            if(@($owned.Identities|Where-Object {Test-MutatorProcess $_}).Count){throw 'Owned workers are still alive; memory recovery will not start replacements.'}
            $view=Get-MutatorRun $runPath
            $recoveryEvent.Restarts=@()
            foreach($entry in $run.Packages){
                $report=Join-Path $runPath ('packages/'+$entry.Id+'/mutation.json')
                $partial=Read-MutatorJson $report
                $completed=@($view.Packages|Where-Object {$_['Id'] -ceq $entry.Id -and $_['Outcome'] -ceq 'Success'}).Count
                if(!$completed){
                    $options=Get-MutatorRestartOptions $run $entry (Split-Path $runPath)
                    $options.Background=$true
                    $mode='FreshRestart'
                    if($partial -and $partial['mode'] -ceq 'Partial'){$options.ResumeFrom=$report;$mode='ResumePartial'}
                    $resumed=Invoke-MutatorRun @options
                    $recoveryEvent.Restarts+=@{Module=$entry.Name;Run=$resumed.Path;Mode=$mode}
                }
            }
            if(!$recoveryEvent.Restarts.Count){$recoveryEvent.Outcome='CompletedBeforeRecovery'}else{$recoveryEvent.Outcome='Restarted'}
    }catch{$recoveryEvent.Outcome='RecoveryFailed';$recoveryEvent.Error=$_.Exception.Message}
    finally{if($recoveryLock){$recoveryLock.Dispose()}}
    Write-MutatorJson $file $recoveryEvent
    $recoveryEvent
}

function Stop-MutatorMemoryProcess {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private action is authorized by starting the memory watchdog; the exact process identity is rechecked here.')]
    [CmdletBinding()]
    param([Collections.IDictionary]$Target)
    if($Target.Id -eq $PID){throw 'The watchdog cannot stop itself.'}
    $process=[Diagnostics.Process]::GetProcessById($Target.Id)
    try{
        if([math]::Abs(($process.StartTime.ToUniversalTime()-[datetime]::Parse($Target.StartedUtc).ToUniversalTime()).TotalSeconds) -ge 1){throw 'The process changed before memory recovery.'}
        $process.Kill($true)
    }finally{$process.Dispose()}
}

function Invoke-MutatorMemoryWatchdogLoop {
    param([string]$Directory)
    $settings=Read-MutatorJson (Join-Path $Directory 'watchdog.json')
    $state=@{Outcome='Monitoring';Utc=[datetime]::UtcNow.ToString('O');UsedBytes=0L;LastAction=$null;Error=$null}
    $cooldown=[datetimeoffset]::MinValue
    try{
        while(!(Test-Path (Join-Path $Directory 'stop.json'))){
            try{
                $sample=Get-MutatorHostMemorySample
                $state.Utc=$sample.Utc;$state.UsedBytes=$sample.UsedBytes;$state.Outcome='Monitoring';$state.Error=$null
                if($sample.UsedBytes -ge $settings.TriggerBytes -and [datetimeoffset]::UtcNow -ge $cooldown){
                    $target=Get-MutatorMemoryRecoveryTarget $sample $settings
                    if($target){$state.LastAction=Invoke-MutatorMemoryRecovery $target $Directory;$state.Outcome=$state.LastAction.Outcome;$state.Error=$state.LastAction['Error'];$cooldown=[datetimeoffset]::UtcNow.AddSeconds(30)}
                    elseif($settings['PodmanMachine']){
                        $state.LastAction=Invoke-MutatorPodmanCacheRecovery $settings.PodmanMachine
                        $state.Outcome=$state.LastAction.Outcome
                        Write-MutatorJson (Join-Path $Directory ('events/'+[guid]::NewGuid().ToString('N')+'.json')) $state.LastAction
                        $cooldown=[datetimeoffset]::UtcNow.AddSeconds(60)
                    }
                    else{$state.Outcome='PressureWithoutOwnedWorker';$state.Error='Host RAM is high but no registered Mutator worker above the minimum reclaimable size was found.'}
                }
            }catch{$state.Outcome='MonitoringFailed';$state.Error=$_.Exception.Message}
            Write-MutatorJson (Join-Path $Directory 'state.json') $state
            Start-Sleep -Seconds $settings.PollSeconds
        }
    }finally{$state.Outcome='Stopped';$state.Utc=[datetime]::UtcNow.ToString('O');Write-MutatorJson (Join-Path $Directory 'state.json') $state}
}
