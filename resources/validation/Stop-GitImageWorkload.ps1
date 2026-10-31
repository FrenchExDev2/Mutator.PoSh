#requires -Version 7.6
param([Parameter(Mandatory)][string]$ReportRoot)
$ErrorActionPreference='Stop'
$metadata=Get-Content (Join-Path $ReportRoot 'mutations/FrenchExDev.QuietCli.Git.PoSh/runs/run.json') -Raw|ConvertFrom-Json -AsHashtable
if($metadata.Id -notmatch '^\d{8}-\d{6}-[a-f0-9]{8}$'){throw 'Invalid retained mutation run identity.'}
$source=[IO.Path]::GetFullPath($metadata.SourceRoot)
$parent=Split-Path $source
$temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
if(!$source.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $parent -Leaf) -notmatch '^mutator-git-[a-f0-9]{32}$' -or (Split-Path $source -Leaf) -cne 'modules'){throw 'The run is not inside a Git validation sandbox.'}
$runPath=Join-Path $parent ('validation-runs/FrenchExDev.QuietCli.Git.PoSh/'+$metadata.Id)
$live=Get-Content (Join-Path $runPath 'run.json') -Raw|ConvertFrom-Json -AsHashtable
if($live.Id -cne $metadata.Id -or $live.SourceRoot -cne $metadata.SourceRoot){throw 'The live run differs from the retained request.'}
Import-Module (Join-Path $source 'FrenchExDev.Mutator.PoSh/FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
$result=Stop-MutatorRun -Path $runPath
@{StopRequested=$true;Outcome=$result.Outcome;Evaluated=$result.EvaluatedMutants;Planned=$result.PlannedMutants}|ConvertTo-Json -Compress
