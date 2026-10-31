BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Dependency validation preserves every repeated test association' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            $script:SubtreeRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            foreach($name in @('A','B')){[void][IO.Directory]::CreateDirectory((Join-Path $script:SubtreeRoot $name))}
        }
        It 'validates unique paths once without changing the full associations' {
            $tests=@('A/test/Unit.Tests.ps1')*500
            $configuration=@{sandboxSubtrees=@('A','B');mutate=@('A/A.ps1','B/B.ps1');tests=@{'A/A.ps1'=$tests;'B/B.ps1'=$tests}}
            $before=$configuration|ConvertTo-Json -Depth 8 -Compress
            @(Get-MutatorSubtree $script:SubtreeRoot $configuration)|Should -Be @('A','B')
            ($configuration|ConvertTo-Json -Depth 8 -Compress)|Should -BeExactly $before
            $configuration.tests['A/A.ps1'].Count|Should -Be 500
        }
        It 'rejects invalid entries even when other repeated associations are valid: <Entry>' -ForEach @(@{Entry=$null},@{Entry=''},@{Entry=42},@{Entry='../outside.ps1'}) {
            $configuration=@{sandboxSubtrees=@('A');mutate=@('A/A.ps1');tests=@{'A/A.ps1'=@('A/Unit.Tests.ps1',$Entry)}}
            {Get-MutatorSubtree $script:SubtreeRoot $configuration}|Should -Throw
        }
    }
}
Describe 'Mutation test inventory never traverses retained run artifacts' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            $script:InventoryRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            foreach($p in @('test/Unit','test/Integration','test/Artifacts/deep/copied/module/test/Unit')){[void][IO.Directory]::CreateDirectory((Join-Path $script:InventoryRoot $p))}
            foreach($p in @('test/Unit/Unit.Tests.ps1','test/Integration/Integration.Tests.ps1','test/Artifacts/deep/copied/module/test/Unit/Retained.Tests.ps1')){[IO.File]::WriteAllText((Join-Path $script:InventoryRoot $p),'# fixture')}
            $script:InventoryGetChildItem=Get-Command Get-ChildItem -CommandType Cmdlet
            Mock Get-ChildItem {
                param($LiteralPath,[switch]$File,[switch]$Directory,$Filter)
                $options=@{LiteralPath=$LiteralPath}
                if($File){$options.File=$true};if($Directory){$options.Directory=$true};if($Filter){$options.Filter=$Filter}
                & $script:InventoryGetChildItem @options
            }
            Mock Get-ChildItem {throw 'Artifact content must never be enumerated'} -ParameterFilter {$LiteralPath -match '[/\\]Artifacts(?:[/\\]|$)'}
        }
        It 'discovers every semantic test while pruning artifacts before enumeration' {
            $files=@(Get-MutatorTestFile $script:InventoryRoot)
            $files.Count|Should -Be 2
            $files.Name|Should -Contain Unit.Tests.ps1
            $files.Name|Should -Contain Integration.Tests.ps1
            Should -Invoke Get-ChildItem -Times 0 -Exactly -ParameterFilter {$LiteralPath -match '[/\\]Artifacts(?:[/\\]|$)'}
        }
        It 'refuses links instead of silently loading external test sources' {
            $target=Join-Path $script:InventoryRoot 'target';[void][IO.Directory]::CreateDirectory($target)
            $link=Join-Path $script:InventoryRoot 'test/external'
            $type=if($IsWindows){'Junction'}else{'SymbolicLink'}
            $null=New-Item -Path $link -ItemType $type -Target $target
            try{{Get-MutatorTestFile $script:InventoryRoot}|Should -Throw '*directory links*'}finally{[IO.Directory]::Delete($link,$false)}
        }
    }
}
