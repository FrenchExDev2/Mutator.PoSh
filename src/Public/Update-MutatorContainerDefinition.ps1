function Update-MutatorContainerDefinition {
    <#
    .SYNOPSIS
    Regenerate shared/selected recipes with a change report.

    .DESCRIPTION
    Restricts selection to active siblings and preserves existing macOS definitions. Does not build or
    qualify images.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ModuleRoot=(Split-Path $script:MutatorRoot),[string[]]$ModulePath,
        [ValidateSet('Dockurr','Native')][string]$WindowsBackend='Dockurr',[switch]$IncludeMacOS,
        [string]$OutputDirectory,[switch]$UI)
    $root=(Resolve-Path -LiteralPath $ModuleRoot -ErrorAction Stop).ProviderPath
    $paths=if($PSBoundParameters.ContainsKey('ModulePath')){@($ModulePath|ForEach-Object {(Resolve-Path -LiteralPath $_ -ErrorAction Stop).ProviderPath})}
        else{@(foreach($directory in @($root,(Join-Path $root 'QuietCliEcosystem'))){if(Test-Path $directory){Get-ChildItem -LiteralPath $directory -Directory -Filter 'FrenchExDev.*.PoSh'|Where-Object {$_.Name -cnotin @('FrenchExDev.QuietCli.Git.PoSh','FrenchExDev.QuietCli.PoSh') -and (Test-Path -LiteralPath (Join-Path $_.FullName ($_.Name+'.psd1')) -PathType Leaf)}|Select-Object -ExpandProperty FullName}})}
    $paths=@($paths|Sort-Object -Unique)
    if(!$paths.Count){throw 'Container definition discovery was empty.'}
    foreach($path in $paths){
        try{$expected=Resolve-MutatorModuleDirectory $root (Split-Path $path -Leaf)}catch{throw 'Regenerate only modules inside ModuleRoot or its QuietCliEcosystem.'}
        if(![string]::Equals($path,$expected,$(if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}))){throw 'Regenerate only modules inside ModuleRoot or its QuietCliEcosystem.'}
    }
    if(!$PSCmdlet.ShouldProcess($root,'Regenerate shared bases and per-module Dockerfiles from Mutator templates')){return}
    $output=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}
        else{Join-Path $script:MutatorRoot ('test/Artifacts/container-definitions/'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))}
    if((Test-Path -LiteralPath $output) -and @(Get-ChildItem -LiteralPath $output -Force).Count){throw 'Select a new or empty container definition report directory.'}
    $targets=@(@($paths|ForEach-Object {Join-Path $_ 'containers'})+@(Join-Path $root 'FrenchExDev.Mutator.PoSh/resources/containers/base')|Sort-Object -Unique)
    $before=@{}
    foreach($target in $targets){
        $folder=$target
        if(Test-Path -LiteralPath $folder){foreach($file in Get-ChildItem -LiteralPath $folder -File -Recurse){$before[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName).Hash}}
    }
    $result=@{SchemaVersion=1;Outcome='Running';Path=$output;ModuleRoot=$root;StartedUtc=[datetime]::UtcNow.ToString('O');Modules=@();ChangedFiles=@();Files=0;BuildExecuted=$false}
    try{
        Write-MutatorJson (Join-Path $output 'summary.json') $result
        $base=Export-MutatorContainerBaseDefinition -ModuleRoot $root
        $result.BaseFingerprint=$base.Fingerprint
        foreach($path in $paths){
            if($UI){Write-Progress -Activity (Get-MutatorText 'Generation.Activity') -Status (Split-Path $path -Leaf) -PercentComplete (100*$result.Modules.Count/$paths.Count)}
            # Existing macOS definitions remain in sync without probing or building a macOS environment.
            $mac=$IncludeMacOS -or (Test-Path -LiteralPath (Join-Path $path 'containers/macos/Dockerfile'))
            $definition=Export-MutatorContainerDefinition -ModulePath $path -WindowsBackend $WindowsBackend -IncludeMacOS:$mac -Force
            $result.Modules+=@($definition.Module)
            Write-MutatorJson (Join-Path $output 'summary.json') $result
        }
        foreach($target in $targets){
            foreach($file in Get-ChildItem -LiteralPath $target -File -Recurse){
                $result.Files++
                if(!$before.ContainsKey($file.FullName) -or $before[$file.FullName] -cne (Get-FileHash -LiteralPath $file.FullName).Hash){$result.ChangedFiles+=@([IO.Path]::GetRelativePath($root,$file.FullName).Replace('\','/'))}
            }
        }
        $result.Outcome='Success'
    }catch{$result.Outcome='Failed';$result.Error=$_.Exception.Message;throw}
    finally{
        $result.CompletedUtc=[datetime]::UtcNow.ToString('O')
        Write-MutatorJson (Join-Path $output 'summary.json') $result
        if($UI){Write-Progress -Activity (Get-MutatorText 'Generation.Activity') -Completed}
    }
    [pscustomobject]$result
}
