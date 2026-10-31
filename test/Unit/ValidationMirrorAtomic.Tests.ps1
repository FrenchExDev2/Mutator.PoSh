<#
.SYNOPSIS
Expected behavior for the ValidationMirrorAtomic tests.

.DESCRIPTION
Mirror the same completed bytes within the exact sharing-conflict budget. Preserve previous proof
and relative package paths; unrelated errors fail immediately and clean temporary files.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Validation proof mirrors use the same bounded atomic replacement as state JSON' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            $script:MirrorSource=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:MirrorTarget=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($script:MirrorSource)
            [void][IO.Directory]::CreateDirectory($script:MirrorTarget)
            [IO.File]::WriteAllText((Join-Path $script:MirrorSource 'run.json'),'{"Value":"new","Unicode":"é"}')
            [IO.File]::WriteAllText((Join-Path $script:MirrorTarget 'run.json'),'{"Value":"old"}')
            $script:MirrorMoves=0
            Mock Start-Sleep {}
        }
        It 'publishes the completed bytes after two transient sharing conflicts' {
            Mock Move-MutatorAtomicFile {
                param($Source,$Destination)
                $script:MirrorMoves++
                if($script:MirrorMoves -le 2){throw [IO.IOException]::new('sharing denied',32)}
                [IO.File]::Move($Source,$Destination,$true)
            }
            Copy-MutatorValidationMutationProof $script:MirrorSource $script:MirrorTarget
            [IO.File]::ReadAllText((Join-Path $script:MirrorTarget 'run.json'))|Should -BeExactly '{"Value":"new","Unicode":"é"}'
            Should -Invoke Move-MutatorAtomicFile -Times 3 -Exactly
            Should -Invoke Start-Sleep -Times 2 -Exactly
            @(Get-ChildItem $script:MirrorTarget -Filter '*.tmp').Count|Should -Be 0
        }
        It 'retains the previous proof and cleans its temporary after the exact replacement budget' {
            Mock Move-MutatorAtomicFile {throw [IO.IOException]::new('sharing denied',5)}
            {Copy-MutatorValidationMutationProof $script:MirrorSource $script:MirrorTarget}|Should -Throw '*sharing denied*'
            Should -Invoke Move-MutatorAtomicFile -Times 40 -Exactly
            Should -Invoke Start-Sleep -Times 39 -Exactly
            [IO.File]::ReadAllText((Join-Path $script:MirrorTarget 'run.json'))|Should -BeExactly '{"Value":"old"}'
            @(Get-ChildItem $script:MirrorTarget -Filter '*.tmp').Count|Should -Be 0
            $stream=[IO.File]::Open((Join-Path $script:MirrorSource 'run.json'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $stream.Dispose()
        }
        It 'does not retry an unrelated failure or remove the prior destination' {
            Mock Move-MutatorAtomicFile {throw [IO.IOException]::new('unrelated failure',6000)}
            {Copy-MutatorValidationMutationProof $script:MirrorSource $script:MirrorTarget}|Should -Throw '*unrelated failure*'
            Should -Invoke Move-MutatorAtomicFile -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
            [IO.File]::ReadAllText((Join-Path $script:MirrorTarget 'run.json'))|Should -BeExactly '{"Value":"old"}'
            @(Get-ChildItem $script:MirrorTarget -Filter '*.tmp').Count|Should -Be 0
        }
        It 'preserves nested package proof paths' {
            $package=Join-Path $script:MirrorSource 'packages/p0000'
            [void][IO.Directory]::CreateDirectory($package)
            [IO.File]::WriteAllText((Join-Path $package 'mutants.jsonl'),'{"id":1}')
            Copy-MutatorValidationMutationProof $script:MirrorSource $script:MirrorTarget
            [IO.File]::ReadAllText((Join-Path $script:MirrorTarget 'packages/p0000/mutants.jsonl'))|Should -BeExactly '{"id":1}'
        }
    }
}