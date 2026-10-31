function Resume-MutatorRun {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ModulePath,[string]$RunRoot,[switch]$Background)
    $previous=Get-MutatorRun -Path $Path
    if($previous.PSObject.Properties['Mode'] -and $previous.Mode -eq 'Recheck'){throw 'A recheck has no full mutation score or partial full-run report. Start a new isolated recheck from its original survivor report.'}
    if($previous.Origin -eq 'Imported'){throw 'Imported legacy evidence cannot seed a resume without the original partial report and complete context.'}
    if($previous.Outcome -in @('Running','Starting')){throw 'Stop the previous run before resuming it.'}
    $root=(Resolve-Path -LiteralPath $ModulePath).ProviderPath
    $entry=@($previous.Packages|Where-Object Name -CEQ (Split-Path $root -Leaf))
    if($entry.Count -ne 1){throw 'Select one module present in the interrupted run.'}
    $partial=Join-Path $previous.Path ('packages/'+$entry[0].Id+'/mutation.json')
    $original=Read-MutatorJson (Join-Path $previous.Path 'run.json')
    if($PSCmdlet.ShouldProcess($previous.Id,'Resume the retained partial scope after complete fingerprint validation')){
        $selection=@($original.Packages|Where-Object Id -CEQ $entry[0].Id)[0]
        $selection.ModulePath=$root
        if(!$RunRoot){$RunRoot=Split-Path $previous.Path}
        $options=Get-MutatorRestartOptions $original $selection $RunRoot
        $options.ModulePath=$root;$options.ResumeFrom=$partial;$options.Background=[bool]$Background
        Invoke-MutatorRun @options
    }
}
