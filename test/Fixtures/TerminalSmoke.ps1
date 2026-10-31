#requires -Version 7.6
# Interactive fixture only: it never starts a mutation worker.
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
$path=Join-Path $root 'test/Artifacts/development/terminal-smoke'
$before=[Console]::TreatControlCAsInput
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Path)
    $now=[datetime]::UtcNow.ToString('O')
    Write-MutatorJson (Join-Path $Path 'run.json') @{Id='terminal-smoke-fixture';Outcome='Running';CreatedUtc=$now;Platform='windows';Runtime=$PSVersionTable.PSVersion.ToString();Process=@{Id=$PID;StartedUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('O')};Packages=@(@{Id='p0';Name='Complete fixture'},@{Id='p1';Name='Active fixture'});Schedule=@{Slots=2;Workers=1;WorkerBudget=2;ReservedMemoryMiB=2048};IsFixture=$true;Error=$null}
    Write-MutatorJson (Join-Path $Path 'packages/p0/state.json') @{Id='p0';Name='Complete fixture';Outcome='Success';Phase='Completed';PSMutant=@{Total=4;Survived=0}}
    Write-MutatorJson (Join-Path $Path 'packages/p1/state.json') @{Id='p1';Name='Active fixture';Outcome='Running';Phase='PSMutant'}
    [IO.File]::WriteAllText((Join-Path $Path 'packages/p1/mutants.jsonl'),'{"Evaluated":6,"Planned":16,"Survived":1}')
} $path
$null=Watch-MutatorRun -Path $path
@{TerminalFixture=$true;ControlCRestored=([Console]::TreatControlCAsInput -eq $before);MutationWorkersStarted=0}|ConvertTo-Json -Compress
