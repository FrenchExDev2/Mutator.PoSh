function Get-MutatorRunRoot {
    param([string]$Path)
    if (!$Path) { $Path = Join-Path $script:MutatorRoot 'test/Artifacts/mutator' }
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}
function Move-MutatorAtomicFile {
    param([string]$Source,[string]$Destination)
    [IO.File]::Move($Source,$Destination,$true)
}

function Open-MutatorJsonFile {
    param([string]$Path)
    [IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
}

function Complete-MutatorAtomicWrite {
    # Only retry the same completed local replacement, never a business command.
    param([string]$Source,[string]$Destination)
    for($attempt=0;$attempt -lt 40;$attempt++){
        try{Move-MutatorAtomicFile $Source $Destination;return}
        catch{
            $native=$_.Exception
            while($native.InnerException){$native=$native.InnerException}
            if(($native.HResult -band 65535) -notin @(5,32,33) -or $attempt -eq 39){throw}
            Start-Sleep -Milliseconds 50
        }
    }
}

function Write-MutatorJson {
    param([string]$Path, [object]$Data)
    [void][IO.Directory]::CreateDirectory((Split-Path $Path))
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Data | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        Complete-MutatorAtomicWrite $temporary $Path
    } catch {
        throw [IO.IOException]::new(('Atomic JSON write failed at '+$Path+': '+$_.Exception.Message),$_.Exception)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function Read-MutatorJson {
    param([string]$Path)
    if (!(Test-Path -LiteralPath $Path)) { return }
    $stream=$null
    for($attempt=0;$attempt -lt 40;$attempt++){
        try {
            # Readers must allow the completed state file to be atomically replaced.
            $stream=Open-MutatorJsonFile $Path
            break
        } catch {
            $native=$_.Exception
            while($native.InnerException){$native=$native.InnerException}
            if(($native.HResult -band 65535) -notin @(5,11,32,33) -or $attempt -eq 39){throw}
            # Retry only this local read after a transient exclusive handle.
            Start-Sleep -Milliseconds 50
        }
    }
    $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
    try {$reader.ReadToEnd()|ConvertFrom-Json -AsHashtable -DateKind String}
    finally {$reader.Dispose()}
}
function Read-MutatorProgressTail {
    param([string]$Path)
    $stream=$null;$reader=$null
    try{
        try{$stream=Open-MutatorJsonFile $Path}catch [IO.FileNotFoundException]{return}
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
        $lines=[Collections.Generic.Queue[string]]::new()
        while($null -ne ($line=$reader.ReadLine())){
            $lines.Enqueue($line)
            if($lines.Count -gt 2){[void]$lines.Dequeue()}
        }
        return $lines.ToArray()
    }finally{
        if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}
    }
}
function Copy-MutatorTree {
    param([string]$Source, [string]$Destination)
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if ($item.Name -in @('.git','.cache','Artifacts')) { continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Mutation staging refuses links: $($item.FullName)" }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) { Copy-MutatorTree $item.FullName $target }
        else { [IO.File]::Copy($item.FullName, $target, $true) }
    }
}
function Start-MutatorWorker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private worker bootstrap is covered by the public run ShouldProcess boundary.')]
    [CmdletBinding()]
    param([string]$RunDirectory, [string]$Package = '')
    if((Test-MutatorWindowsPlatform) -and !$Package){return Start-MutatorDetachedWorker -RunDirectory $RunDirectory}
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $script:MutatorRoot 'resources/Run-Worker.ps1'),'-RunDirectory',$RunDirectory)
    if ($Package) { $arguments += @('-Package',$Package) }
    $name = if ($Package) { $Package } else { 'supervisor' }
    $parameters = @{ FilePath = (Get-MutatorPowerShellExecutable); ArgumentList = @($arguments | ForEach-Object { '"' + $_.Replace('"','\"') + '"' })
        PassThru = $true; RedirectStandardOutput = (Join-Path $RunDirectory ($name + '.stdout.log')); RedirectStandardError = (Join-Path $RunDirectory ($name + '.stderr.log')) }
    if (Test-MutatorWindowsPlatform) { $parameters.WindowStyle = 'Hidden' }
    $process = Start-Process @parameters
    @{ Id = $process.Id; StartedUtc = $process.StartTime.ToUniversalTime().ToString('O'); Role = $name }
}
function Test-MutatorProcess {
    param([Collections.IDictionary]$Identity)
    if (!$Identity -or !$Identity['Id'] -or !$Identity['StartedUtc']) { return $false }
    $process = Get-Process -Id $Identity.Id -ErrorAction Ignore
    $process -and !$process.HasExited -and [math]::Abs(($process.StartTime.ToUniversalTime() - [datetime]::Parse($Identity.StartedUtc).ToUniversalTime()).TotalSeconds) -lt 1
}
function Invoke-MutatorNative {
    param([string]$Command, [string[]]$Arguments, [string]$Directory, [int]$TimeoutSeconds = 3600,[string]$ProgressPath,[string]$StopPath,[string]$Encoding = 'utf-8')
    $state = @{ Out = [Text.StringBuilder]::new(); Err = [Text.StringBuilder]::new();ProgressPath=$ProgressPath;OutTruncated=$false;ErrTruncated=$false }
    Invoke-MutatorQuietOperation {
        param($inheritedConfiguration)
        $result=$null
        try{
            $result = FrenchExDev.QuietCli.PoSh\Invoke-QuietCli -FilePath $Command -ArgumentList $(if($Arguments){,$Arguments}else{,[string[]]@()}) -WorkingDirectory $Directory -Context mutator -Environment @{DOTNET_CLI_UI_LANGUAGE='en-US';DOTNET_NOLOGO='1';DOTNET_CLI_TELEMETRY_OPTOUT='1';QUIETCLI_CONFIG_PATH=$inheritedConfiguration} -TimeoutSeconds $TimeoutSeconds -CancellationFile $StopPath -Encoding $Encoding -MaxRecordCharacters 1048576 -State $state -OnOutput {
                param($output,$s)
                # Records end at the line feed, so CRLF output keeps its carriage return.
                $text=$output.Text.TrimEnd([char]13)
                $isOut=$output.Stream -eq 'stdout'
                $buffer = if ($isOut) { $s.Out } else { $s.Err }
                $line=$text+[Environment]::NewLine
                $remaining=1048576-$buffer.Length
                if($remaining -gt 0){[void]$buffer.Append($line,0,[math]::Min($remaining,$line.Length))}
                if($line.Length -gt $remaining){
                    if($isOut){$s.OutTruncated=$true}else{$s.ErrTruncated=$true}
                }
                if($s.ProgressPath -and $text -match '(?i)(?:mutation testing|mutants? tested|tested).*?(?<done>\d+)\s*/\s*(?<total>\d+)'){
                    $evaluated=[long]$Matches.done;$planned=[long]$Matches.total
                    if($planned -gt 0 -and $evaluated -le $planned){
                        $progressEvent=@{Engine='Stryker';Evaluated=$evaluated;Planned=$planned;Utc=[datetime]::UtcNow.ToString('O')}
                        # Progress is advisory: an unwritable file must not turn a sound native command into a failed analysis.
                        try{[IO.File]::AppendAllText($s.ProgressPath,(($progressEvent|ConvertTo-Json -Compress)+[Environment]::NewLine))}catch{}
                    }
                }
            }
            # No process ran: a configuration error must not read as a native failure.
            if($result.Error -and $result.Error.Phase -ceq 'Context'){throw "QuietCli context failure ($($result.Error.Code)): $($result.Error.Message)"}
            # This value stays inside the module; native text is not a dashboard or public result.
            $failure=if($result.Outcome -ne 'Success'){
                $result | FrenchExDev.QuietCli.PoSh\Out-QuietResult -AsJson -MaxOutputBytes 16384 -ExcerptLines 5 | ConvertFrom-Json -AsHashtable
            }else{$null}
            @{ Outcome = $result.Outcome; ExitCode = $result.Execution.ExitCode; Stdout = $state.Out.ToString(); Stderr = $state.Err.ToString(); StdoutTruncated = $state.OutTruncated; StderrTruncated = $state.ErrTruncated; Failure = $failure }
        }finally{if($result -and $result.Capture){$result.Capture.Dispose()}}
    }
}
