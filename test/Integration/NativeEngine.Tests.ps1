BeforeAll {
    $script:EngineModule=Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1'
    Import-Module $script:EngineModule -Force -DisableNameChecking
    # SDK images may launch PowerShell through a musl-compatible shim while
    # the apphost in PSHOME targets another C runtime. Use the installed launcher.
    $script:EnginePwsh=(Get-Command pwsh -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
}
Describe 'Native execution through QuietCli without simulation' {
    It 'returns the internal contract with both streams, without carriage returns' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Pwsh=$script:EnginePwsh;Root=$TestDrive} {
            param($Pwsh,$Root)
            $r=Invoke-MutatorNative $Pwsh @('-NoProfile','-Command',"[Console]::Out.Write(""first``r``nsecond``r``n"");[Console]::Error.WriteLine('diagnostic')") $Root 60
            $r.Outcome|Should -BeExactly Success
            $r.ExitCode|Should -Be 0
            $r.Failure|Should -BeNullOrEmpty
            $r.StdoutTruncated|Should -BeFalse
            $r.StderrTruncated|Should -BeFalse
            @($r.Stdout -split '\r?\n')[0..1]|Should -Be @('first','second')
            ($r.Stdout -replace [Environment]::NewLine,'')|Should -Not -Match "`r"
            $r.Stderr|Should -Match 'diagnostic'
        }
    }
    It 'reports an absent executable as a start failure, with an empty argument vector' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $r=Invoke-MutatorNative 'mutator-absent-executable' @() $Root 30
            $r.Outcome|Should -BeExactly Failed
            $r.Failure.Error.Code|Should -BeExactly NativeStartOrReadFailed
        }
    }
    It 'keeps an empty argument and a spaced argument as distinct values' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Pwsh=$script:EnginePwsh;Root=$TestDrive} {
            param($Pwsh,$Root)
            $probe=Join-Path $Root 'arguments-probe.ps1'
            [IO.File]::WriteAllText($probe,'foreach($value in $args){[Console]::Out.WriteLine("[$value]")}')
            $r=Invoke-MutatorNative $Pwsh @('-NoProfile','-File',$probe,'','a b') $Root 60
            $r.Outcome|Should -BeExactly Success
            @($r.Stdout -split '\r?\n')[0..1]|Should -Be @('[]','[a b]')
        }
    }
    It 'exposes a failed exit code with a bounded masked failure excerpt' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Pwsh=$script:EnginePwsh;Root=$TestDrive} {
            param($Pwsh,$Root)
            $r=Invoke-MutatorNative $Pwsh @('-NoProfile','-Command',"[Console]::Error.WriteLine('native failure text');exit 7") $Root 60
            $r.Outcome|Should -BeExactly Failed
            $r.ExitCode|Should -Be 7
            $r.Failure.Error.Code|Should -BeExactly NativeFailed
            $r.Failure.Excerpt.stderr -join ' '|Should -Match 'native failure text'
        }
    }
    It 'reports a timeout and kills the process tree' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Pwsh=$script:EnginePwsh;Root=$TestDrive} {
            param($Pwsh,$Root)
            $pidFile=Join-Path $Root 'timeout-child.pid'
            $inner="`$PID|Set-Content -LiteralPath '$pidFile';Start-Sleep -Seconds 120"
            $outer="`$p=Start-Process -FilePath '$Pwsh' -ArgumentList @('-NoProfile','-Command','$($inner -replace "'","''")') -PassThru -WindowStyle Hidden;`$p.WaitForExit()"
            if(!$IsWindows){$outer=$outer -replace ' -WindowStyle Hidden',''}
            $r=Invoke-MutatorNative $Pwsh @('-NoProfile','-Command',$outer) $Root 15
            $r.Outcome|Should -BeExactly Timeout
            Test-Path $pidFile|Should -BeTrue
            Start-Sleep -Seconds 1
            Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction Ignore|Should -BeNullOrEmpty
        }
    }
    It 'stops a running child when the cancellation file appears' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Pwsh=$script:EnginePwsh;Root=$TestDrive} {
            param($Pwsh,$Root)
            $signal=Join-Path $Root 'engine-stop.json'
            $r=Invoke-MutatorNative $Pwsh @('-NoProfile','-Command',"[IO.File]::WriteAllText('$signal','stop');Start-Sleep -Seconds 60") $Root 50 -StopPath $signal
            $r.Outcome|Should -BeExactly Cancelled
        }
    }
    It 'retains a line longer than the 64 KiB QuietCli default' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Pwsh=$script:EnginePwsh;Root=$TestDrive} {
            param($Pwsh,$Root)
            $r=Invoke-MutatorNative $Pwsh @('-NoProfile','-Command',"[Console]::Out.WriteLine(('x'*100000))") $Root 60
            $r.Outcome|Should -BeExactly Success
            $r.Stdout.TrimEnd().Length|Should -Be 100000
        }
    }
    It 'fails explicitly on a line above the record limit' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Pwsh=$script:EnginePwsh;Root=$TestDrive} {
            param($Pwsh,$Root)
            $r=Invoke-MutatorNative $Pwsh @('-NoProfile','-Command',"[Console]::Out.WriteLine(('x'*1100000))") $Root 60
            $r.Outcome|Should -BeExactly Failed
            $r.ExitCode|Should -Be 0
            $r.Failure.Error.Code|Should -BeExactly RecordLimit
        }
    }
    It 'marks the retained stream when it exceeds the 1 MiB buffer' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Pwsh=$script:EnginePwsh;Root=$TestDrive} {
            param($Pwsh,$Root)
            $r=Invoke-MutatorNative $Pwsh @('-NoProfile','-Command',"`$l='x'*1000;foreach(`$i in 1..1200){[Console]::Out.WriteLine(`$l)}") $Root 120
            $r.Outcome|Should -BeExactly Success
            $r.StdoutTruncated|Should -BeTrue
            $r.StderrTruncated|Should -BeFalse
        }
    }
    It 'fails explicitly on bytes that are not UTF-8' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Pwsh=$script:EnginePwsh;Root=$TestDrive} {
            param($Pwsh,$Root)
            $r=Invoke-MutatorNative $Pwsh @('-NoProfile','-Command','$o=[Console]::OpenStandardOutput();$o.Write([byte[]](0xE9,0x0A),0,2);$o.Flush()') $Root 60
            $r.Outcome|Should -BeExactly Failed
            $r.ExitCode|Should -Be 0
            $r.Failure.Error.Code|Should -BeExactly DecodeFailed
        }
    }
    It 'bounds and marks the last record when it crosses the retained buffer limit' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Pwsh=$script:EnginePwsh;Root=$TestDrive} {
            param($Pwsh,$Root)
            $r=Invoke-MutatorNative $Pwsh @('-NoProfile','-Command',"[Console]::Out.WriteLine(('x'*1000));[Console]::Out.WriteLine(('y'*1048000))") $Root 60
            $r.Outcome|Should -BeExactly Success
            $r.Stdout.Length|Should -Be 1048576
            $r.StdoutTruncated|Should -BeTrue
            $r.StderrTruncated|Should -BeFalse
        }
    }
    It 'keeps the native outcome when the progress file cannot be written' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Pwsh=$script:EnginePwsh;Root=$TestDrive} {
            param($Pwsh,$Root)
            $progress=Join-Path $Root 'locked-progress.jsonl'
            $lock=[IO.File]::Open($progress,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{
                $r=Invoke-MutatorNative $Pwsh @('-NoProfile','-Command',"'Mutation testing 1/2';'after progress'") $Root 60 $progress
            }finally{$lock.Dispose()}
            $r.Outcome|Should -BeExactly Success
            $r.Stdout|Should -Match 'after progress'
        }
    }
    It 'restores the session configuration and hands the inherited value to the child' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Pwsh=$script:EnginePwsh;Root=$TestDrive} {
            param($Pwsh,$Root)
            $saved=$env:QUIETCLI_CONFIG_PATH
            try{
                $env:QUIETCLI_CONFIG_PATH=Join-Path $Root 'session-owned.yaml'
                $r=Invoke-MutatorNative $Pwsh @('-NoProfile','-Command','[Console]::Out.WriteLine("[$env:QUIETCLI_CONFIG_PATH]")') $Root 60
                $r.Stdout|Should -Match ([regex]::Escape('['+(Join-Path $Root 'session-owned.yaml')+']'))
                $env:QUIETCLI_CONFIG_PATH|Should -BeExactly (Join-Path $Root 'session-owned.yaml')
                $env:QUIETCLI_CONFIG_PATH=$null
                $r=Invoke-MutatorNative $Pwsh @('-NoProfile','-Command','[Console]::Out.WriteLine("[$env:QUIETCLI_CONFIG_PATH]")') $Root 60
                $r.Stdout|Should -Match '\[\]'
                $env:QUIETCLI_CONFIG_PATH|Should -BeNullOrEmpty
            }finally{$env:QUIETCLI_CONFIG_PATH=$saved}
        }
    }
    It 'turns a QuietCli context failure into a thrown error and starts no process' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Pwsh=$script:EnginePwsh;Root=$TestDrive} {
            param($Pwsh,$Root)
            $sentinel=Join-Path $Root 'context-sentinel'
            Mock Invoke-MutatorQuietOperation {
                $inherited=$env:QUIETCLI_CONFIG_PATH
                $env:QUIETCLI_CONFIG_PATH=Join-Path $Root 'absent-context.yaml'
                try{& $Operation $inherited}finally{$env:QUIETCLI_CONFIG_PATH=$inherited}
            }
            {Invoke-MutatorNative $Pwsh @('-NoProfile','-Command',"[IO.File]::WriteAllText('$sentinel','x')") $Root 60}|Should -Throw '*QuietCli context failure*'
            Test-Path $sentinel|Should -BeFalse
        }
    }
    It 'names a missing engine instead of running anything' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            Mock Get-Module {}
            Mock Test-Path {$false} -ParameterFilter {$PathType -eq 'Leaf'}
            {Import-MutatorQuietCli}|Should -Throw '*QuietCli engine is missing*'
        }
    }
    It 'refuses a QuietCli already loaded from another location' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Mock Get-Module {[pscustomobject]@{ModuleBase=Join-Path ([IO.Path]::GetTempPath()) 'elsewhere'}}
            {Import-MutatorQuietCli}|Should -Throw '*another location*'
        }
    }
}
Describe 'Diagnostic masking through QuietCli delivery' {
    It 'masks an environment secret and keeps the rest of the message' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $saved=$env:MUTATOR_TEST_TOKEN
            try{
                $env:MUTATOR_TEST_TOKEN='s3cret-value-for-masking'
                $masked=Protect-MutatorDiagnostic 'failure with s3cret-value-for-masking inside'
                $masked|Should -Match 'failure with'
                $masked|Should -Not -Match 's3cret-value-for-masking'
                $masked|Should -Match 'REDACTED'
            }finally{$env:MUTATOR_TEST_TOKEN=$saved}
        }
    }
    It 'keeps ordinary, quoted and non-ASCII text intact' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $message='plain "quoted" é \ path'
            Protect-MutatorDiagnostic $message|Should -BeExactly $message
        }
    }
    It 'truncates only after masking' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $masked=Protect-MutatorDiagnostic ('y'*5000)
            $masked.Length|Should -Be 2051
            $masked|Should -Match '\.\.\.$'
        }
    }
    It 'stays closed and names the cause when masking fails' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Mock Import-MutatorQuietCli {throw [IO.FileNotFoundException]::new('secret-bearing detail')}
            $masked=Protect-MutatorDiagnostic 'raw native text'
            $masked|Should -Match 'masking unavailable: FileNotFoundException'
            $masked|Should -Not -Match 'raw native text'
            $masked|Should -Not -Match 'secret-bearing detail'
        }
    }
}
Describe 'QuietCli persistence owned by Mutator' {
    It 'writes no QuietCli state under the user profile and releases its capture files' {
        $profileRoot=Join-Path $TestDrive 'isolated-profile'
        $temporary=Join-Path $TestDrive 'isolated-temp'
        [void][IO.Directory]::CreateDirectory($profileRoot)
        [void][IO.Directory]::CreateDirectory($temporary)
        $script=Join-Path $TestDrive 'persistence-probe.ps1'
        $body=@'
param($Module,$Pwsh,$Directory)
$ErrorActionPreference='Stop'
Import-Module $Module -DisableNameChecking
& (Get-Module FrenchExDev.Mutator.PoSh) {
    param($Pwsh,$Directory)
    $ok=Invoke-MutatorNative $Pwsh @('-NoProfile','-Command','1') $Directory 60
    $failed=Invoke-MutatorNative $Pwsh @('-NoProfile','-Command',"[Console]::Error.WriteLine('x');exit 3") $Directory 60
    [void](Protect-MutatorDiagnostic 'probe message')
    "$($ok.Outcome)|$($failed.Outcome)"
} $Pwsh $Directory
'@
        [IO.File]::WriteAllText($script,$body)
        $saved=@{HOME=$env:HOME;USERPROFILE=$env:USERPROFILE;TEMP=$env:TEMP;TMP=$env:TMP;TMPDIR=$env:TMPDIR;QUIETCLI_CONFIG_PATH=$env:QUIETCLI_CONFIG_PATH}
        try{
            $env:HOME=$profileRoot;$env:USERPROFILE=$profileRoot;$env:TEMP=$temporary;$env:TMP=$temporary;$env:TMPDIR=$temporary;$env:QUIETCLI_CONFIG_PATH=$null
            $output=& $script:EnginePwsh -NoProfile -File $script $script:EngineModule $script:EnginePwsh $TestDrive
        }finally{foreach($entry in $saved.GetEnumerator()){Set-Item -LiteralPath "Env:$($entry.Key)" -Value $entry.Value}}
        @($output)[-1]|Should -BeExactly 'Success|Failed'
        @(Get-ChildItem -LiteralPath $profileRoot -Force -Filter '*quietcli*').Count|Should -Be 0
        @(Get-ChildItem -LiteralPath $temporary -Force -Filter 'quietcli-*').Count|Should -Be 0
    }
}
