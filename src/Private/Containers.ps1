function Invoke-MutatorContainerCommand {
    <#
    .SYNOPSIS
    Execute a captured container-engine operation with the selected connection.

    .DESCRIPTION
    Routes Docker builds through the bounded BuildKit adapter and normalizes requested JSON output.
    Returns native outcome and locally retained streams.
    #>

    param([string[]]$Arguments, [string]$Directory, [int]$TimeoutSeconds=60, [string]$Connection,[switch]$DefaultConnection)
    if($DefaultConnection){$Connection=$null}elseif(!$Connection){$Connection=$script:MutatorContainerConnection}
    $prefix=@(Get-MutatorContainerPrefix -Engine $script:MutatorContainerEngine -Connection $Connection -Directory $Directory -DefaultConnection:$DefaultConnection)
    if($script:MutatorContainerEngine -eq 'Docker'){
        if($Arguments[0] -eq 'build'){return Invoke-MutatorDockerBuild -Arguments $Arguments -Directory $Directory -TimeoutSeconds $TimeoutSeconds -Connection $Connection}
        $dockerArguments=@($Arguments)
        $json=$false
        for($i=0;$i -lt $dockerArguments.Count-1;$i++){
            if($dockerArguments[$i] -eq '--format' -and $dockerArguments[$i+1] -eq 'json'){$dockerArguments[$i+1]='{{json .}}';$json=$true}
        }
        $result=Invoke-MutatorNative docker ($prefix+$dockerArguments) $Directory $TimeoutSeconds
        if($result.Outcome -eq 'Success' -and $json){
            if($Arguments[0] -eq 'info'){$result.Stdout=ConvertTo-Json -InputObject (ConvertFrom-MutatorDockerInfo ($result.Stdout|ConvertFrom-Json -AsHashtable)) -Depth 8 -Compress}
            else{$rows=@($result.Stdout -split "`r?`n"|Where-Object {![string]::IsNullOrWhiteSpace($_)}|ForEach-Object {$_|ConvertFrom-Json -AsHashtable});$result.Stdout=ConvertTo-Json -InputObject $rows -Depth 20 -Compress}
        }
        return $result
    }
    Invoke-MutatorNative podman ($prefix+$Arguments) $Directory $TimeoutSeconds
}

function Get-MutatorRootlessSiblingConnection {
    <#
    .SYNOPSIS
    Find the rootless storage connection paired with a rootful Podman connection.

    .DESCRIPTION
    Requires an exact discovered sibling. Does not probe Podman when Docker is selected or change the
    default connection.
    #>

    param([string]$Directory, [string]$Connection)
    if($script:MutatorContainerEngine -eq 'Docker'){return}
    if(!$Connection){
        $Connection=$script:MutatorContainerConnection
        if(!$Connection){
            $setting=if($script:MutatorContainerSetting){$script:MutatorContainerSetting}else{Get-MutatorEngineSetting Podman}
            if($setting.Pipe){
                $endpoint=Resolve-MutatorPodmanEndpoint $setting.Pipe $Directory
                if(!$endpoint.Contains('Connection')){return}
                $Connection=$endpoint.Connection
            }
        }
    }
    $result=Invoke-MutatorContainerCommand -Arguments @('system','connection','list','--format','json') -Directory $Directory
    if($result.Outcome -ne 'Success'){throw 'Cannot discover the rootless runtime image storage.'}
    $connections=@($result.Stdout|ConvertFrom-Json -AsHashtable|Where-Object{$_ -is [Collections.IDictionary] -and $_['Name']})
    $selected=@($connections|Where-Object{if($Connection){$_['Name'] -ceq $Connection}else{$_['Default'] -eq $true}})
    if($selected.Count -eq 1 -and $selected[0].Name.EndsWith('-root',[StringComparison]::Ordinal)){
        $name=$selected[0].Name.Substring(0,$selected[0].Name.Length-5)
        if(@($connections|Where-Object{$_['Name'] -ceq $name}).Count -eq 1){$name}
    }
}

function Resolve-MutatorContainerConnection {
    <#
    .SYNOPSIS
    Inspect resource controllers for the selected container connection.

    .DESCRIPTION
    May select an existing rootful Podman sibling when an implicit default lacks memory controls.
    Explicit connections and configured endpoints remain authoritative.
    #>

    param([string]$Directory, [string]$Connection)
    $result=Invoke-MutatorContainerCommand -Arguments @('info','--format','json') -Directory $Directory -Connection $Connection
    if($result.Outcome -ne 'Success'){throw ('Cannot inspect the selected '+$script:MutatorContainerEngine+' connection.')}
    $info=($result.Stdout|ConvertFrom-Json -AsHashtable).host
    $controllers=@($info['cgroupControllers'])
    $setting=if($script:MutatorContainerSetting){$script:MutatorContainerSetting}else{Get-MutatorEngineSetting $script:MutatorContainerEngine}
    if($script:MutatorContainerEngine -eq 'Podman' -and !$Connection -and !$setting.Pipe -and $controllers -notcontains 'memory'){
        $list=Invoke-MutatorContainerCommand -Arguments @('system','connection','list','--format','json') -Directory $Directory
        if($list.Outcome -ne 'Success'){throw 'Cannot discover a Podman connection with memory controls.'}
        $connections=@($list.Stdout|ConvertFrom-Json -AsHashtable)
        $default=@($connections|Where-Object Default -EQ $true)
        if($default.Count -eq 1){
            $candidate=@($connections|Where-Object Name -CEQ ($default[0].Name+'-root'))
            if($candidate.Count -eq 1){
                $root=Invoke-MutatorContainerCommand -Arguments @('info','--format','json') -Directory $Directory -Connection $candidate[0].Name
                if($root.Outcome -ne 'Success'){throw 'The rootful Podman connection is unavailable; memory hard limits cannot be guaranteed.'}
                $rootHost=($root.Stdout|ConvertFrom-Json -AsHashtable).host
                if(@($rootHost['cgroupControllers']) -contains 'memory'){$Connection=$candidate[0].Name;$info=$rootHost;$controllers=@($info.cgroupControllers)}
            }
        }
    }
    @{Engine=$script:MutatorContainerEngine;Connection=$Connection;Controllers=$controllers;Rootless=$info.security.rootless}
}

function Get-MutatorContainerRecipe {
    <#
    .SYNOPSIS
    Resolve the module recipe, generated definition or required runtime descriptor.

    .DESCRIPTION
    Checks module identity and definition files, then retains fingerprints for scheduling. Required
    isolation can select a descriptor even when a host binary exists.
    #>

    param([string]$ModulePath,[switch]$Required)
    $local = Join-Path $ModulePath 'test/mutator.container.psd1'
    $path = if (Test-Path -LiteralPath $local) { $local } else { Join-Path $script:MutatorRoot ('resources/containers/' + (Split-Path $ModulePath -Leaf) + '.psd1') }
    $recipe=$null
    if(Test-Path -LiteralPath $path){
        $data = Import-PowerShellDataFile -LiteralPath $path
        switch ($data.UseWhen) {
            'Windows' { if (!$Required -and !$IsWindows) { return } }
            'Missing' { if (!$Required -and (Get-Command $data.Binary -CommandType Application -ErrorAction Ignore)) { return } }
            'Always' { }
            default { throw 'Container UseWhen must be Windows, Missing or Always.' }
        }
        $recipe=@{Kind='Recipe';Path=$path;Sha256=(Get-FileHash -LiteralPath $path).Hash;Binary=$data.Binary}
    }
    $definitionPath=Join-Path $ModulePath 'containers/image.json'
    if((Split-Path $ModulePath -Leaf) -cmatch '^FrenchExDev\.[A-Za-z0-9_.-]+\.PoSh$' -and (Test-Path -LiteralPath $definitionPath)){
        $metadata=Read-MutatorJson $definitionPath
        if(!$metadata -or $metadata['Module'] -cne (Split-Path $ModulePath -Leaf)){throw 'Generated container module identity differs from the selected module.'}
        $linuxProfile=$metadata.Platforms.Linux
        $binary=if($recipe){$recipe.Binary}else{$linuxProfile['Binary']}
        if(!$recipe -and !$Required -and (!$binary -or (Get-Command $binary -CommandType Application -ErrorAction Ignore))){return}
        if($linuxProfile.Status -cne 'Prepared'){throw ('Linux container definition is not prepared: '+[string]$linuxProfile['Reason'])}
        $dockerfile=Join-Path $ModulePath 'containers/linux/Dockerfile'
        $ignore=$dockerfile+'.dockerignore'
        if(!(Test-Path -LiteralPath $dockerfile) -or !(Test-Path -LiteralPath $ignore)){throw 'The declared Linux Dockerfile or its ignore file is missing.'}
        if(!$recipe){$recipe=@{Path=$definitionPath;Sha256=(Get-FileHash -LiteralPath $definitionPath).Hash;Binary=$binary}}
        $recipe.Kind='Generated';$recipe.DefinitionPath=$definitionPath;$recipe.DefinitionSha256=(Get-FileHash -LiteralPath $definitionPath).Hash
        $recipe.DockerfilePath=$dockerfile;$recipe.DockerfileSha256=(Get-FileHash -LiteralPath $dockerfile).Hash
        $recipe.IgnorefilePath=$ignore;$recipe.IgnorefileSha256=(Get-FileHash -LiteralPath $ignore).Hash
    }
    if(!$recipe -and $Required){
        $manifest=Join-Path $script:MutatorRoot 'FrenchExDev.Mutator.PoSh.psd1'
        $recipe=@{Kind='Runtime';Path=$manifest;Sha256=(Get-FileHash -LiteralPath $manifest).Hash;Binary='pwsh'}
    }
    $recipe
}

function Invoke-MutatorContainerPackage {
    <#
    .SYNOPSIS
    Execute one scheduled package in its isolated Linux container.

    .DESCRIPTION
    Uses an immutable local image, read-only inputs and owned report storage. Retains business outcomes
    and available reports even when the client or worker fails.
    #>

    param([string]$RunDirectory, [Collections.IDictionary]$Run, [Collections.IDictionary]$Entry,
        [Collections.IDictionary]$State, [string]$StatePath)
    $artifacts = Split-Path $StatePath
    $recipe = $Entry.ContainerRecipe
    if ((Get-FileHash -LiteralPath $recipe.Path).Hash -cne $recipe.Sha256) { throw 'Container recipe changed since scheduling.' }
    $State.Phase = 'Building Container'
    $State.Platform = 'linux'
    Write-MutatorJson $StatePath $State
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $runtime=Resolve-MutatorContainerConnection -Directory $artifacts -Connection $Run['ContainerConnection']
    if($Run['Isolation'] -eq 'Podman' -and $script:MutatorContainerEngine -ne 'Podman'){throw 'Linux PSMutant campaigns require Podman.'}
    if($recipe['Kind'] -ceq 'Runtime'){
        if(!$Run['ContainerBaseImage']){throw 'A Linux campaign without a module image requires an explicit local -ContainerBaseImage with PowerShell 7.6+, Pester 6.2.0 and PSMutant 0.6.0.'}
        $inspect=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$Run.ContainerBaseImage) -Directory $artifacts -Connection $runtime.Connection
        if($inspect.Outcome -ne 'Success'){throw 'The selected Linux runtime image is unavailable locally; no image is pulled and no host fallback is permitted.'}
        $base=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
        if($base.Os -ne 'linux' -or $base.Id -notmatch '^(sha256:)?[a-f0-9]{64}$'){throw 'The selected runtime must be a Linux image with a complete immutable image ID.'}
        $image=[pscustomobject]@{Image=$Run.ContainerBaseImage;ImageId=$base.Id;BaseImageId=$base.Id;Reused=$true}
        Write-MutatorJson (Join-Path $artifacts 'container-build/image.json') @{Image=$image.Image;ImageId=$image.ImageId;BaseImageId=$image.BaseImageId;ContainerEngine='Podman';Platform='linux';Reused=$true}
    }elseif($recipe['Kind'] -ceq 'Generated'){
        foreach($pair in @(@('DefinitionPath','DefinitionSha256'),@('DockerfilePath','DockerfileSha256'),@('IgnorefilePath','IgnorefileSha256'))){
            if(!(Test-Path -LiteralPath $recipe[$pair[0]]) -or (Get-FileHash -LiteralPath $recipe[$pair[0]]).Hash -cne $recipe[$pair[1]]){throw 'Generated container definition changed since scheduling.'}
        }
        $build=@{ModulePath=$Entry.ModulePath;Platform='Linux';Connection=$runtime.Connection;OutputDirectory=(Join-Path $artifacts 'container-build');Reuse=$true
            MemoryMiB=[int]($Run.Schedule.ReservedMemoryMiB/$Run.Schedule.Slots);Cpus=$Run.Schedule.Workers}
        if($Run['ContainerBaseImage']){$build.BaseImage=$Run.ContainerBaseImage}
        $image=New-MutatorContainerImage @build
    }else{
    if(!$Run['ContainerBaseImage']){throw 'A custom container recipe requires an explicit -ContainerBaseImage; generated module images use containers/linux/Dockerfile by default.'}
        $image=New-MutatorToolImage -RecipePath $recipe.Path -BaseImage $Run.ContainerBaseImage -Connection $runtime.Connection -OutputDirectory (Join-Path $artifacts 'container-build')
    }
    $State.Container = @{Engine=$script:MutatorContainerEngine;Image=$image.Image;ImageId=$image.ImageId;BaseImageId=$image.BaseImageId;Reused=$image.Reused;BuildMs=$clock.Elapsed.TotalMilliseconds;Connection=$runtime.Connection;Rootless=$runtime.Rootless}
    $State.Container.Started=$false
    $State.Container.BuildKind=if($recipe['Kind'] -ceq 'Runtime'){'LocalRuntime'}elseif($recipe['Kind'] -ceq 'Generated'){'Generated'}else{'ExplicitRecipe'}
    $State.Container.BuildReceipt=Join-Path $artifacts ('container-build/'+$(if($recipe['Kind'] -ceq 'Generated'){'build.json'}else{'image.json'}))
    if (Test-Path -LiteralPath (Join-Path $RunDirectory 'stop.json')) { throw [OperationCanceledException]::new('Mutation run stopped before container execution.') }
    $directory = Join-Path $artifacts 'container-run'
    $linuxEntry = @{Id=$Entry.Id;Name=$Entry.Name;ModulePath=('/mutator/source/'+[IO.Path]::GetRelativePath($Run.SourceRoot,$Entry.ModulePath).Replace('\','/'))
        Configuration=('/mutator/source/'+[IO.Path]::GetRelativePath($Run.SourceRoot,$Entry.Configuration).Replace('\','/'));Stryker=$Entry.Stryker;ResumeFrom=$null}
    $linuxRun = @{SourceRoot='/mutator/source';Packages=@($linuxEntry);Schedule=$Run.Schedule;TestOrder=$Run.TestOrder;StrykerRuntime='Host'
        StopPath='/mutator/owner/stop.json';ToolCacheRoot='/mutator/run/tools';ContainerImageId=$image.ImageId}
    $linuxRun.IsolationBoundary='Podman'
    $resumeMount = @()
    if ($Entry.ResumeFrom) {
        $resume = (Resolve-Path -LiteralPath $Entry.ResumeFrom -ErrorAction Stop).ProviderPath
        if ($resume.Contains(',')) { throw 'Container mount paths containing commas are unsupported.' }
        $linuxEntry.ResumeFrom='/mutator/resume/'+(Split-Path $resume -Leaf)
        $resumeMount=@('--mount',('type=bind,source='+(Split-Path $resume)+',target=/mutator/resume,readonly'))
    }
    if($Entry['RecheckFrom']){
        $baseline=Join-Path $artifacts 'recheck-input/mutation.json'
        [void][IO.Directory]::CreateDirectory((Split-Path $baseline))
        Copy-Item -LiteralPath $Entry.RecheckFrom -Destination $baseline
        if((Get-FileHash -LiteralPath $baseline).Hash -cne $Entry.RecheckSha256){throw 'The selected recheck baseline changed since scheduling.'}
        $linuxEntry.RecheckFrom='/mutator/recheck-input.json'
        $linuxEntry.RecheckSha256=$Entry.RecheckSha256
        if($baseline.Contains(',')){throw 'Container mount paths containing commas are unsupported.'}
        $resumeMount+=@('--mount',('type=bind,source='+$baseline+',target=/mutator/recheck-input.json,readonly'))
    }
    Write-MutatorJson (Join-Path $directory 'run.json') $linuxRun
    $State.Container.StatePath = Join-Path $directory ('packages/'+$Entry.Id+'/state.json')
    $State.Container.ProgressPath = Join-Path $directory ('packages/'+$Entry.Id+'/mutants.jsonl')
    $controllers = @($runtime.Controllers)
    $State.Container.ResourceLimits = @{Cpu=($controllers -contains 'cpu');Memory=($controllers -contains 'memory');MemoryMiB=[int]($Run.Schedule.ReservedMemoryMiB / $Run.Schedule.Slots);CpuQuota=$Run.Schedule.Workers}
    if (!$State.Container.ResourceLimits.Cpu -or !$State.Container.ResourceLimits.Memory) {
        $State.Container.ResourceWarning = 'Unavailable cgroup controllers: the shared worker reservations remain active; unsupported CPU/RAM hard limits cannot be enforced.'
    }
    $State.Phase = 'Preparation'
    Write-MutatorJson $StatePath $State
    $name = 'mutator-' + [guid]::NewGuid().ToString('N')
    if (@(@($Run.SourceRoot,$directory,$RunDirectory) | Where-Object { $_.Contains(',') }).Count) { throw 'Container mount paths containing commas are unsupported.' }
    $limits = @()
    if ($State.Container.ResourceLimits.Cpu) { $limits += @('--cpus',[string]$Run.Schedule.Workers) }
    if ($State.Container.ResourceLimits.Memory) {
        $memory=[string][int]($Run.Schedule.ReservedMemoryMiB / $Run.Schedule.Slots)+'m'
        $limits += @('--memory',$memory,'--memory-swap',$memory)
    }
    $sourceMount=@('--mount',('type=bind,source='+$Run.SourceRoot+',target=/mutator/source,readonly'))
    if($image.PSObject.Properties['Owner'] -and $image.Owner -ceq 'CliEnvironment'){$sourceMount=@(Get-CliEnvironmentSourceMount -ModuleRoot $Run.SourceRoot -Destination '/mutator/source')}
    $arguments = @('run','--rm','--pull=never','--name',$name,'--network=none') + $limits + $resumeMount + $sourceMount + @(
        '--mount',('type=bind,source='+$directory+',target=/mutator/run'),
        '--mount',('type=bind,source='+$RunDirectory+',target=/mutator/owner,readonly'),
        '--entrypoint','pwsh',$image.ImageId,'-NoLogo','-NoProfile','-NonInteractive','-File',
        '/mutator/source/FrenchExDev.Mutator.PoSh/resources/Run-Worker.ps1','-RunDirectory','/mutator/run','-Package',$Entry.Id)
    $native = $null
    try {
        $native = Invoke-MutatorContainerCommand -Arguments $arguments -Directory $artifacts -TimeoutSeconds 604800 -Connection $runtime.Connection
        [IO.File]::WriteAllText((Join-Path $artifacts 'container.stdout.log'),$native.Stdout)
        [IO.File]::WriteAllText((Join-Path $artifacts 'container.stderr.log'),$native.Stderr)
        $inner = Read-MutatorJson $State.Container.StatePath
        if($inner){$State.Container.Started=$true}
        if (!$inner -or $inner.Outcome -eq 'Running') { throw 'Linux mutation worker exited without a final package report.' }
        foreach ($key in @('Outcome','Phase','PSMutant','Stryker','Recheck','Error','ContextSha256','SourceSha256')) { $State[$key] = $inner[$key] }
        $reports = Join-Path $directory ('packages/'+$Entry.Id)
        foreach ($file in Get-ChildItem -LiteralPath $reports -File -Filter 'mutation*.json*') { Copy-Item -LiteralPath $file.FullName -Destination $artifacts -Force }
        if (Test-Path (Join-Path $reports 'stryker')) { Copy-MutatorTree (Join-Path $reports 'stryker') (Join-Path $artifacts 'stryker') }
        if ($native.Outcome -ne 'Success') { throw ($script:MutatorContainerEngine+' worker execution failed; see retained container logs.') }
    } finally {
        Copy-MutatorIsolatedReport -Source (Join-Path $directory ('packages/'+$Entry.Id)) -Destination $artifacts
        # A failed client may leave its container alive; the generated name is owned by this invocation.
        if (!$native -or $native.Outcome -ne 'Success') { $null = Invoke-MutatorContainerCommand -Arguments @('rm','--force',$name) -Directory $artifacts -Connection $runtime.Connection }
    }
}
