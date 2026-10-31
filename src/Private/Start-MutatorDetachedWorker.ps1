function Start-MutatorDetachedWorker {
    <#
    .SYNOPSIS
    Launch an owned Windows supervisor, watchdog or Git controller independently.

    .DESCRIPTION
    Requires a retained plan, creates a hidden CIM process with the caller's environment and records
    actual identity. Creation failures never claim a running worker.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private background supervisor launch is authorized by the public run ShouldProcess boundary.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory,[ValidateSet('Supervisor','MemoryWatchdog','GitValidation')][string]$Kind='Supervisor')
    $directory=(Resolve-Path -LiteralPath $RunDirectory -ErrorAction Stop).ProviderPath
    $plan=switch($Kind){Supervisor{'run.json'};MemoryWatchdog{'watchdog.json'};GitValidation{'controller.request.json'}}
    if(!(Test-Path -LiteralPath (Join-Path $directory $plan) -PathType Leaf)){throw 'A retained run plan is required before starting its detached worker.'}
    $executable=Join-Path $PSHOME 'pwsh.exe'
    $arguments=if($Kind -eq 'Supervisor'){@('-File',(Join-Path $script:MutatorRoot 'resources/Run-DetachedWorker.ps1'),'-RunDirectory',$directory)}
        elseif($Kind -eq 'MemoryWatchdog'){@('-STA','-File',(Join-Path $script:MutatorRoot 'resources/Run-MemoryWatchdog.ps1'),'-Path',$directory)}
        else{@('-File',(Join-Path $script:MutatorRoot 'resources/validation/Invoke-GitImageController.ps1'),'-RequestPath',(Join-Path $directory $plan))}
    $commandLine=(@($executable,'-NoLogo','-NoProfile','-NonInteractive')+$arguments|ForEach-Object {
        '"'+[regex]::Replace($_,'(\\+)$','$1$1')+'"'
    }) -join ' '
    # WMI owns this launch, rather than the invoking terminal's process tree.
    # CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT | CREATE_BREAKAWAY_FROM_JOB.
    # A console handle is required by PowerShell's UTF-8 stream initialization.
    # Match native process inheritance, rather than inheriting the WMI service's
    # environment. Values are passed locally and never written to run receipts.
    $environment=[string[]]@(foreach($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()){
        [string]$entry.Key+'='+[string]$entry.Value
    })
    $startup=New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{
        ShowWindow=[uint16]0;CreateFlags=[uint32]0x01000410;EnvironmentVariables=$environment
    }
    $created=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine=$commandLine;CurrentDirectory=$directory;ProcessStartupInformation=$startup
    } -ErrorAction Stop
    if(!$created -or $created.ReturnValue -ne 0 -or $created.ProcessId -le 0){
        $status=if($created){$created.ReturnValue}else{'NoResult'}
        throw ('Detached worker creation failed; Windows return value: '+$status)
    }
    $process=Get-Process -Id $created.ProcessId -ErrorAction Stop
    try{@{Id=$process.Id;StartedUtc=$process.StartTime.ToUniversalTime().ToString('O');Role=$(switch($Kind){Supervisor{'supervisor'};MemoryWatchdog{'memory-watchdog'};GitValidation{'git-validation'}});Launcher='CimDetached'}}
    finally{$process.Dispose()}
}
