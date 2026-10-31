function Get-MutatorProductionFile {
    param([Parameter(Mandatory)][string]$ModulePath)
    $root=(Resolve-Path -LiteralPath $ModulePath -ErrorAction Stop).ProviderPath
    $name=Split-Path $root -Leaf
    $manifest=Import-PowerShellDataFile -LiteralPath (Join-Path $root ($name+'.psd1'))
    $entry=[IO.Path]::GetFullPath((Join-Path $root $manifest.RootModule))
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(!$entry.StartsWith(($root+[IO.Path]::DirectorySeparatorChar),$comparison)) {throw 'RootModule must remain inside the module.'}
    if(!(Test-Path -LiteralPath $entry -PathType Leaf)){throw 'The declared RootModule is missing.'}
    $paths=@($entry)+@(Get-ChildItem -LiteralPath $root -File -Filter '*.ps1'|Select-Object -ExpandProperty FullName)
    foreach($directory in @('src','resources')){
        $folder=Join-Path $root $directory
        if(Test-Path -LiteralPath $folder){
            $paths+=@(Get-ChildItem -LiteralPath $folder -File -Recurse|Where-Object Extension -In @('.ps1','.psm1')|Select-Object -ExpandProperty FullName)
        }
    }
    $paths|Sort-Object -Unique
}
