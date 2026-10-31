function New-MutatorContainerImage {
    <#
    .SYNOPSIS
    Build or reuse a pinned image with explicit resource proof.

    .DESCRIPTION
    Validates identity, dependencies and base overrides. Honors WhatIf before allocation and retains
    failures without retries.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ModulePath,
        [ValidateSet('Alpine','Debian','Swift','WindowsBootstrap','Windows','MacOSBootstrap','MacOS')][string]$BaseVariant,
        [ValidateSet('Linux','Windows','MacOS')][string]$Platform='Linux',
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Connection,
        [Alias('Engine')][ValidateSet('Podman','Docker')][string]$ContainerEngine,
        [string]$BaseImage,
        [switch]$Reuse,
        [ValidateRange(256,65536)][int]$MemoryMiB=2048,
        [ValidateRange(1,64)][int]$Cpus=2,
        [ValidateRange(1,14400)][int]$TimeoutSeconds=3600
    )
    $module=(Resolve-Path -LiteralPath $ModulePath -ErrorAction Stop).ProviderPath
    $context=Get-MutatorModuleRoot $module
    $name=Split-Path $module -Leaf
    $sources=[ordered]@{}
    if($BaseImage -and $BaseVariant){throw 'BaseImage overrides apply only to module images, not shared base recipes.'}
    if($name -cnotmatch '^FrenchExDev\.[A-Za-z0-9_.-]+\.PoSh$'){throw 'A generated FrenchExDev module is required.'}
    $sharedMetadata=Read-MutatorJson (Join-Path $module 'containers/image.json')
    if(!$BaseVariant -and $name -ceq 'FrenchExDev.QuietCli.Git.PoSh' -and $sharedMetadata -and $sharedMetadata['Git'] -and $Platform -in @('Linux','Windows')){
        if($BaseImage){throw 'The Git recipe uses its pinned CliEnvironment base; arbitrary BaseImage overrides are unsupported.'}
        if(!$PSCmdlet.ShouldProcess($name,'Build the Git environment through its shared owner')){return}
        Import-Module (Join-Path $context 'FrenchExDev.CliEnvironment.PoSh/FrenchExDev.CliEnvironment.PoSh.psd1') -DisableNameChecking
        $engine=Resolve-MutatorEngineSelection $ContainerEngine
        $built=New-CliEnvironmentGitImage -ModuleRoot $context -Platform $Platform -Engine $engine -Connection $Connection -OutputDirectory $OutputDirectory -MemoryMiB $MemoryMiB -Cpus $Cpus -TimeoutSeconds $TimeoutSeconds
        if($built.Outcome -ne 'Built'){throw $built.Error}
        return [pscustomobject]@{Outcome='Success';Image=$built.Image;ImageId=$built.ImageId;BaseImageId=$null;Reused=$false;Fingerprint=$built.Fingerprint;Owner='CliEnvironment'}
    }
    if($BaseVariant){
        if($name -ne 'FrenchExDev.Mutator.PoSh'){throw 'Shared bases belong to the Mutator module.'}
        $variant=switch($BaseVariant){'WindowsBootstrap'{'windows-bootstrap'};'MacOSBootstrap'{'macos-bootstrap'};default{$BaseVariant.ToLowerInvariant()}}
        $directory=Join-Path $module ('resources/containers/base/'+$variant)
        $runtime=Read-MutatorJson (Join-Path $module 'resources/containers/base/runtime.json')
        $key=switch($BaseVariant){'WindowsBootstrap'{'Bootstrap'};'MacOSBootstrap'{'MacBootstrap'};default{$BaseVariant}}
        $image=$runtime.Images[$key]
    }else{
        $platformName=switch($Platform){'Windows'{'Windows'};'MacOS'{'MacOS'};default{'Linux'}}
        $directory=Join-Path $module ('containers/'+$platformName.ToLowerInvariant())
        $metadata=Read-MutatorJson (Join-Path $module 'containers/image.json')
        $toolProfile=$metadata.Platforms[$platformName]
        if($toolProfile.Status -ne 'Prepared'){throw ('The '+$platformName+' tool recipe is not prepared for building.')}
        if($platformName -eq 'Windows' -and $toolProfile.Backend -ne 'Dockurr'){throw 'Native Windows images require a Windows container engine; this driver uses Linux dockurr.'}
        foreach($dependency in @(Get-MutatorContainerDependency $module)){
            $sources[$dependency]=(Get-MutatorSourceSnapshot (Resolve-MutatorModuleDirectory $context $dependency)).Sha256
        }
        $sources['bootstrap']=(Get-MutatorSourceSnapshot (Join-Path $script:MutatorRoot 'resources/containers/definitions/bootstrap')).Sha256
        $sources['dockerfile']=(Get-FileHash (Join-Path $directory 'Dockerfile')).Hash
        $sources['ignorefile']=(Get-FileHash (Join-Path $directory 'Dockerfile.dockerignore')).Hash
        $identity=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-MutatorContainerJson $sources)))).ToLowerInvariant()
        $image='localhost/'+($name.ToLowerInvariant() -replace '\.posh$','')+':'+$platformName.ToLowerInvariant()+'-'+$identity.Substring(0,16)
    }
    $dockerfile=Join-Path $directory 'Dockerfile'
    $ignore=$dockerfile+'.dockerignore'
    foreach($path in @($dockerfile,$ignore)){if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing generated build input: $path"}}
    if(!$PSCmdlet.ShouldProcess($image,'Build the generated Linux image with bounded resources and retained logs')){return}
    $ContainerEngine=Resolve-MutatorEngineSelection $ContainerEngine -UseContext
    if(!$PSBoundParameters.ContainsKey('Connection') -and $ContainerEngine -eq $script:MutatorContainerEngine){$Connection=$script:MutatorContainerConnection}
    $setting=if($ContainerEngine -eq $script:MutatorContainerEngine){$script:MutatorContainerSetting}else{$null}
    Set-MutatorContainerContext -Engine $ContainerEngine -Connection $Connection -Setting $setting
    $ContainerEngine=$script:MutatorContainerEngine
    $output=[IO.Path]::GetFullPath($OutputDirectory)
    [void][IO.Directory]::CreateDirectory($output)
    $receipt=@{SchemaVersion=1;Module=$name;BaseVariant=$BaseVariant;Platform=$Platform;Image=$image;Connection=$Connection;ContainerEngine=$ContainerEngine
        StartedUtc=[datetime]::UtcNow.ToString('O');Outcome='Running';MemoryLimitMiB=$MemoryMiB;Cpus=$Cpus
        DockerfileSha256=(Get-FileHash -LiteralPath $dockerfile).Hash;IgnorefileSha256=(Get-FileHash -LiteralPath $ignore).Hash
        SourceFingerprints=$sources;BaseImageId=$null;Reused=$false;Dependencies=@()
        StdoutLog=(Join-Path $output 'build.stdout.log');StderrLog=(Join-Path $output 'build.stderr.log')}
    $receiptPath=Join-Path $output 'build.json'
    Write-MutatorJson $receiptPath $receipt
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        if($BaseImage){
            if([IO.File]::ReadAllText($dockerfile) -notmatch '(?m)^ARG BASE_IMAGE='){throw 'The generated Dockerfile does not accept a BASE_IMAGE override.'}
            $base=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$BaseImage) -Directory $context -Connection $Connection
            if($base.Outcome -ne 'Success'){throw 'The explicit base image is unavailable in the selected connection.'}
            $value=@($base.Stdout|ConvertFrom-Json -AsHashtable)[0]
            if($value.Os -ne 'linux' -or $value.Id -notmatch '^(sha256:)?[a-f0-9]{64}$'){throw 'The explicit base must have a valid Linux image identity.'}
            $receipt.BaseImageId=$value.Id
            $sources['baseImage']=$value.Id
            $identity=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-MutatorContainerJson $sources)))).ToLowerInvariant()
            $image='localhost/'+($name.ToLowerInvariant() -replace '\.posh$','')+':'+$platformName.ToLowerInvariant()+'-'+$identity.Substring(0,16)
            $receipt.Image=$image
        }
        $cached=$null
        if($Reuse -and !$BaseVariant){
            $inspection=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$image) -Directory $context -Connection $Connection
            if($inspection.Outcome -eq 'Success'){
                $candidate=@($inspection.Stdout|ConvertFrom-Json -AsHashtable)[0]
                if($candidate.Os -eq 'linux' -and $candidate.Id -match '^(sha256:)?[a-f0-9]{64}$' -and
                    $candidate['Config'] -and $candidate.Config['Labels'] -and $candidate.Config.Labels['org.frenchexdev.mutator.build-identity'] -ceq $identity -and
                    $candidate.Config.Labels['org.frenchexdev.mutator.base-image-id'] -match '^(sha256:)?[a-f0-9]{64}$'){$cached=$candidate}
            }
        }
        if($cached){
            $receipt.Reused=$true;$receipt.Outcome='Success';$receipt.ExitCode=0
            $receipt.ImageId=$cached.Id;$receipt.SizeBytes=$cached.Size
            $receipt.BaseImageId=$cached.Config.Labels['org.frenchexdev.mutator.base-image-id']
            [IO.File]::WriteAllText($receipt.StdoutLog,'Reused the image with the matching build identity.')
            [IO.File]::WriteAllText($receipt.StderrLog,'')
        }else{
            $receipt.Dependencies=@(Initialize-MutatorImagePrerequisite -Dockerfile $dockerfile -ModuleRoot $context -OutputDirectory $output -Connection $Connection -MemoryMiB $MemoryMiB -Cpus $Cpus -TimeoutSeconds $TimeoutSeconds -BaseImage $BaseImage)
            if(!$BaseVariant -and !$BaseImage){
                $parent=[regex]::Match([IO.File]::ReadAllText($dockerfile),'(?m)^ARG BASE_IMAGE=([^\s]+)').Groups[1].Value
                $dependency=@($receipt.Dependencies|Where-Object Image -CEQ $parent)
                if($dependency.Count -eq 1){$receipt.BaseImageId=$dependency[0].ImageId}
            }
            $extra=@()
            if(!$BaseVariant){$extra+=@('--label',('org.frenchexdev.mutator.build-identity='+$identity))}
            if($receipt.BaseImageId){$extra+=@('--label',('org.frenchexdev.mutator.base-image-id='+$receipt.BaseImageId))}
            if($BaseImage){$extra+=@('--build-arg',('BASE_IMAGE='+$receipt.BaseImageId))}
            $arguments=@('build','--retry','0','--layers','--jobs','1','--memory',($MemoryMiB.ToString()+'m'),'--memory-swap',($MemoryMiB.ToString()+'m'),
                '--cpu-period','100000','--cpu-quota',($Cpus*100000).ToString(),$(if($BaseVariant){'--pull=missing'}else{'--pull=never'}),
                '--file',$dockerfile,'--ignorefile',$ignore,'--tag',$image)+$extra+@($context)
            $build=Invoke-MutatorContainerCommand -Arguments $arguments -Directory $context -TimeoutSeconds $TimeoutSeconds -Connection $Connection
            [IO.File]::WriteAllText($receipt.StdoutLog,$build.Stdout)
            [IO.File]::WriteAllText($receipt.StderrLog,$build.Stderr)
            $receipt.ExitCode=$build.ExitCode
            $receipt.Outcome=$build.Outcome
            if($build.Outcome -ne 'Success'){throw "Image build failed; retained receipt: $receiptPath"}
            $inspect=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$image) -Directory $context -Connection $Connection
            if($inspect.Outcome -ne 'Success'){throw 'The built image could not be inspected.'}
            $built=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
            if($built.Os -ne 'linux' -or $built.Id -notmatch '^(sha256:)?[a-f0-9]{64}$'){throw 'Invalid built Linux image identity.'}
            $receipt.ImageId=$built.Id
            $receipt.SizeBytes=$built.Size
        }
    }catch{
        if($receipt.Outcome -eq 'Running' -or $receipt.Outcome -eq 'Success'){$receipt.Outcome='Failed'}
        throw
    }finally{
        $receipt.DurationSeconds=[math]::Round($watch.Elapsed.TotalSeconds,3)
        $receipt.CompletedUtc=[datetime]::UtcNow.ToString('O')
        Write-MutatorJson $receiptPath $receipt
    }
    [pscustomobject]$receipt
}
