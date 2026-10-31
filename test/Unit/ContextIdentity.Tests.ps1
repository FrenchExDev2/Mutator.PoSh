BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Complete mutation context identity' {
    BeforeEach {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=(Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))} {
            param($Root)
            $script:ContextFixtureRoot=$Root
            foreach($name in @('source/A','source/B','tool-a','tool-b')){[void][IO.Directory]::CreateDirectory((Join-Path $Root $name))}
            foreach($name in @('A','B')){[IO.File]::WriteAllText((Join-Path $Root ('source/'+$name+'/Value.ps1')),'function Get-Value { 42 }')}
            foreach($name in @('tool-a','tool-b')){[IO.File]::WriteAllText((Join-Path $Root ($name+'/runner.ps1')),'fixture adapter bytes')}
            $script:ContextConfiguration=Join-Path $Root 'configuration.json'
            Write-MutatorJson $script:ContextConfiguration @{coveredLinesOnly=$false;Fixture=$true}
            $script:ContextTool=@{Version='0.6.0';Path=(Join-Path $Root 'tool-a/runner.ps1');SourceHashes=@(('a'*64));AdapterSha256=('b'*64);UnexpectedSecret='fixture-secret-must-not-leak'}
            $script:ContextArguments=@{SourceRoot=(Join-Path $Root 'source');Subtrees=@('A','B');ConfigurationPath=$script:ContextConfiguration;Tool=$script:ContextTool}
            $pester=Get-Module Pester
            $script:ContextPesterRoot=$pester.ModuleBase
            $script:ContextPesterHash='c'*64
            $script:ContextOriginalSnapshot=(Get-Command Get-MutatorSourceSnapshot).ScriptBlock
            Mock Get-MutatorSourceSnapshot {
                param($Root)
                if($Root -ceq $script:ContextPesterRoot){@{Sha256=$script:ContextPesterHash}}
                else{& $script:ContextOriginalSnapshot $Root}
            }
        }
    }
    It 'retains all dependency configuration tool and runtime fingerprints without arbitrary tool properties' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $context=New-MutatorContext @script:ContextArguments
            $identity=$context.Identity
            $identity.SchemaVersion|Should -Be 1
            $context.Sha256|Should -Match '^[A-F0-9]{64}$'
            $identity.Dependencies.Path|Should -BeExactly @('A','B')
            foreach($dependency in $identity.Dependencies){$dependency.Sha256|Should -Match '^[a-f0-9]{64}$'}
            $identity.ConfigurationSha256|Should -BeExactly (Get-FileHash $script:ContextConfiguration).Hash
            $identity.Runtime|Should -BeExactly $PSVersionTable.PSVersion.ToString()
            $identity.Framework|Should -BeExactly ([Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)
            $identity.OS|Should -BeExactly ([Runtime.InteropServices.RuntimeInformation]::OSDescription)
            $identity.Architecture|Should -BeExactly ([string][Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)
            $identity.PesterVersion|Should -BeExactly '6.2.0'
            $identity.PesterSha256|Should -BeExactly ('c'*64)
            $identity.Tool.Version|Should -BeExactly '0.6.0'
            $identity.Tool.SourceHashes|Should -BeExactly @(('a'*64))
            $identity.Tool.AdapterSha256|Should -BeExactly ('b'*64)
            $identity.Tool.FilesSha256|Should -Match '^[a-f0-9]{64}$'
            @($identity.Tool.Keys)|Should -BeExactly @('Version','SourceHashes','AdapterSha256','FilesSha256')
            $json=$identity|ConvertTo-Json -Depth 10 -Compress
            $json|Should -Not -Match 'fixture-secret-must-not-leak|tool-a|tool-b'
            $identity.Contains('ContainerImageId')|Should -BeFalse
        }
    }
    It 'is independent of an absolute cache location when the executable bytes are identical' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $first=New-MutatorContext @script:ContextArguments
            $script:ContextTool.Path=Join-Path $script:ContextFixtureRoot 'tool-b/runner.ps1'
            $second=New-MutatorContext @script:ContextArguments
            $second.Sha256|Should -BeExactly $first.Sha256
        }
    }
    It 'invalidates a context when a retained input changes: <Component>' -ForEach @(
        @{Component='source'},@{Component='configuration'},@{Component='tool bytes'},@{Component='raw source hashes'},@{Component='adapter'},@{Component='version'},@{Component='Pester bytes'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Component=$Component} {
            param($Component)
            $before=New-MutatorContext @script:ContextArguments
            switch($Component){
                source {[IO.File]::AppendAllText((Join-Path $script:ContextFixtureRoot 'source/B/Value.ps1'),'# changed source')}
                configuration {Write-MutatorJson $script:ContextConfiguration @{coveredLinesOnly=$false;Fixture='changed'}}
                'tool bytes' {[IO.File]::AppendAllText($script:ContextTool.Path,'changed adapter bytes')}
                'raw source hashes' {$script:ContextTool.SourceHashes=@(('d'*64))}
                adapter {$script:ContextTool.AdapterSha256='e'*64}
                version {$script:ContextTool.Version='0.6.1'}
                'Pester bytes' {$script:ContextPesterHash='f'*64}
            }
            (New-MutatorContext @script:ContextArguments).Sha256|Should -Not -BeExactly $before.Sha256
        }
    }
    It 'pins the immutable container identity without confusing it with a host-only context' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $hostContext=New-MutatorContext @script:ContextArguments
            $first=New-MutatorContext @script:ContextArguments -ContainerImageId ('1'*64)
            $second=New-MutatorContext @script:ContextArguments -ContainerImageId ('2'*64)
            $first.Identity.ContainerImageId|Should -BeExactly ('1'*64)
            $first.Sha256|Should -Not -BeExactly $hostContext.Sha256
            $second.Sha256|Should -Not -BeExactly $first.Sha256
        }
    }
    It 'ignores generated artifacts and timestamps while retaining executable input bytes' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $before=New-MutatorContext @script:ContextArguments
            [IO.File]::SetLastWriteTimeUtc((Join-Path $script:ContextFixtureRoot 'source/A/Value.ps1'),[datetime]'2020-01-01T00:00:00Z')
            foreach($name in @('Artifacts','.cache')){
                $directory=Join-Path $script:ContextFixtureRoot ('source/A/'+$name)
                [void][IO.Directory]::CreateDirectory($directory)
                [IO.File]::WriteAllText((Join-Path $directory 'generated-output.txt'),'temporary generated bytes')
            }
            (New-MutatorContext @script:ContextArguments).Sha256|Should -BeExactly $before.Sha256
        }
    }
    It 'refuses a missing Pester runtime with an actionable error instead of capturing an incomplete identity' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Mock Get-Module {} -ParameterFilter {$Name -eq 'Pester'}
            {New-MutatorContext @script:ContextArguments}|Should -Throw '*Pester must be imported*'
        }
    }
}
