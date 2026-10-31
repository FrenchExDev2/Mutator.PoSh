#requires -Version 7.6
param([string]$Machine='podman-frenchexdev',[ValidateSet('Ag','Journalctl')][string]$Profile='Journalctl',[string]$ResumeStorePath)
$ErrorActionPreference='Stop'
if($Machine -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]*$'){throw 'A simple Podman machine name is required.'}
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Machine,$Profile,$ResumeStorePath)
    $id='mutator-cold-'+[guid]::NewGuid().ToString('N')
    $storage='/var/tmp/'+$id
    $proof=Join-Path $script:MutatorRoot ('test/Artifacts/development/'+$id)
    if($ResumeStorePath){
        $proof=(Resolve-Path -LiteralPath $ResumeStorePath -ErrorAction Stop).ProviderPath
        $owned=Read-MutatorJson (Join-Path $proof 'store.json')
        if(!$owned -or $owned.Id -cnotmatch '^mutator-cold-[0-9a-f]{32}$' -or $owned.Path -cne ('/var/tmp/'+$owned.Id) -or
            $proof -cne (Join-Path $script:MutatorRoot ('test/Artifacts/development/'+$owned.Id)) -or $owned.Profile -notin @('Ag','Journalctl') -or $owned.VM -cne $Machine){throw 'Invalid retained isolated fixture identity.'}
        if(Test-Path (Join-Path $proof 'cleanup.json')){throw 'The retained isolated store has already been cleaned.'}
        $id=$owned.Id;$storage=$owned.Path;$Profile=$owned.Profile
    }
    $list=Invoke-MutatorContainerCommand -Arguments @('system','connection','list','--format','json') -Directory $script:MutatorRoot
    if($list.Outcome -ne 'Success'){throw 'Cannot discover the rootful machine connection.'}
    $parent=@($list.Stdout|ConvertFrom-Json -AsHashtable|Where-Object Name -CEQ ($Machine+'-root'))
    if($parent.Count -ne 1){throw 'The expected rootful machine connection is absent.'}
    $uri=[uri]$parent[0].URI
    if($uri.UserInfo -cne 'root' -or $uri.Host -cne '127.0.0.1'){throw 'This fixture requires a local rootful Podman machine connection.'}
    $target='ssh://root@127.0.0.1:'+$uri.Port+$storage+'/podman.sock'
    if(!$ResumeStorePath){
        $owned=@{Id=$id;VM=$Machine;Path=$storage;URI=$target;Profile=$Profile;CreatedUtc=[datetime]::UtcNow.ToString('O')}
        Write-MutatorJson (Join-Path $proof 'store.json') $owned
    }
    elseif($owned.URI -cne $target -or @($list.Stdout|ConvertFrom-Json -AsHashtable|Where-Object { $_.Name -ceq $id -and $_.URI -ceq $target }).Count -ne 1){throw 'The retained connection no longer matches its owner.'}
    $started=[bool]$ResumeStorePath;$registered=[bool]$ResumeStorePath
    try{
        if(!$ResumeStorePath){
        $start=Invoke-MutatorContainerCommand -Arguments @('machine','ssh','--username','root',$Machine,'systemd-run',('--unit='+$id),'--collect',
            '/usr/bin/podman',('--root='+$storage+'/storage'),('--runroot='+$storage+'/runroot'),'--storage-driver=vfs','--events-backend=file',
            'system','service','--time=0',('unix:'+$storage+'/podman.sock')) -Directory $script:MutatorRoot
        [IO.File]::WriteAllText((Join-Path $proof 'service.stdout.log'),$start.Stdout)
        [IO.File]::WriteAllText((Join-Path $proof 'service.stderr.log'),$start.Stderr)
        if($start.Outcome -ne 'Success'){throw ('Isolated service failed; proof: '+$proof)}
        $started=$true
        $add=Invoke-MutatorContainerCommand -Arguments @('system','connection','add','--identity',$parent[0].Identity,$id,$target) -Directory $script:MutatorRoot
        if($add.Outcome -ne 'Success'){throw 'Cannot register the temporary connection.'}
        $registered=$true
        }
        $info=Invoke-MutatorContainerCommand -Arguments @('info','--format','json') -Directory $script:MutatorRoot -Connection $id
        if($info.Outcome -ne 'Success' -or ($info.Stdout|ConvertFrom-Json -AsHashtable).store.graphRoot -cne ($storage+'/storage')){throw 'The isolated graph root differs from the owned directory.'}
        # A script invoked inside a module introduces its own script scope. Use a
        # fresh host so its imports and the driver's script variables stay isolated.
        if(!$ResumeStorePath){
        $witness=Invoke-MutatorNative (Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})) @('-NoProfile','-File',
            (Join-Path $script:MutatorRoot 'test/Fixtures/GeneratedLinuxSmoke.ps1'),'-Connection',$id,'-RequireEmptyStore','-Profile',$Profile) $script:MutatorRoot 1200
        [IO.File]::WriteAllText((Join-Path $proof 'witness.stdout.log'),$witness.Stdout)
        [IO.File]::WriteAllText((Join-Path $proof 'witness.stderr.log'),$witness.Stderr)
        if($witness.Outcome -ne 'Success'){throw ('Generated worker validation failed; proof: '+$proof)}
        }
        $summaryLines=@([IO.File]::ReadAllText((Join-Path $proof 'witness.stdout.log')) -split "`r?`n"|Where-Object {$_ -like '{*'})
        if(!$summaryLines.Count){throw 'The witness did not return a structured result.'}
        $generated=$summaryLines[-1]|ConvertFrom-Json -AsHashtable -DateKind String
        if($generated.Outcome -cne 'Success' -or $generated.Connection -cne $id -or $generated.InitialImages -ne 0){throw 'The isolated generated-worker fixture failed or belongs to another store.'}
        $attempt=if($ResumeStorePath){'resumed-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'}else{''}
        # Qualify the actual contributor separately from the synthetic mutation witness.
        $image=New-MutatorContainerImage -ModulePath (Join-Path (Split-Path $script:MutatorRoot) ('FrenchExDev.Tools.'+$Profile+'.PoSh')) `
            -OutputDirectory (Join-Path $proof ($attempt+'contributor-build')) -Connection $id -MemoryMiB 2048 -Cpus 2 -Reuse
        $qualification=Test-MutatorContainerImage -Image $image.ImageId -Profile $Profile -OutputDirectory (Join-Path $proof ($attempt+'qualification')) -Connection $id
        if($qualification.Outcome -cne 'Success'){throw 'The real contributor qualification failed.'}
        $receipt=@{Outcome='Success';Profile=$Profile;Witness=$generated;ContributorImage=$image.ImageId;Qualification=$qualification;Proof=$proof}
        Write-MutatorJson (Join-Path $proof 'receipt.json') $receipt
        @{Outcome='Success';Profile=$Profile;WitnessProof=$generated.Proof;QualificationOutcome=$qualification.Outcome;Proof=$proof}|ConvertTo-Json -Compress
    }catch{
        Write-MutatorJson (Join-Path $proof 'error.json') @{Message=$_.Exception.Message;ErrorId=$_.FullyQualifiedErrorId;Script=$_.InvocationInfo.ScriptName;Line=$_.InvocationInfo.ScriptLineNumber;Stack=$_.ScriptStackTrace}
        throw
    }finally{
        $cleanup=@{ServiceStopped=$false;ConnectionRemoved=$false;StorageRemoved=$false;Utc=[datetime]::UtcNow.ToString('O')}
        if($registered){
            $containers=Invoke-MutatorContainerCommand -Arguments @('ps','--all','--format','json') -Directory $script:MutatorRoot -Connection $id
            if($containers.Outcome -ne 'Success' -or @($containers.Stdout|ConvertFrom-Json -AsHashtable).Count){throw ('Containers remain in the isolated store; cleanup refused: '+$proof)}
        }
        if($started){
            $resolved=Invoke-MutatorContainerCommand -Arguments @('machine','ssh','--username','root',$Machine,'realpath','--',$storage) -Directory $script:MutatorRoot
            if($storage -cnotmatch '^/var/tmp/mutator-cold-[0-9a-f]{32}$' -or $resolved.Outcome -ne 'Success' -or $resolved.Stdout.Trim() -cne $storage){throw 'Isolated cleanup path validation failed.'}
            $stop=Invoke-MutatorContainerCommand -Arguments @('machine','ssh','--username','root',$Machine,'systemctl','stop',($id+'.service')) -Directory $script:MutatorRoot
            if($stop.Outcome -ne 'Success'){throw 'Cannot stop the owned service.'}
            $cleanup.ServiceStopped=$true
        }
        if($registered){
            $remove=Invoke-MutatorContainerCommand -Arguments @('system','connection','remove',$id) -Directory $script:MutatorRoot
            if($remove.Outcome -ne 'Success'){throw 'Cannot remove the owned connection.'}
            $cleanup.ConnectionRemoved=$true
        }
        if($started){
            $delete=Invoke-MutatorContainerCommand -Arguments @('machine','ssh','--username','root',$Machine,'/usr/bin/rm','-rf','--',$storage) -Directory $script:MutatorRoot
            if($delete.Outcome -ne 'Success'){throw 'Cannot remove the owned isolated storage.'}
            $cleanup.StorageRemoved=$true
        }
        Write-MutatorJson (Join-Path $proof 'cleanup.json') $cleanup
    }
} $Machine $Profile $ResumeStorePath
