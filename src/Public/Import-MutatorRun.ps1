function Import-MutatorRun {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path,[string]$RunRoot,[ValidateSet('Interrupted','Failed','Success')][string]$Outcome='Interrupted')
    $sourcePath=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $source=Read-MutatorJson $sourcePath
    if(!$source.Reports -or !$source.Expected -or !$source.Platform){throw 'Expected a consolidated package mutation receipt.'}
    if($source.Platform -cnotin @('windows','linux','macos')){throw 'The imported platform must be windows, linux or macos.'}
    if($Outcome -eq 'Success' -and ($source.Outcome -ne 'Success' -or $source.Completed -ne $source.Expected)){throw 'An incomplete receipt cannot be imported as a successful run.'}
    $root=Get-MutatorRunRoot $RunRoot
    $hash=(Get-FileHash $sourcePath).Hash
    $id='import-'+$source.Platform+'-'+$hash.Substring(0,12).ToLowerInvariant()
    $directory=Join-Path $root $id
    if(Test-Path (Join-Path $directory 'run.json')){return Get-MutatorRun -Path $directory}
    if(!$PSCmdlet.ShouldProcess($directory,'Import retained evidence without executing mutations')){return}
    $names=@(@($source.Reports.Package)+@($source.Missing))
    $unique=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($name in $names){
        if($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or !$unique.Add($name)){throw 'Imported package names must be nonempty and unique.'}
    }
    if($names.Count -ne $source.Expected){throw 'Imported package discovery does not match the receipt.'}
    $packages=@()
    foreach($name in $names){
        $entry=@{Id=('p{0:d4}' -f $packages.Count);Name=$name;ModulePath='';Configuration='';ResumeFrom='';Stryker=$false}
        $packages+=$entry
        $report=@($source.Reports|Where-Object Package -CEQ $name)
        $state=@{Id=$entry.Id;Name=$name;Outcome='Pending';Phase='NotCompleted';PSMutant=$null;Stryker=$null;Error=$null}
        if($report.Count){$state.Outcome=$report[0].Outcome;$state.Phase=$report[0].Outcome;$state.PSMutant=$report[0].Mutation;if($report[0].Assembly){$state.Stryker=$report[0].Assembly['Mutation']}}
        Write-MutatorJson (Join-Path $directory ('packages/'+$entry.Id+'/state.json')) $state
    }
    $now=[datetime]::UtcNow.ToString('O')
    Write-MutatorJson (Join-Path $directory 'run.json') @{SchemaVersion=1;Id=$id;Outcome=$Outcome;CreatedUtc=$now;CompletedUtc=$now;Platform=$source.Platform;Runtime=$source.Runtime
        Packages=$packages;Process=$null;Error=$null;Origin='Imported';OriginalStartKnown=$false;SourceReceipt=$sourcePath;SourceReceiptSha256=$hash;ReadOnly=$true}
    Get-MutatorRun -Path $directory
}
