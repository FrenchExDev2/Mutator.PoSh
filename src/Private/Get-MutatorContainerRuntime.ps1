function Get-MutatorContainerRuntime {
    param([string]$ModuleRoot)
    $directory=Join-Path $script:MutatorRoot 'resources/containers/definitions'
    $runtime=Import-PowerShellDataFile (Join-Path $directory 'runtime-versions.psd1')
    $lock=Read-MutatorJson (Join-Path $directory 'container-images.lock.json')
    $versions=Read-MutatorJson (Join-Path $directory 'package-versions.json')
    $bootstrap=(Get-MutatorSourceSnapshot (Join-Path $directory 'bootstrap')).Sha256
    $identity=@(ConvertTo-MutatorContainerJson $runtime.Stable)+@($lock.stable.Reference,$versions.Sources.DockurrImage,$versions.Windows['dotnet-sdk'],$bootstrap)
    $identity+=@(ConvertTo-MutatorContainerJson $versions.Linux)+@(ConvertTo-MutatorContainerJson $versions.LinuxGlibc)
    foreach($file in @('bootstrap/Initialize-Image.ps1','guest/Install-WindowsBase.ps1','guest/Test-WindowsBase.ps1','guest/Initialize-WindowsModule.ps1','guest/Start-SeededGuest.sh','Dockerfile.linux.template','Dockerfile.debian.template','Dockerfile.windows.template','Dockerfile.windows-base.template','Dockerfile.windows-seed.template')){
        $identity+=(Get-FileHash (Join-Path $directory $file)).Hash
    }
    $fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($identity -join "`n")))).ToLowerInvariant()
    $tag='pwsh-'+$runtime.Stable.Version+'-'+$fingerprint.Substring(0,12)
    $macIdentity=@(ConvertTo-MutatorContainerJson $versions.MacOS)+@($bootstrap)
    foreach($file in @('bootstrap/Initialize-Image.ps1','macos/Install-MacOSBase.sh','macos/Initialize-MacOSBase.ps1','macos/Initialize-MacOSModule.ps1','macos/Invoke-MacOSBootstrapCommand.ps1','guest/Start-SeededGuest.sh','Dockerfile.macos-base.template')){$macIdentity+=(Get-FileHash (Join-Path $directory $file)).Hash}
    $macFingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($macIdentity -join "`n")))).ToLowerInvariant()
    $macTag='pwsh-'+$runtime.Stable.Version+'-'+$macFingerprint.Substring(0,12)
    # Host-only changes must not invalidate a verified immutable Windows/macOS disk.
    $controllerIdentity=(Get-FileHash (Join-Path $directory 'Dockerfile.host-powershell.template')).Hash+'|'+(Get-FileHash (Join-Path $script:MutatorRoot 'src/Private/Add-MutatorHostPowerShell.ps1')).Hash+'|'+$runtime.Stable.Version+'|'+$runtime.Stable.LinuxSHA256
    $controllerFingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($controllerIdentity))).ToLowerInvariant()
    $controllerSuffix='-controller-'+$controllerFingerprint.Substring(0,12)
    @{Fingerprint=$fingerprint;MacFingerprint=$macFingerprint;ControllerFingerprint=$controllerFingerprint;Tag=$tag;Runtime=$runtime.Stable;Lock=$lock;Versions=$versions;Images=@{
        Alpine='localhost/frenchexdev-mutator-base:alpine-'+$tag
        Debian='localhost/frenchexdev-mutator-base:debian-'+$tag
        Swift='localhost/frenchexdev-mutator-base:swift-'+$tag
        Native='localhost/frenchexdev-mutator-base:windows-native-'+$tag
        Bootstrap='localhost/frenchexdev-mutator-base:windows-bootstrap-'+$tag+$controllerSuffix
        Windows='localhost/frenchexdev-mutator-base:windows-'+$tag+$controllerSuffix
        MacBootstrap='localhost/frenchexdev-mutator-base:macos-bootstrap-'+$macTag+$controllerSuffix
        MacOS='localhost/frenchexdev-mutator-base:macos-'+$macTag+$controllerSuffix
    }}
}
