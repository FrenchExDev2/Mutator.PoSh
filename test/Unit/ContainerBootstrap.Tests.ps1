<#
.SYNOPSIS
Expected behavior for the ContainerBootstrap tests.

.DESCRIPTION
Entrypoint arguments and quoting must survive forwarding. Select the native dependency for the
requested RID and reject a missing target rather than using the build host's library.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:Bootstrap=Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'resources/containers/definitions/bootstrap'
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Container entrypoint and native module dependencies' {
    It 'forwards pwsh -Command and quoted arguments without binding them as entrypoint parameters' {
        $root=Join-Path $TestDrive 'image'
        $bootstrap=Join-Path $root 'bootstrap'
        [void][IO.Directory]::CreateDirectory($bootstrap)
        foreach($file in @('Enter-Image.ps1','Environment.ps1')){Copy-Item (Join-Path $script:Bootstrap $file) $bootstrap}
        $file=Join-Path $root 'forwarded.json'
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Bootstrap=$bootstrap;File=$file} {
            param($Bootstrap,$File)
            $executable=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
            $code='[IO.File]::WriteAllText('''+$File.Replace("'","''")+''', ''{"value":"spaces and --flags"}'')'
            $result=Invoke-MutatorNative $executable @('-NoProfile','-File',(Join-Path $Bootstrap 'Enter-Image.ps1'),$executable,'-NoProfile','-Command',$code) (Split-Path $Bootstrap) 30
            $result.Outcome | Should -BeExactly Success
            (Get-Content $File -Raw|ConvertFrom-Json).value | Should -BeExactly 'spaces and --flags'
        }
    }
    It 'selects the <Rid> native dependency instead of a library from the build host' -ForEach @(
        @{Rid='linux-musl-x64';Name='libe_sqlite3.so'}
        @{Rid='linux-x64';Name='libe_sqlite3.so'}
        @{Rid='win-x64';Name='e_sqlite3.dll'}
        @{Rid='osx-arm64';Name='libe_sqlite3.dylib'}
    ) {
        $root=Join-Path $TestDrive $Rid
        $directory=Join-Path $root 'modules/QuietCliEcosystem/FrenchExDev.QuietCli.PoSh/resources/runtime'
        $native=Join-Path $directory ('runtimes/'+$Rid+'/native')
        [void][IO.Directory]::CreateDirectory($native)
        [IO.File]::WriteAllText((Join-Path $directory $Name),'wrong host library')
        [IO.File]::WriteAllText((Join-Path $native $Name),$Rid)
        & (Join-Path $script:Bootstrap 'Initialize-ImageModules.ps1') -Root $root -RuntimeIdentifier $Rid
        (Get-Content (Join-Path $directory $Name) -Raw) | Should -BeExactly $Rid
        $receipt=Get-Content (Join-Path $root 'module-runtime.json') -Raw|ConvertFrom-Json
        $receipt.RuntimeIdentifier | Should -BeExactly $Rid
        $receipt.Sha256 | Should -BeExactly (Get-FileHash (Join-Path $native $Name)).Hash
    }
    It 'fails rather than reusing a host library when the selected RID is missing' {
        $root=Join-Path $TestDrive 'missing-runtime'
        {& (Join-Path $script:Bootstrap 'Initialize-ImageModules.ps1') -Root $root -RuntimeIdentifier linux-musl-arm64}|Should -Throw '*Missing SQLite dependency*'
        Test-Path (Join-Path $root 'module-runtime.json') | Should -BeFalse
    }
}
