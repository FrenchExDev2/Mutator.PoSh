BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Mutation preview staging' {
    It 'excludes generated artifacts before the tool clones dependencies and cleans its owned stage' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $module=Join-Path $Root 'Project'
            foreach($part in @('src','test/Artifacts','.cache')){[void][IO.Directory]::CreateDirectory((Join-Path $module $part))}
            Set-Content (Join-Path $module 'src/Value.ps1') 'function Get-Value {1}'
            Set-Content (Join-Path $module 'test/Value.Tests.ps1') '# test'
            Set-Content (Join-Path $module 'test/Artifacts/large-report.json') '{}'
            Set-Content (Join-Path $module '.cache/generated.txt') 'generated'
            Write-MutatorJson (Join-Path $module 'test/psmutant.config.json') @{mutate=@('Project/src/Value.ps1');tests=@{'Project/src/Value.ps1'=@('Project/test/Value.Tests.ps1')};sandboxSubtrees=@('Project');coveredLinesOnly=$false}
            function Invoke-PSMutation {param($ConfigFile,$SourceRoot,[switch]$ListOnly,[switch]$Quiet) throw 'The tool must be mocked.'}
            Mock Import-MutatorTool {}
            Mock Invoke-PSMutation {
                param($ConfigFile,$SourceRoot)
                $script:ObservedPreviewStage=$SourceRoot
                Test-Path (Join-Path $SourceRoot 'Project/src/Value.ps1')|Should -BeTrue
                Test-Path (Join-Path $SourceRoot 'Project/test/Value.Tests.ps1')|Should -BeTrue
                Test-Path (Join-Path $SourceRoot 'Project/test/Artifacts')|Should -BeFalse
                Test-Path (Join-Path $SourceRoot 'Project/.cache')|Should -BeFalse
                Test-Path $ConfigFile|Should -BeTrue
                [pscustomobject]@{Total=2}
            }
            (Get-MutatorPreview $module).Total|Should -Be 2
            Test-Path $script:ObservedPreviewStage|Should -BeFalse
            Test-Path (Join-Path $module 'test/Artifacts/large-report.json')|Should -BeTrue
            Should -Invoke Invoke-PSMutation -Times 1 -ParameterFilter {$ListOnly -and $Quiet}
        }
    }
}
