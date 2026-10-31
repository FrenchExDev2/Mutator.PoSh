function Stop-MutatorGitImageValidation {
    <#
    .SYNOPSIS
    Request an identity-bound stop for a Git validation.

    .DESCRIPTION
    Signals workload/controller while preserving proof. Forced handling remains constrained to owned
    process identities.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path,[switch]$Force)
    $directory=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $run=Read-MutatorJson (Join-Path $directory 'summary.json')
    if(!$run -or $run.Id -notmatch '^[a-f0-9]{32}$' -or [IO.Path]::GetFullPath($run.Path) -ine $directory){throw 'A retained Git image validation identity is required.'}
    if(!$PSCmdlet.ShouldProcess($run.Id,'Stop the owned Git image validation and retain all reports and containers')){return}
    Write-MutatorJson (Join-Path $directory 'stop.json') @{RunId=$run.Id;Utc=[datetime]::UtcNow.ToString('o');Reason='UserRequested'}
    if(!$Force){
        foreach($platform in @('Linux','Windows')){
            $state=$run.Platforms[$platform]
            if(!$state){continue}
            if($state.Outcome -in @('Running','Pending') -and $state['Reports']){
                Write-MutatorJson (Join-Path $state.Reports 'stop.json') @{RunId=$run.Id;Reason='UserRequested'}
            }
        }
        return [pscustomobject]@{Path=$directory;Outcome='StopRequested'}
    }
    $controller=Read-MutatorJson (Join-Path $directory 'controller.json')
    if($controller -and (Test-MutatorProcess $controller)){
        if($controller.Role -cne 'git-validation' -or $controller.Id -eq $PID){throw 'Refusing to stop an unrelated controller.'}
        Stop-Process -Id $controller.Id -Force -ErrorAction Stop
    }
    Set-MutatorContainerContext -Engine $run.ContainerEngine -Connection $run.Connection
    foreach($platform in @('Linux','Windows')){
        $state=$run.Platforms[$platform]
        $container=$null;$label=$null;$owner=$null
        if($platform -ceq 'Windows' -and $state['Guest']){
            $guest=Read-MutatorJson (Join-Path $state.Guest 'guest.json')
            if($guest){$container=$guest.ContainerId;$owner=$guest.Id;$label='org.frenchexdev.cli.run'}
        }elseif($platform -ceq 'Linux' -and $state['ContainerId']){$container=$state.ContainerId;$owner=$run.Id;$label='org.frenchexdev.mutator.validation'}
        if($container){
            $inspection=Invoke-MutatorContainerCommand -Arguments @('inspect',$container) -Directory $directory -Connection $run.Connection
            if($inspection.Outcome -ne 'Success'){throw 'The owned validation container could not be inspected; its resources are retained.'}
            $owned=@($inspection.Stdout|ConvertFrom-Json -AsHashtable)[0]
            if($owned.Id -cne $container -or $owned.Config.Labels[$label] -cne $owner){throw 'Refusing to stop a container outside this validation.'}
            if($owned.State.Running){
                $stopped=Invoke-MutatorContainerCommand -Arguments @('stop','--time','180',$container) -Directory $directory -Connection $run.Connection -TimeoutSeconds 240
                if($stopped.Outcome -ne 'Success'){throw 'The owned container did not stop; its reports and disk are retained.'}
            }
            $state.RetainedContainer=$container
        }
        if($state.Outcome -in @('Running','Pending')){$state.Outcome='Interrupted';$state.Phase='Interrupted';$state.Qualified=$false}
    }
    $run.Outcome='Interrupted'
    Write-MutatorValidationReport $run
    [pscustomobject]@{Path=$directory;Outcome=$run.Outcome}
}
