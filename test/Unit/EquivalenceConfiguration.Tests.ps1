<#
.SYNOPSIS
Expected behavior for the EquivalenceConfiguration tests.

.DESCRIPTION
Strict mutation configuration must reject equivalence exclusions instead of using them to improve
the score. Invalid or stale declarations cannot become accepted gate evidence.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:MutatorRoot=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:MutatorRoot 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    Import-Module (Join-Path (Split-Path $script:MutatorRoot) 'FrenchExDev.DevPoSh.PoSh/FrenchExDev.DevPoSh.PoSh.psd1') -Force -DisableNameChecking
    Import-Module PSMutant -RequiredVersion 0.6.0
}
Describe 'Equivalence declarations bind to exact reviewed source candidates' {
    BeforeEach {
        $script:Fixture=New-DevPoShModule -Name ('Fixture.Equivalent'+[guid]::NewGuid().ToString('N')) -Path $TestDrive -Function Get-Value
        $script:File=Join-Path $script:Fixture.Path 'src/Public/Get-Value.ps1'
        Set-Content $script:File 'function Get-Value { $number=0;[int]::TryParse("5",[ref]$number)|Out-Null;$number }'
        Set-Content (Join-Path $script:Fixture.Path 'test/Unit/Value.Tests.ps1') 'Describe value {It parses {Get-Value|Should -Be 5}}'
        $candidate=@(& (Get-Module PSMutant) {param($File) Get-PSMutationCandidate $File|Where-Object Original -CEQ '0'} $script:File)[0]
        $script:Entry=@{File=($script:Fixture.Name+'/src/Public/Get-Value.ps1');Sha256=(Get-FileHash $script:File).Hash;Function=$candidate.Function
            Line=$candidate.Line;StartOffset=$candidate.StartOffset;EndOffset=$candidate.EndOffset;Operator=$candidate.Operator;Original=$candidate.Original;Mutated=$candidate.Mutated
            Reason='The TryParse out argument overwrites this initializer before its first read.';Evidence=@('test/Unit/Value.Tests.ps1')}
        $script:Declaration=Join-Path $script:Fixture.Path 'test/mutation-equivalents.json'
    }
    It 'discovers a module test suite below an ancestor called Artifacts while excluding that modules own artifacts' {
        $fixture=New-DevPoShModule -Name Fixture.ArtifactParent -Path (Join-Path $TestDrive 'Artifacts/source') -Function Get-Value
        $artifact=Join-Path $fixture.Path 'test/Artifacts/stale';[void][IO.Directory]::CreateDirectory($artifact)
        Set-Content (Join-Path $artifact 'Old.Tests.ps1') 'throw "must not discover"'
        $result=New-MutatorConfiguration -ModulePath $fixture.Path
        $result.TestFiles|Should -Be 1
        $config=Get-Content $result.Path -Raw|ConvertFrom-Json -AsHashtable
        @($config.tests.Values|ForEach-Object {$_}|Where-Object {$_ -like '*Old.Tests.ps1'}).Count|Should -Be 0
    }
    It 'recognizes a historical source-bound declaration but refuses to exclude it from a strict gate' {
        @{SchemaVersion=1;Entries=@($script:Entry)}|ConvertTo-Json -Depth 7|Set-Content $script:Declaration
        {New-MutatorConfiguration -ModulePath $script:Fixture.Path}|Should -Throw '*zero excluded equivalences*'
        Test-Path (Join-Path $script:Fixture.Path 'test/psmutant.config.json')|Should -BeFalse
        $configuration=@{mutate=@($script:Entry.File);equivalents=@{historical='reviewed'}}
        {& (Get-Module FrenchExDev.Mutator.PoSh) {param($Root,$Config) Confirm-MutatorEquivalence $Root $Config} $script:Fixture.Path $configuration}|Should -Throw '*zero excluded equivalences*'
        $map=& (Get-Module FrenchExDev.Mutator.PoSh) {param($Root,$Paths) Get-MutatorEquivalence $Root $Paths} $script:Fixture.Path @($script:Entry.File)
        $map.Count|Should -Be 1
        Add-Content $script:File '# changed after configuration'
        {& (Get-Module FrenchExDev.Mutator.PoSh) {param($Root,$Config) Confirm-MutatorEquivalence $Root $Config} $script:Fixture.Path $configuration}|Should -Throw '*fingerprint is stale*'
    }
    It 'rejects an invalid declaration before writing the mutation configuration: <Fault>' -ForEach @(
        @{Fault='hash'},@{Fault='candidate'},@{Fault='reason'},@{Fault='evidence'},@{Fault='duplicate'},@{Fault='empty'},@{Fault='scope'}
    ) {
        switch($Fault){
            hash {Add-Content $script:File '# source changed'}
            candidate {$script:Entry.Mutated='2'}
            reason {$script:Entry.Reason=' '}
            evidence {$script:Entry.Evidence=@('../outside.Tests.ps1')}
            scope {$script:Entry.File='Other/source.ps1'}
        }
        $entries=@($script:Entry)
        if($Fault -eq 'duplicate'){$entries+=@($script:Entry)}
        if($Fault -eq 'empty'){$entries=@()}
        @{SchemaVersion=1;Entries=$entries}|ConvertTo-Json -Depth 7|Set-Content $script:Declaration
        {New-MutatorConfiguration -ModulePath $script:Fixture.Path}|Should -Throw
        Test-Path (Join-Path $script:Fixture.Path 'test/psmutant.config.json')|Should -BeFalse
    }
}
