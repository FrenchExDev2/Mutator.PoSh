function Write-MutatorValidationReport {
    <#
    .SYNOPSIS
    Publish validation JSON, escaped HTML and optional terminal progress.

    .DESCRIPTION
    Retains separate platform outcomes and unknown progress. HTML refresh is active only while
    validation is running.
    #>

    param([Collections.IDictionary]$Run,[switch]$UI)
    Write-MutatorJson (Join-Path $Run.Path 'summary.json') $Run
    $rows=foreach($os in @('Linux','Windows','MacOS')){
        $state=$Run.Platforms[$os]
        '<tr><td>'+[Net.WebUtility]::HtmlEncode($os)+'</td><td>'+[Net.WebUtility]::HtmlEncode([string]$state.Outcome)+'</td><td><pre>'+[Net.WebUtility]::HtmlEncode(($state|ConvertTo-Json -Depth 12))+'</pre></td></tr>'
    }
    $links=@(foreach($os in @('linux','windows','macos')){
        $folder=Join-Path $Run.Path ($os+'/reports')
        if(Test-Path -LiteralPath $folder){foreach($file in Get-ChildItem -LiteralPath $folder -File -Recurse|Where-Object Extension -In @('.json','.xml','.html')){
            $relative=[IO.Path]::GetRelativePath($Run.Path,$file.FullName).Replace('\','/')
            $href=($relative.Split('/')|ForEach-Object {[uri]::EscapeDataString($_)}) -join '/'
            '<li><a href="'+$href+'">'+[Net.WebUtility]::HtmlEncode($relative)+'</a></li>'
        }}
    })
    $refresh=if($Run.Outcome -eq 'Running'){'<meta http-equiv="refresh" content="3">'}else{''}
    $title=Get-MutatorText 'Validation.Title';$language=Get-MutatorLanguage
    $html='<!doctype html><html lang="'+$language+'"><meta charset="utf-8">'+$refresh+'<title>'+$title+'</title><h1>'+$title+' '+[Net.WebUtility]::HtmlEncode($Run.Id)+'</h1><p>'+[Net.WebUtility]::HtmlEncode($Run.Outcome)+'</p><p><a href="summary.json">'+(Get-MutatorText 'Validation.Json')+'</a></p><table><tr><th>OS</th><th>'+(Get-MutatorText 'Validation.State')+'</th><th>'+(Get-MutatorText 'Validation.Details')+'</th></tr>'+($rows -join '')+'</table><ul>'+($links -join '')+'</ul></html>'
    [IO.File]::WriteAllText((Join-Path $Run.Path 'index.html'),$html,[Text.UTF8Encoding]::new($false))
    if($UI){
        $heading=@('OS')+@('Module','Suite','Phase','State'|ForEach-Object {Get-MutatorText ('Header.'+$_)})+@('%')+@('Errors','Mutants','ProcessMemory','Engine'|ForEach-Object {Get-MutatorText ('Header.'+$_)})
        $lines=@(('{0,-8} {1,-30} {2,-12} {3,-12} {4,-13} {5,6} {6,8} {7,-13} {8,8} {9}' -f $heading))
        foreach($os in @('Linux','Windows','MacOS')){
            $s=$Run.Platforms[$os]
            $p=if($s['Progress']){$s.Progress}else{@{}}
            $percent=if($null -ne $p['CompletionPercent']){'{0:N1}' -f $p.CompletionPercent}else{'?'}
            $mutants=if($p['PlannedMutants']){[string]$p['EvaluatedMutants']+'/'+$p.PlannedMutants}else{'?'}
            $memory=if($p['MemoryBytes']){[math]::Round($p.MemoryBytes/1MB)}else{'?'}
            $phase=if($p['Phase']){$p.Phase}else{$s['Phase']}
            $engine=if($s['ContainerEngine']){$s.ContainerEngine}else{$Run['ContainerEngine']}
            $lines+=('{0,-8} {1,-30} {2,-12} {3,-12} {4,-13} {5,6} {6,8} {7,-13} {8,8} {9}' -f $os,[string]$p['Module'],[string]$p['Suite'],[string]$phase,$s.Outcome,$percent,[string]$p['Errors'],$mutants,$memory,[string]$engine)
        }
        $prefix=if(Test-MutatorTerminalInteractive){[char]27+'[H'+[char]27+'[J'}else{''}
        Write-Information ($prefix+($lines -join [Environment]::NewLine)) -InformationAction Continue
    }
}

function New-MutatorValidationSource {
    <#
    .SYNOPSIS
    Freeze selected modules and declared validation dependencies.

    .DESCRIPTION
    Checks live/copied fingerprints before retaining proof. Optional recipe regeneration affects only
    the copy and retains original identities.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private staging runs inside the public Invoke-MutatorValidation ShouldProcess boundary.')]
    [CmdletBinding()]
    param([string[]]$ModulePath,[string]$OutputDirectory,[switch]$RefreshContainerDefinitions)
    $parent=Split-Path $script:MutatorRoot
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($name in @('FrenchExDev.Mutator.PoSh','FrenchExDev.DevPoSh.PoSh','QuietCliEcosystem/FrenchExDev.QuietCli.PoSh')){[void]$names.Add($name)}
    foreach($path in $ModulePath){
        [void]$names.Add([IO.Path]::GetRelativePath($parent,$path).Replace('\','/'))
        $config=Read-MutatorJson (Join-Path $path 'test/psmutant.config.json')
        if(!$config){throw 'A complete mutation configuration is required to freeze validation dependencies.'}
        foreach($name in @(Get-MutatorSubtree $parent $config)){[void]$names.Add($name)}
    }
    $target=Join-Path $OutputDirectory 'source'
    $proof=@(foreach($name in @($names|Sort-Object)){
        $live=Join-Path $parent $name;$copy=Join-Path $target $name
        $before=Get-MutatorSourceSnapshot $live
        Copy-MutatorTree $live $copy
        $after=Get-MutatorSourceSnapshot $live;$frozen=Get-MutatorSourceSnapshot $copy
        if($before.Sha256 -cne $after.Sha256 -or $before.Sha256 -cne $frozen.Sha256){throw ('Sources changed while freezing '+$name)}
        @{Module=$name;Sha256=$frozen.Sha256}
    })
    if($RefreshContainerDefinitions){
        $null=Update-MutatorContainerDefinition -ModuleRoot $target -OutputDirectory (Join-Path $OutputDirectory 'container-definitions')
        foreach($entry in $proof){
            $entry.OriginalSha256=$entry.Sha256
            $entry.Sha256=(Get-MutatorSourceSnapshot (Join-Path $target $entry.Module)).Sha256
        }
    }
    Write-MutatorJson (Join-Path $OutputDirectory 'sources.json') $proof
    @{Path=$target;Sha256=(Get-MutatorSourceSnapshot $target).Sha256}
}

function Invoke-MutatorValidationContainerCommand {
    <#
    .SYNOPSIS
    Run validation transport and require native success.

    .DESCRIPTION
    Turns timeouts and native errors into explicit transport failures with bounded diagnostics.
    #>

    param([string[]]$Arguments,[string]$Directory,[string]$Connection,[int]$TimeoutSeconds=120)
    $r=Invoke-MutatorContainerCommand -Arguments $Arguments -Directory $Directory -Connection $Connection -TimeoutSeconds $TimeoutSeconds
    if($r.Outcome -cne 'Success'){throw ($script:MutatorContainerEngine+' validation operation failed: '+$Arguments[0]+'; '+(ConvertTo-Json -InputObject $r.Failure -Depth 8 -Compress))}
    $r
}
