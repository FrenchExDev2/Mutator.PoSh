function Get-MutatorTestFile {
    param([Parameter(Mandatory)][string]$ModulePath)
    $pending=[Collections.Generic.Stack[string]]::new()
    $pending.Push((Join-Path $ModulePath 'test'))
    while($pending.Count){
        $directory=$pending.Pop()
        foreach($file in Get-ChildItem -LiteralPath $directory -File -Filter '*.Tests.ps1'){
            if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Test discovery refuses file links.'}
            $file
        }
        foreach($child in Get-ChildItem -LiteralPath $directory -Directory){
            if($child.Name -eq 'Artifacts'){continue}
            if($child.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Test discovery refuses directory links.'}
            $pending.Push($child.FullName)
        }
    }
}
