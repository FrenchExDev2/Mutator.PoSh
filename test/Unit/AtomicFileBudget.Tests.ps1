<#
.SYNOPSIS
Expected behavior for the AtomicFileBudget tests.

.DESCRIPTION
Persistent file locks must exhaust a bounded budget without changing retained bytes. Released locks
permit a complete read; replacement follows the host's actual sharing semantics.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Bounded local JSON sharing recovery' {
    It 'exhausts a persistent read lock within the local retry budget and preserves the retained bytes' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $path=Join-Path $Root 'persistently-locked.json'
            Write-MutatorJson $path @{Marker='retained'}
            $before=[IO.File]::ReadAllText($path)
            $handle=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $script:ReadBudgetDelays=[Collections.Generic.List[int]]::new()
            Mock Start-Sleep {param($Milliseconds);$script:ReadBudgetDelays.Add($Milliseconds)}
            try {{Read-MutatorJson $path}|Should -Throw}
            finally {$handle.Dispose()}
            $script:ReadBudgetDelays.Count|Should -Be 39
            @($script:ReadBudgetDelays|Where-Object {$_ -ne 50}).Count|Should -Be 0
            ($script:ReadBudgetDelays|Measure-Object -Sum).Sum|Should -Be 1950
            [IO.File]::ReadAllText($path)|Should -BeExactly $before
        }
    }
    It 'returns the complete original value as soon as the exclusive reader releases its handle' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $path=Join-Path $Root 'released.json'
            Write-MutatorJson $path @{Marker='é 🧪';Count=3}
            $script:ReleaseReadHandle=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            Mock Start-Sleep {$script:ReleaseReadHandle.Dispose()}
            try {$result=Read-MutatorJson $path}finally{$script:ReleaseReadHandle.Dispose()}
            $result.Marker|Should -BeExactly 'é 🧪'
            $result.Count|Should -Be 3
            Should -Invoke Start-Sleep -Times 1 -ParameterFilter {$Milliseconds -eq 50}
        }
    }
    It 'bounds replacement conflicts on Windows and publishes atomically under Unix reader semantics' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $path=Join-Path $Root 'replacement.json'
            Write-MutatorJson $path @{Marker='original'}
            $handle=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $script:WriteBudgetDelays=[Collections.Generic.List[int]]::new()
            Mock Start-Sleep {param($Milliseconds);$script:WriteBudgetDelays.Add($Milliseconds)}
            try {
                if($IsWindows){
                    {Write-MutatorJson $path @{Marker='replacement'}}|Should -Throw '*Atomic JSON write failed*'
                    $script:WriteBudgetDelays.Count|Should -Be 39
                    @($script:WriteBudgetDelays|Where-Object {$_ -ne 50}).Count|Should -Be 0
                    ($script:WriteBudgetDelays|Measure-Object -Sum).Sum|Should -Be 1950
                }else{
                    Write-MutatorJson $path @{Marker='replacement'}
                    $script:WriteBudgetDelays.Count|Should -Be 0
                    $reader=[IO.StreamReader]::new($handle,[Text.Encoding]::UTF8,$true,1024,$true)
                    try {($reader.ReadToEnd()|ConvertFrom-Json).Marker|Should -BeExactly original}finally{$reader.Dispose()}
                }
            }finally{$handle.Dispose()}
            $expected=if($IsWindows){'original'}else{'replacement'}
            (Read-MutatorJson $path).Marker|Should -BeExactly $expected
            @(Get-ChildItem $Root -Filter 'replacement.json.*.tmp').Count|Should -Be 0
        }
    }
}
