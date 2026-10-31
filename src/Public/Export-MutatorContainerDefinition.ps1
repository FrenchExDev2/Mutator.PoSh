function Export-MutatorContainerDefinition {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string[]]$ModulePath,[switch]$Force,[ValidateSet('Dockurr','Native')][string]$WindowsBackend='Dockurr',[switch]$IncludeMacOS)
    $templates=Join-Path $script:MutatorRoot 'resources/containers/definitions'
    foreach($inputPath in $ModulePath){
        $root=(Resolve-Path -LiteralPath $inputPath -ErrorAction Stop).ProviderPath
        $name=Split-Path $root -Leaf
        if($name -ceq 'FrenchExDev.QuietCli.Git.PoSh'){throw 'Git container definitions are owned by CliEnvironment; use Export-CliEnvironmentGitDefinition. Force cannot overwrite that ownership.'}
        $manifest=Import-PowerShellDataFile (Join-Path $root ($name+'.psd1'))
        if($name -cnotmatch '^FrenchExDev\.(?<profile>[A-Za-z0-9_.-]+)\.PoSh$'){throw 'Container definitions require a FrenchExDev module.'}
        $key=$Matches.profile -creplace '^Tools\.',''
        if($name -in @('FrenchExDev.Mutator.PoSh','FrenchExDev.QuietCli.PoSh','FrenchExDev.DevPoSh.PoSh')){$key='Engine'}
        $metadata=if($manifest['PrivateData'] -and $manifest.PrivateData['Mutator']){$manifest.PrivateData.Mutator}else{@{}}
        if($metadata['Profile']){$key=[string]$metadata.Profile}
        $commands=@($metadata['Commands']|Where-Object {$_})
        if(!$commands.Count -and !$metadata['Profile']){$key='Engine'}
        $binary=if($commands.Count){$commands[0]}else{$null}
        if($key -eq 'Gradle'){$binary='gradle'}elseif($key -eq 'Mvn'){$binary='mvn'}elseif($key -eq 'Pytest'){$binary='pytest'}
        $profiles=Get-MutatorContainerProfile $key $binary
        if($IncludeMacOS){$profiles.MacOS=Get-MutatorMacOSProfile $key $binary}
        if($metadata['Container']){
            if($metadata.Container -isnot [Collections.IDictionary]){throw 'Mutator.Container must map canonical platforms to pinned asset settings.'}
            foreach($platform in $metadata.Container.Keys){
                if($platform -cnotin @('Linux','Windows','MacOS') -or $metadata.Container[$platform] -isnot [Collections.IDictionary]){throw 'Invalid pinned container platform.'}
                foreach($field in $metadata.Container[$platform].Keys){
                    if($field -cnotin @('Version','Uri','Sha256','RunTestsSha256') -or $metadata.Container[$platform][$field] -isnot [string]){throw 'Invalid pinned container asset setting.'}
                    if($profiles.ContainsKey($platform)){$profiles[$platform][$field]=$metadata.Container[$platform][$field]}
                }
                if($profiles.ContainsKey($platform) -and $profiles[$platform].Method -eq 'Artifact' -and $profiles[$platform]['Uri'] -and $profiles[$platform]['Sha256'] -match '^[a-fA-F0-9]{64}$'){$profiles[$platform].Status='Prepared'}
            }
        }
        $moduleRoot=Get-MutatorModuleRoot $root
        $runtime=Get-MutatorContainerRuntime $moduleRoot
        $dependencies=@(Get-MutatorContainerDependency $root)
        $profiles.Windows.Backend=$WindowsBackend
        $profiles.Windows.ContainerOS=if($WindowsBackend -eq 'Dockurr'){'Linux'}else{'Windows'}
        if($WindowsBackend -eq 'Dockurr'){$profiles.Windows.GuestOS='Windows Server 2025';$profiles.Windows.Installation='OnCloneBoot';$profiles.Windows.VirtualMachine=$true}
        $metadata=@{SchemaVersion=1;Module=$name;Commands=$commands;Architecture='amd64';Platforms=$profiles;Runtime=$runtime.Runtime;BaseFingerprint=$runtime.Fingerprint;MacBaseFingerprint=$runtime.MacFingerprint;HostControllerFingerprint=$runtime.ControllerFingerprint
            BootstrapSha256=(Get-MutatorSourceSnapshot (Join-Path $templates 'bootstrap')).Sha256}
        $files=@{'image.json'=(ConvertTo-MutatorContainerJson $metadata)}
        $platforms=@('Linux','Windows')+$(if($IncludeMacOS){@('MacOS')}else{@()})
        foreach($platformName in $platforms){
            $platform=$platformName.ToLowerInvariant()
            $toolProfile=$profiles[$platformName]
            $macos=$platform -eq 'macos'
            $dockurr=$platform -eq 'windows' -and $WindowsBackend -eq 'Dockurr'
            $template=if($macos){'Dockerfile.macos.template'}elseif($dockurr){'Dockerfile.dockurr.template'}else{'Dockerfile.module.template'}
            $text=[IO.File]::ReadAllText((Join-Path $templates $template)).Replace("`r`n","`n")
            $text=$text.Replace('__MODULE_SOURCE__',[IO.Path]::GetRelativePath($moduleRoot,$root).Replace('\','/'))
            $destination=if($dockurr -or $macos){'/shared/mutator/modules/'}elseif($platform -eq 'linux'){'/opt/mutator/modules/'}else{'C:/mutator/modules/'}
            $image=if($macos){$runtime.Images.MacOS}elseif($dockurr){$runtime.Images.Windows}elseif($platform -eq 'windows'){$runtime.Images.Native}elseif($key -eq 'Swift'){$runtime.Images.Swift}else{$runtime.Images[$profiles.Linux.Distribution]}
            $installRoot=if($platform -eq 'linux'){'/opt/mutator'}else{'C:/mutator'}
            $copies=@(foreach($module in $dependencies){
                $relative=[IO.Path]::GetRelativePath($moduleRoot,(Resolve-MutatorModuleDirectory $moduleRoot $module)).Replace('\','/')
                'COPY '+(ConvertTo-Json -InputObject @(($relative+'/'),($destination+$relative+'/')) -Compress)
            })
            $copy=if($toolProfile.Method -eq 'ImageCopy'){'COPY --from='+$toolProfile.SourceImage+' '+$toolProfile.SourcePath+' /opt/mutator/bin/'+$toolProfile.Binary}else{''}
            $user=if($toolProfile['User']){'USER '+$toolProfile.User}else{''}
            $text=$text.Replace('__MODULE__',$name).Replace('__MODULE_COPIES__',($copies -join "`n")).Replace('__RUNTIME_BASE__',$image).Replace('__ROOT__',$installRoot).Replace('__PLATFORM__',$platform).Replace('__INSTALL_PLATFORM__',$(if($platform -eq 'linux'){'Linux'}else{'Windows'})).Replace('__TOOL_COPY__',$copy).Replace('__USER__',$user)
            if($platform -eq 'windows' -and !$dockurr){$text='# escape=`'+"`n"+$text}
            if($toolProfile.Method -eq 'Unsupported'){
                $notice='# UNSUPPORTED: '+$toolProfile.Reason+"`n"
                $text=if($platform -eq 'windows' -and !$dockurr){$text.Replace('# escape=`'+"`n",'# escape=`'+"`n"+$notice)}else{$notice+$text}
            }
            $files[$platform+'/Dockerfile']=$text
            $files[$platform+'/Dockerfile.dockerignore']=[IO.File]::ReadAllText((Join-Path $templates 'context.ignore'))
            if($dockurr){$files['windows/compose.yaml']=[IO.File]::ReadAllText((Join-Path $templates 'compose.windows.template')).Replace('__MODULE__',$name).Replace('__IMAGE_NAME__',($name.ToLowerInvariant() -replace '\.posh$','')).Replace('__PROJECT_NAME__',(($name.ToLowerInvariant() -replace '\.posh$','') -replace '\.','-'))}
            if($macos){$files['macos/compose.yaml']=[IO.File]::ReadAllText((Join-Path $templates 'compose.macos.template')).Replace('__MODULE__',$name).Replace('__IMAGE_NAME__',($name.ToLowerInvariant() -replace '\.posh$','')).Replace('__PROJECT_NAME__',(($name.ToLowerInvariant() -replace '\.posh$','') -replace '\.','-'))}
        }
        $directory=Join-Path $root 'containers'
        if(!$Force -and @($files.Keys|Where-Object{Test-Path (Join-Path $directory $_)}).Count){throw "Container definitions already exist for $name; use -Force to regenerate."}
        if($PSCmdlet.ShouldProcess($directory,'Write per-module layers using the shared prepared runtime bases')){
            foreach($file in $files.Keys){$target=Join-Path $directory $file;[void][IO.Directory]::CreateDirectory((Split-Path $target));[IO.File]::WriteAllText($target,$files[$file],[Text.UTF8Encoding]::new($false))}
        }
        [pscustomobject]@{Module=$name;Linux=$profiles.Linux.Status;Windows=$profiles.Windows.Status;MacOS=$(if($IncludeMacOS){$profiles.MacOS.Status}else{$null});Path=$directory}
    }
}
