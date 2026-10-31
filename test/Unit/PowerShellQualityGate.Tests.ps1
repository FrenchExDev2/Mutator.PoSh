<#
.SYNOPSIS
Expected behavior for the PowerShellQualityGate tests.

.DESCRIPTION
Write success only when exact production-source identity, full coverage and complete mutation proof
agree. Missing, stale or misleading evidence must fail before publishing success.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:MutatorRoot=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:MutatorRoot 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    Import-Module (Join-Path (Split-Path $script:MutatorRoot) 'FrenchExDev.DevPoSh.PoSh/FrenchExDev.DevPoSh.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'The final PowerShell quality proof binds full scopes to current source bytes' {
    BeforeEach {
        $script:CaseRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Fixture=New-DevPoShModule -Name Fixture.Quality -Path $script:CaseRoot -Function Get-Value
        $null=New-MutatorConfiguration -ModulePath $script:Fixture.Path
        $source=@(& (Get-Module FrenchExDev.Mutator.PoSh) {param($Root) Get-MutatorProductionFile $Root} $script:Fixture.Path)
        $hashes=@{};$fingerprints=@(foreach($file in $source){$relative=[IO.Path]::GetRelativePath($script:Fixture.Path,$file).Replace('\','/');$hash=(Get-FileHash $file).Hash;$hashes[$script:Fixture.Name+'/'+$relative]=$hash.ToLowerInvariant();@{Path=$relative;Sha256=$hash}})
        $script:Coverage=@{FullGateSatisfied=$true;CommandGateSatisfied=$true;Analyzed=1;Executed=1;Missed=0;Lines=@{Missed=0};Branches=@{Total=2;Covered=2;Missed=0};SourceFingerprints=$fingerprints}
        $script:Report=@{total=1;killed=1;survived=0;mutationScore=100;timedOut=0;declaredEquivalent=0;sourceHashes=$hashes
            skippedAsUncovered=0;staleEquivalents=@();filesWithoutTestMapping=@();mutants=@(@{File=($script:Fixture.Name+'/src/Public/Get-Value.ps1');Id=1;Line=1;Description='42 -> 43';Status='Killed'})}
        $script:Run=Join-Path $script:CaseRoot 'run';$script:CoveragePath=Join-Path $script:CaseRoot 'coverage.json'
        & (Get-Module FrenchExDev.Mutator.PoSh) {param($Run,$Name) Write-MutatorJson (Join-Path $Run 'run.json') @{Outcome='Success';Platform='windows';Runtime='7.6.9';Packages=@(@{Id='p0';Name=$Name})};Write-MutatorJson (Join-Path $Run 'packages/p0/state.json') @{Outcome='Success';Stryker=$null;PSMutant=@{Total=1;Killed=1;Score=100;TimedOut=0;Tool=@{Version='0.6.0'}}}} $script:Run $script:Fixture.Name
    }
    It 'writes a source-bound proof only after complete coverage and mutation evidence agree' {
        $script:Coverage|ConvertTo-Json -Depth 8|Set-Content $script:CoveragePath
        $script:Report|ConvertTo-Json -Depth 8|Set-Content (Join-Path $script:Run 'packages/p0/mutation.json')
        $discovered=@(& (Get-Module FrenchExDev.Mutator.PoSh) {param($Root) Get-MutatorProductionFile $Root} $script:Fixture.Path)
        $discovered.Count|Should -Be $script:Coverage.SourceFingerprints.Count
        $output=Join-Path $script:CaseRoot 'quality.json'
        $result=Test-MutatorPowerShellQualityGate -ModulePath $script:Fixture.Path -CoveragePath $script:CoveragePath -MutationRunPath $script:Run -OutputPath $output
        $result.FullGateSatisfied|Should -BeTrue
        $result.Scope|Should -BeExactly PowerShell
        $result.SourceFiles|Should -Be $script:Coverage.SourceFingerprints.Count
        $result.Mutation[0].Detected|Should -Be 1
        Test-Path $output|Should -BeTrue
        $preview=Join-Path $script:CaseRoot 'preview.json'
        $null=Test-MutatorPowerShellQualityGate -ModulePath $script:Fixture.Path -CoveragePath $script:CoveragePath -MutationRunPath $script:Run -OutputPath $preview -WhatIf
        Test-Path $preview|Should -BeFalse
    }
    It 'refuses misleading evidence before writing a successful proof: <Fault>' -ForEach @(
        @{Fault='coverage hash'},@{Fault='mutation hash'},@{Fault='branch miss'},@{Fault='survivor'},@{Fault='partial'},@{Fault='duplicate'},@{Fault='foreign verdict'},@{Fault='stale'},@{Fault='empty'},
        @{Fault='coverage incomplete'},@{Fault='command gate incomplete'},@{Fault='commands missed'},@{Fault='commands empty'},@{Fault='commands inconsistent'},
        @{Fault='lines missed'},@{Fault='branches empty'},@{Fault='branches inconsistent'},@{Fault='coverage scope missing'},@{Fault='coverage foreign source'},@{Fault='coverage duplicate source'},
        @{Fault='failed run'},@{Fault='multiple packages'},@{Fault='foreign package'},@{Fault='failed package'},@{Fault='mutation scope missing'},@{Fault='foreign candidate'},
        @{Fault='timeout mismatch'},@{Fault='CSharp survivor'},@{Fault='CSharp empty'}
    ) {
        switch($Fault){
            'coverage hash' {$script:Coverage.SourceFingerprints[0].Sha256='A'*64}
            'mutation hash' {$key=@($script:Report.sourceHashes.Keys)[0];$script:Report.sourceHashes[$key]='b'*64}
            'branch miss' {$script:Coverage.Branches.Covered=1;$script:Coverage.Branches.Missed=1}
            survivor {$script:Report.survived=1}
            partial {$script:Report.mode='Partial'}
            duplicate {$script:Report.mutants+=@($script:Report.mutants[0])}
            'foreign verdict' {$script:Report.mutants[0].Status='Skipped'}
            stale {$script:Report.staleEquivalents=@('stale')}
            empty {$script:Report.total=0;$script:Report.killed=0}
            'coverage incomplete' {$script:Coverage.FullGateSatisfied=$false}
            'command gate incomplete' {$script:Coverage.CommandGateSatisfied=$false}
            'commands missed' {$script:Coverage.Missed=1}
            'commands empty' {$script:Coverage.Analyzed=0}
            'commands inconsistent' {$script:Coverage.Executed=0}
            'lines missed' {$script:Coverage.Lines.Missed=1}
            'branches empty' {$script:Coverage.Branches.Total=0}
            'branches inconsistent' {$script:Coverage.Branches.Covered=1}
            'coverage scope missing' {$script:Coverage.SourceFingerprints=@()}
            'coverage foreign source' {$script:Coverage.SourceFingerprints[0].Path='src/Foreign.ps1'}
            'coverage duplicate source' {$script:Coverage.SourceFingerprints[1]=$script:Coverage.SourceFingerprints[0]}
            'mutation scope missing' {$script:Report.sourceHashes=@{}}
            'foreign candidate' {$script:Report.mutants[0].File='Foreign.Module/src/Public/Get-Value.ps1'}
            {$_ -in @('failed run','multiple packages','foreign package')} {
                $path=Join-Path $script:Run 'run.json'
                $plan=Get-Content $path -Raw|ConvertFrom-Json -AsHashtable
                if($Fault -eq 'failed run'){$plan.Outcome='Failed'}
                elseif($Fault -eq 'multiple packages'){$plan.Packages+=@($plan.Packages[0])}
                else{$plan.Packages[0].Name='Foreign.Module'}
                $plan|ConvertTo-Json -Depth 8|Set-Content $path
            }
            {$_ -in @('failed package','timeout mismatch','CSharp survivor','CSharp empty')} {
                $path=Join-Path $script:Run 'packages/p0/state.json'
                $state=Get-Content $path -Raw|ConvertFrom-Json -AsHashtable
                if($Fault -eq 'failed package'){$state.Outcome='Failed'}
                elseif($Fault -eq 'timeout mismatch'){$state.PSMutant.TimedOut=1}
                elseif($Fault -eq 'CSharp survivor'){$state.Stryker=@{Detected=1;Undetected=1}}
                else{$state.Stryker=@{Detected=0;Undetected=0}}
                $state|ConvertTo-Json -Depth 8|Set-Content $path
            }
        }
        $script:Coverage|ConvertTo-Json -Depth 8|Set-Content $script:CoveragePath
        $script:Report|ConvertTo-Json -Depth 8|Set-Content (Join-Path $script:Run 'packages/p0/mutation.json')
        $output=Join-Path $script:CaseRoot 'must-not-exist.json'
        {Test-MutatorPowerShellQualityGate -ModulePath $script:Fixture.Path -CoveragePath $script:CoveragePath -MutationRunPath $script:Run -OutputPath $output}|Should -Throw
        Test-Path $output|Should -BeFalse
    }
}
