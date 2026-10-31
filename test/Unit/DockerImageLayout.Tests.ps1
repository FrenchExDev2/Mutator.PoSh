<#
.SYNOPSIS
Expected behavior for the DockerImageLayout tests.

.DESCRIPTION
Extract only contained regular files and convert exactly one inspected image to an OCI layout.
Verify configuration/layer identity and reject traversal, links, malformed manifests and
inconsistent image IDs.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:DockerLayoutModule=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:DockerLayoutModule 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    . (Join-Path $script:DockerLayoutModule 'test/Fixtures/DockerExportFixture.ps1')
}
Describe 'Local Docker image exports become verified OCI contexts' {
    It 'preserves the exact config and both raw and compressed layers: <Layers>' -ForEach @(@{Layers=0},@{Layers=1},@{Layers=2}) {
        $fixture=New-DockerExportFixture $TestDrive -Layers $Layers
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Fixture=$fixture;Root=$TestDrive;Layers=$Layers} {
            param($Fixture,$Root,$Layers)
            $destination=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $r=ConvertTo-MutatorDockerImageLayout $Fixture.Archive $destination $Fixture.ImageId
            $r.Layers|Should -Be $Layers;$r.Reference|Should -BeLike 'oci-layout://*@sha256:*'
            $index=Read-MutatorJson (Join-Path $r.Path 'index.json')
            $index.manifests.Count|Should -Be 1
            $manifest=Read-MutatorJson (Join-Path $r.Path ('blobs/sha256/'+$r.Manifest.Substring(7)))
            $manifest.config.digest|Should -BeExactly $Fixture.ImageId
            $manifest.layers.Count|Should -Be $Layers
            for($i=0;$i -lt $Layers;$i++){
                $layer=$manifest.layers[$i]
                $layer.mediaType|Should -BeExactly $(if($i -eq 0){'application/vnd.oci.image.layer.v1.tar'}else{'application/vnd.oci.image.layer.v1.tar+gzip'})
                $blob=Join-Path $r.Path ('blobs/sha256/'+$layer.digest.Substring(7))
                (Get-FileHash $blob).Hash.ToLowerInvariant()|Should -BeExactly $layer.digest.Substring(7)
                (Get-Item $blob).Length|Should -Be $layer.size
            }
            (Read-MutatorJson (Join-Path $r.Path 'oci-layout')).imageLayoutVersion|Should -BeExactly '1.0.0'
            [IO.File]::ReadAllText((Join-Path $destination 'archive/empty-file'))|Should -BeExactly ''
            Test-Path (Join-Path $destination 'archive/empty-directory') -PathType Container|Should -BeTrue
            $blobs=Join-Path $r.Path 'blobs/sha256'
            $again=Copy-MutatorDockerBlob (Join-Path $Fixture.Payload 'config.json') $blobs 'application/vnd.oci.image.config.v1+json'
            $again.digest|Should -BeExactly $Fixture.ImageId
        }
    }
    It 'refuses incomplete or foreign exports: <Fault>' -ForEach @(
        @{Fault='Multiple';Expected='*exactly one complete*'},@{Fault='MissingLayers';Expected='*exactly one complete*'},
        @{Fault='EscapingConfig';Expected='*escapes its owned extraction*'},@{Fault='WrongImage';Expected='*immutable identity*'}
    ) {
        $fixture=New-DockerExportFixture $TestDrive -Fault $Fault
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Fixture=$fixture;Root=$TestDrive;Fault=$Fault;Expected=$Expected} {
            param($Fixture,$Root,$Fault,$Expected)
            $id=if($Fault -eq 'WrongImage'){'a'*64}else{$Fixture.ImageId}
            {ConvertTo-MutatorDockerImageLayout $Fixture.Archive (Join-Path $Root ([guid]::NewGuid().ToString('N'))) $id}|Should -Throw $Expected
        }
    }
    It 'refuses path traversal, absolute paths and empty archive paths: <Name>' -ForEach @(@{Name='../outside'},@{Name='/absolute'},@{Name=''}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive;Name=$Name} {
            param($Root,$Name)
            {Resolve-MutatorDockerArchiveFile $Root $Name}|Should -Throw '*escapes its owned extraction*'
        }
    }
    It 'refuses links and escaping entries before creating any outside file: <Kind>' -ForEach @(@{Kind='Link'},@{Kind='Escape'}) {
        $archive=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'.tar')
        $stream=[IO.File]::Create($archive);$writer=[System.Formats.Tar.TarWriter]::new($stream)
        try{
            $entry=if($Kind -eq 'Link'){[System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::SymbolicLink,'alias')}else{[System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile,'../outside')}
            if($Kind -eq 'Link'){$entry.LinkName='../outside'}else{$entry.DataStream=[IO.MemoryStream]::new([byte[]]@(1,2,3))}
            $writer.WriteEntry($entry)
        }finally{$writer.Dispose();$stream.Dispose()}
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Archive=$archive;Root=$TestDrive;Kind=$Kind} {
            param($Archive,$Root,$Kind)
            {Expand-MutatorDockerArchive $Archive (Join-Path $Root ([guid]::NewGuid().ToString('N')))}|Should -Throw $(if($Kind -eq 'Link'){'*regular files and directories*'}else{'*escapes its owned extraction*'})
            Test-Path (Join-Path $Root 'outside')|Should -BeFalse
            $blobs=Join-Path $Root ([guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($blobs)
            {Copy-MutatorDockerBlob $Root $blobs fixture}|Should -Throw '*regular file*'
        }
    }
}
