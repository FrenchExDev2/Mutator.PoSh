<#
.SYNOPSIS
Expected behavior for the EditorRestartContracts tests.

.DESCRIPTION
Editor recovery must verify automatic replacements, parent ownership, one window, focus and the
exact restart command. Ambiguous UI state or absent replacement must fail without sending unrelated
keystrokes.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    & (Get-Module FrenchExDev.Mutator.PoSh) {. (Join-Path $script:MutatorRoot 'test/Fixtures/WindowsCimContracts.ps1')}
}
Describe 'Editor restart verifies identity, focus and the exact command without touching a real window' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            . (Join-Path $script:MutatorRoot 'test/Fixtures/WindowsCimContracts.ps1')
            (Get-MutatorUtcNow).Offset|Should -Be ([timespan]::Zero)
            $script:EditorFault='normal';$script:EditorTime=[datetimeoffset]'2026-10-27T00:00:00Z'
            $script:EditorPrevious=@{Id=90;ParentId=12}
            $script:EditorDllRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($script:EditorDllRoot)
            foreach($name in @('WindowsBase.dll','UIAutomationTypes.dll','UIAutomationClient.dll','System.Windows.Forms.dll')){Copy-Item (Join-Path $PSHOME 'System.Linq.dll') (Join-Path $script:EditorDllRoot $name)}
            if('Mutator.EditorFixture' -as [type]){[Mutator.EditorFixture]::Reset('normal')}
            $script:EditorAddType=Get-Command Add-Type -CommandType Cmdlet
            Mock Add-Type {
                param($TypeDefinition)
                $TypeDefinition|Should -Match 'DllImport\("user32.dll"\)'
                & $script:EditorAddType -TypeDefinition ([IO.File]::ReadAllText((Join-Path $script:MutatorRoot 'test/Fixtures/EditorAutomationFixture.cs')))
                [Mutator.EditorFixture]::Reset($script:EditorFault)
            }
            Mock Get-MutatorUtcNow {$script:EditorTime}
            Mock Start-Sleep {$script:EditorTime=$script:EditorTime.AddSeconds(9)}
            Mock Get-CimInstance {
                param($Filter)
                if($Filter -eq 'ProcessId=12'){
                    if($script:EditorFault -eq 'missing parent'){return $null}
                    return [pscustomobject]@{Name=$(if($script:EditorFault -eq 'wrong parent'){'other.exe'}else{'Code.exe'})}
                }
                $invoked=('Mutator.EditorFixture' -as [type]) -and [Mutator.EditorFixture]::Invoked -gt 0
                if($script:EditorFault -eq 'automatic' -or ($invoked -and $script:EditorFault -ne 'no replacement')){
                    @([pscustomobject]@{ProcessId=90;ParentProcessId=12;CommandLine='PowerShellEditorServices Start-EditorServices';CreationDate=[datetime]'2026-10-26'},
                      [pscustomobject]@{ProcessId=91;ParentProcessId=13;CommandLine='PowerShellEditorServices Start-EditorServices';CreationDate=[datetime]'2026-10-27'},
                      [pscustomobject]@{ProcessId=92;ParentProcessId=12;CommandLine='PowerShellEditorServices Start-EditorServices';CreationDate=[datetime]'2026-10-27'})
                }
            }
            Mock Get-Process {
                if($script:EditorFault -eq 'no window'){return @()}
                $window=[pscustomobject]@{MainWindowHandle=[intptr]101}
                if($script:EditorFault -eq 'multiple windows'){return @($window,$window)}
                $window
            }
            Mock Get-ChildItem {
                if($script:EditorFault -eq 'no desktop'){return @()}
                [pscustomobject]@{Name='10.0.0';FullName=$script:EditorDllRoot}
            } -ParameterFilter {$LiteralPath -eq $script:EditorDllRoot}
        }
        It 'accepts an automatically recovered session without focusing or invoking any command' {
            $script:EditorFault='automatic'
            $r=Restart-MutatorEditorSession $script:EditorPrevious -DesktopRuntimeRoot $script:EditorDllRoot
            $r.Mode|Should -BeExactly VSCodeAutomatic
            $r.Id|Should -Be 92
            Should -Invoke Get-Process -Times 0 -Exactly
        }
        It 'executes only the verified restart item using <Mode>' -ForEach @(@{Mode='normal'},@{Mode='fallback'}) {
            $script:EditorFault=$Mode
            if('Mutator.EditorFixture' -as [type]){[Mutator.EditorFixture]::Reset($Mode)}
            $r=Restart-MutatorEditorSession $script:EditorPrevious -DesktopRuntimeRoot $script:EditorDllRoot
            $r.Mode|Should -BeExactly VerifiedVSCodeCommand
            $r.Id|Should -Be 92
            [Mutator.EditorFixture]::Value|Should -BeExactly '>PowerShell: Restart Session'
            [Mutator.EditorFixture]::Invoked|Should -Be 1
            if($Mode -eq 'fallback'){[Mutator.EditorFixture]::Keys|Should -Contain '{ENTER}'}
            else{[Mutator.EditorFixture]::Keys|Should -Not -Contain '{ENTER}'}
        }
        It 'refuses an unverified or ambiguous editor: <Fault>' -ForEach @(
            @{Fault='missing parent'},@{Fault='wrong parent'},@{Fault='no window'},@{Fault='multiple windows'},@{Fault='no desktop'},
            @{Fault='focus'},@{Fault='no palette'},@{Fault='no command'},@{Fault='wrong type'},@{Fault='changed value'},@{Fault='lost focus'}
        ) {
            $script:EditorFault=$Fault
            if('Mutator.EditorFixture' -as [type]){[Mutator.EditorFixture]::Reset($Fault)}
            {Restart-MutatorEditorSession $script:EditorPrevious -DesktopRuntimeRoot $script:EditorDllRoot}|Should -Throw
            if('Mutator.EditorFixture' -as [type]){[Mutator.EditorFixture]::Invoked|Should -Be 0}
        }
        It 'does not claim recovery when the requested command creates no replacement process' {
            $script:EditorFault='no replacement';[Mutator.EditorFixture]::Reset('no replacement')
            {Restart-MutatorEditorSession $script:EditorPrevious -DesktopRuntimeRoot $script:EditorDllRoot}|Should -Throw '*no replacement*'
            [Mutator.EditorFixture]::Invoked|Should -Be 1
        }
    }
}
