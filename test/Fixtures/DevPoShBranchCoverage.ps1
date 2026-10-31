#requires -Version 7.6
param([ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]+$')][string]$Module='FrenchExDev.DevPoSh.PoSh',
    [ValidateSet('All','Unit','Integration')][string]$TestScope='All',[string]$ProofDirectory)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Module,$TestScope,$ProofDirectory)
    $prefix=$Module.ToLowerInvariant() -replace '^frenchexdev\.|\.posh$',''
    $proof=if($ProofDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProofDirectory)}else{Join-Path $script:MutatorRoot ('test/Artifacts/development/'+$prefix+'-branches-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))}
    if((Test-Path -LiteralPath $proof) -and @(Get-ChildItem -LiteralPath $proof -Force).Count){throw 'Branch qualification requires a new or empty proof directory.'}
    $source=Join-Path $proof 'source'
    $original=Join-Path (Split-Path $script:MutatorRoot) $Module
    $configuration=Read-MutatorJson (Join-Path $original 'test/psmutant.config.json')
    $subtrees=@(Get-MutatorSubtree (Split-Path $script:MutatorRoot) $configuration)
    foreach($name in $subtrees){
        Copy-MutatorTree (Join-Path (Split-Path $script:MutatorRoot) $name) (Join-Path $source $name)
    }
    $subject=Join-Path $source $Module
    $observerNamespace=if($Module -eq 'FrenchExDev.Mutator.PoSh'){'Obs'+[guid]::NewGuid().ToString('N')}else{$null}
    $definitions=[Collections.Generic.List[object]]::new()
    $fingerprints=[Collections.Generic.List[object]]::new()
    foreach($file in Get-MutatorProductionFile $original){
        $relative=[IO.Path]::GetRelativePath($original,$file).Replace('\','/')
        $parameters=@{Path=$file;RelativePath=$relative}
        if($observerNamespace){$parameters.ObserverNamespace=$observerNamespace}
        $converted=ConvertTo-MutatorBranchSource @parameters
        [IO.File]::WriteAllText((Join-Path $subject $relative),$converted.Code,[Text.UTF8Encoding]::new($false))
        foreach($branch in $converted.Branches){$definitions.Add($branch)}
        $fingerprints.Add(@{Path=$relative;Sha256=$converted.Sha256})
    }
    $runId=[guid]::NewGuid().ToString('N')
    $manifest=@{Run=$runId;Module=$Module;SourceFingerprints=$fingerprints.ToArray();Branches=$definitions.ToArray();ObserverNamespace=$observerNamespace}
    $settings=@{MUTATOR_BRANCH_PROBE=(Join-Path $source 'FrenchExDev.Mutator.PoSh/resources/coverage/BranchProbe.ps1');MUTATOR_BRANCH_DIRECTORY=(Join-Path $proof 'records');MUTATOR_BRANCH_RUN=$runId}
    if($observerNamespace){
        $observer=Join-Path $proof 'observer.ps1'
        $generated=New-MutatorBranchObserver -Path (Join-Path $script:MutatorRoot 'resources/coverage/BranchProbe.ps1') -Namespace $observerNamespace
        [IO.File]::WriteAllText($observer,$generated.Code,[Text.UTF8Encoding]::new($false))
        $settings['MUTATOR_BRANCH_PROBE'+$observerNamespace]=$observer
        $settings['MUTATOR_BRANCH_DIRECTORY'+$observerNamespace]=Join-Path $proof 'records'
        $settings['MUTATOR_BRANCH_RUN'+$observerNamespace]=$runId
        $settings.MUTATOR_BRANCH_DIRECTORY=Join-Path $proof 'subject-records'
        $manifest.ObserverSha256=(Get-FileHash -LiteralPath $observer).Hash
        $manifest.ObserverSourceSha256=$generated.SourceSha256
    }
    Write-MutatorJson (Join-Path $proof 'manifest.json') $manifest
    $saved=@{}
    foreach($key in $settings.Keys){$saved[$key]=[Environment]::GetEnvironmentVariable($key)}
    try{
        foreach($key in $settings.Keys){[Environment]::SetEnvironmentVariable($key,$settings[$key])}
        if($observerNamespace){
            $preparation=Invoke-MutatorNative (Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})) @('-NoProfile','-File',
                (Join-Path $source 'FrenchExDev.Mutator.PoSh/test/Fixtures/Prepare-InstrumentedContainers.ps1'),'-ProofDirectory',$proof) $source 900
            if($preparation.Outcome -ne 'Success'){
                Write-MutatorJson (Join-Path $proof 'preparation-failure.json') $preparation.Failure
                throw ('Derived container preparation failed in the instrumented copy; proof: '+$proof)
            }
        }
        $run=Invoke-MutatorNative (Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})) @('-NoProfile','-File',
            (Join-Path $source 'FrenchExDev.Mutator.PoSh/test/Invoke-Tests.ps1'),'-Path',(Join-Path $subject $(if($TestScope -eq 'All'){'test'}else{'test/'+$TestScope}))) $source 900
        [IO.File]::WriteAllText((Join-Path $proof 'stdout.log'),$run.Stdout)
        [IO.File]::WriteAllText((Join-Path $proof 'stderr.log'),$run.Stderr)
        if($run.Outcome -ne 'Success'){Write-MutatorJson (Join-Path $proof 'native-failure.json') $run.Failure}
        $lines=@($run.Stdout -split "`r?`n"|Where-Object {$_ -like '{*'})
        if(!$lines.Count){throw ('Instrumented tests returned no summary; proof: '+$proof)}
        $tests=$lines[-1]|ConvertFrom-Json -AsHashtable -DateKind String
        $tests.NativeOutcome=$run.Outcome;$tests.NativeExitCode=$run.ExitCode
        Write-MutatorJson (Join-Path $proof 'tests.json') $tests
        if($run.Outcome -ne 'Success' -or !$tests.Passed -or $tests.Failed -or $tests.Skipped -or $tests.DiscoveryErrors -or !$tests.SourceUnchanged){throw ('Instrumented semantic validation failed; proof: '+$proof)}
        $observed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($file in Get-ChildItem (Join-Path $proof 'records') -Filter '*.jsonl'){
            foreach($line in [IO.File]::ReadLines($file.FullName)){
                $entry=$line|ConvertFrom-Json -AsHashtable -DateKind String
                if($entry.Run -cne $runId){throw 'A branch event belongs to a different coverage run.'}
                [void]$observed.Add($entry.Id+'|'+$entry.Outcome)
            }
        }
        $missed=[Collections.Generic.List[object]]::new();$total=0
        foreach($branch in $definitions){
            foreach($outcome in $branch.Outcomes){
                $total++
                if(!$observed.Contains($branch.Id+'|'+$outcome)){$missed.Add(@{Id=$branch.Id;File=$branch.File;Kind=$branch.Kind;Line=$branch.Line;Column=$branch.Column;Outcome=$outcome})}
            }
        }
        if(!$total){throw 'Branch discovery was empty.'}
        $result=@{Run=$runId;Metric='BranchOutcomes';Platform=$(if($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'});Total=$total;Covered=($total-$missed.Count);Missed=$missed.ToArray();Percent=(100.0*($total-$missed.Count)/$total)
            Branches=$definitions.ToArray();Observed=@($observed);SourceFingerprints=$fingerprints.ToArray();Tests=$tests;Proof=$proof}
        Write-MutatorJson (Join-Path $proof 'coverage.json') $result
        @{Metric=$result.Metric;Total=$total;Covered=$result.Covered;Missed=$missed.Count;Percent=$result.Percent;Passed=$tests.Passed;Proof=$proof}|ConvertTo-Json -Compress
    }catch{
        @{Outcome='Failed';Proof=$proof;Error=$_.Exception.Message}|ConvertTo-Json -Compress
        throw
    }finally{foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])}}
} $Module $TestScope $ProofDirectory
