BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Read-only retention planning' {
    BeforeEach {
        $script:RetentionRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        & (Get-Module FrenchExDev.Mutator.PoSh) {param($Root)
            foreach($entry in @(@('old','Success','2020-01-01'),@('new','Success','2020-02-01'),@('failed','Failed','2020-01-01'),@('partial','Interrupted','2020-01-01'))){
                Write-MutatorJson (Join-Path $Root ($entry[0]+'/run.json')) @{Id=$entry[0];Outcome=$entry[1];CompletedUtc=($entry[2]+'T00:00:00Z');Packages=@();Process=$null}
            }
        } $script:RetentionRoot
    }
    It 'selects only old successful runs and leaves every file intact' {
        $before=@(Get-ChildItem $script:RetentionRoot -Recurse -File|ForEach-Object {(Get-FileHash $_.FullName).Hash})
        $plan=Get-MutatorRetentionPlan -RunRoot $script:RetentionRoot -KeepLast 1 -BeforeUtc '2021-01-01T00:00:00Z'
        $plan.ReadOnly|Should -BeTrue
        $plan.EligibleCount|Should -Be 1
        @($plan.Items|Where-Object Eligible)[0].Id|Should -BeExactly old
        @(Get-ChildItem $script:RetentionRoot -Recurse -File|ForEach-Object {(Get-FileHash $_.FullName).Hash})|Should -Be $before
    }
    It 'bounds the delivered plan without changing its exact eligible count' {
        $plan=Get-MutatorRetentionPlan -RunRoot $script:RetentionRoot -KeepLast 1 -BeforeUtc '2021-01-01T00:00:00Z' -MaxItems 1
        $plan.Items.Count|Should -Be 1
        $plan.TotalCount|Should -Be 4
        $plan.Omitted|Should -Be 3
    }
}
