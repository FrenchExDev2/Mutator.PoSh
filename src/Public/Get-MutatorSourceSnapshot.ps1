function Get-MutatorSourceSnapshot {
    param([string]$Root)
    $rootPath=[IO.Path]::GetFullPath($Root)
    $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($rootPath)
    $files=[Collections.Generic.List[object]]::new()
    while($pending.Count) {
        $directory=[IO.DirectoryInfo]::new($pending.Pop())
        foreach($child in $directory.EnumerateDirectories()) {
            if($child.Name -notin @('.git','.cache','Artifacts') -and !($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pending.Push($child.FullName) }
        }
        foreach($file in $directory.EnumerateFiles()) {
            if($file.Name -eq '.git'){continue}
            $files.Add([ordered]@{Path=[IO.Path]::GetRelativePath($rootPath,$file.FullName).Replace('\','/');Bytes=$file.Length
                Sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()})
        }
    }
    $ordered=@($files|Sort-Object {$_.Path} -CaseSensitive)
    $identity=(@($ordered|ForEach-Object{$_.Path+':'+$_.Sha256}) -join "`n")
    return @{Files=$ordered;Sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()}
}
