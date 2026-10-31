BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    function New-BranchReport($Hits) {
        $definitions=@(@{Id=('a'*64);File='Value.ps1';Kind='If';Line=1;Column=1;Outcomes=@('true','false')})
        @{Metric='BranchOutcomes';Platform='Windows';Branches=$definitions;SourceFingerprints=@(@{Path='Value.ps1';Sha256=('b'*64)})
            Total=2;Covered=$Hits.Count;Observed=@($Hits|ForEach-Object {('a'*64)+'|'+$_});Missed=@(@('true','false')|Where-Object {$_ -notin $Hits})
            Tests=@{Passed=1;Failed=0;Skipped=0;DiscoveryErrors=0;SourceUnchanged=$true;NativeOutcome='Success'}}
    }
}
Describe 'Branch proof merge' {
    It 'preserves a switch target represented as a singleton outcome' {
        $report=New-BranchReport @('true')
        $report.Branches[0].Kind='SwitchCase';$report.Branches[0].Outcomes='hit'
        $report.Total=1;$report.Covered=1;$report.Observed=@(('a'*64)+'|hit');$report.Missed=@()
        $path=Join-Path $TestDrive 'singleton.json';$output=Join-Path $TestDrive 'singleton-merged.json'
        $report|ConvertTo-Json -Depth 8|Set-Content $path
        (Merge-MutatorBranchCoverage -Path @($path) -OutputPath $output).Percent|Should -Be 100
    }
    It 'unions exact complementary outcomes and preserves the complete definition set' {
        $a=Join-Path $TestDrive 'a.json';$b=Join-Path $TestDrive 'b.json';$output=Join-Path $TestDrive 'merged.json'
        New-BranchReport @('true')|ConvertTo-Json -Depth 8|Set-Content $a
        New-BranchReport @('false')|ConvertTo-Json -Depth 8|Set-Content $b
        $result=Merge-MutatorBranchCoverage -Path @($a,$b) -OutputPath $output
        $result.Percent|Should -Be 100
        $result.Total|Should -Be 2
        $result.BranchGateSatisfied|Should -BeTrue
        $preview=Join-Path $TestDrive 'preview.json'
        $null=Merge-MutatorBranchCoverage -Path @($a,$b) -OutputPath $preview -WhatIf
        Test-Path $preview|Should -BeFalse
    }
    It 'refuses invalid evidence: <Fault>' -ForEach @(@{Fault='hash'},@{Fault='tests'},@{Fault='unknown'},@{Fault='counter'},@{Fault='empty'}) {
        $first=New-BranchReport @('true');$second=New-BranchReport @('false')
        switch($Fault){
            hash {$second.SourceFingerprints[0].Sha256='c'*64}
            tests {$second.Tests.Failed=1}
            unknown {$second.Observed=@(('z'*64)+'|false')}
            counter {$second.Total=3}
            empty {$second.Branches=@();$second.Total=0}
        }
        $a=Join-Path $TestDrive 'first.json';$b=Join-Path $TestDrive 'second.json';$output=Join-Path $TestDrive 'absent.json'
        $first|ConvertTo-Json -Depth 8|Set-Content $a;$second|ConvertTo-Json -Depth 8|Set-Content $b
        {Merge-MutatorBranchCoverage -Path @($a,$b) -OutputPath $output}|Should -Throw
        Test-Path $output|Should -BeFalse
    }
}
