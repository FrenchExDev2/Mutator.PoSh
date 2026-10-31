#requires -Version 7.6
param([Parameter(Mandatory)][string]$RunDirectory)
$ErrorActionPreference='Stop'
$directory=(Resolve-Path -LiteralPath $RunDirectory -ErrorAction Stop).ProviderPath
$stdout=Join-Path $directory 'supervisor.stdout.log'
$stderr=Join-Path $directory 'supervisor.stderr.log'
try{
    [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
    # One writer owns this file. Redirecting several streams separately to the
    # same file creates conflicting file handles on Windows.
    & (Join-Path $PSScriptRoot 'Run-Worker.ps1') -RunDirectory $directory *> $stdout
}catch{
    # The caller receives structured run state; diagnostics stay with the owned run.
    [IO.File]::AppendAllText($stderr,($_.Exception.ToString()+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    $failure=@{Outcome='Failed';Phase='SupervisorStartup';Error=$_.Exception.Message;ErrorId=$_.FullyQualifiedErrorId;Utc=[datetime]::UtcNow.ToString('O')}
    [IO.File]::WriteAllText((Join-Path $directory 'supervisor-failure.json'),($failure|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    throw
}
