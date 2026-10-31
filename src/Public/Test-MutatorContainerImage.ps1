function Test-MutatorContainerImage {
    <#
    .SYNOPSIS
    Qualify a supported immutable tool image with source-bound proof.

    .DESCRIPTION
    Runs Ag or Journalctl with resource limits. Rejects failed transport, absent reports, identity
    mismatch and source drift.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][Alias('Profile')][ValidateSet('Ag','Journalctl')][string]$ValidationProfile,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Connection,
        [ValidateRange(256,65536)][int]$MemoryMiB=2048,
        [ValidateRange(1,64)][int]$Cpus=2,
        [ValidateRange(1,14400)][int]$TimeoutSeconds=600
    )
    $profileName=switch($ValidationProfile){'Ag'{'Ag'};'Journalctl'{'Journalctl'}}
    $output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    $receiptPath=Join-Path $output 'qualification-run.json'
    # A retained green report must never stand in for a subsequent failed process.
    if((Test-Path $receiptPath) -or (Test-Path (Join-Path $output 'qualification.json'))){throw 'Use a new output directory to preserve previous qualification evidence.'}
    if(!$PSCmdlet.ShouldProcess($Image,'Run the selected image qualification with bounded resources and retained reports')){return}
    [void][IO.Directory]::CreateDirectory($output)
    $receipt=@{SchemaVersion=1;Image=$Image;Profile=$profileName;Connection=$Connection;Outcome='Running'
        StartedUtc=[datetime]::UtcNow.ToString('O');MemoryLimitMiB=$MemoryMiB;Cpus=$Cpus
        StdoutLog=(Join-Path $output 'qualification.stdout.log');StderrLog=(Join-Path $output 'qualification.stderr.log')}
    Write-MutatorJson $receiptPath $receipt
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try {
        $inspect=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$Image) -Directory $script:MutatorRoot -Connection $Connection
        if($inspect.Outcome -ne 'Success'){throw 'The qualification image is not available locally.'}
        $built=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
        $moduleName=[string]$built.Config.Labels['org.frenchexdev.mutator.module']
        if($built.Os -ne 'linux' -or $built.Id -notmatch '^(sha256:)?[a-f0-9]{64}$' -or $moduleName -cnotmatch '^FrenchExDev\.[A-Za-z0-9_.-]+\.PoSh$' -or !$moduleName.EndsWith('.'+$profileName+'.PoSh',[StringComparison]::Ordinal)){
            throw 'The image OS, immutable identity or module label does not match the selected profile.'
        }
        $receipt.ImageId=$built.Id
        $fixture=Join-Path $script:MutatorRoot ('resources/containers/probes/Test-Generated'+$profileName+'Image.ps1')
        $receipt.FixtureSha256=(Get-FileHash -LiteralPath $fixture).Hash
        $receipt.MutatorSourceSha256=(Get-MutatorSourceSnapshot $script:MutatorRoot).Sha256
        Copy-Item -LiteralPath $fixture -Destination $output
        $arguments=@('run','--rm','--init','--network=none','--pull=never','--memory',($MemoryMiB.ToString()+'m'),'--memory-swap',($MemoryMiB.ToString()+'m'),'--cpus',$Cpus.ToString(),
            '--volume',($output+':/proof'),'--volume',($script:MutatorRoot+':/opt/mutator/modules/FrenchExDev.Mutator.PoSh:ro'),
            $built.Id,'pwsh','-NoProfile','-File',('/proof/'+(Split-Path $fixture -Leaf)))
        if($profileName -eq 'Journalctl'){
            $versions=Read-MutatorJson (Join-Path $script:MutatorRoot 'resources/containers/definitions/package-versions.json')
            $arguments+=@('-ExpectedDotnetVersion',$versions.LinuxGlibc.Dotnet.Version)
        }
        $run=Invoke-MutatorContainerCommand -Arguments $arguments -Directory $script:MutatorRoot -TimeoutSeconds $TimeoutSeconds -Connection $Connection
        [IO.File]::WriteAllText($receipt.StdoutLog,$run.Stdout)
        [IO.File]::WriteAllText($receipt.StderrLog,$run.Stderr)
        $receipt.ExitCode=$run.ExitCode
        $receipt.Outcome=$run.Outcome
        if($run.Outcome -ne 'Success'){throw "Image qualification failed; retained receipt: $receiptPath"}
        if((Get-MutatorSourceSnapshot $script:MutatorRoot).Sha256 -cne $receipt.MutatorSourceSha256){throw 'Mutator sources changed during the image qualification.'}
        $report=Read-MutatorJson (Join-Path $output 'qualification.json')
        if($report -isnot [Collections.IDictionary]){throw 'The image test gate is empty, incomplete or failed.'}
        $counts=@{}
        foreach($field in @('Passed','Failed','Skipped','DiscoveryErrors')){
            [long]$count=0
            if(![long]::TryParse([string]$report[$field],[ref]$count) -or $count -lt 0){throw 'The image test gate contains an invalid counter.'}
            $counts[$field]=$count
        }
        if($counts.Passed -le 0 -or $counts.Failed -ne 0 -or $counts.Skipped -ne 0 -or $counts.DiscoveryErrors -ne 0){throw 'The image test gate is empty, incomplete or failed.'}
        [long]$limit=0;[long]$peak=0
        if(![long]::TryParse([string]$report.MemoryLimitBytes,[ref]$limit) -or $limit -ne ([long]$MemoryMiB*1MB) -or
            ![long]::TryParse([string]$report.MemoryPeakBytes,[ref]$peak) -or $peak -le 0){throw 'The container did not prove the requested cgroup memory limit and measured peak.'}
        $receipt.Passed=$counts.Passed
        $receipt.MemoryPeakBytes=$peak
        $receipt.MemoryLimitBytes=$limit
        $receipt.Outcome='Success'
    } catch {
        if($receipt.Outcome -in @('Running','Success')){$receipt.Outcome='Failed'}
        $receipt.Error=$_.Exception.Message
        throw
    } finally {
        $receipt.DurationSeconds=[math]::Round($watch.Elapsed.TotalSeconds,3)
        $receipt.CompletedUtc=[datetime]::UtcNow.ToString('O')
        Write-MutatorJson $receiptPath $receipt
    }
    [pscustomobject]$receipt
}
