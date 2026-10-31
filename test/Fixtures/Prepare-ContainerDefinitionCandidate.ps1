#requires -Version 7.6
# Prepare generated-file changes in an owned copy; never overwrite the checkout.
param()
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {
    $parent=Split-Path $script:MutatorRoot
    $proof=Join-Path $script:MutatorRoot ('test/Artifacts/development/container-definitions-candidate-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $source=Join-Path $proof 'source'
    $config=Read-MutatorJson (Join-Path $script:MutatorRoot 'test/psmutant.config.json')
    foreach($name in Get-MutatorSubtree $parent $config){Copy-MutatorTree (Join-Path $parent $name) (Join-Path $source $name)}
    $copiedManifest=Join-Path $source 'FrenchExDev.Mutator.PoSh/FrenchExDev.Mutator.PoSh.psd1'
    $copied=Import-Module $copiedManifest -Force -DisableNameChecking -PassThru
    & $copied {
        param($Source,$Parent,$Proof)
        $null=Export-MutatorContainerBaseDefinition -ModuleRoot $Source
        $modules=@(Get-ChildItem $Source -Directory -Filter 'FrenchExDev.*.PoSh'|Where-Object {Test-Path (Join-Path $_.FullName ($_.Name+'.psd1'))})
        $null=Export-MutatorContainerDefinition -ModulePath @($modules.FullName) -Force -IncludeMacOS
        $oldRuntime=Read-MutatorJson (Join-Path $Parent 'QuietCliEcosystem/FrenchExDev.QuietCli.PoSh/containers/base/runtime.json')
        $newRuntime=Read-MutatorJson (Join-Path $Source 'QuietCliEcosystem/FrenchExDev.QuietCli.PoSh/containers/base/runtime.json')
        $oldImage=Read-MutatorJson (Join-Path $Parent 'FrenchExDev.Tools.Ag.PoSh/containers/image.json')
        $newImage=Read-MutatorJson (Join-Path $Source 'FrenchExDev.Tools.Ag.PoSh/containers/image.json')
        $replacements=@(
            @($newRuntime.Fingerprint,$oldRuntime.Fingerprint),
            @($newRuntime.MacFingerprint,$oldRuntime.MacFingerprint),
            @($newRuntime.ControllerFingerprint,$oldRuntime.ControllerFingerprint),
            @($newImage.BootstrapSha256,$oldImage.BootstrapSha256)
        )
        $files=[Collections.Generic.List[object]]::new()
        foreach($module in $modules){
            foreach($candidate in Get-ChildItem (Join-Path $module.FullName 'containers') -File -Recurse){
                $relative=[IO.Path]::GetRelativePath($Source,$candidate.FullName)
                $target=Join-Path $Parent $relative
                $newText=[IO.File]::ReadAllText($candidate.FullName).Replace("`r`n","`n")
                $oldText=if(Test-Path -LiteralPath $target){[IO.File]::ReadAllText($target).Replace("`r`n","`n")}else{$null}
                $reconstructed=$newText
                foreach($pair in $replacements){
                    if($pair[0] -and $pair[1]){
                        $reconstructed=$reconstructed.Replace($pair[0],$pair[1]).Replace($pair[0].Substring(0,12),$pair[1].Substring(0,12))
                    }
                }
                $files.Add(@{Path=$relative;Candidate=$candidate.FullName;Target=$target;Changed=($newText -cne $oldText);GeneratedOnly=($reconstructed -ceq $oldText)
                    CurrentSha256=$(if($null -ne $oldText){(Get-FileHash -LiteralPath $target).Hash}else{$null});CandidateSha256=(Get-FileHash -LiteralPath $candidate.FullName).Hash})
            }
        }
        Write-MutatorJson (Join-Path $Proof 'comparison.json') @{Source=$Source;Modules=$modules.Count;Files=$files.ToArray();Unexpected=@($files|Where-Object {!$_.GeneratedOnly})}
        @{Proof=$Proof;Modules=$modules.Count;Files=$files.Count;Changed=@($files|Where-Object Changed).Count;Unexpected=@($files|Where-Object {!$_.GeneratedOnly}|ForEach-Object Path)}|ConvertTo-Json -Compress
    } $source $parent $proof
}
