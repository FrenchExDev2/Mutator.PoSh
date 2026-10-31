BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Explicit removal from a reviewed retention plan' {
    BeforeEach {
        $script:RemovalRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        & (Get-Module FrenchExDev.Mutator.PoSh) {param($Root,$Source)
            Write-MutatorJson (Join-Path $Root '20200101-000000-aaaaaaaa/run.json') @{SchemaVersion=1;Id='20200101-000000-aaaaaaaa';Outcome='Success';CompletedUtc='2020-01-01T00:00:00Z';SourceRoot=$Source;Packages=@();Process=$null}
            Write-MutatorJson (Join-Path $Root '20200201-000000-bbbbbbbb/run.json') @{SchemaVersion=1;Id='20200201-000000-bbbbbbbb';Outcome='Success';CompletedUtc='2020-02-01T00:00:00Z';SourceRoot=$Source;Packages=@();Process=$null}
        } $script:RemovalRoot $TestDrive
    }
    It 'supports WhatIf without changing the retained evidence' {
        (Remove-MutatorRun -RunRoot $script:RemovalRoot -KeepLast 1 -BeforeUtc '2021-01-01T00:00:00Z' -WhatIf).Removed|Should -Be 0
        @(Get-ChildItem $script:RemovalRoot -Directory).Count|Should -Be 2
    }
    It 'removes only the explicitly eligible old test run' {
        (Remove-MutatorRun -RunRoot $script:RemovalRoot -KeepLast 1 -BeforeUtc '2021-01-01T00:00:00Z').Removed|Should -Be 1
        Test-Path (Join-Path $script:RemovalRoot '20200101-000000-aaaaaaaa')|Should -BeFalse
        Test-Path (Join-Path $script:RemovalRoot '20200201-000000-bbbbbbbb')|Should -BeTrue
    }
    It 'refuses a candidate containing its original source tree' {
        & (Get-Module FrenchExDev.Mutator.PoSh) {param($Root)
            $path=Join-Path $Root '20200101-000000-aaaaaaaa/run.json';$run=Read-MutatorJson $path;$run.SourceRoot=Split-Path $path;Write-MutatorJson $path $run
        } $script:RemovalRoot
        {Remove-MutatorRun -RunRoot $script:RemovalRoot -KeepLast 1 -BeforeUtc '2021-01-01T00:00:00Z'}|Should -Throw '*original source tree*'
        @(Get-ChildItem $script:RemovalRoot -Directory).Count|Should -Be 2
    }
}
