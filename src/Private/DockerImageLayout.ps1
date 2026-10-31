function Resolve-MutatorDockerArchiveFile {
    param([string]$Root,[string]$Name)
    $prefix=[IO.Path]::GetFullPath($Root)+[IO.Path]::DirectorySeparatorChar
    $path=[IO.Path]::GetFullPath((Join-Path $Root $Name))
    if([string]::IsNullOrWhiteSpace($Name) -or [IO.Path]::IsPathRooted($Name) -or !$path.StartsWith($prefix,[StringComparison]::Ordinal)){
        throw 'A Docker archive entry escapes its owned extraction directory.'
    }
    $path
}

function Expand-MutatorDockerArchive {
    param([string]$Archive,[string]$Destination)
    [void][IO.Directory]::CreateDirectory($Destination)
    $stream=[IO.File]::OpenRead($Archive)
    $reader=[System.Formats.Tar.TarReader]::new($stream)
    try{
        while($entry=$reader.GetNextEntry()){
            $path=Resolve-MutatorDockerArchiveFile $Destination $entry.Name
            if($entry.EntryType -eq [System.Formats.Tar.TarEntryType]::Directory){[void][IO.Directory]::CreateDirectory($path);continue}
            if($entry.EntryType -notin @([System.Formats.Tar.TarEntryType]::RegularFile,[System.Formats.Tar.TarEntryType]::V7RegularFile)){
                throw 'Docker image exports must contain only regular files and directories.'
            }
            [void][IO.Directory]::CreateDirectory((Split-Path $path))
            $output=[IO.FileStream]::new($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{if($entry.DataStream){$entry.DataStream.CopyTo($output)}}finally{$output.Dispose()}
        }
    }finally{$reader.Dispose();$stream.Dispose()}
}

function Copy-MutatorDockerBlob {
    param([string]$Path,[string]$Blobs,[string]$MediaType)
    $file=Get-Item -LiteralPath $Path -ErrorAction Stop
    if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'An image blob must be a regular file.'}
    $digest=(Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant()
    $destination=Join-Path $Blobs $digest
    if(!(Test-Path -LiteralPath $destination)){[IO.File]::Copy($Path,$destination,$false)}
    @{mediaType=$MediaType;digest=('sha256:'+$digest);size=$file.Length}
}

function ConvertTo-MutatorDockerImageLayout {
    param([string]$Archive,[string]$Destination,[string]$ExpectedImageId)
    $unpacked=Join-Path $Destination 'archive';Expand-MutatorDockerArchive $Archive $unpacked
    $manifests=@(Get-Content -LiteralPath (Join-Path $unpacked 'manifest.json') -Raw|ConvertFrom-Json -AsHashtable)
    if($manifests.Count -ne 1 -or !$manifests[0]['Config'] -or $null -eq $manifests[0]['Layers']){throw 'Export exactly one complete Docker image for its OCI build context.'}
    $manifest=$manifests[0]
    $layout=Join-Path $Destination 'oci';$blobs=Join-Path $layout 'blobs/sha256';[void][IO.Directory]::CreateDirectory($blobs)
    $config=Copy-MutatorDockerBlob (Resolve-MutatorDockerArchiveFile $unpacked $manifest.Config) $blobs 'application/vnd.oci.image.config.v1+json'
    if($config.digest -cne ('sha256:'+($ExpectedImageId -creplace '^sha256:',''))){throw 'The exported Docker image config differs from its inspected immutable identity.'}
    $layers=@(foreach($name in $manifest.Layers){
        $path=Resolve-MutatorDockerArchiveFile $unpacked $name
        $layerStream=[IO.File]::OpenRead($path)
        try{$gzip=($layerStream.ReadByte() -eq 31 -and $layerStream.ReadByte() -eq 139)}finally{$layerStream.Dispose()}
        $type=if($gzip){'application/vnd.oci.image.layer.v1.tar+gzip'}else{'application/vnd.oci.image.layer.v1.tar'}
        Copy-MutatorDockerBlob $path $blobs $type
    })
    $imageFile=Join-Path $Destination 'image-manifest.json'
    Write-MutatorJson $imageFile @{schemaVersion=2;mediaType='application/vnd.oci.image.manifest.v1+json';config=$config;layers=$layers}
    $image=Copy-MutatorDockerBlob $imageFile $blobs 'application/vnd.oci.image.manifest.v1+json'
    Write-MutatorJson (Join-Path $layout 'index.json') @{schemaVersion=2;manifests=@($image)}
    Write-MutatorJson (Join-Path $layout 'oci-layout') @{imageLayoutVersion='1.0.0'}
    @{Path=$layout;Reference=('oci-layout://'+$layout.Replace('\','/')+'@'+$image.digest);ImageId=$ExpectedImageId;Manifest=$image.digest;Layers=$layers.Count}
}
