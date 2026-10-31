<#
.SYNOPSIS
Expected behavior for the CoverageMerge tests.

.DESCRIPTION
Union exact command spans and branch outcomes only for identical sources and valid semantic passes.
Reject drift, incompatible metadata, incomplete proof and fabricated counters.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    function New-CoverageFixture($Root,$Platform,$Hits) {
        <#
        .SYNOPSIS
        Build exact command spans and selected coverage hits for merge tests.

        .DESCRIPTION
        Uses controlled source fingerprints and test outcomes to distinguish a valid union from incompatible
        or fabricated proof.
        #>

        $rows=@(1..3|ForEach-Object {@{File=$Root+'/src/Value.ps1';Line=$_;EndLine=$_;StartColumn=1;EndColumn=5;Function='Get-Value';Class=''}})
        @{Metric='Commands';Backend='Breakpoints';Platform=$Platform;ModulePath=$Root;Runtime='7.6.7';SourcesUnchanged=$true
            Tests=@{Passed=1;Failed=0;Skipped=0;DiscoveryErrors=0};Analyzed=3;Executed=@($Hits).Count;Missed=(3-@($Hits).Count)
            SourceFingerprints=@(@{Path=$Root+'/src/Value.ps1';Sha256=('a'*64)})
            ExecutedLocations=@($rows|Where-Object {$_.Line -in $Hits});MissedLocations=@($rows|Where-Object {$_.Line -notin $Hits})}
    }
}
Describe 'Exact source coverage merge' {
    It 'joins exact command and branch proofs and refuses drift or fabricated counters' {
        $command=New-CoverageFixture 'C:/source/Dev' Windows @(1,2,3)
        $commandPath=Join-Path $TestDrive 'commands.json';$branchPath=Join-Path $TestDrive 'branches.json';$output=Join-Path $TestDrive 'full.json'
        $command|ConvertTo-Json -Depth 8|Set-Content $commandPath
        $id='c'*64
        $branch=@{Metric='BranchOutcomes';Inputs=@(@{Path='semantic-tests.json'});Total=2;Covered=2;Missed=@();Observed=@("$id|true","$id|false")
            SourceFingerprints=@(@{Path='src/Value.ps1';Sha256=('A'*64)})
            Branches=@(@{Id=$id;File='src/Value.ps1';Outcomes=@('true','false')})}
        $branch|ConvertTo-Json -Depth 8|Set-Content $branchPath
        $merged=Merge-MutatorCoverage -Path $commandPath -BranchPath $branchPath -OutputPath $output
        $merged.FullGateSatisfied|Should -BeTrue
        $merged.Lines.Covered|Should -Be 3
        $merged.Lines.Percent|Should -Be 100
        $merged.Branches.Percent|Should -Be 100
        $details=Get-Content $output -Raw|ConvertFrom-Json
        $details.CommandLocations.Count|Should -Be 3
        $details.MissingMetrics.Count|Should -Be 0
        $branch.Covered=1;$branch.Observed=@($id+'|true');$branch.Missed=@($id+'|false')
        $branch|ConvertTo-Json -Depth 8|Set-Content $branchPath
        (Merge-MutatorCoverage -Path $commandPath -BranchPath $branchPath -OutputPath $output).FullGateSatisfied|Should -BeFalse
        $branch.Covered=2
        $branch|ConvertTo-Json -Depth 8|Set-Content $branchPath
        {Merge-MutatorCoverage -Path $commandPath -BranchPath $branchPath -OutputPath $output}|Should -Throw '*counters*'
        $branch.SourceFingerprints[0].Sha256='B'*64
        $branch|ConvertTo-Json -Depth 8|Set-Content $branchPath
        {Merge-MutatorCoverage -Path $commandPath -BranchPath $branchPath -OutputPath $output}|Should -Throw '*fingerprints*'
    }
    It 'combines complementary Windows and Linux spans without conflating command and branch coverage' {
        $windows=New-CoverageFixture 'C:/source/Dev' Windows @(1,2)
        $linux=New-CoverageFixture '/workspace/Dev' Linux @(3)
        $first=Join-Path $TestDrive 'windows.json';$second=Join-Path $TestDrive 'linux.json';$output=Join-Path $TestDrive 'merged.json'
        $windows|ConvertTo-Json -Depth 8|Set-Content $first
        $linux|ConvertTo-Json -Depth 8|Set-Content $second
        $merged=Merge-MutatorCoverage -Path @($first,$second) -OutputPath $output
        $merged.Analyzed|Should -Be 3
        $merged.Missed|Should -Be 0
        $merged.Percent|Should -Be 100
        $merged.CommandGateSatisfied|Should -BeTrue
        $merged.FullGateSatisfied|Should -BeFalse
        $detail=Get-Content $output -Raw|ConvertFrom-Json
        $detail.MissingMetrics|Should -Contain BranchCoverage
        $detail.Inputs.Count|Should -Be 2
        $preview=Join-Path $TestDrive 'preview.json'
        $null=Merge-MutatorCoverage -Path @($first,$second) -OutputPath $preview -WhatIf
        Test-Path $preview|Should -BeFalse
    }
    It 'rejects incompatible or incomplete evidence: <Fault>' -ForEach @(
        @{Fault='hash'},@{Fault='collector'},@{Fault='failed tests'},@{Fault='source changed'},@{Fault='span'},@{Fault='counter'},@{Fault='duplicate'},@{Fault='empty'},@{Fault='scope'}
    ) {
        $windows=New-CoverageFixture 'C:/source/Dev' Windows @(1,2)
        $linux=New-CoverageFixture '/workspace/Dev' Linux @(3)
        switch($Fault){
            hash {$linux.SourceFingerprints[0].Sha256='b'*64}
            collector {$linux.Backend='Profiler'}
            'failed tests' {$linux.Tests.Failed=1}
            'source changed' {$linux.SourcesUnchanged=$false}
            span {$linux.ExecutedLocations[0].StartColumn=0}
            counter {$linux.Analyzed=4}
            duplicate {$linux.ExecutedLocations+=@($linux.ExecutedLocations[0]);$linux.Analyzed++}
            empty {$linux.ExecutedLocations=@();$linux.MissedLocations=@();$linux.Analyzed=0;$linux.Executed=0;$linux.Missed=0}
            scope {$linux.ExecutedLocations[0].EndColumn=6}
        }
        $first=Join-Path $TestDrive 'first.json';$second=Join-Path $TestDrive 'second.json';$output=Join-Path $TestDrive 'must-not-exist.json'
        $windows|ConvertTo-Json -Depth 8|Set-Content $first
        $linux|ConvertTo-Json -Depth 8|Set-Content $second
        {Merge-MutatorCoverage -Path @($first,$second) -OutputPath $output}|Should -Throw
        Test-Path $output|Should -BeFalse
    }
}
