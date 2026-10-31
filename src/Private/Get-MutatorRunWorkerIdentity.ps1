function Read-MutatorProcessArgument {
    param([int]$Id,[string]$ProcRoot='/proc')
    [IO.File]::ReadAllText((Join-Path $ProcRoot ($Id.ToString()+'/cmdline'))).Split([char]0)
}

function Get-MutatorRunWorkerIdentity {
    param([string]$RunDirectory)
    $comparison=if(Test-MutatorWindowsPlatform){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    foreach($process in Get-Process -Name pwsh -ErrorAction Ignore){
        if($process.Id -eq $PID){continue}
        $directory=$null
        if(Test-MutatorWindowsPlatform){
            $native=Get-CimInstance Win32_Process -Filter ('ProcessId = '+$process.Id) -ErrorAction Ignore
            if(!$native){continue}
            $line=$native.CommandLine
            if($line -notmatch '(?i)(?:^|\s)"?-File"?\s+"?[^"\r\n]*[/\\]Run-Worker\.ps1"?(?:\s|$)'){continue}
            $argument=[regex]::Match($line,'(?i)"?-RunDirectory"?\s+(?:"([^"]+)"|(\S+))')
            if($argument.Success){$directory=if($argument.Groups[1].Success){$argument.Groups[1].Value}else{$argument.Groups[2].Value}}
        }elseif(Test-MutatorLinuxPlatform){
            try{$arguments=@(Read-MutatorProcessArgument $process.Id)}catch{continue}
            $file=[array]::IndexOf($arguments,'-File');$run=[array]::IndexOf($arguments,'-RunDirectory')
            if($file -lt 0 -or $file+1 -ge $arguments.Count -or (Split-Path $arguments[$file+1] -Leaf) -cne 'Run-Worker.ps1'){continue}
            if($run -ge 0 -and $run+1 -lt $arguments.Count){$directory=$arguments[$run+1]}
        }
        try{$matchesRun=$directory -and [IO.Path]::GetFullPath($directory).Equals([IO.Path]::GetFullPath($RunDirectory),$comparison)}catch{continue}
        if($matchesRun){
            @{Id=$process.Id;StartedUtc=$process.StartTime.ToUniversalTime().ToString('O')}
        }
    }
}
