#requires -Version 7.6
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$ReportRoot,
    [Parameter(Mandatory)][ValidateSet('Linux','Windows')][string]$Platform,[switch]$BaselineOnly,[string]$RunId,[string]$OriginalModuleSha256)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[text.UTF8Encoding]::new($false)
Import-Module (Join-Path $SourceRoot 'FrenchExDev.Mutator.PoSh/FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($SourceRoot,$ReportRoot,$Platform,$BaselineOnly,$RunId,$OriginalModuleSha256)
    [void][IO.Directory]::CreateDirectory($ReportRoot)
    if(!$RunId){$job=Read-MutatorJson (Join-Path (Split-Path $ReportRoot) 'workload-request.json');$RunId=$job.RunId;$OriginalModuleSha256=$job.OriginalModuleSha256;$BaselineOnly=[bool]$job['BaselineOnly']}
    if($RunId -notmatch '^[a-f0-9]{32}$' -or $OriginalModuleSha256 -notmatch '^[a-f0-9]{64}$'){throw 'The workload requires a source-bound run request.'}
    $id=$RunId
    $local=Join-Path ([IO.Path]::GetTempPath()) ('mutator-git-'+$id)
    $gitDirectory=Resolve-MutatorModuleDirectory $SourceRoot 'FrenchExDev.QuietCli.Git.PoSh'
    $gitRelative=[IO.Path]::GetRelativePath($SourceRoot,$gitDirectory).Replace('\','/')
    $original=Get-MutatorSourceSnapshot $gitDirectory
    if($original.Sha256 -cne $OriginalModuleSha256){throw 'The mounted Git module differs from the requested sources.'}
    $retainSandbox=$true
    try{
        $configuration=Read-MutatorJson (Join-Path $gitDirectory 'test/psmutant.config.json')
        foreach($subtree in @(@(Get-MutatorSubtree $SourceRoot $configuration)+@('FrenchExDev.DevPoSh.PoSh')|Sort-Object -Unique)){
            Copy-MutatorTree (Join-Path $SourceRoot $subtree) (Join-Path $local ('modules/'+$subtree))
        }
        $before=Get-MutatorSourceSnapshot (Join-Path $local 'modules')
        $request=@{SchemaVersion=1;RunId=$id;OS=$Platform;Modules=@($gitRelative);Test=@('Unit','Integration');Workers=1;WorkerBudget=1;MemoryBudgetMiB=4096;SourceSha256=$before.Sha256;OriginalModuleSha256=$original.Sha256}
        if(!$BaselineOnly){$request.Test+=@('Mutations')}
        Write-MutatorJson (Join-Path $local 'request.json') $request
        $stagedModule=Import-Module (Join-Path $local 'modules/FrenchExDev.Mutator.PoSh/FrenchExDev.Mutator.PoSh.psd1') -Force -PassThru -DisableNameChecking
        $result=& $stagedModule {param($local,$ReportRoot) Invoke-MutatorValidationWorkload -Root $local -ReportRoot $ReportRoot} $local $ReportRoot
        if((Get-MutatorSourceSnapshot $gitDirectory).Sha256 -cne $original.Sha256){throw 'The mounted original Git module changed during validation.'}
        $retainSandbox=($result.Outcome -cne 'Success' -or [bool]$result['RetainSandbox'])
        if($result.Outcome -cne 'Success'){throw 'Git validation gates remain open; see result.json.'}
    }finally{
        if(Test-Path $local){
            $expected=Join-Path ([IO.Path]::GetTempPath()) ('mutator-git-'+$id)
            if([IO.Path]::GetFullPath($local) -cne [IO.Path]::GetFullPath($expected)){throw 'Refusing cleanup outside this workload sandbox.'}
            if($retainSandbox){
                Write-MutatorJson (Join-Path $ReportRoot 'retained-sandbox.json') @{RunId=$id;Path=$local;Reason='ValidationNotComplete'}
            }else{Remove-Item -LiteralPath $local -Recurse -Force}
        }
    }
} $SourceRoot $ReportRoot $Platform ([bool]$BaselineOnly) $RunId $OriginalModuleSha256
