#requires -Version 7.6
param(
    [string]$Root='C:\mutator',
    [string]$JobsDirectory='\\host.lan\Data\jobs',
    [string]$ContextPath=(Join-Path $PSScriptRoot 'guest-context.json'),
    [string]$PowerShellExecutable=(Join-Path $PSHOME 'pwsh.exe'),
    [uri]$ControlBaseUri='http://host.lan:8765/',
    [switch]$Once
)
$ErrorActionPreference='Stop'
$context=Get-Content $ContextPath -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$jobs=$JobsDirectory
while($true){
    foreach($directory in @(Get-ChildItem -LiteralPath $jobs -Directory -ErrorAction Ignore)){
        if($directory.Name -notmatch '^[a-f0-9]{32}$'){continue}
        $request=Join-Path $directory.FullName 'request.json'
        $resultPath=Join-Path $directory.FullName 'result.json'
        if(!(Test-Path $request) -or (Test-Path $resultPath)){continue}
        $result=@{RunId=$context.RunId;JobId=$directory.Name;Outcome='Running';StartedUtc=[datetime]::UtcNow.ToString('O')}
        try{
            $job=Get-Content $request -Raw|ConvertFrom-Json -AsHashtable -DateKind String
            if($job.RunId -cne $context.RunId -or $job.JobId -cne $directory.Name -or $job.Type -cnotin @('AgQualification','PSMutantPackage')){throw 'Unsupported or foreign guest job.'}
            $mutation=$job.Type -ceq 'PSMutantPackage'
            $scriptFile=Join-Path $Root $(if($mutation){'modules/FrenchExDev.Mutator.PoSh/resources/containers/jobs/Invoke-GuestMutation.ps1'}else{'modules/FrenchExDev.Mutator.PoSh/resources/containers/probes/Test-WindowsAgImage.ps1'})
            if((Get-FileHash $scriptFile).Hash -cne $job.FixtureSha256){throw 'The guest qualification fixture fingerprint differs.'}
            $timeout=600
            if($mutation){
                if((Get-FileHash (Join-Path $directory.FullName 'mutation.json')).Hash -cne $job.DescriptorSha256){throw 'The Windows mutation descriptor fingerprint differs.'}
            }
            if($mutation -or $job.ContainsKey('TimeoutSeconds')){
                [int]$timeout=0
                if(![int]::TryParse([string]$job.TimeoutSeconds,[ref]$timeout) -or $timeout -lt 1 -or $timeout -gt 86400){throw 'Invalid Windows mutation timeout.'}
            }
            $start=[Diagnostics.ProcessStartInfo]::new($PowerShellExecutable)
            $parameter=if($mutation){'JobDirectory'}else{'ProofDirectory'}
            # The owned bootstrap initializes UTF-8 before the selected fixture
            # writes its first record. Keep paths as literal process arguments.
            foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'Invoke-GuestJobProcess.ps1'),'-ScriptFile',$scriptFile,'-ParameterName',$parameter,'-Directory',$directory.FullName,'-Root',$Root,'-JobsDirectory',$JobsDirectory)){$start.ArgumentList.Add($argument)}
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
            $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$started=$false
            $controlWorker=$null;$controlToken=$null;$controlPending=$null
            try{
                if($mutation){
                    # A separate runspace keeps stop delivery independent of SMB report writes.
                    $controlToken=[Threading.CancellationTokenSource]::new()
                    $controlWorker=[powershell]::Create()
                    [void]$controlWorker.AddCommand((Join-Path $PSScriptRoot 'Watch-GuestControl.ps1')).AddParameter('RunId',$context.RunId).AddParameter('JobId',$directory.Name).AddParameter('CancellationToken',$controlToken.Token).AddParameter('Root',$Root).AddParameter('ControlBaseUri',$ControlBaseUri)
                    $controlPending=$controlWorker.BeginInvoke()
                }
                $started=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
                $deadline=[datetimeoffset]::UtcNow.AddSeconds($timeout)
                $completionDeadline=$deadline;$stopRequested=$false;$timedOut=$false
                $local=Join-Path $Root ('mutation-jobs/'+$directory.Name+'/run/packages/p0000')
                $mirror=Join-Path $directory.FullName 'run/packages/p0000'
                do{
                    $exited=$process.WaitForExit(1000)
                    if($mutation -and !$stopRequested){
                        if([datetimeoffset]::UtcNow -ge $deadline){
                            # Let PSMutant finish its partial report before enforcing the hard deadline.
                            [IO.File]::WriteAllText((Join-Path $directory.FullName 'stop.json'),'{"Reason":"TimedOut"}')
                            $timedOut=$true;$stopRequested=$true
                        }elseif(Test-Path (Join-Path $directory.FullName 'stop.json')){
                            $control=Get-Content (Join-Path $directory.FullName 'stop.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
                            $stopRequested=$true;$timedOut=$control['Reason'] -ceq 'TimedOut'
                        }
                        if($stopRequested){$completionDeadline=[datetimeoffset]::UtcNow.AddSeconds(120)}
                    }
                    if($mutation -and $stopRequested){
                        $localStop=Join-Path $Root ('mutation-jobs/'+$directory.Name+'/stop.json')
                        if(Test-Path -LiteralPath (Split-Path $localStop)){
                            # PSMutant polls a local file. The guest supervisor transports the
                            # shared signal, avoiding stale negative SMB lookups in its loop.
                            [IO.File]::WriteAllText($localStop,'{"Stop":true}')
                        }
                    }
                    if($mutation -and (Test-Path $local)){
                        if(!(Test-Path -LiteralPath $mirror -PathType Container)){throw 'The host did not prepare the Windows mutation report directory.'}
                        foreach($name in @('state.json','mutants.jsonl','stryker.jsonl')){
                            $file=Join-Path $local $name
                            if(Test-Path $file){
                                # Replace atomically: readers never see a half-written state/progress file.
                                $temporary=Join-Path $mirror ($name+'.tmp')
                                try{
                                    # The worker replaces state.json atomically. File.Copy holds a
                                    # source handle without Delete sharing and can break that replace.
                                    $reader=[IO.FileStream]::new($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                                    try{
                                        $writer=[IO.FileStream]::new($temporary,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::Read)
                                        try{$reader.CopyTo($writer)}finally{$writer.Dispose()}
                                    }finally{$reader.Dispose()}
                                    [IO.File]::Move($temporary,(Join-Path $mirror $name),$true)
                                }catch [IO.IOException]{$result.ProgressMirrorError=$_.Exception.Message}
                            }
                        }
                    }
                }while(!$exited -and [datetimeoffset]::UtcNow -lt $completionDeadline)
                if(!$exited){$process.Kill($true);$process.WaitForExit();$result.Outcome='TimedOut'}
                if($mutation -and (Test-Path $local)){
                    # Package cleanup has finished; retain reports and contexts, never a live sandbox.
                    Get-ChildItem $local -File | ForEach-Object {
                        $target=Join-Path $mirror $_.Name
                        [IO.File]::Copy($_.FullName,$target,$true)
                    }
                    $report=Join-Path $local 'stryker/reports/mutation-report.json'
                    if(Test-Path $report){[IO.File]::Copy($report,(Join-Path $mirror 'stryker/reports/mutation-report.json'),$true)}
                }
                [IO.File]::WriteAllText((Join-Path $directory.FullName 'guest.stdout.log'),$stdout.GetAwaiter().GetResult())
                [IO.File]::WriteAllText((Join-Path $directory.FullName 'guest.stderr.log'),$stderr.GetAwaiter().GetResult())
                $result.ExitCode=$process.ExitCode
                if($exited){$result.Outcome=if($process.ExitCode -eq 0){'Success'}else{'Failed'}}
                if($stopRequested){$result.Outcome=if($timedOut){'TimedOut'}else{'Interrupted'}}
            }finally{
                if($started -and !$process.HasExited){$process.Kill($true);$process.WaitForExit()}
                $process.Dispose()
                if($controlWorker){$controlToken.Cancel();$null=$controlWorker.EndInvoke($controlPending);$controlWorker.Dispose();$controlToken.Dispose()}
            }
        }catch{$result.Outcome='Failed';$result.Error=$_.Exception.Message}
        $result.CompletedUtc=[datetime]::UtcNow.ToString('O')
        $temporary=$resultPath+'.tmp'
        [IO.File]::WriteAllText($temporary,($result|ConvertTo-Json -Depth 5))
        [IO.File]::Move($temporary,$resultPath,$true)
    }
    if($Once){break}
    Start-Sleep -Seconds 2
}
