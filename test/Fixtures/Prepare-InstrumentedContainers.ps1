#requires -Version 7.6
param([Parameter(Mandatory)][string]$ProofDirectory)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$proof=(Resolve-Path -LiteralPath $ProofDirectory -ErrorAction Stop).ProviderPath
if(!(Test-Path -LiteralPath (Join-Path $proof 'manifest.json') -PathType Leaf)){throw 'An owned branch instrumentation manifest is required.'}
$source=Join-Path $proof 'source'
$module=Join-Path $source 'FrenchExDev.Mutator.PoSh/FrenchExDev.Mutator.PoSh.psd1'
Import-Module $module -DisableNameChecking
# Instrumentation changes executable payload bytes. Recreate only the derived
# definitions in the frozen copy before tests take their source snapshots.
$definitions=Update-MutatorContainerDefinition -ModuleRoot $source -IncludeMacOS -OutputDirectory (Join-Path $proof 'container-definitions')
$result=@{Outcome='Success';Scope='InstrumentedCopyOnly';Modules=$definitions.Modules.Count;Definitions=$definitions.Modules.Count;Base=$definitions.BaseFingerprint;Source=$source}
$result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $proof 'preparation.json')
@{Outcome=$result.Outcome;Scope=$result.Scope;Modules=$result.Modules}|ConvertTo-Json -Compress
