function Invoke-MutatorValidation {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('Unit','Mutations','Integration')][string[]]$Test=@('Unit','Integration','Mutations'),
        [ValidateSet('Linux','Windows','MacOS')][string[]]$OS=@('Linux','Windows'),
        [string[]]$ModulePath=@($script:MutatorRoot),
        [Alias('Engine')][ValidateSet('Podman','Docker')][string]$ContainerEngine,
        [string]$ContainerConnection,[string]$MacOSConnection,
        [string]$OutputDirectory,[switch]$UI,[string]$Ram='40go',
        [ValidateRange(1,64)][int]$Workers=1,[ValidateRange(1,64)][int]$WorkerBudget=2,
        [ValidateRange(2048,1048576)][int]$MemoryBudgetMiB=6144
    )
    if(!$Test.Count -or !$OS.Count -or !$ModulePath.Count){throw 'Select at least one test suite, OS and module.'}
    if($Workers -gt $WorkerBudget){throw 'Workers must not exceed WorkerBudget.'}
    $limit=ConvertTo-MutatorMemoryLimit $Ram
    $paths=@($ModulePath|ForEach-Object {(Resolve-Path -LiteralPath $_ -ErrorAction Stop).ProviderPath}|Sort-Object -Unique)
    $parent=Split-Path $script:MutatorRoot
    foreach($path in $paths){if((Get-MutatorModuleRoot $path) -ne $parent){throw 'Validation modules must share the Mutator module directory or its QuietCliEcosystem.'}}
    $id=[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $output=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $script:MutatorRoot ('test/Artifacts/validation/'+$id)}
    if((Test-Path $output) -and @(Get-ChildItem -LiteralPath $output -Force).Count){throw 'Validation requires a new or empty report directory.'}
    if(!$PSCmdlet.ShouldProcess($output,'Run selected suites in isolated OS containers and retain reports')){return}
    $ContainerEngine=Resolve-MutatorEngineSelection $ContainerEngine
    $containerSetting=Get-MutatorEngineSetting $ContainerEngine
    if(!$PSBoundParameters.ContainsKey('ContainerConnection')){
        $ContainerConnection=if($ContainerEngine -eq $script:MutatorPreferredContainerEngine -and $script:MutatorPreferredContainerConnection){$script:MutatorPreferredContainerConnection}elseif($ContainerEngine -eq 'Podman' -and !$containerSetting.Pipe){'podman-frenchexdev-root'}else{$null}
    }
    Set-MutatorContainerContext -Engine $ContainerEngine -Connection $ContainerConnection -Setting $containerSetting
    $ContainerEngine=$script:MutatorContainerEngine
    $run=@{SchemaVersion=1;Id=$id;Outcome='Running';Path=$output;StartedUtc=[datetime]::UtcNow.ToString('O');Test=@('Unit','Integration','Mutations'|Where-Object {$_ -in $Test})
        Modules=@($paths|ForEach-Object {[IO.Path]::GetRelativePath($parent,$_).Replace('\','/')});Platforms=@{};FullGateSatisfied=$false;HostMemoryLimitBytes=$limit;ContainerEngine=$ContainerEngine;ContainerSetting=$containerSetting;ContainerConnection=$ContainerConnection}
    foreach($platform in @('Linux','Windows','MacOS')){$run.Platforms[$platform]=@{Outcome=$(if($platform -in $OS){'Pending'}else{'NotSelected'});Suites=@{}}}
    $watchdog=$null
    try{
        Write-MutatorValidationReport $run
        if($IsWindows){$watchdog=Start-MutatorMemoryWatchdog -LimitGB ($limit/1e9) -Path (Join-Path $output 'watchdog')}
        $source=New-MutatorValidationSource -ModulePath $paths -OutputDirectory $output -RefreshContainerDefinitions
        foreach($platform in @('Linux','Windows','MacOS'|Where-Object {$_ -in $OS})){
            $state=$run.Platforms[$platform];$state.Outcome='Running';$state.Phase='Preparing'
            $state.Path=Join-Path $output $platform.ToLowerInvariant()
            Write-MutatorValidationReport $run -UI:$UI
            try{
                $connection=if($platform -eq 'MacOS'){$MacOSConnection}else{$ContainerConnection}
                if($platform -eq 'MacOS' -and !$connection){throw 'macOS requires -MacOSConnection and a prepared base on the dedicated machine.'}
                $request=@{SchemaVersion=1;RunId=$id;OS=$platform;Test=$run.Test;Modules=$run.Modules;Workers=$Workers;WorkerBudget=$WorkerBudget;MemoryBudgetMiB=$MemoryBudgetMiB;SourceSha256=$source.Sha256}
                $result=Invoke-MutatorValidationContainer -Platform $platform -Source $source.Path -Request $request -OutputDirectory $state.Path -Connection $connection -Run $run -UI:$UI
                $run.Platforms[$platform]=$result
            }catch{
                $state.Outcome=if($_.Exception -is [TimeoutException]){'TimedOut'}elseif($_.Exception -is [OperationCanceledException]){'Interrupted'}elseif($state.Phase -eq 'Preparing'){'Blocked'}else{'Failed'}
                $state.Error=$_.Exception.Message
                foreach($suite in $run.Test){$state.Suites[$suite]=@{Outcome='Blocked';Reason=$state.Error}}
            }
            Write-MutatorValidationReport $run -UI:$UI
        }
        $selected=@($run.Platforms.Values|Where-Object Outcome -NE 'NotSelected')
        $run.Outcome=if(@($selected|Where-Object Outcome -NE 'Success').Count){'Failed'}else{'Success'}
        $run.FullGateSatisfied=($run.Outcome -eq 'Success' -and $run.Test.Count -eq 3)
    }catch{$run.Outcome='Failed';$run.Error=$_.Exception.Message}
    finally{
        if($watchdog){Stop-MutatorMemoryWatchdog -Path $watchdog.Path|Out-Null}
        $run.CompletedUtc=[datetime]::UtcNow.ToString('O')
        Write-MutatorValidationReport $run -UI:$UI
    }
    [pscustomobject]$run
}
