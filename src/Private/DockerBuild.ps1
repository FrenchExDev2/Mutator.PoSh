function ConvertTo-MutatorDockerBuildOption {
    param([string[]]$Arguments)
    $options=[Collections.Generic.List[string]]::new()
    $settings=@{Memory='2048m';MemorySwap='2048m';CpuPeriod='100000';CpuQuota='200000';Jobs=1;File=$null;Ignore=$null;Base=$null;Pull='missing'}
    $keys=@{'--memory'='Memory';'--memory-swap'='MemorySwap';'--cpu-period'='CpuPeriod';'--cpu-quota'='CpuQuota';'--jobs'='Jobs';'--ignorefile'='Ignore'}
    for($i=1;$i -lt $Arguments.Count;$i++){
        $argument=$Arguments[$i]
        if($argument -eq '--layers'){continue}
        if($argument -eq '--retry'){
            $i++;if($i -ge $Arguments.Count -or $Arguments[$i] -cne '0'){throw 'Docker builds do not automatically retry.'};continue
        }
        if($keys.ContainsKey($argument)){
            $i++;if($i -ge $Arguments.Count){throw 'A Docker build option is missing its value.'}
            $settings[$keys[$argument]]=$Arguments[$i];continue
        }
        if($argument -like '--pull=*'){$settings.Pull=$argument.Substring(7);$options.Add('--pull=false');continue}
        if($argument -eq '--build-arg' -and $i+1 -lt $Arguments.Count -and $Arguments[$i+1] -clike 'BASE_IMAGE=*'){$i++;$settings.Base=$Arguments[$i].Substring(11);continue}
        if($argument -in @('--file','-f')){
            $i++;if($i -ge $Arguments.Count){throw 'A Docker build file option is missing its value.'}
            $settings.File=$Arguments[$i];continue
        }
        $options.Add($argument)
    }
    if(!$settings.File){throw 'Docker builds require an explicit Dockerfile.'}
    if($settings.Ignore -and [IO.Path]::GetFullPath($settings.Ignore) -cne ([IO.Path]::GetFullPath($settings.File)+'.dockerignore')){throw 'Docker requires the selected Dockerfile-specific .dockerignore file.'}
    if($settings.Pull -notin @('missing','never')){throw 'Unsupported Docker build pull policy.'}
    foreach($key in @('Memory','MemorySwap')){if($settings[$key] -cnotmatch '^[1-9][0-9]*[kmg]?$'){throw 'Docker build memory limits must be positive byte, k, m or g values.'}}
    foreach($key in @('CpuPeriod','CpuQuota','Jobs')){if([string]$settings[$key] -cnotmatch '^[1-9][0-9]*$'){throw 'Docker CPU and parallel build limits must be positive integers.'}}
    $settings.Options=$options.ToArray()
    $settings
}

function ConvertTo-MutatorDockerMemorySize {
    param([string]$Value)
    if($Value -cnotmatch '^([1-9][0-9]*)([kmg]?)$'){throw 'Invalid Docker memory size.'}
    $units=@{''=1L;k=1KB;m=1MB;g=1GB}
    [long]$Matches[1]*$units[$Matches[2]]
}

function Invoke-MutatorDockerBuildStep {
    param([string]$Name,[string[]]$Arguments,[string]$Directory,[string]$Connection,[int]$TimeoutSeconds,[string]$Proof)
    $prefix=@(Get-MutatorContainerPrefix -Engine Docker -Connection $Connection -Directory $Directory)
    $native=Invoke-MutatorNative docker ($prefix+$Arguments) $Directory $TimeoutSeconds
    [IO.File]::WriteAllText((Join-Path $Proof ($Name+'.stdout.log')),$native.Stdout)
    [IO.File]::WriteAllText((Join-Path $Proof ($Name+'.stderr.log')),$native.Stderr)
    Write-MutatorJson (Join-Path $Proof ($Name+'.json')) @{Outcome=$native.Outcome;ExitCode=$native.ExitCode;Arguments=$Arguments}
    $native
}

function Remove-MutatorDockerBuildScratch {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private finally cleanup checks the exact temporary path and owner; the public build owns ShouldProcess.')]
    [CmdletBinding()]
    param([string]$Path,[string]$Owner)
    $absolute=[IO.Path]::GetFullPath($Path)
    $expected=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('mutator-docker-build-'+$Owner)))
    if($absolute -cne $expected -or $Owner -cnotmatch '^[a-f0-9]{32}$' -or (Read-MutatorJson (Join-Path $absolute 'owner.json')).Owner -cne $Owner){throw 'Docker scratch cleanup refused an unowned path.'}
    Remove-Item -LiteralPath $absolute -Recurse -Force
}

function Invoke-MutatorDockerBuild {
    param([string[]]$Arguments,[string]$Directory,[int]$TimeoutSeconds,[string]$Connection)
    $settings=ConvertTo-MutatorDockerBuildOption $Arguments
    $owner=[guid]::NewGuid().ToString('N');$builder='mutator-build-'+$owner
    $proof=Join-Path $script:MutatorRoot ('test/Artifacts/docker-builds/'+$owner)
    [void][IO.Directory]::CreateDirectory($proof)
    $scratch=Join-Path ([IO.Path]::GetTempPath()) ('mutator-docker-build-'+$owner)
    Write-MutatorJson (Join-Path $scratch 'owner.json') @{Owner=$owner}
    $receipt=@{SchemaVersion=1;Engine='Docker';Builder=$builder;Connection=$Connection;Outcome='Preparing';Cleanup='NotStarted';SourceDockerfile=$settings.File;SourceSha256=(Get-FileHash $settings.File).Hash}
    $created=$false;$succeeded=$false
    try{
        $version=Invoke-MutatorDockerBuildStep version @('buildx','version') $Directory $Connection 30 $proof
        if($version.Outcome -ne 'Success'){throw 'Docker Buildx is required for bounded builds; see the retained version check.'}
        $receipt.BuildxVersion=$version.Stdout.Trim()
        $text=[IO.File]::ReadAllText($settings.File)
        $base=if($settings.Base){$settings.Base}else{[regex]::Match($text,'(?m)^ARG BASE_IMAGE=([^\r\n]+)').Groups[1].Value}
        if(!$base){$base=[regex]::Match($text,'(?im)^FROM\s+([^\s$]+)').Groups[1].Value}
        if($base -and $base -cne 'scratch'){
            $inspection=Invoke-MutatorDockerBuildStep base-inspect @('image','inspect',$base) $Directory $Connection 60 $proof
            if($inspection.Outcome -eq 'Success'){
                $image=@($inspection.Stdout|ConvertFrom-Json -AsHashtable)[0]
                if($image.Id -notmatch '^(sha256:)?[a-f0-9]{64}$' -or $image.Os -cne 'linux'){throw 'Docker BuildKit requires an inspected immutable Linux base image.'}
                $archive=Join-Path $scratch 'base.tar'
                $saved=Invoke-MutatorDockerBuildStep base-save @('image','save','--output',$archive,$image.Id) $Directory $Connection $TimeoutSeconds $proof
                if($saved.Outcome -ne 'Success'){throw 'The local Docker base could not be exported for the isolated builder.'}
                $layout=ConvertTo-MutatorDockerImageLayout $archive (Join-Path $scratch 'base') $image.Id
                $receipt.LocalBase=@{ImageId=$layout.ImageId;Manifest=$layout.Manifest;Layers=$layout.Layers}
                $settings.Options=@('--build-context',('mutator_base='+$layout.Reference))+@($settings.Options)
                if($text -match '(?m)^ARG BASE_IMAGE='){$settings.Options=@('--build-arg','BASE_IMAGE=mutator_base')+@($settings.Options)}
                else{$text=[regex]::Replace($text,'(?im)^(FROM\s+)'+[regex]::Escape($base)+'(?=\s|$)','$1mutator_base')}
            }elseif($settings.Pull -eq 'never'){throw 'The immutable Docker base is missing; the selected policy forbids a pull.'}
            elseif($settings.Base){$settings.Options=@('--build-arg',('BASE_IMAGE='+$settings.Base))+@($settings.Options)}
        }
        $file=Join-Path $scratch 'Dockerfile';[IO.File]::WriteAllText($file,$text,[Text.UTF8Encoding]::new($false))
        $ignore=if($settings.Ignore){$settings.Ignore}elseif(Test-Path ($settings.File+'.dockerignore')){$settings.File+'.dockerignore'}else{$null}
        if($ignore){Copy-Item -LiteralPath $ignore -Destination ($file+'.dockerignore')}
        $config=Join-Path $scratch 'buildkitd.toml'
        [IO.File]::WriteAllText($config,('[worker.oci]'+"`n"+'  max-parallelism = '+$settings.Jobs+"`n"),[Text.UTF8Encoding]::new($false))
        $driver='memory='+$settings.Memory+',memory-swap='+$settings.MemorySwap+',cpu-period='+$settings.CpuPeriod+',cpu-quota='+$settings.CpuQuota
        $created=$true
        $create=Invoke-MutatorDockerBuildStep create @('buildx','create','--name',$builder,'--driver','docker-container','--driver-opt',$driver,'--buildkitd-config',$config,'--bootstrap') $Directory $Connection $TimeoutSeconds $proof
        if($create.Outcome -ne 'Success'){throw 'The owned Docker BuildKit container could not be prepared.'}
        $inspect=Invoke-MutatorDockerBuildStep limits @('inspect',('buildx_buildkit_'+$builder+'0')) $Directory $Connection 60 $proof
        if($inspect.Outcome -ne 'Success'){throw 'Docker builder resource limits could not be inspected.'}
        $container=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
        $limits=$container.HostConfig
        if(!$container.State.Running -or [long]$limits.Memory -ne (ConvertTo-MutatorDockerMemorySize $settings.Memory) -or [long]$limits.MemorySwap -ne (ConvertTo-MutatorDockerMemorySize $settings.MemorySwap) -or [long]$limits.CpuPeriod -ne [long]$settings.CpuPeriod -or [long]$limits.CpuQuota -ne [long]$settings.CpuQuota){throw 'Docker did not enforce the requested builder memory and CPU limits.'}
        $receipt.Limits=@{MemoryBytes=[long]$limits.Memory;MemorySwapBytes=[long]$limits.MemorySwap;CpuPeriod=[long]$limits.CpuPeriod;CpuQuota=[long]$limits.CpuQuota}
        $receipt.BuilderImageId=$container.Image
        $buildArguments=@('buildx','build','--builder',$builder,'--load','--progress','plain','--file',$file)+@($settings.Options)
        $built=Invoke-MutatorDockerBuildStep build $buildArguments $Directory $Connection $TimeoutSeconds $proof
        $receipt.Outcome=$built.Outcome;$receipt.ExitCode=$built.ExitCode
        $succeeded=$built.Outcome -eq 'Success'
        $built.BackendProof=Join-Path $proof 'summary.json'
        return $built
    }catch{$receipt.Outcome='Failed';$receipt.Error=$_.Exception.Message;throw}
    finally{
        try{
            if($created){
                $cleanup=Invoke-MutatorDockerBuildStep cleanup @('buildx','rm','--force',$builder) $Directory $Connection 120 $proof
                $receipt.Cleanup=$cleanup.Outcome
                if($cleanup.Outcome -ne 'Success' -and $succeeded){$receipt.Outcome='Failed';throw 'The Docker build completed but its owned builder could not be removed.'}
            }
        }finally{
            Write-MutatorJson (Join-Path $proof 'summary.json') $receipt
            Remove-MutatorDockerBuildScratch $scratch $owner
        }
    }
}
