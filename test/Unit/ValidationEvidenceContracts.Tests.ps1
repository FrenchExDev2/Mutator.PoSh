<#
.SYNOPSIS
Expected behavior for the ValidationEvidenceContracts tests.

.DESCRIPTION
Freeze each dependency once and prove live/copied identity. Regenerate only inside the copy; reports
must escape data, expose evidence links and preserve actual console/progress observations.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Validation source freeze and human-readable evidence' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            $script:EvidenceRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:EvidenceCopies=[Collections.Generic.List[object]]::new()
            $script:EvidenceHashCalls=@{}
            $script:EvidenceFault='none'
            Mock Read-MutatorJson { @{sandboxSubtrees=@('FrenchExDev.Mutator.PoSh')} }
            Mock Get-MutatorSubtree { @('FrenchExDev.Mutator.PoSh') }
            Mock Copy-MutatorTree {
                param($Source,$Destination)
                $script:EvidenceCopies.Add(@{Source=$Source;Destination=$Destination})
                [void][IO.Directory]::CreateDirectory($Destination)
            }
            Mock Get-MutatorSourceSnapshot {
                param($Root)
                if(!$script:EvidenceHashCalls.ContainsKey($Root)){$script:EvidenceHashCalls[$Root]=0}
                $script:EvidenceHashCalls[$Root]++
                $sha=if($script:EvidenceFault -eq 'live' -and $script:EvidenceHashCalls[$Root] -eq 2){'changed'}elseif($script:EvidenceFault -eq 'copy' -and $Root.StartsWith($script:EvidenceRoot)){ 'corrupt-copy' }else{'fixed'}
                @{Sha256=$sha}
            }
        }
        It 'freezes unique dependencies and persists their identities' {
            $r=New-MutatorValidationSource -ModulePath @($script:MutatorRoot,$script:MutatorRoot) -OutputDirectory $script:EvidenceRoot
            $r.Path|Should -BeExactly (Join-Path $script:EvidenceRoot 'source')
            $r.Sha256|Should -BeExactly fixed
            $script:EvidenceCopies.Count|Should -Be 3
            $proof=Get-Content (Join-Path $script:EvidenceRoot 'sources.json') -Raw|ConvertFrom-Json -AsHashtable
            @($proof).Count|Should -Be 3
            @($proof.Module|Sort-Object -Unique).Count|Should -Be 3
            @($proof|Where-Object Sha256 -NE fixed).Count|Should -Be 0
        }
        It 'regenerates Dockerfiles only in the frozen copy and records original and derived source identities' {
            Mock Update-MutatorContainerDefinition {}
            $r=New-MutatorValidationSource -ModulePath @($script:MutatorRoot) -OutputDirectory $script:EvidenceRoot -RefreshContainerDefinitions
            Should -Invoke Update-MutatorContainerDefinition -Times 1 -Exactly -ParameterFilter {$ModuleRoot -ceq (Join-Path $script:EvidenceRoot 'source') -and $OutputDirectory -ceq (Join-Path $script:EvidenceRoot 'container-definitions')}
            $proof=Get-Content (Join-Path $script:EvidenceRoot 'sources.json') -Raw|ConvertFrom-Json -AsHashtable
            @($proof.OriginalSha256)|Should -Be @('fixed','fixed','fixed')
            $r.Sha256|Should -BeExactly fixed
        }
        It 'refuses mutation configurations that cannot establish dependencies' {
            Mock Read-MutatorJson {$null}
            {New-MutatorValidationSource -ModulePath @($script:MutatorRoot) -OutputDirectory $script:EvidenceRoot}|Should -Throw '*complete mutation configuration*'
            $script:EvidenceCopies.Count|Should -Be 0
        }
        It 'refuses a changed source or an incomplete copy: <Fault>' -ForEach @(@{Fault='live'},@{Fault='copy'}) {
            $script:EvidenceFault=$Fault
            {New-MutatorValidationSource -ModulePath @($script:MutatorRoot) -OutputDirectory $script:EvidenceRoot}|Should -Throw '*Sources changed*'
            Test-Path (Join-Path $script:EvidenceRoot 'sources.json')|Should -BeFalse
        }
        It 'renders escaped reports, report links, progress columns and completed states' {
            Mock Test-MutatorTerminalInteractive {$true}
            $report=Join-Path $script:EvidenceRoot 'linux/reports/unit/space & value/tests.xml'
            [void][IO.Directory]::CreateDirectory((Split-Path $report));[IO.File]::WriteAllText($report,'<test-results/>')
            $run=@{Id='<script>unsafe</script>';Outcome='Running';Path=$script:EvidenceRoot;Platforms=@{
                Linux=@{Outcome='Running';Phase='Executing';Progress=@{Module='Fixture.Value';Suite='Mutations';CompletionPercent=25.5;EvaluatedMutants=1;PlannedMutants=4;MemoryBytes=256MB;Errors=1;Phase='PSMutant'}}
                Windows=@{Outcome='Pending';Phase='Preparing'};MacOS=@{Outcome='NotSelected'}
            }}
            $output=@(Write-MutatorValidationReport $run -UI 6>&1)|Out-String
            $output|Should -Match 'Fixture.Value'
            $output|Should -Match '1/4'
            $output|Should -Match '256'
            $output|Should -Match 'NotSelected'
            $html=[IO.File]::ReadAllText((Join-Path $script:EvidenceRoot 'index.html'))
            $html|Should -Not -Match '<script>unsafe'
            $html|Should -Match '&lt;script&gt;unsafe'
            $html|Should -Match 'space%20%26%20value/tests.xml'
            $html|Should -Match 'http-equiv="refresh"'
            $run.Outcome='Success'
            Mock Test-MutatorTerminalInteractive {$false}
            $null=Write-MutatorValidationReport $run -UI 6>&1
            [IO.File]::ReadAllText((Join-Path $script:EvidenceRoot 'index.html'))|Should -Not -Match 'http-equiv="refresh"'
        }
        It 'requires both terminal streams to be interactive: <InputRedirected>/<OutputRedirected>' -ForEach @(
            @{InputRedirected=$true;OutputRedirected=$true;Expected=$false},@{InputRedirected=$false;OutputRedirected=$true;Expected=$false},
            @{InputRedirected=$true;OutputRedirected=$false;Expected=$false},@{InputRedirected=$false;OutputRedirected=$false;Expected=$true}
        ) {
            $script:EvidenceConsole=@{InputRedirected=$InputRedirected;OutputRedirected=$OutputRedirected}
            Mock Get-MutatorConsoleState {$script:EvidenceConsole}
            Test-MutatorTerminalInteractive|Should -Be $Expected
        }
        It 'reads the actual console metadata without writing to a console' {
            $state=Get-MutatorConsoleState
            $state.InputRedirected|Should -Be ([Console]::IsInputRedirected)
            $state.OutputRedirected|Should -Be ([Console]::IsOutputRedirected)
        }
    }
}
