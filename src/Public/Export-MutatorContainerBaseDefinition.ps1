function Export-MutatorContainerBaseDefinition {
    <#
    .SYNOPSIS
    Generate shared pinned runtime and guest seed recipes.

    .DESCRIPTION
    Uses version/template fingerprints and honors ShouldProcess. Writes definitions without building or
    booting images.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$ModuleRoot)
    $root=(Resolve-Path -LiteralPath $ModuleRoot -ErrorAction Stop).ProviderPath
    $definition=Get-MutatorContainerRuntime $root
    $directory=Join-Path $root 'FrenchExDev.Mutator.PoSh/resources/containers/base'
    $templates=Join-Path $script:MutatorRoot 'resources/containers/definitions'
    $files=@{}
    $packages=@(foreach($name in @('ca-certificates','curl','dotnet10-sdk','icu-libs','krb5-libs','libgcc','libintl','libssl3','libstdc++','ncurses-terminfo-base','tzdata','zlib')){$name+'='+$definition.Versions.Linux[$name]})
    foreach($variant in @('alpine','debian','swift','windows-native')){
        $template=switch($variant){'alpine'{'linux'};'windows-native'{'windows'};default{'debian'}}
        $text=[IO.File]::ReadAllText((Join-Path $templates ('Dockerfile.'+$template+'.template'))).Replace("`r`n","`n")
        $cut=$text.IndexOf('COPY [')
        if($cut -lt 0){throw 'Missing shared runtime boundary.'}
        $text=$text.Substring(0,$cut)
        $sha=switch($variant){'alpine'{$definition.Runtime.LinuxMuslSHA256};'windows-native'{$definition.Runtime.WindowsSHA256};default{$definition.Runtime.LinuxSHA256}}
        $base=if($variant -eq 'swift'){'docker.io/library/swift:6.4.1-bookworm'}else{'docker.io/library/debian:bookworm-slim'}
        $text=$text.Replace('__MODULE__','runtime-base').Replace('__PWSH_VERSION__',$definition.Runtime.Version).Replace('__PWSH_SHA256__',$sha).Replace('__ALPINE_BASE__',$definition.Lock.stable.Reference).Replace('__RUNTIME_PACKAGES__',($packages -join ' ')).Replace('__DEBIAN_BASE__',$base)
        $text=$text.Replace('__DOTNET_SDK_URI__',$definition.Versions.LinuxGlibc.Dotnet.Uri).Replace('__DOTNET_SDK_SHA512__',$definition.Versions.LinuxGlibc.Dotnet.Sha512)
        $destination=if($variant -eq 'windows-native'){'C:/mutator'}else{'/opt/mutator'}
        $bootstrapPath=$destination+'/bootstrap/Initialize-Image.ps1'
        $text+='COPY '+(ConvertTo-Json -InputObject @('FrenchExDev.Mutator.PoSh/resources/containers/definitions/bootstrap/Initialize-Image.ps1',$bootstrapPath) -Compress)+"`n"
        $text+='RUN '+(ConvertTo-Json -InputObject @('pwsh','-NoLogo','-NoProfile','-File',$bootstrapPath) -Compress)+"`n"
        $text+='LABEL org.frenchexdev.mutator.fingerprint="'+$definition.Fingerprint+'"'+"`n"
        $files[$variant+'/Dockerfile']=$text
        $files[$variant+'/Dockerfile.dockerignore']=[IO.File]::ReadAllText((Join-Path $templates 'context.ignore'))
    }
    foreach($pair in @(@('windows-bootstrap','Dockerfile.windows-base.template'),@('windows','Dockerfile.windows-seed.template'))){
        $files[$pair[0]+'/Dockerfile']=[IO.File]::ReadAllText((Join-Path $templates $pair[1])).Replace('__DOCKURR_IMAGE__',$definition.Versions.Sources.DockurrImage).Replace('__FINGERPRINT__',$definition.Fingerprint)
        $files[$pair[0]+'/Dockerfile.dockerignore']=[IO.File]::ReadAllText((Join-Path $templates 'context.ignore'))
    }
    $base=@{SchemaVersion=1;Module='FrenchExDev.Mutator.PoSh';Runtime=$definition.Runtime;BaseFingerprint=$definition.Fingerprint;Platforms=@{Windows=@{Method='Chocolatey';Binary='dotnet';Packages=@('dotnet-sdk='+$definition.Versions.Windows['dotnet-sdk'])}}}
    $files['windows-bootstrap/image.json']=ConvertTo-MutatorContainerJson $base
    $files['macos-bootstrap/Dockerfile']=[IO.File]::ReadAllText((Join-Path $templates 'Dockerfile.macos-base.template')).Replace('__MACOS_IMAGE__',$definition.Versions.MacOS.Image).Replace('__FINGERPRINT__',$definition.MacFingerprint)
    $files['macos-bootstrap/Dockerfile.dockerignore']=[IO.File]::ReadAllText((Join-Path $templates 'context.ignore'))
    $mac=@{Fingerprint=$definition.MacFingerprint;PowerShell=$definition.Versions.MacOS.PowerShell;Dotnet=$definition.Versions.MacOS.Dotnet;HomebrewSha256=$definition.Versions.Sources.HomebrewBootstrapSHA256}
    $files['macos-bootstrap/runtime.json']=ConvertTo-MutatorContainerJson $mac
    $files['macos/Dockerfile']=[IO.File]::ReadAllText((Join-Path $templates 'Dockerfile.windows-seed.template')).Replace('__DOCKURR_IMAGE__',$definition.Versions.MacOS.Image).Replace('__FINGERPRINT__',$definition.MacFingerprint).Replace('/container-bases/windows/seed/','/container-bases/macos/seed/').Replace('VERSION=2025','VERSION=15').Replace('windows-seed','macos-seed')
    $files['macos/Dockerfile.dockerignore']=[IO.File]::ReadAllText((Join-Path $templates 'context.ignore'))
    foreach($variant in @('windows-bootstrap','windows','macos-bootstrap','macos')){$files[$variant+'/Dockerfile']=Add-MutatorHostPowerShell $files[$variant+'/Dockerfile'] $definition}
    $files['runtime.json']=ConvertTo-MutatorContainerJson @{Fingerprint=$definition.Fingerprint;MacFingerprint=$definition.MacFingerprint;ControllerFingerprint=$definition.ControllerFingerprint;Images=$definition.Images;BuildValidated=$false}
    foreach($platform in @('windows','macos')){
        $prefix='FrenchExDev.Mutator.PoSh/test/Artifacts'
        $files[$platform+'/Dockerfile.dockerignore']+="`n!$prefix/`n$prefix/**`n!$prefix/container-bases/`n!$prefix/container-bases/$platform/`n!$prefix/container-bases/$platform/seed/`n!$prefix/container-bases/$platform/seed/**`n"
    }
    if($PSCmdlet.ShouldProcess($directory,'Write shared runtime bases and the Windows prepared-disk seed recipe')){
        foreach($file in $files.Keys){$target=Join-Path $directory $file;[void][IO.Directory]::CreateDirectory((Split-Path $target));if(!(Test-Path $target) -or [IO.File]::ReadAllText($target) -cne $files[$file]){[IO.File]::WriteAllText($target,$files[$file],[Text.UTF8Encoding]::new($false))}}
        foreach($platform in @('windows','macos')){[void][IO.Directory]::CreateDirectory((Join-Path $root ('FrenchExDev.Mutator.PoSh/test/Artifacts/container-bases/'+$platform+'/seed')))}
    }
    [pscustomobject]@{Path=$directory;Fingerprint=$definition.Fingerprint;Images=$definition.Images}
}
