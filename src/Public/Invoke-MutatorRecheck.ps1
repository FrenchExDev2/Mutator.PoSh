function Invoke-MutatorRecheck {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$ModulePath,[Parameter(Mandatory)][string]$ReportPath,
        [string]$OutputDirectory,[string]$SourceRoot,[ValidateSet('Windows','Linux')][string]$OS,
        [string]$ContainerBaseImage,[string]$ContainerConnection,
        [ValidateRange(2048,1048576)][int]$MemoryBudgetMiB=4096,[switch]$Background)
    $root=(Resolve-Path -LiteralPath $ModulePath -ErrorAction Stop).ProviderPath
    $baseline=(Resolve-Path -LiteralPath $ReportPath -ErrorAction Stop).ProviderPath
    $prior=Read-MutatorJson $baseline
    if(!@($prior['survivors']).Count){throw 'Recheck requires recorded survivors; use a full run for final validation.'}
    if(!$OutputDirectory){$OutputDirectory=Join-Path $root ('test/Artifacts/mutator/rechecks/'+[guid]::NewGuid().ToString('N'))}
    $output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    if(Test-Path -LiteralPath $output){throw 'Recheck output directory already exists.'}
    if(!$PSCmdlet.ShouldProcess($output,'Re-evaluate recorded survivors in Windows Sandbox or Podman, without a global mutation score')){return}
    $options=@{ModulePath=$root;RecheckFrom=$baseline;RunRoot=$output;Workers=1;WorkerBudget=1;ThrottleLimit=1
        MemoryBudgetMiB=$MemoryBudgetMiB;SkipStryker=$true;Background=[bool]$Background;Confirm=$false}
    foreach($key in @('OS','SourceRoot','ContainerBaseImage','ContainerConnection')){if($PSBoundParameters[$key]){$options[$key]=$PSBoundParameters[$key]}}
    $run=Invoke-MutatorRun @options
    if($Background){return $run}
    $package=@($run.Packages)[0]
    $proof=Join-Path $run.Path ('packages/'+$package.Id)
    $check=$package['Recheck']
    $report=Join-Path $proof 'mutation.recheck.json'
    $outcome=if($check){$check.Outcome}elseif($run.Outcome -eq 'Interrupted'){'Interrupted'}else{'Failed'}
    [pscustomobject]@{Mode='Recheck';Outcome=$outcome;Score=$null;FullGateSatisfied=$false
        Baseline=$baseline;BaselineSha256=$(if($check){$check.BaselineSha256}else{$null});Rechecked=$(if($check){$check.Rechecked}else{$null})
        NowKilled=$(if($check){$check.NowKilled}else{$null});Survived=$(if($check){$check.Survived}else{$null})
        SourceSha256=$(if($check){$check.SourceSha256}else{$null});Report=$(if(Test-Path -LiteralPath $report){$report}else{$null})
        Proof=$proof;RunPath=$run.Path;Isolation=$run.Isolation;Error=$package['Error']}
}
