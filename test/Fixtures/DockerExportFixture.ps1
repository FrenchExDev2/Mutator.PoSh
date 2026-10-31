function New-DockerExportFixture {
    param([string]$Root,[int]$Layers=2,[string]$Fault)
    $directory=Join-Path $Root ([guid]::NewGuid().ToString('N'));$payload=Join-Path $directory 'payload'
    [void][IO.Directory]::CreateDirectory($payload)
    $layerSource=Join-Path $directory 'layer';[void][IO.Directory]::CreateDirectory($layerSource)
    [IO.File]::WriteAllText((Join-Path $layerSource 'value.txt'),'image layer fixture')
    $raw=Join-Path $payload 'layer.tar';[System.Formats.Tar.TarFile]::CreateFromDirectory($layerSource,$raw,$false)
    $diff=(Get-FileHash $raw).Hash.ToLowerInvariant()
    $gzip=Join-Path $payload 'layer.tar.gz';$input=[IO.File]::OpenRead($raw);$output=[IO.File]::Create($gzip)
    $compressed=[IO.Compression.GZipStream]::new($output,[IO.Compression.CompressionMode]::Compress)
    try{$input.CopyTo($compressed)}finally{$input.Dispose();$compressed.Dispose();$output.Dispose()}
    $names=@(if($Layers -ge 1){'layer.tar'};if($Layers -ge 2){'layer.tar.gz'})
    $ids=@(foreach($name in $names){'sha256:'+$diff})
    $config=Join-Path $payload 'config.json'
    [IO.File]::WriteAllText($config,(@{architecture='amd64';os='linux';rootfs=@{type='layers';diff_ids=$ids};config=@{}}|ConvertTo-Json -Depth 5 -Compress))
    $id='sha256:'+(Get-FileHash $config).Hash.ToLowerInvariant()
    $manifest=@{Config='config.json';Layers=$names;RepoTags=@('base:fixture')}
    if($Fault -eq 'MissingLayers'){$manifest.Remove('Layers')}
    if($Fault -eq 'EscapingConfig'){$manifest.Config='../config.json'}
    $manifests=if($Fault -eq 'Multiple'){@($manifest,$manifest)}else{@($manifest)}
    [IO.File]::WriteAllText((Join-Path $payload 'manifest.json'),(ConvertTo-Json -InputObject $manifests -Depth 5 -Compress))
    [void][IO.Directory]::CreateDirectory((Join-Path $payload 'empty-directory'))
    [IO.File]::WriteAllText((Join-Path $payload 'empty-file'),'')
    $archive=Join-Path $directory 'image.tar';[System.Formats.Tar.TarFile]::CreateFromDirectory($payload,$archive,$false)
    @{Archive=$archive;ImageId=$id;Payload=$payload}
}
