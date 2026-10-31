function Invoke-MutatorRecheckCore {
    <#
    .SYNOPSIS
    Re-evaluate survivors inside an already isolated worker.

    .DESCRIPTION
    Freezes inputs, uses one worker and checks report identity and counters. Retains recheck evidence
    with no score and FullGateSatisfied false.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$ModulePath,[Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][string]$OutputDirectory,[string]$SourceRoot,[string]$StopPath,[string]$ToolCacheRoot)
    if(!$script:MutatorIsolationBoundary){throw 'Recheck execution requires an isolated worker.'}
    $root=(Resolve-Path -LiteralPath $ModulePath -ErrorAction Stop).ProviderPath
    $baseline=(Resolve-Path -LiteralPath $ReportPath -ErrorAction Stop).ProviderPath
    $configuration=Read-MutatorJson (Join-Path $root 'test/psmutant.config.json')
    if($configuration.coveredLinesOnly -ne $false){throw 'Recheck requires the complete source configuration.'}
    $prior=Read-MutatorJson $baseline
    if(!@($prior.survivors).Count){throw 'Recheck requires recorded survivors; use a full run for final validation.'}
    $parent=if($SourceRoot){(Resolve-Path -LiteralPath $SourceRoot).ProviderPath}else{Get-MutatorModuleRoot $root};$subtrees=@(Get-MutatorSubtree $parent $configuration)
    Confirm-MutatorEquivalence -ModulePath $root -Configuration $configuration
    $output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    if(Test-Path -LiteralPath $output){throw 'Recheck output directory already exists.'}
    if($StopPath -and (Test-Path -LiteralPath $StopPath)){throw [OperationCanceledException]::new('Recheck stopped before execution.')}
    if(!$PSCmdlet.ShouldProcess($output,'Re-evaluate recorded survivors in a frozen sandbox without producing a mutation score')){return}
    [void][IO.Directory]::CreateDirectory($output)
    $stage=Join-Path $output 'source';$receipt=Join-Path $output 'recheck.json'
    $result=@{Mode='Recheck';Outcome='Running';Score=$null;FullGateSatisfied=$false;StartedUtc=[datetime]::UtcNow.ToString('O')
        Baseline=$baseline;BaselineSha256=(Get-FileHash -LiteralPath $baseline).Hash;Error=$null;Proof=$output
        Rechecked=$null;NowKilled=$null;Survived=$null;SourceSha256=$null}
    try{
        foreach($subtree in $subtrees){
            if($StopPath -and (Test-Path -LiteralPath $StopPath)){throw [OperationCanceledException]::new('Recheck stopped during preparation.')}
            $from=Join-Path $parent $subtree
            $before=Get-MutatorSourceSnapshot $from
            Copy-MutatorTree $from (Join-Path $stage $subtree)
            if($before.Sha256 -cne (Get-MutatorSourceSnapshot (Join-Path $stage $subtree)).Sha256){throw 'Recheck sources changed during snapshotting.'}
        }
        $subject=Join-Path $stage ([IO.Path]::GetRelativePath($parent,$root))
        $stagedConfig=Join-Path $subject 'test/psmutant.config.json'
        $configuration.workers=1
        $result.TestOrder=Set-MutatorTestOrder $configuration FocusedFirst
        Write-MutatorJson $stagedConfig $configuration
        # The configuration is intentionally rewritten before recording the immutable run input.
        $sourceBefore=Get-MutatorSourceSnapshot $subject
        Import-Module Pester -RequiredVersion 6.2.0 -ErrorAction Stop
        $toolOptions=@{ProgressPath=(Join-Path $output 'mutants.jsonl');StopPath=$StopPath}
        if($ToolCacheRoot){$toolOptions.CacheRoot=$ToolCacheRoot}
        $result.Tool=Import-MutatorTool @toolOptions
        Write-MutatorJson $receipt $result
        $run=Invoke-PSMutation -ConfigFile $stagedConfig -SourceRoot $stage -RecheckFrom $baseline -Quiet
        if($StopPath -and (Test-Path -LiteralPath $StopPath)){throw [OperationCanceledException]::new('Recheck was interrupted before completion.')}
        $full=Join-Path $stage $configuration.reportPath
        $detailPath=Join-Path (Split-Path $full) (([IO.Path]::GetFileNameWithoutExtension($full))+'.recheck.json')
        $detail=Read-MutatorJson $detailPath
        if(!$detail -or $detail.mode -cne 'Recheck' -or $run.ExitCode -ne 0 -or $detail.rechecked -le 0 -or
            $detail.rechecked -ne @($prior.survivors).Count -or $detail.rechecked -ne @($detail.mutants).Count -or
            $detail.nowKilled+@($detail.survivors).Count -ne $detail.rechecked){throw 'Recheck discovery or counters are inconsistent.'}
        if($result.BaselineSha256 -cne (Get-FileHash -LiteralPath $baseline).Hash){throw 'Recheck modified its baseline report.'}
        if($sourceBefore.Sha256 -cne (Get-MutatorSourceSnapshot $subject).Sha256){throw 'Frozen recheck input changed during execution.'}
        $result.Rechecked=$detail.rechecked;$result.NowKilled=$detail.nowKilled;$result.Survived=@($detail.survivors).Count
        $result.SourceSha256=$sourceBefore.Sha256;$result.SourcePath=$subject
        $result.Report=Join-Path $output 'mutation.recheck.json'
        Copy-Item -LiteralPath $detailPath -Destination $result.Report
        $result.Outcome=if($result.Survived){'SurvivorsRemain'}else{'Success'}
    }catch{$result.Outcome=if($StopPath -and (Test-Path -LiteralPath $StopPath)){'Interrupted'}else{'Failed'};$result.Error=$_.Exception.Message}
    finally{$result.CompletedUtc=[datetime]::UtcNow.ToString('O');Write-MutatorJson $receipt $result}
    [pscustomobject]$result
}
