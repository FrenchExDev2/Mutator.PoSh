function Stop-MutatorRun {
    <#
    .SYNOPSIS
    Stop cooperatively or terminate only owned workers.

    .DESCRIPTION
    Retains reports and signals owned isolation environments. Force checks identity and stops guests
    before host workers.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path,[switch]$Force)
    $directory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $exists=Test-Path -LiteralPath $directory -PathType Container
    if(!$exists -and !$Force){throw 'Run directory is absent; use -Force to stop its orphan workers.'}
    $metadata=Test-Path -LiteralPath (Join-Path $directory 'run.json')
    $run=if($metadata){Get-MutatorRun -Path $directory}else{[pscustomobject]@{Id=(Split-Path $directory -Leaf);Path=$directory;Outcome='Interrupted';Process=$null;Packages=@();MissingMetadata=$true}}
    $terminal=$run.Outcome -notin @('Running','Starting','Interrupted')
    if(!$Force -and $terminal){return $run}
    if(!$PSCmdlet.ShouldProcess($run.Path,'Stop this mutation run and retain its completed/partial evidence')){return}
    if($exists){Write-MutatorJson (Join-Path $run.Path 'stop.json') @{Reason='UserRequested';Utc=[datetime]::UtcNow.ToString('O');Force=[bool]$Force}}
    foreach($package in $run.Packages){
        if($package['Container'] -and $package.Container['JobPath']){Write-MutatorJson (Join-Path $package.Container.JobPath 'stop.json') @{Reason='UserRequested';Force=[bool]$Force}}
    }
    if($Force){
        # Stop owned guests before killing the host workers that normally perform their cleanup.
        foreach($package in $run.Packages){
            if($package['Container'] -and $package.Container['Engine'] -eq 'WindowsSandbox' -and $package.Container['Id'] -and !$package.Container['Stopped']){
                Stop-MutatorWindowsSandbox -Id $package.Container.Id -Directory (Join-Path $run.Path ('packages/'+$package.Id))
            }
            if($package['Container'] -and $package.Container['GuestPath']){
                if($package.Container['JobPath']){Write-MutatorJson (Join-Path $package.Container.JobPath 'stop.json') @{Reason='UserRequested';Force=$true}}
                $null=Stop-MutatorGuestBase -Path $package.Container.GuestPath
            }
        }
        $identities=@($run.Process)+@($run.Packages|ForEach-Object{$_['Process']})+@(Get-MutatorRunWorkerIdentity $directory)
        foreach($identity in $identities){if($identity -and (Test-MutatorProcess $identity)){
            if($identity.Id -eq $PID){throw 'Cannot force-stop the process invoking this command.'}
            [Diagnostics.Process]::GetProcessById($identity.Id).Kill($true)
        }}
        if($metadata -and !$terminal){$state=Read-MutatorJson (Join-Path $run.Path 'run.json');$state.Outcome='Interrupted';$state.CompletedUtc=[datetime]::UtcNow.ToString('O');Write-MutatorJson (Join-Path $run.Path 'run.json') $state}
        foreach($entry in @(Get-ChildItem -LiteralPath (Join-Path $directory 'packages') -Directory -ErrorAction Ignore)){
            $statePath=Join-Path $entry.FullName 'state.json';$state=Read-MutatorJson $statePath
            if($state -and $state.Outcome -eq 'Running'){$state.Outcome='Interrupted';$state.Phase='Interrupted';$state.CompletedUtc=[datetime]::UtcNow.ToString('O');Write-MutatorJson $statePath $state}
        }
    }
    if($metadata){Get-MutatorRun -Path $run.Path}else{$run}
}
