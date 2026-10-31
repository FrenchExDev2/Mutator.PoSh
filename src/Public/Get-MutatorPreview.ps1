function Get-MutatorPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModulePath)
    $root=(Resolve-Path -LiteralPath $ModulePath -ErrorAction Stop).ProviderPath
    $configuration=Join-Path $root 'test/psmutant.config.json'
    $data=Read-MutatorJson $configuration
    $parent=Split-Path $root
    $subtrees=@(Get-MutatorSubtree $parent $data)
    $owner=Join-Path $script:MutatorRoot 'test/Artifacts/previews'
    $stage=Join-Path $owner ([guid]::NewGuid().ToString('N'))
    try{
        foreach($subtree in $subtrees){Copy-MutatorTree (Join-Path $parent $subtree) (Join-Path $stage $subtree)}
        Import-Module Pester -RequiredVersion 6.2.0 -ErrorAction Stop
        $null=Import-MutatorTool
        $stagedConfiguration=Join-Path $stage ([IO.Path]::GetRelativePath($parent,$configuration))
        Invoke-PSMutation -ConfigFile $stagedConfiguration -SourceRoot $stage -ListOnly -Quiet
    }finally{
        if(Test-Path -LiteralPath $stage){
            $resolved=(Resolve-Path -LiteralPath $stage).ProviderPath
            if(!$resolved.StartsWith(([IO.Path]::GetFullPath($owner)+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing preview cleanup outside its owned directory.'}
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
