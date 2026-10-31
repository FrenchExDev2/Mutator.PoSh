function Get-MutatorConsoleApi {
    <#
    .SYNOPSIS
    Return the console API type used by the terminal.

    .DESCRIPTION
    Keeps direct console access behind a replaceable boundary for simulated keys and terminal-state
    tests.
    #>

    [Console]
}

function Get-MutatorConsoleState {
    <#
    .SYNOPSIS
    Read whether console streams are redirected.

    .DESCRIPTION
    Returns input/output flags without rendering or changing modes.
    #>

    $consoleApi=Get-MutatorConsoleApi
    @{InputRedirected=$consoleApi::IsInputRedirected;OutputRedirected=$consoleApi::IsOutputRedirected}
}

function Test-MutatorTerminalInteractive {
    <#
    .SYNOPSIS
    Require both console streams to be interactive.

    .DESCRIPTION
    Redirected input or output yields false so scripts can select structured monitoring.
    #>

    $consoleState=Get-MutatorConsoleState
    !$consoleState.InputRedirected -and !$consoleState.OutputRedirected
}

function Format-MutatorTerminalFrame {
    <#
    .SYNOPSIS
    Render a localized frame from retained observations.

    .DESCRIPTION
    Separates package completion, mutant results and actual/required runtime. Unknown counts and
    reservations never become completed work or enforced limits.
    #>

    param([object]$Run)
    $done=[int]$Run.ProcessedPackages;$total=[int]$Run.TotalPackages
    $percent=if($total){100*$done/$total}else{0}
    $blocks=[math]::Min(30,[math]::Floor($percent*30/100))
    $bar=('='*$blocks)+('.'*(30-$blocks))
    $evaluated=[int]$Run.EvaluatedMutants;$planned=[int]$Run.PlannedMutants
    $mutantPercent=if($planned){[math]::Round(100*$evaluated/$planned,1)}else{0}
    $end=if($Run.CompletedUtc){([datetime]$Run.CompletedUtc).ToUniversalTime()}else{[datetime]::UtcNow}
    $elapsed=$end-([datetime]$Run.CreatedUtc).ToUniversalTime()
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('MUTATOR  '+$Run.Id+'  '+$Run.Platform+'  '+$Run.Outcome)
    $lines.Add('')
    $lines.Add((Get-MutatorText 'Frame.Modules' @($bar,$percent,$done,$total)))
    $lines.Add((Get-MutatorText 'Frame.Results' @($Run.CompletedPackages,$Run.FailedPackages,$Run.ErrorPercent,$Run.InterruptedPackages)))
    if($Run.PSObject.Properties['Mode'] -and $Run.Mode -eq 'Recheck'){
        $rechecked=if($null -ne $Run.RecheckedMutants){[string]$Run.RecheckedMutants}else{'?'}
        $killed=if($null -ne $Run.RecheckKilledMutants){[string]$Run.RecheckKilledMutants}else{'?'}
        $survivors=if($null -ne $Run.RecheckSurvivedMutants){[string]$Run.RecheckSurvivedMutants}else{'?'}
        $lines.Add((Get-MutatorText 'Frame.Recheck' @($rechecked,$killed,$survivors)))
    }else{$lines.Add((Get-MutatorText 'Frame.Mutants' @($evaluated,$planned,$mutantPercent,$Run.SurvivedMutants)))}
    $lines.Add((Get-MutatorText 'Frame.Duration' @([math]::Floor($elapsed.TotalHours),$elapsed.Minutes,$elapsed.Seconds)))
    if($Run.PSObject.Properties['Schedule'] -and $Run.Schedule){$lines.Add((Get-MutatorText 'Frame.Parallel' @($Run.ActivePackages,$Run.Schedule.Slots,$Run.Schedule.Workers,$Run.Schedule.WorkerBudget,$Run.Schedule.ReservedMemoryMiB)))}
    if($Run.PSObject.Properties['HostMemory'] -and $Run.HostMemory){
        $memory=$Run.HostMemory
        $health=if($memory.Running){$memory.Outcome}else{Get-MutatorText 'Memory.Stopped'}
        $used=if($null -eq $memory.UsedGB){'?'}else{[math]::Round($memory.UsedGB,1)}
        $lines.Add((Get-MutatorText 'Frame.HostMemory' @($used,$memory.LimitGB,$memory.TriggerGB,$health)))
    }
    $lines.Add('')
    $rowFormat='{0,-49} {1,-19} {2,-13} {3,-13} {4,-10} {5,-16} {6,-28} {7}'
    $headers=@('Module','Phase','State','Mutants','Platform','Memory','Connection','Engine'|ForEach-Object {Get-MutatorText ('Header.'+$_)})
    $lines.Add(($rowFormat -f $headers))
    foreach($package in @($Run.Packages|Where-Object Outcome -In @('Running','Failed','Interrupted')|Select-Object -First 10)){
        $name=[string]$package.Name;if($name.Length -gt 48){$name=$name.Substring(0,45)+'...'}
        $counts=if($null -eq $package['PlannedMutants']){Get-MutatorText 'Count.NotStarted'}else{[string]$package['EvaluatedMutants']+'/'+[string]$package['PlannedMutants']}
        $platform=if($package['Platform']){[string]$package['Platform']}elseif($package['Container']){'linux'}else{[string]$Run.Platform}
        $platform=switch($platform.ToLowerInvariant()){'linux'{'Linux'};'windows'{'Windows'};'macos'{'macOS'};default{$platform}}
        $ram='-';$connection='-'
        if($package['Container'] -and $package.Container['ResourceLimits']){
            $limit=$package.Container.ResourceLimits
            $ram=if($limit.Memory -and $limit['MemoryMiB']){Get-MutatorText 'Memory.Maximum' @($limit['MemoryMiB'])}elseif($limit.Memory){Get-MutatorText 'Memory.ActiveLimit'}elseif($limit['MemoryMiB']){Get-MutatorText 'Memory.Reserved' @($limit['MemoryMiB'])}else{Get-MutatorText 'Memory.Reservation'}
        }
        if($package['Container']){$connection=if($package.Container['Connection']){[string]$package.Container['Connection']}elseif($Run.PSObject.Properties['ContainerEndpoint'] -and $Run.ContainerEndpoint){$Run.ContainerEndpoint}else{Get-MutatorText 'Connection.Default'}}
        $engine=if($package['ExecutionRuntime']){
            if($package.ExecutionRuntime -eq 'Pending'){'Pending ('+$package.RequiredRuntime+')'}else{$package.ExecutionRuntime}
        }elseif($package['Container'] -and $package.Container['Engine']){$package.Container.Engine}else{'Host'}
        $lines.Add(($rowFormat -f $name,$package.Phase,$package.Outcome,$counts,$platform,$ram,$connection,$engine))
    }
    $lines.Add('')
    $lines.Add((Get-MutatorText 'Frame.Keys'))
    $lines.Add((Get-MutatorText 'Frame.Reports' @($Run.Path)))
    if($Run.PSObject.Properties['Error'] -and $Run.Error){$lines.Add((Get-MutatorText 'Frame.Error' @($Run.Error)))}
    $lines.Add((Get-MutatorText 'Frame.Explanation'))
    $lines -join [Environment]::NewLine
}
