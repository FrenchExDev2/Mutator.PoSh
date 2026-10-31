BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Stryker host adapter evidence and cancellation' {
    BeforeEach {
        $script:SdkRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:SdkArtifacts=Join-Path $script:SdkRoot 'evidence'
        [void][IO.Directory]::CreateDirectory((Join-Path $script:SdkRoot 'engine'))
        [IO.File]::WriteAllText((Join-Path $script:SdkRoot 'engine/mutator.json'),'{"Project":"Fixture.csproj","TestProject":"Fixture.Tests.csproj"}')
    }
    It 'retains host logs, progress, worker allocation and the report fingerprint' {
        Mock Invoke-MutatorNative -ModuleName FrenchExDev.Mutator.PoSh {
            param($Arguments)
            if($Arguments[0] -eq 'stryker'){
                $output=$Arguments[[array]::IndexOf($Arguments,'--output')+1]
                [void][IO.Directory]::CreateDirectory((Join-Path $output 'reports'))
                [IO.File]::WriteAllText((Join-Path $output 'reports/mutation-report.json'),'{"files":{"Source.cs":{"mutants":[{"status":"Killed"}]}}}')
            }
            @{Outcome='Success';ExitCode=0;Stdout='SDK fixture output';Stderr='SDK fixture diagnostic'}
        }
        $r=Invoke-MutatorStryker -ModulePath $script:SdkRoot -Artifacts $script:SdkArtifacts -Workers 2 -Runtime Host
        $r.Score|Should -Be 100
        $r.Runtime|Should -BeExactly Host
        $r.Workers|Should -Be 2
        $r.Detected|Should -Be 1
        $r.ReportSha256|Should -BeExactly (Get-FileHash $r.Report).Hash
        [IO.File]::ReadAllText((Join-Path $script:SdkArtifacts 'stryker.stdout.log'))|Should -BeExactly 'SDK fixture output'
        [IO.File]::ReadAllText((Join-Path $script:SdkArtifacts 'stryker.stderr.log'))|Should -BeExactly 'SDK fixture diagnostic'
        Should -Invoke Invoke-MutatorNative -ModuleName FrenchExDev.Mutator.PoSh -Times 1 -ParameterFilter {$Arguments[0] -eq 'stryker' -and $Arguments[[array]::IndexOf($Arguments,'--concurrency')+1] -eq '2'}
    }
    It 'refuses the removed container runtime before native execution' {
        Mock Invoke-MutatorNative -ModuleName FrenchExDev.Mutator.PoSh {throw 'Must not run'}
        {Invoke-MutatorStryker -ModulePath $script:SdkRoot -Artifacts $script:SdkArtifacts -Runtime Container}|Should -Throw
        Should -Invoke Invoke-MutatorNative -ModuleName FrenchExDev.Mutator.PoSh -Times 0
    }
    It 'requires explicit project settings before native execution: <Content>' -ForEach @(
        @{Content=$null},@{Content='{}'},@{Content='{"Project":"Fixture.csproj"}'},@{Content='{"Project":"","TestProject":"Tests.csproj"}'}
    ) {
        $path=Join-Path $script:SdkRoot 'engine/mutator.json'
        if($null -eq $Content){[IO.File]::Delete($path)}else{[IO.File]::WriteAllText($path,$Content)}
        Mock Invoke-MutatorNative -ModuleName FrenchExDev.Mutator.PoSh {throw 'Must not run'}
        {Invoke-MutatorStryker -ModulePath $script:SdkRoot -Artifacts $script:SdkArtifacts -Runtime Host}|Should -Throw '*Stryker requires*'
        Should -Invoke Invoke-MutatorNative -ModuleName FrenchExDev.Mutator.PoSh -Times 0
    }
    It 'passes cancellation to tool restore and mutation, without a default timeout override' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:SdkRoot;Artifacts=$script:SdkArtifacts} {
            param($Root,$Artifacts)
            $stop=Join-Path $Root 'stop.json'
            Mock Invoke-MutatorNative {
                param($Arguments)
                if($Arguments[0] -eq 'stryker'){
                    $output=$Arguments[[array]::IndexOf($Arguments,'--output')+1]
                    [void][IO.Directory]::CreateDirectory((Join-Path $output 'reports'))
                    [IO.File]::WriteAllText((Join-Path $output 'reports/mutation-report.json'),'{"files":{"Source.cs":{"mutants":[{"status":"Killed"}]}}}')
                }
                @{Outcome='Success';ExitCode=0}
            }
            $null=Invoke-MutatorStrykerCore $Root $Artifacts 2 Host -StopPath $stop
            Should -Invoke Invoke-MutatorNative -Times 2 -Exactly -ParameterFilter {$StopPath -ceq $stop}
            Should -Invoke Invoke-MutatorNative -Times 1 -Exactly -ParameterFilter {$Arguments[0] -eq 'tool' -and $TimeoutSeconds -eq 600}
        }
    }
    It 'never starts mutation after an interrupted restore' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:SdkRoot;Artifacts=$script:SdkArtifacts} {
            param($Root,$Artifacts)
            $stop=Join-Path $Root 'stop.json'
            Mock Invoke-MutatorNative {param($StopPath);[IO.File]::WriteAllText($StopPath,'{}');@{Outcome='Success';ExitCode=0}}
            {Invoke-MutatorStrykerCore $Root $Artifacts 2 Host -StopPath $stop}|Should -Throw '*interrupted*'
            Should -Invoke Invoke-MutatorNative -Times 1 -Exactly
        }
    }
    It 'refuses a report containing an excluded mutant: <Status>' -ForEach @(@{Status='Ignored'},@{Status='CompileError'},@{Status='Pending'},@{Status='Survived'}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$script:SdkRoot;Artifacts=$script:SdkArtifacts;Status=$Status} {
            param($Root,$Artifacts,$Status)
            Mock Invoke-MutatorNative {
                param($Arguments)
                if($Arguments[0] -eq 'stryker'){
                    $output=$Arguments[[array]::IndexOf($Arguments,'--output')+1]
                    [void][IO.Directory]::CreateDirectory((Join-Path $output 'reports'))
                    Write-MutatorJson (Join-Path $output 'reports/mutation-report.json') @{files=@{'Source.cs'=@{mutants=@(@{status='Killed'},@{status=$Status})}}}
                }
                @{Outcome='Success';ExitCode=0}
            }
            {Invoke-MutatorStrykerCore $Root $Artifacts 2 Host}|Should -Throw '*undetected mutants remain*'
        }
    }
}
