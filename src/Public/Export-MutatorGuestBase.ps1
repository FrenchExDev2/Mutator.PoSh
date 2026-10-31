function Export-MutatorGuestBase {
    <#
    .SYNOPSIS
    Export a verified cleanly stopped guest to a new seed.

    .DESCRIPTION
    Checks fingerprint, readiness and standalone qcow2 headers. Retains hashes and sizes; incomplete
    exports stay available for diagnosis.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Container,[Parameter(Mandatory)][string]$ModuleRoot,[string]$Connection,[string]$Destination,[ValidateSet('Windows','MacOS')][string]$Platform='Windows')
    $root=(Resolve-Path -LiteralPath $ModuleRoot -ErrorAction Stop).ProviderPath
    $definition=Get-MutatorContainerRuntime $root
    if($Platform -eq 'MacOS'){$definition.Fingerprint=$definition.MacFingerprint}
    if(!$Destination){$Destination=Join-Path $root ('FrenchExDev.Mutator.PoSh/test/Artifacts/container-bases/'+$Platform.ToLowerInvariant()+'/seed')}
    $Destination=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
    $inspect=Invoke-MutatorContainerCommand -Arguments @('inspect',$Container) -Directory $root -Connection $Connection
    if($inspect.Outcome -ne 'Success'){throw 'The guest base container cannot be inspected.'}
    $identity=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
    if($identity.State.Running -or $identity.State.Status -ne 'exited' -or $identity.State.ExitCode -ne 0){throw 'Shut down the prepared guest base cleanly before exporting its disk.'}
    if($identity.Config.Labels['org.frenchexdev.mutator.fingerprint'] -cne $definition.Fingerprint){throw 'The container was not prepared with the current base fingerprint.'}
    if(@(Get-ChildItem -LiteralPath $Destination -Force -ErrorAction Ignore|Where-Object Name -NE '.gitignore').Count){throw 'The seed destination is not empty. Select another destination instead of overwriting a prepared base.'}
    if(!$PSCmdlet.ShouldProcess($Destination,'Export a cleanly stopped guest base, verify its readiness receipt and fingerprint its qcow2 disk')){return}
    [void][IO.Directory]::CreateDirectory($Destination)
    $receipt=Join-Path $Destination 'base-ready.json'
    $copy=Invoke-MutatorContainerCommand -Arguments @('cp',($identity.Id+':/shared/base-ready.json'),$receipt) -Directory $root -TimeoutSeconds 60 -Connection $Connection
    if($copy.Outcome -ne 'Success'){throw 'The base has no retained guest readiness receipt.'}
    $proof=Read-MutatorJson $receipt
    if(!$proof -or $proof.Outcome -ne 'Success' -or $proof.Fingerprint -cne $definition.Fingerprint){throw 'The guest common runtime did not pass its preparation gate.'}
    $storage=Join-Path $Destination 'storage';[void][IO.Directory]::CreateDirectory($storage)
    $copy=Invoke-MutatorContainerCommand -Arguments @('cp',($identity.Id+':/storage/.'),$storage) -Directory $root -TimeoutSeconds 7200 -Connection $Connection
    if($copy.Outcome -ne 'Success'){throw 'guest base storage export failed; the incomplete destination is retained for diagnosis.'}
    $files=@(foreach($file in Get-ChildItem -LiteralPath $storage -Force -Recurse){
        if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Base storage links are refused.'}
        if($file.PSIsContainer){continue}
        if($file.Extension -eq '.qcow2'){
            $stream=[IO.File]::OpenRead($file.FullName);$header=[byte[]]::new(24)
            try{$read=$stream.Read($header,0,$header.Length)}finally{$stream.Dispose()}
            if($read -lt 24 -or [Convert]::ToHexString($header[0..3]) -ne '514649FB' -or [Convert]::ToHexString($header[4..7]) -notin @('00000002','00000003')){throw 'The base disk is not a valid qcow2 image.'}
            if(@($header[8..19]|Where-Object{$_ -ne 0}).Count){throw 'The prepared base already depends on another backing disk; flatten it before exporting.'}
        }
        @{Path=[IO.Path]::GetRelativePath($storage,$file.FullName).Replace('\','/');Sha256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant();Bytes=$file.Length}
    })
    if(!@($files|Where-Object Path -Like '*.qcow2').Count){throw 'The base must be provisioned with DISK_FMT=qcow2 for isolated thin clones.'}
    Write-MutatorJson (Join-Path $Destination 'base.json') @{Fingerprint=$definition.Fingerprint;ContainerId=$identity.Id;Files=$files;CapturedUtc=[datetime]::UtcNow.ToString('O');CleanShutdown=$true}
    [pscustomobject]@{Path=$Destination;Fingerprint=$definition.Fingerprint;Files=$files.Count;Outcome='Success'}
}
