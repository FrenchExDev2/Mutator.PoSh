function Invoke-MutatorGitImageValidation {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$ModuleRoot,[ValidateSet('Linux','Windows')][string[]]$OS=@('Linux'),
        [ValidateSet('Podman','Docker')][string]$Engine='Podman',[string]$Connection,[string]$OutputDirectory,[ValidateSet('Alpine','Debian')][string]$Distribution='Alpine',
        [ValidateRange(1,1440)][int]$TimeoutMinutes=1440,[string]$Ram='40go',[switch]$UI,[switch]$BaselineOnly,[switch]$Background)
    $root=(Resolve-Path -LiteralPath $ModuleRoot -ErrorAction Stop).ProviderPath
    if(!$OS.Count){throw 'Select at least one validation OS.'}
    $gitDirectory=Resolve-MutatorModuleDirectory $root 'FrenchExDev.QuietCli.Git.PoSh'
    $configuration=Read-MutatorJson (Join-Path $gitDirectory 'test/psmutant.config.json')
    if(!$configuration -or !$configuration['sandboxSubtrees']){throw 'QuietCli Git image validation is not ready: test/psmutant.config.json is missing. The dev tests and CliEnvironment images require a qualified workload before validation can start.'}
    $gitRelative=[IO.Path]::GetRelativePath($root,$gitDirectory).Replace('\','/')
    if($gitRelative -cnotin $configuration.sandboxSubtrees){throw 'The Git module is outside its declared validation dependencies.'}
    if(!$OutputDirectory){$OutputDirectory=Join-Path $script:MutatorRoot ('test/Artifacts/git-images/'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))}
    $output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    if(Test-Path (Join-Path $output 'summary.json')){throw 'Select a fresh validation directory; existing reports are never reused as a new result.'}
    $controller=Read-MutatorJson (Join-Path $output 'controller.json')
    if($controller -and $controller.Id -ne $PID -and (Test-MutatorProcess $controller)){throw 'A controller already owns this validation directory.'}
    if(!$PSCmdlet.ShouldProcess($output,'Validate Git in mounted-source Linux and Windows environments')){return}
    $ownedWatchdog=$null
    try{
    if($Background){
        if(!(Test-MutatorWindowsPlatform)){throw 'Detached Git validation controllers are currently qualified only on Windows hosts.'}
        $requestPath=Join-Path $output 'controller.request.json'
        if(Test-Path $requestPath){throw 'Select a fresh validation directory; a retained controller request already exists.'}
        $null=ConvertTo-MutatorMemoryLimit $Ram
        Write-MutatorJson $requestPath @{ModuleRoot=$root;OS=$OS;Engine=$Engine;Connection=$Connection;OutputDirectory=$output;Distribution=$Distribution;TimeoutMinutes=$TimeoutMinutes;Ram=$Ram;BaselineOnly=[bool]$BaselineOnly}
        $identity=Start-MutatorDetachedWorker -RunDirectory $output -Kind GitValidation
        Write-MutatorJson (Join-Path $output 'controller.json') $identity
        return [pscustomobject]@{Path=$output;Outcome='Starting';Controller=$identity}
    }
    Import-Module (Join-Path $root 'FrenchExDev.CliEnvironment.PoSh/FrenchExDev.CliEnvironment.PoSh.psd1') -DisableNameChecking
    Set-MutatorContainerContext -Engine $Engine -Connection $Connection
    if($IsWindows){
        $watchdog=@{LimitGB=((ConvertTo-MutatorMemoryLimit $Ram)/1e9);Path=(Join-Path $output 'watchdog')}
        if($Engine -eq 'Podman' -and $Connection){$watchdog.PodmanMachine=$Connection -creplace '-root$',''}
        $ownedWatchdog=Start-MutatorMemoryWatchdog @watchdog
    }
    $run=@{Id=[guid]::NewGuid().ToString('N');Path=$output;Outcome='Running';ContainerEngine=$Engine;Connection=$Connection;Platforms=@{}}
    $run.SourceFingerprints=@{}
    foreach($dependency in @(@($configuration.sandboxSubtrees)+@('FrenchExDev.DevPoSh.PoSh','FrenchExDev.CliEnvironment.PoSh')|Sort-Object -Unique)){
        if($dependency -cnotmatch '^(?:QuietCliEcosystem/)?FrenchExDev\.[A-Za-z0-9_.-]+\.PoSh$'){throw 'Invalid Git dependency module name.'}
        $run.SourceFingerprints[$dependency]=(Get-MutatorSourceSnapshot (Join-Path $root $dependency)).Sha256
    }
    $expectedSource=$run.SourceFingerprints[$gitRelative]
    $run.OriginalModuleSha256=$expectedSource
    $assertSources={
        foreach($dependency in $run.SourceFingerprints.Keys){
            if((Get-MutatorSourceSnapshot (Join-Path $root $dependency)).Sha256 -cne $run.SourceFingerprints[$dependency]){
                if($dependency -ceq $gitRelative){throw 'The original Git module changed during validation; start a new campaign.'}
                throw "The dependency $dependency changed during validation; start a new campaign."
            }
        }
    }
    foreach($platform in @('Linux','Windows','MacOS')){
        $pending=if($platform -in $OS){'Pending'}else{'NotSelected'}
        $run.Platforms[$platform]=@{Outcome=$pending;Phase=$pending;Qualified=$false}
    }
    Write-MutatorValidationReport $run -UI:$UI
    foreach($platform in @('Linux','Windows'|Where-Object {$_ -in $OS})){
        if(Test-MutatorValidationStop $output $run.Id){
            foreach($pending in $OS){
                if($run.Platforms[$pending].Outcome -eq 'Pending'){$run.Platforms[$pending].Outcome='Interrupted';$run.Platforms[$pending].Phase='Interrupted'}
            }
            break
        }
        $state=$run.Platforms[$platform];$state.Outcome='Running';$state.Phase='Building Container'
        $directory=Join-Path $output $platform.ToLowerInvariant();[void][IO.Directory]::CreateDirectory($directory)
        $container=$null
        try{
            Write-MutatorValidationReport $run -UI:$UI
            if($platform -eq 'Windows'){
                $seed=Join-Path $root 'FrenchExDev.CliEnvironment.PoSh/test/Artifacts/container-bases/windows/seed/base.json'
                if(!(Test-Path $seed)){
                    $base=New-CliEnvironmentGitImage -ModuleRoot $root -Platform Windows -BaseOnly -Engine $Engine -Connection $Connection -OutputDirectory (Join-Path $directory 'bootstrap-build')
                    if($base.Outcome -ne 'Built'){throw $base.Error}
                    $guest=Start-CliEnvironmentWindowsGuest -ModuleRoot $root -Kind Base -Engine $Engine -Connection $Connection -OutputDirectory (Join-Path $directory 'base-guest')
                    if($guest.Outcome -ne 'Running'){throw $guest.Error}
                    $state.Phase='Preparing Windows Base';$state.Guest=$guest.Path
                    $deadline=(Get-MutatorUtcNow).AddMinutes([math]::Min(120,$TimeoutMinutes))
                    while(!(Test-Path (Join-Path $guest.Share 'base-ready.json'))){
                        $failed=Read-MutatorJson (Join-Path $guest.Share 'base-failed.json');if($failed){throw $failed.Error}
                        Write-MutatorValidationReport $run -UI:$UI
                        if((Get-MutatorUtcNow) -ge $deadline){throw [TimeoutException]::new('Windows base preparation timed out; its disk and logs are retained.')}
                        Start-Sleep -Seconds 5
                    }
                    $null=Export-CliEnvironmentWindowsBase -GuestPath $guest.Path -Destination (Split-Path $seed)
                }
            }
            Assert-MutatorValidationActive $output $run.Id
            $built=New-CliEnvironmentGitImage -ModuleRoot $root -Platform $platform -Distribution $Distribution -Engine $Engine -Connection $Connection -OutputDirectory (Join-Path $directory 'build')
            if($built.Outcome -ne 'Built'){throw $built.Error}
            Assert-MutatorValidationActive $output $run.Id
            $state.Image=$built.Image;$state.ImageId=$built.ImageId;$state.Phase='Qualifying Environment'
            & $assertSources
            $reports=Join-Path $directory 'reports';[void][IO.Directory]::CreateDirectory($reports)
            if($platform -eq 'Linux'){
                $state.Environment=Test-CliEnvironmentGitImage -ModuleRoot $root -Image $built.ImageId -Distribution $Distribution -Engine $Engine -Connection $Connection -OutputDirectory (Join-Path $directory 'qualification')
                Assert-MutatorValidationActive $output $run.Id
                $name='mutator-linux-git-'+$run.Id
                $mounts=@(Get-CliEnvironmentSourceMount -ModuleRoot $root -Distribution $Distribution)
                $arguments=@('run','--detach','--name',$name,'--label',('org.frenchexdev.mutator.validation='+$run.Id),'--network','none','--memory','4096m','--memory-swap','4096m','--cpus','2',
                    '--volume',($reports+':/reports:rw'))+$mounts+@('--entrypoint','pwsh',$built.ImageId,'-NoProfile','-File','/source/FrenchExDev.Mutator.PoSh/resources/validation/Invoke-GitImageWorkload.ps1','-SourceRoot','/source','-ReportRoot','/reports','-Platform','Linux','-RunId',$run.Id,'-OriginalModuleSha256',$expectedSource)
                if($BaselineOnly){$arguments+=@('-BaselineOnly')}
                $created=Invoke-MutatorContainerCommand -Arguments $arguments -Directory $directory -Connection $Connection
                if($created.Outcome -ne 'Success' -or $created.Stdout.Trim() -notmatch '^[a-f0-9]{64}$'){throw 'The owned Linux workload could not start.'}
                $container=$created.Stdout.Trim()
                $state.ContainerId=$container
            }else{
                Initialize-MutatorGitImageReports -Path (Join-Path $directory 'git-guest/share/reports') -BaselineOnly:$BaselineOnly
                $guest=Start-CliEnvironmentWindowsGuest -ModuleRoot $root -Kind Git -ImageId $built.ImageId -Engine $Engine -Connection $Connection -OutputDirectory (Join-Path $directory 'git-guest') -Workload 'FrenchExDev.Mutator.PoSh/resources/validation/Invoke-GitImageWorkload.ps1' -WorkloadRequest @{RunId=$run.Id;OriginalModuleSha256=$expectedSource;BaselineOnly=[bool]$BaselineOnly}
                $state.Guest=$guest.Path
                if($guest.Outcome -ne 'Running'){throw $guest.Error}
                $reports=Join-Path $guest.Share 'reports'
            }
            $state.Reports=$reports
            $state.Phase='Executing';$deadline=(Get-MutatorUtcNow).AddMinutes($TimeoutMinutes)
            while(!(Test-Path (Join-Path $reports 'result.json'))){
                if(Test-MutatorValidationStop $output $run.Id){
                    $run.StopRequested=$true
                    Write-MutatorJson (Join-Path $reports 'stop.json') @{RunId=$run.Id;Reason='UserRequested'}
                    $state.Phase='Stopping'
                }
                if($platform -eq 'Windows'){$failed=Read-MutatorJson (Join-Path $guest.Share 'module-failed.json');if($failed){throw $failed.Error}}
                $progress=Read-MutatorJson (Join-Path $reports 'progress.json');if($progress){$state.Progress=$progress;$state.Phase=$progress.Phase}
                Write-MutatorValidationReport $run -UI:$UI
                if((Get-MutatorUtcNow) -ge $deadline){throw [TimeoutException]::new('Git validation timed out; reports and owned container are retained.')}
                if($container){
                    $inspect=Invoke-MutatorContainerCommand -Arguments @('inspect',$container) -Directory $directory -Connection $Connection
                    if($inspect.Outcome -ne 'Success'){
                        [IO.File]::WriteAllText((Join-Path $directory 'inspection.stderr.log'),[string]$inspect.Stderr)
                        Write-MutatorJson (Join-Path $directory 'inspection.failure.json') @{Outcome=$inspect.Outcome;ExitCode=$inspect.ExitCode;Failure=$inspect.Failure}
                        throw ('The Linux workload state could not be inspected ('+$inspect.Outcome+'); see inspection.failure.json.')
                    }
                    if(!@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0].State.Running){
                        # Guest writes and the Windows bind mount can become visible
                        # in a different order from the container's stopped state.
                        $flushDeadline=(Get-MutatorUtcNow).AddSeconds(10)
                        while(!(Test-Path (Join-Path $reports 'result.json')) -and (Get-MutatorUtcNow) -lt $flushDeadline){Start-Sleep -Milliseconds 200}
                        if(!(Test-Path (Join-Path $reports 'result.json'))){throw 'The Linux workload exited before returning a report.'}
                    }
                }
                Start-Sleep -Seconds 5
            }
            $result=Read-MutatorJson (Join-Path $reports 'result.json')
            if(!$result -or $result.RunId -cne $run.Id -or $result.OS -cne $platform -or $result.OriginalModuleSha256 -cne $expectedSource){throw 'The validation result belongs to another run, OS or source snapshot.'}
            & $assertSources
            if(!$BaselineOnly -and $result.Outcome -ceq 'Success' -and $result.FullGateSatisfied -ne $true){throw 'The complete validation gate was not satisfied.'}
            $state.Result=$result;$state.Reports=$reports;$state.Outcome=$result.Outcome;$state.Phase=$(if($result.Outcome -eq 'Interrupted'){'Interrupted'}else{'Completed'});$state.Qualified=($result.Outcome -ceq 'Success' -and $result.OS -ceq $platform -and $result.FullGateSatisfied -eq $true)
            if($platform -eq 'Windows'){Copy-MutatorTree $reports (Join-Path $directory 'reports')}
            if($container){
                $wait=Invoke-MutatorContainerCommand -Arguments @('wait',$container) -Directory $directory -Connection $Connection -TimeoutSeconds 60
                if($wait.Outcome -ne 'Success' -or ($wait.Stdout.Trim() -ne '0' -and $result.Outcome -ceq 'Success')){throw 'The workload exit contradicts its result.'}
                $logs=Invoke-MutatorContainerCommand -Arguments @('logs',$container) -Directory $directory -Connection $Connection
                [IO.File]::WriteAllText((Join-Path $directory 'workload.stdout.log'),$logs.Stdout);[IO.File]::WriteAllText((Join-Path $directory 'workload.stderr.log'),$logs.Stderr)
            }
        }catch{
            $state.Outcome=$(if($_.Exception -is [OperationCanceledException]){'Interrupted'}else{'Failed'})
            $state.Phase=$state.Outcome;$state.Qualified=$false;$state.Error=Protect-MutatorDiagnostic $_.Exception.Message
        }
        finally{
            if($platform -eq 'Windows' -and $state['Guest']){
                $guestRun=Read-MutatorJson (Join-Path $state.Guest 'guest.json')
                if($guestRun -and $guestRun['ContainerId']){
                    $inspection=Invoke-MutatorContainerCommand -Arguments @('inspect',$guestRun.ContainerId) -Directory $directory -Connection $Connection
                    if($inspection.Outcome -eq 'Success'){
                        $owned=@($inspection.Stdout|ConvertFrom-Json -AsHashtable)[0]
                        if($owned.Id -ceq $guestRun.ContainerId -and $owned.Config.Labels['org.frenchexdev.cli.run'] -ceq $guestRun.Id -and $owned.State.Running){
                            $null=Invoke-MutatorContainerCommand -Arguments @('stop','--time','180',$guestRun.ContainerId) -Directory $directory -Connection $Connection -TimeoutSeconds 240
                        }
                    }
                }
            }
            if($container){
                $inspection=Invoke-MutatorContainerCommand -Arguments @('inspect',$container) -Directory $directory -Connection $Connection
                if($inspection.Outcome -eq 'Success'){
                    $owned=@($inspection.Stdout|ConvertFrom-Json -AsHashtable)[0]
                    if($owned.Id -ceq $container -and $owned.Config.Labels['org.frenchexdev.mutator.validation'] -ceq $run.Id){
                        if($owned.State.Running -and $state.Outcome -ne 'Success' -and (Test-Path (Join-Path $reports 'mutations/FrenchExDev.QuietCli.Git.PoSh/runs/run.json'))){
                            $stop=Invoke-MutatorContainerCommand -Arguments @('exec',$container,'pwsh','-NoProfile','-File','/source/FrenchExDev.Mutator.PoSh/resources/validation/Stop-GitImageWorkload.ps1','-ReportRoot','/reports') -Directory $directory -Connection $Connection -TimeoutSeconds 60
                            $state.StopRequest=@{Outcome=$stop.Outcome}
                            if($stop.Outcome -eq 'Success'){
                                $stopDeadline=(Get-MutatorUtcNow).AddSeconds(60)
                                while(!(Test-Path (Join-Path $reports 'result.json')) -and (Get-MutatorUtcNow) -lt $stopDeadline){Start-Sleep -Milliseconds 500}
                            }else{$state.StopRequest.Failure=$stop.Failure}
                        }
                        if($owned.State.Running){$null=Invoke-MutatorContainerCommand -Arguments @('stop','--time','30',$container) -Directory $directory -Connection $Connection}
                        $logs=Invoke-MutatorContainerCommand -Arguments @('logs',$container) -Directory $directory -Connection $Connection
                        [IO.File]::WriteAllText((Join-Path $directory 'workload.stdout.log'),$logs.Stdout);[IO.File]::WriteAllText((Join-Path $directory 'workload.stderr.log'),$logs.Stderr)
                        if($state.Outcome -eq 'Success'){$null=Invoke-MutatorContainerCommand -Arguments @('rm',$container) -Directory $directory -Connection $Connection}
                        else{
                            $state.RetainedContainer=$container
                            $state.PartialReportAvailable=(Test-Path (Join-Path $reports 'mutations/FrenchExDev.QuietCli.Git.PoSh/runs/packages/p0000/mutation.json'))
                        }
                    }
                }
            }
            Write-MutatorValidationReport $run -UI:$UI
        }
    }
    $outcomes=@($OS|ForEach-Object{$run.Platforms[$_].Outcome})
    $run.Outcome=if($outcomes -contains 'Failed'){'Failed'}elseif($outcomes -contains 'Interrupted'){'Interrupted'}else{'Success'}
    Write-MutatorValidationReport $run -UI:$UI
    [pscustomobject]@{Path=$run.Path;Outcome=$run.Outcome;Platforms=$run.Platforms}
    }finally{if($ownedWatchdog){$null=Stop-MutatorMemoryWatchdog -Path (Join-Path $output 'watchdog') -Confirm:$false}}
}
