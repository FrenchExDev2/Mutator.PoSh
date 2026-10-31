BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Atomic state retries preserve the completed payload and exact retry budget' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            $script:RetryRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($script:RetryRoot)
            $script:RetryFile=Join-Path $script:RetryRoot 'state.json'
            [IO.File]::WriteAllText($script:RetryFile,'{"Value":"previous"}')
            $script:RetryCalls=0;$script:RetrySources=[Collections.Generic.List[string]]::new()
            Mock Start-Sleep {}
        }
        It 'replaces one fully serialized temporary file after two transient sharing failures' {
            Mock Move-MutatorAtomicFile {
                param($Source,$Destination)
                $script:RetrySources.Add($Source);$script:RetryCalls++
                if($script:RetryCalls -le 2){throw [Exception]::new('wrapped',[IO.IOException]::new('sharing denied',32))}
                [IO.File]::Move($Source,$Destination,$true)
            }
            Write-MutatorJson $script:RetryFile @{Value='replacement';Unicode=[string][char]0x3BB}
            (Read-MutatorJson $script:RetryFile).Value|Should -BeExactly replacement
            (Read-MutatorJson $script:RetryFile).Unicode|Should -BeExactly ([string][char]0x3BB)
            @($script:RetrySources|Sort-Object -Unique).Count|Should -Be 1
            Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter {$Milliseconds -eq 50}
            @(Get-ChildItem $script:RetryRoot -Filter '*.tmp').Count|Should -Be 0
        }
        It 'fails after exactly 40 attempts, preserves the old state and removes its temporary file' {
            Mock Move-MutatorAtomicFile {throw [IO.IOException]::new('sharing denied',5)}
            {Write-MutatorJson $script:RetryFile @{Value='replacement'}}|Should -Throw '*Atomic JSON write failed*'
            Should -Invoke Move-MutatorAtomicFile -Times 40 -Exactly
            Should -Invoke Start-Sleep -Times 39 -Exactly -ParameterFilter {$Milliseconds -eq 50}
            [IO.File]::ReadAllText($script:RetryFile)|Should -BeExactly '{"Value":"previous"}'
            @(Get-ChildItem $script:RetryRoot -Filter '*.tmp').Count|Should -Be 0
        }
        It 'does not retry an unrelated filesystem error' {
            Mock Move-MutatorAtomicFile {throw [IO.IOException]::new('unrelated failure',6000)}
            {Write-MutatorJson $script:RetryFile @{Value='replacement'}}|Should -Throw '*unrelated failure*'
            Should -Invoke Move-MutatorAtomicFile -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
        It 'retries a transient reader lock and always closes its reader after parsing' {
            Mock Open-MutatorJsonFile {
                param($Path)
                $script:RetryCalls++
                if($script:RetryCalls -le 2){throw [Exception]::new('wrapper',[IO.IOException]::new('locked',11))}
                [IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            }
            (Read-MutatorJson $script:RetryFile).Value|Should -BeExactly previous
            Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter {$Milliseconds -eq 50}
            $exclusive=[IO.File]::Open($script:RetryFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $exclusive.Dispose()
        }
        It 'does not exceed the reader lock budget' {
            Mock Open-MutatorJsonFile {throw [IO.IOException]::new('reader locked',32)}
            {Read-MutatorJson $script:RetryFile}|Should -Throw '*reader locked*'
            Should -Invoke Open-MutatorJsonFile -Times 40 -Exactly
            Should -Invoke Start-Sleep -Times 39 -Exactly -ParameterFilter {$Milliseconds -eq 50}
        }
        It 'fails immediately on nontransient reader errors' {
            Mock Open-MutatorJsonFile {throw [IO.IOException]::new('reader invalid',6000)}
            {Read-MutatorJson $script:RetryFile}|Should -Throw '*reader invalid*'
            Should -Invoke Open-MutatorJsonFile -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
        It 'closes a real stream even when JSON parsing fails' {
            [IO.File]::WriteAllText($script:RetryFile,'{invalid')
            {Read-MutatorJson $script:RetryFile}|Should -Throw
            $exclusive=[IO.File]::Open($script:RetryFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $exclusive.Dispose()
        }
        It 'refuses directory links while staging mutation sources' {
            $source=Join-Path $script:RetryRoot 'input';$destination=Join-Path $script:RetryRoot 'copy'
            [void][IO.Directory]::CreateDirectory($source)
            $target=Join-Path $script:RetryRoot 'target';[void][IO.Directory]::CreateDirectory($target)
            $type=if($IsWindows){'Junction'}else{'SymbolicLink'}
            $link=Join-Path $source 'link'
            $null=New-Item -Path $link -ItemType $type -Target $target
            try{{Copy-MutatorTree $source $destination}|Should -Throw '*refuses links*'}
            finally{[IO.Directory]::Delete($link,$false)}
        }
    }
}
