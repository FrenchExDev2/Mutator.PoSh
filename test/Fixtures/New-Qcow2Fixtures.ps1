#requires -Version 7.6
param([Parameter(Mandatory)][string]$Image,[string]$Connection='podman-frenchexdev-root',[string]$OutputDirectory=(Join-Path $PSScriptRoot 'Disks'))
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Image,$Connection,$OutputDirectory)
    $output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    if(@(Get-ChildItem -LiteralPath $output -Force -ErrorAction Ignore).Count){throw 'QCOW2 fixtures require a new empty output directory.'}
    [void][IO.Directory]::CreateDirectory($output)
    $inspect=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$Image) -Directory $output -Connection $Connection
    if($inspect.Outcome -ne 'Success'){throw 'The local QEMU fixture image cannot be inspected.'}
    $identity=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
    if($identity.Os -cne 'linux' -or $identity.Id -notmatch '^(sha256:)?[a-f0-9]{64}$'){throw 'An immutable local Linux image with qemu-img is required.'}
    $base=@('run','--rm','--pull=never','--network=none','--memory','256m','--memory-swap','256m','--cpus','1',
        '--mount',('type=bind,source='+$output+',target=/proof'),'--entrypoint','qemu-img',$identity.Id)
    $version=Invoke-MutatorContainerCommand -Arguments ($base+@('--version')) -Directory $output -Connection $Connection
    $help=Invoke-MutatorContainerCommand -Arguments ($base+@('create','-f','qcow2','-o','help')) -Directory $output -Connection $Connection
    if($version.Outcome -ne 'Success' -or $help.Outcome -ne 'Success' -or $help.Stdout -notmatch '(?m)^\s*compat\s*='){
        throw 'The image must expose qemu-img and its qcow2 compatibility option.'
    }
    $fixtures=@(foreach($entry in @(@{Version=2;Compat='0.10'},@{Version=3;Compat='1.1'})){
        $name='qcow2-v'+$entry.Version+'.qcow2'
        $created=Invoke-MutatorContainerCommand -Arguments ($base+@('create','-f','qcow2','-o',('compat='+$entry.Compat),('/proof/'+$name),'1M')) -Directory $output -Connection $Connection
        if($created.Outcome -ne 'Success'){throw 'QCOW2 fixture creation failed.'}
        $checked=Invoke-MutatorContainerCommand -Arguments ($base+@('info','--output=json',('/proof/'+$name))) -Directory $output -Connection $Connection
        if($checked.Outcome -ne 'Success'){throw 'QCOW2 fixture inspection failed.'}
        $info=$checked.Stdout|ConvertFrom-Json -AsHashtable
        if($info.format -cne 'qcow2' -or $info['virtual-size'] -ne 1048576 -or $info.ContainsKey('backing-filename')){throw 'The generated fixture is not a self-contained one-MiB qcow2 disk.'}
        $path=Join-Path $output $name
        @{File=$name;Sha256=(Get-FileHash $path).Hash;Bytes=(Get-Item $path).Length;Version=$entry.Version;Compatibility=$entry.Compat;VirtualBytes=$info['virtual-size'];BackingFile=$null}
    })
    $proof=@{Tool='qemu-img';ToolVersion=(@($version.Stdout -split "`r?`n"|Where-Object {$_ -like 'qemu-img version *'})[0]);ImageId=$identity.Id;Connection=$Connection;Fixtures=$fixtures
        Network='None';MemoryMiB=256;Cpus=1;CreatedUtc=[datetime]::UtcNow.ToString('O');VirtualMachineStarted=$false}
    Write-MutatorJson (Join-Path $output 'provenance.json') $proof
    @{Outcome='Success';Path=$output;Fixtures=$fixtures.Count;ImageId=$identity.Id;VirtualMachineStarted=$false}|ConvertTo-Json -Compress
} $Image $Connection $OutputDirectory
