BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Terminal run UI' {
    It 'shows completion and errors separately from successful mutant detection' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $run=[pscustomobject]@{Id='fixture';Platform='windows';Outcome='Running';ProcessedPackages=2;TotalPackages=4;CompletedPackages=1;FailedPackages=1;ErrorPercent=50;InterruptedPackages=0
                EvaluatedMutants=10;PlannedMutants=20;SurvivedMutants=1;CreatedUtc=[datetime]::UtcNow.AddSeconds(-30).ToString('O');CompletedUtc=$null;Packages=@();Path='fixture';HostMemory=@{UsedGB=32.5;LimitGB=40;TriggerGB=38;Running=$true;Outcome='Monitoring'}}
            $text=Format-MutatorTerminalFrame $run
            $text | Should -Match '50[.,]0%.*2/4'
            $text | Should -Match 'Erreurs 1.*50[.,]0%'
            $text | Should -Match 'Survivants 1'
            $text | Should -Match 'tues sont detectes avec succes'
            $text | Should -Match 'RAM poste 32[.,]5 / 40 Go.*38 Go.*Monitoring'
        }
    }
    It 'exports the terminal entry point from Mutator and keeps authoring in DevPoSh' {
        (Get-Command mutator).CommandType | Should -Be Alias
        (Get-Command mutator).Definition | Should -BeExactly Invoke-MutatorRun
        (Get-Command mutator).ModuleName | Should -BeExactly FrenchExDev.Mutator.PoSh
        @((Get-Module FrenchExDev.Mutator.PoSh).ExportedFunctions.Keys|Where-Object{$_ -like '*DevPoSh*'}).Count | Should -Be 0
    }
    It 'returns bounded actionable survivor reports for agent review' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $run=Join-Path $Root 'failed-run'
            Write-MutatorJson (Join-Path $run 'run.json') @{Id='failed-run';Outcome='Failed';CreatedUtc='2026-10-25T08:00:00Z';CompletedUtc='2026-10-25T09:00:00Z';Platform='windows';Runtime='7.6.7';Process=$null;Packages=@(@{Id='p0000';Name='Fixture'});Error=$null}
            Write-MutatorJson (Join-Path $run 'packages/p0000/state.json') @{Id='p0000';Name='Fixture';Outcome='Failed';Phase='PSMutant';Error='Survivors remain.'}
            Write-MutatorJson (Join-Path $run 'packages/p0000/mutation.json') @{mutants=@(@{Status='Survived';File='src/Parser.ps1';Line=7;Id=3;Operator='NumberLiteral';Description='0 -> 1'})}
            $first=Get-MutatorFailure -Path $run -MaxItems 1
            $first.TotalFailures | Should -Be 2
            $first.Truncated | Should -BeTrue
            $second=Get-MutatorFailure -Path $run -MaxItems 1 -Skip $first.NextSkip
            $second.Items[0].File | Should -BeExactly 'src/Parser.ps1'
            $second.Items[0].Line | Should -Be 7
            $second.Items[0].Id | Should -Be 3
        }
    }
    It 'masks credentials before returning a diagnostic to the terminal or agent' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $run=Join-Path $Root 'masked-run'
            Write-MutatorJson (Join-Path $run 'run.json') @{Id='masked';Outcome='Failed';CreatedUtc='2026-10-25T08:00:00Z';Platform='windows';Runtime='7.6.7';Process=$null;Packages=@(@{Id='p0';Name='Fixture'});Error=$null}
            Write-MutatorJson (Join-Path $run 'packages/p0/state.json') @{Id='p0';Name='Fixture';Outcome='Failed';Phase='Baseline';Error='error https://private-user:private-pass@feed.invalid token=secret-value'}
            $result=Get-MutatorFailure -Path $run
            $json=$result|ConvertTo-Json -Depth 10 -Compress
            $json | Should -Not -Match 'private-user|private-pass|secret-value'
            $json | Should -Match 'REDACTED'
            [Text.Encoding]::UTF8.GetByteCount($json) | Should -BeLessOrEqual 8192
        }
    }
}
