function Copy-MutatorIsolatedReport {
    <#
    .SYNOPSIS
    Recover mutation and recheck evidence from an isolated package directory.

    .DESCRIPTION
    Copies available mutation reports, context receipts and dedicated recheck reports to the canonical
    host directory. Missing sources produce no invented evidence.
    #>

    param([string]$Source,[string]$Destination)
    if(!(Test-Path -LiteralPath $Source -PathType Container)){return}
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach($file in @(Get-ChildItem -LiteralPath $Source -File -Filter 'mutation*.json*')){
        Copy-Item -LiteralPath $file.FullName -Destination $Destination -Force
    }
    foreach($name in @('recheck.json','mutation.recheck.json')){
        $path=Join-Path $Source ('recheck/'+$name)
        if(Test-Path -LiteralPath $path -PathType Leaf){Copy-Item -LiteralPath $path -Destination (Join-Path $Destination $name) -Force}
    }
}
