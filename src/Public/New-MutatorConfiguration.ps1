function New-MutatorConfiguration {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$ModulePath,[string[]]$Dependency=@(),[switch]$Force)
    $root=(Resolve-Path -LiteralPath $ModulePath -ErrorAction Stop).ProviderPath
    $parent=Get-MutatorModuleRoot $root;$name=[IO.Path]::GetRelativePath($parent,$root).Replace('\','/')
    $sources=@(Get-MutatorProductionFile $root)
    $testFiles=@(Get-MutatorTestFile $root|Sort-Object FullName)
    $tests=@(foreach($file in $testFiles){[IO.Path]::GetRelativePath($parent,$file.FullName).Replace('\','/')})
    if(!$tests.Count){throw 'Mutation configuration requires test files.'}
    $paths=@(@(foreach($file in $sources){[IO.Path]::GetRelativePath($parent,$file).Replace('\','/')})|Sort-Object -Unique)
    $map=[ordered]@{};foreach($path in $paths){$map[$path]=$tests}
    $configuration=[ordered]@{workers=0;coveredLinesOnly=$false;mutate=$paths;tests=$map;thresholds=@{high=100;low=100;break=100};reportPath=$name+'/test/Artifacts/mutation.json';sandboxSubtrees=@($name)+@($Dependency)}
    $equivalents=Get-MutatorEquivalence -Root $root -Paths $paths
    if($equivalents.Count){throw 'Strict 100% mutation requires zero excluded equivalences. Remove the declarations after resolving or simplifying the affected code.'}
    [void](Get-MutatorSubtree $parent $configuration)
    $target=Join-Path $root 'test/psmutant.config.json'
    if((Test-Path $target) -and !$Force){throw 'Mutation configuration exists. Use -Force to replace it explicitly.'}
    if($PSCmdlet.ShouldProcess($target,'Write complete mutation scope and test associations')){Write-MutatorJson $target $configuration}
    [pscustomobject]@{Path=$target;SourceFiles=$paths.Count;TestFiles=$tests.Count;CoveredLinesOnly=$false;Equivalents=$equivalents.Count}
}
