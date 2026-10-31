<#
.SYNOPSIS
Expected behavior for the TerminalInteractionContracts tests.

.DESCRIPTION
Once returns structured state without console access; redirected streams refuse interactive mode. Q
detaches, stop keys signal cooperatively and all exit/error paths restore terminal state.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    if(!('Mutator.ConsoleFixture' -as [type])){Add-Type -LiteralPath (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'test/Fixtures/TerminalConsoleFixture.cs')}
}
Describe 'Terminal dashboard interaction without a real console' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            [Mutator.ConsoleFixture]::Reset()
            $script:TerminalClock=[datetimeoffset]'2026-10-27T00:00:00Z'
            $script:TerminalSamples=[Collections.Generic.Queue[string]]::new()
            $script:TerminalSamples.Enqueue('Running');$script:TerminalSamples.Enqueue('Success')
            Mock Get-MutatorConsoleApi { [Mutator.ConsoleFixture] }
            Mock Get-MutatorUtcNow {$script:TerminalClock}
            Mock Start-Sleep {$script:TerminalClock=$script:TerminalClock.AddSeconds(2)}
            Mock Get-MutatorRun { [pscustomobject]@{Outcome=$script:TerminalSamples.Dequeue()} }
            Mock Format-MutatorTerminalFrame {param($Run) 'frame '+$Run.Outcome}
            Mock Get-MutatorProgress { [pscustomobject]@{Outcome='snapshot'} }
            Mock Stop-MutatorRun { }
        }
        It 'returns a structured snapshot without requesting console access under Once' {
            (Watch-MutatorRun -Path $TestDrive -Once).Outcome|Should -BeExactly snapshot
            Should -Invoke Get-MutatorConsoleApi -Times 0 -Exactly
            [Mutator.ConsoleFixture]::Writes.Count|Should -Be 0
        }
        It 'refuses redirected terminal streams before switching terminal modes' {
            [Mutator.ConsoleFixture]::IsOutputRedirected=$true
            {Watch-MutatorRun -Path $TestDrive}|Should -Throw '*interactive terminal*'
            [Mutator.ConsoleFixture]::Writes.Count|Should -Be 0
        }
        It 'refreshes to completion and restores terminal state' {
            (Watch-MutatorRun -Path $TestDrive).Outcome|Should -BeExactly snapshot
            [Mutator.ConsoleFixture]::TreatControlCAsInput|Should -BeFalse
            [Mutator.ConsoleFixture]::Writes -join ''|Should -Match 'frame Running'
            [Mutator.ConsoleFixture]::Writes -join ''|Should -Match 'frame Success'
            [Mutator.ConsoleFixture]::Writes[-1]|Should -Match '\[\?25h'
            Should -Invoke Stop-MutatorRun -Times 0 -Exactly
        }
        It 'detaches on Q without stopping the running mutation' {
            [Mutator.ConsoleFixture]::Keys.Enqueue([ConsoleKeyInfo]::new('q',[ConsoleKey]::Q,$false,$false,$false))
            Watch-MutatorRun -Path $TestDrive|Out-Null
            Should -Invoke Get-MutatorRun -Times 1 -Exactly
            Should -Invoke Stop-MutatorRun -Times 0 -Exactly
        }
        It 'requests cooperative stop on <Key>' -ForEach @(@{Key='S'},@{Key='C'}) {
            $keyEnum=[ConsoleKey][Enum]::Parse([ConsoleKey],$Key)
            [Mutator.ConsoleFixture]::Keys.Enqueue([ConsoleKeyInfo]::new($Key[0],$keyEnum,$false,$false,($Key -eq 'C')))
            Watch-MutatorRun -Path $TestDrive|Out-Null
            Should -Invoke Stop-MutatorRun -Times 1 -Exactly -ParameterFilter {$Path -eq $TestDrive}
            [Mutator.ConsoleFixture]::TreatControlCAsInput|Should -BeFalse
        }
        It 'ignores unrelated keys and continues refreshing' {
            [Mutator.ConsoleFixture]::Keys.Enqueue([ConsoleKeyInfo]::new('a',[ConsoleKey]::A,$false,$false,$false))
            Watch-MutatorRun -Path $TestDrive|Out-Null
            Should -Invoke Stop-MutatorRun -Times 0 -Exactly
            Should -Invoke Get-MutatorRun -Times 2 -Exactly
        }
        It 'restores cursor and control mode even when reading a run fails' {
            [Mutator.ConsoleFixture]::TreatControlCAsInput=$true
            Mock Get-MutatorRun {throw 'read failed'}
            {Watch-MutatorRun -Path $TestDrive}|Should -Throw '*read failed*'
            [Mutator.ConsoleFixture]::TreatControlCAsInput|Should -BeTrue
            [Mutator.ConsoleFixture]::Writes[-1]|Should -Match '\[\?1049l'
        }
    }
}
