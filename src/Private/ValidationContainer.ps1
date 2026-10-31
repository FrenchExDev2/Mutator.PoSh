function Get-MutatorValidationImage {
    param([string]$Platform,[string]$Source,[string]$OutputDirectory,[string]$Connection,[string[]]$ModuleNames=@())
    $tools=@(foreach($name in $ModuleNames){
        $path=Join-Path $Source $name
        $metadata=Read-MutatorJson (Join-Path $path 'containers/image.json')
        if($metadata -and $metadata.Platforms[$Platform]['Binary']){$path}
    })
    if($tools.Count -gt 1){throw 'Select one binary contributor per validation run so its pinned tool image remains unambiguous.'}
    if($tools.Count){
        if($Platform -eq 'Linux'){$null=Export-MutatorContainerBaseDefinition -ModuleRoot $Source}
        else{$null=Get-MutatorValidationBaseImage $Platform $Source $OutputDirectory $Connection}
        $built=New-MutatorContainerImage -ModulePath $tools[0] -Platform $Platform -OutputDirectory (Join-Path $OutputDirectory 'tool-build') -Connection $Connection -Reuse
        $runtime=Get-MutatorContainerRuntime $Source
        return @{ImageId=$built.ImageId;Fingerprint=$(if($Platform -eq 'MacOS'){$runtime.MacFingerprint}else{$runtime.Fingerprint});Reused=$built.Reused;ToolModule=(Split-Path $tools[0] -Leaf)}
    }
    Get-MutatorValidationBaseImage $Platform $Source $OutputDirectory $Connection
}

function Get-MutatorValidationBaseImage {
    param([string]$Platform,[string]$Source,[string]$OutputDirectory,[string]$Connection)
    $definition=Export-MutatorContainerBaseDefinition -ModuleRoot $Source
    $runtime=Get-MutatorContainerRuntime $Source
    $variant=if($Platform -eq 'Linux'){'Alpine'}else{$Platform}
    $image=$definition.Images[$variant]
    $expected=if($Platform -eq 'MacOS'){$runtime.MacFingerprint}else{$runtime.Fingerprint}
    $inspection=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$image) -Directory $Source -Connection $Connection
    if($inspection.Outcome -eq 'Success'){
        $built=@($inspection.Stdout|ConvertFrom-Json -AsHashtable)[0]
        $kind=if($Platform -eq 'Linux'){$true}else{$built.Config.Labels['org.frenchexdev.mutator.base'] -ceq ($Platform.ToLowerInvariant()+'-seed')}
        if($kind -and $built.Os -ceq 'linux' -and $built.Id -match '^(sha256:)?[a-f0-9]{64}$' -and $built.Config.Labels['org.frenchexdev.mutator.fingerprint'] -ceq $expected){return @{ImageId=$built.Id;Fingerprint=$expected;Reused=$true}}
        throw 'The existing validation image does not match the pinned runtime fingerprint.'
    }
    if($Platform -ne 'Linux'){
        $seed=Join-Path $script:MutatorRoot ('test/Artifacts/container-bases/'+$Platform.ToLowerInvariant()+'/seed')
        if(!(Test-Path (Join-Path $seed 'base.json'))){throw ('Prepare and export the cleanly stopped '+$Platform+' base before validation. Missing: '+$seed)}
        $receipt=Read-MutatorJson (Join-Path $seed 'base.json')
        if($receipt['Fingerprint'] -cne $expected -or $receipt['CleanShutdown'] -ne $true){throw ('Prepare and export the '+$Platform+' base for runtime '+$expected+'. The retained seed is stale or was not cleanly stopped.')}
        $destination=Join-Path $Source ('FrenchExDev.Mutator.PoSh/test/Artifacts/container-bases/'+$Platform.ToLowerInvariant()+'/seed')
        Copy-MutatorTree $seed $destination
    }
    $built=New-MutatorContainerImage -ModulePath (Join-Path $Source 'FrenchExDev.Mutator.PoSh') -BaseVariant $variant -Connection $Connection -OutputDirectory (Join-Path $OutputDirectory 'build')
    @{ImageId=$built.ImageId;Fingerprint=$expected;Reused=$false}
}

function Invoke-MutatorValidationContainer {
    param([string]$Platform,[string]$Source,[Collections.IDictionary]$Request,[string]$OutputDirectory,[string]$Connection,[Collections.IDictionary]$Run,[switch]$UI)
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    $image=Get-MutatorValidationImage -Platform $Platform -Source $Source -OutputDirectory $OutputDirectory -Connection $Connection -ModuleNames $Request.Modules
    $memory=if($Platform -eq 'Linux'){[math]::Min(4096,$Request.MemoryBudgetMiB)}else{6144}
    if($Request.MemoryBudgetMiB -lt $memory){throw 'Windows/macOS validation requires at least 6144 MiB of memory budget.'}
    $Request.MemoryBudgetMiB=if($Platform -eq 'Linux'){$memory}else{4096}
    if($Platform -ne 'Linux'){$null=Test-MutatorGuestHost -Image $image.ImageId -Connection $Connection -OutputDirectory (Join-Path $OutputDirectory 'preflight') -MemoryMiB $memory}
    $payload=Join-Path $OutputDirectory 'payload'
    Copy-MutatorTree $Source (Join-Path $payload 'modules')
    $Request.SourceSha256=(Get-MutatorSourceSnapshot (Join-Path $payload 'modules')).Sha256
    Write-MutatorJson (Join-Path $payload 'request.json') $Request
    $name='mutator-'+$Platform.ToLowerInvariant()+'-validation-'+[guid]::NewGuid().ToString('N')
    $state=$Run.Platforms[$Platform];$state.Phase='Starting';$state.Container=$name;$state.ImageId=$image.ImageId;$state.MemoryMiB=$memory
    $state.Connection=$Connection;$state.ImageReused=$image.Reused;$state.ContainerEngine=$script:MutatorContainerEngine
    $owner='org.frenchexdev.mutator.validation='+$Request.RunId
    $containerArguments=@('create','--name',$name,'--label',$owner,'--pull=never','--memory',($memory.ToString()+'m'),'--memory-swap',($memory.ToString()+'m'),'--cpus','2')
    $root='/opt/validation'
    if($Platform -eq 'Linux'){
        $network=if(@($Request.Modules|Where-Object {Test-Path (Join-Path $Source ($_+'/engine/dotnet-tools.json'))}).Count){'bridge'}else{'none'}
        $state.Network=$network
        $containerArguments+=@(('--network='+$network),'--entrypoint','pwsh',$image.ImageId,'-NoLogo','-NoProfile','-File',($root+'/modules/FrenchExDev.Mutator.PoSh/resources/validation/Invoke-ValidationWorkload.ps1'),'-Root',$root,'-ReportRoot',($root+'/reports'))
    }else{
        $root='/shared/mutator'
        $bootstrap=Join-Path $payload 'bootstrap'
        Copy-MutatorTree (Join-Path $script:MutatorRoot 'resources/containers/definitions/bootstrap') $bootstrap
        Copy-Item (Join-Path $bootstrap 'Install-ImageTool.ps1') (Join-Path $bootstrap 'Install-ImageTool.Original.ps1')
        Copy-Item (Join-Path $script:MutatorRoot 'resources/validation/Install-ValidationPayload.ps1') (Join-Path $bootstrap 'Install-ImageTool.ps1') -Force
        $metadata=@{Module='FrenchExDev.Mutator.PoSh';BaseFingerprint=$image.Fingerprint;MacBaseFingerprint=$image.Fingerprint}
        Write-MutatorJson (Join-Path $payload 'image.json') $metadata
        [IO.File]::WriteAllLines((Join-Path $payload 'tool-inputs.txt'),[string[]]@('','',''))
        $containerArguments+=@('--device','/dev/kvm','--device','/dev/net/tun','--cap-add','NET_ADMIN','--stop-timeout','120','--env','RAM_SIZE=4096M','--env','CPU_CORES=2','--env','RAM_CHECK=N',$image.ImageId)
    }
    $created=$false;$started=$false
    try{
        $create=Invoke-MutatorValidationContainerCommand $containerArguments $OutputDirectory $Connection
        $container=$create.Stdout.Trim()
        if($container -notmatch '^[a-f0-9]{64}$'){throw 'Invalid validation container identity.'}
        $created=$true;$state.ContainerId=$container
        Write-MutatorJson (Join-Path $OutputDirectory 'container.json') $state
        if($Platform -ne 'Linux' -and $image['ToolModule']){
            foreach($file in @('image.json','tool-inputs.txt')){
                $null=Invoke-MutatorValidationContainerCommand @('cp',($container+':/shared/mutator/'+$file),(Join-Path $payload $file)) $OutputDirectory $Connection
            }
        }
        $null=Invoke-MutatorValidationContainerCommand @('cp',($payload+'/.'),($container+':'+$root)) $OutputDirectory $Connection 600
        $null=Invoke-MutatorValidationContainerCommand @('start',$container) $OutputDirectory $Connection
        $started=$true;$state.Phase='Executing'
        $deadline=(Get-MutatorUtcNow).AddHours(24)
        $remote=$root+'/reports'
        do{
            $inspect=Invoke-MutatorValidationContainerCommand @('inspect',$container) $OutputDirectory $Connection
            $identity=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
            if($identity.Config.Labels['org.frenchexdev.mutator.validation'] -cne $Request.RunId){throw 'Validation container ownership differs.'}
            if(!$identity.State.Running){break}
            # Read only the bounded progress document; native test logs stay in the container.
            $probe=Invoke-MutatorContainerCommand -Arguments @('exec',$container,'pwsh','-NoProfile','-Command',('if(Test-Path -LiteralPath '''+$remote+'/progress.json''){[IO.File]::ReadAllText('''+$remote+'/progress.json'')}')) -Directory $OutputDirectory -Connection $Connection
            if($probe.Outcome -eq 'Success' -and $probe.Stdout.Trim()){$state.Progress=$probe.Stdout|ConvertFrom-Json -AsHashtable -DateKind String}
            $finished=Invoke-MutatorContainerCommand -Arguments @('exec',$container,'pwsh','-NoProfile','-Command',('if(Test-Path -LiteralPath '''+$remote+'/result.json''){''complete''}')) -Directory $OutputDirectory -Connection $Connection
            Write-MutatorValidationReport $Run -UI:$UI
            if($finished.Outcome -eq 'Success' -and $finished.Stdout.Trim() -ceq 'complete'){break}
            if((Get-MutatorUtcNow) -ge $deadline){throw [TimeoutException]::new('Validation exceeded its 24 hour timeout.')}
            Start-Sleep -Seconds 3
        }while($true)
        $exitCode=$null
        if($Platform -eq 'Linux'){
            $wait=Invoke-MutatorValidationContainerCommand @('wait',$container) $OutputDirectory $Connection 120
            $exitCode=[int]$wait.Stdout.Trim()
        }
        $reports=Join-Path $OutputDirectory 'reports'
        [void][IO.Directory]::CreateDirectory($reports)
        $null=Invoke-MutatorValidationContainerCommand @('cp',($container+':'+$remote+'/.'),$reports) $OutputDirectory $Connection 600
        $result=Read-MutatorJson (Join-Path $reports 'result.json')
        if(!$result -or $result.RunId -cne $Request.RunId -or $result.OS -cne $Platform -or $result.SourceSha256 -cne $Request.SourceSha256){throw 'Validation returned no matching source-bound result.'}
        if($result['Outcome'] -cnotin @('Success','Failed') -or !$result['Modules'] -or $result.Modules.Count -ne $Request.Modules.Count -or
            @($Request.Modules|Where-Object {!$result.Modules.Contains($_)}).Count -or !$result['Suites'] -or $result.Suites.Count -ne $Request.Test.Count){throw 'Validation returned an incomplete suite or module manifest.'}
        if($Platform -eq 'Linux' -and $exitCode -ne 0 -and $result.Outcome -ceq 'Success'){throw 'The container exit code contradicts the validation result.'}
        $state.Suites=$result.Suites;$state.Modules=$result.Modules;$state.Outcome=$result.Outcome;$state.Phase='Completed';$state.Reports=$reports
        $progress=Read-MutatorJson (Join-Path $reports 'progress.json')
        if($progress){$state.Progress=$progress}
        $state.Qualified=($result.Outcome -ceq 'Success')
        $state
    }finally{
        if($created){
            $inspection=Invoke-MutatorContainerCommand -Arguments @('inspect',$container) -Directory $OutputDirectory -Connection $Connection
            if($inspection.Outcome -eq 'Success'){
                $owned=@($inspection.Stdout|ConvertFrom-Json -AsHashtable)[0]
                if($owned.Id -ceq $container -and $owned.Config.Labels['org.frenchexdev.mutator.validation'] -ceq $Request.RunId){
                    if($started -and $owned.State.Running){$null=Invoke-MutatorContainerCommand -Arguments @('stop','--time','120',$container) -Directory $OutputDirectory -Connection $Connection -TimeoutSeconds 150}
                    # Remove only a stopped container after all available proof has been copied.
                    $logs=Invoke-MutatorContainerCommand -Arguments @('logs',$container) -Directory $OutputDirectory -Connection $Connection
                    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'container.stdout.log'),$logs.Stdout)
                    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'container.stderr.log'),$logs.Stderr)
                    $retained=Join-Path $OutputDirectory 'reports';[void][IO.Directory]::CreateDirectory($retained)
                    $copy=Invoke-MutatorContainerCommand -Arguments @('cp',($container+':'+$root+'/reports/.'),$retained) -Directory $OutputDirectory -Connection $Connection -TimeoutSeconds 600
                    if($copy.Outcome -eq 'Success'){$null=Invoke-MutatorContainerCommand -Arguments @('rm','--volumes',$container) -Directory $OutputDirectory -Connection $Connection}
                    else{Write-MutatorJson (Join-Path $OutputDirectory 'retained-container.json') @{ContainerId=$container;Connection=$Connection;Reason='Reports could not be recovered; stopped container retained.'}}
                }
            }
        }
    }
}
