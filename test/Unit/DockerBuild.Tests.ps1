<#
.SYNOPSIS
Expected behavior for the DockerBuild tests.

.DESCRIPTION
Bounded BuildKit uses verified local OCI bases, explicit resource limits and retained step evidence.
Reject unsupported options/unverified stages; failed builds remain failed after owned cleanup.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:DockerBuildModuleRoot=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:DockerBuildModuleRoot 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Docker builds use an owned, bounded BuildKit container' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {
            . (Join-Path $script:MutatorRoot 'test/Fixtures/DockerExportFixture.ps1')
            $script:DockerBuildFixture=New-DockerExportFixture $TestDrive
            $script:BuildDirectory=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($script:BuildDirectory)
            $script:BuildFile=Join-Path $script:BuildDirectory 'Dockerfile'
            [IO.File]::WriteAllText($script:BuildFile,"ARG BASE_IMAGE=base:fixture`nFROM `$BASE_IMAGE`nRUN true`n")
            [IO.File]::WriteAllText(($script:BuildFile+'.dockerignore'),'**/Artifacts/**')
            $script:BuildFault='None';$script:DockerNativeCalls=[Collections.Generic.List[object]]::new()
            $script:BuildProofBefore=@(if(Test-Path (Join-Path $script:MutatorRoot 'test/Artifacts/docker-builds')){Get-ChildItem (Join-Path $script:MutatorRoot 'test/Artifacts/docker-builds') -Directory|Select-Object -ExpandProperty Name})
            $script:ObservedBuildText=$null;$script:ObservedBuildArguments=@();$script:ObservedScratch=$null
            Mock Invoke-MutatorNative {
                param($Command,$Arguments)
                $script:DockerNativeCalls.Add(@{Command=$Command;Arguments=@($Arguments)})
                $argsCopy=if($Arguments[0] -eq '--context'){@($Arguments|Select-Object -Skip 2)}else{@($Arguments)}
                $step=if($argsCopy[0] -eq 'buildx'){$argsCopy[1]}elseif($argsCopy[0] -eq 'image'){$argsCopy[1]}else{$argsCopy[0]}
                $text='';$exit=0
                switch($step){
                    'version' {$text='github.com/docker/buildx v0.fixture';if($script:BuildFault -eq 'Version'){$exit=7}}
                    'inspect' {
                        if($argsCopy[0] -eq 'image'){
                            if($script:BuildFault -in @('Remote','NeverMissing','Override')){$exit=7}
                            $text=ConvertTo-Json -InputObject @(@{Id=$(if($script:BuildFault -eq 'BaseId'){'invalid'}else{$script:DockerBuildFixture.ImageId});Os=$(if($script:BuildFault -eq 'BaseOS'){'windows'}else{'linux'})}) -Compress
                        }else{
                            if($script:BuildFault -eq 'Inspect'){$exit=7}
                            $limits=@{Memory=512MB;MemorySwap=512MB;CpuPeriod=100000;CpuQuota=200000}
                            switch($script:BuildFault){'Memory' {$limits.Memory=1};'Swap' {$limits.MemorySwap=1};'Cpu' {$limits.CpuQuota=1};'Period' {$limits.CpuPeriod=1}}
                            $text=ConvertTo-Json -InputObject @(@{HostConfig=$limits;State=@{Running=($script:BuildFault -ne 'Stopped')};Image=('sha256:'+('b'*64))}) -Depth 5 -Compress
                        }
                    }
                    'save' {
                        if($script:BuildFault -eq 'Save'){$exit=7}else{Copy-Item -LiteralPath $script:DockerBuildFixture.Archive -Destination $argsCopy[3]}
                    }
                    'create' {if($script:BuildFault -eq 'Create'){$exit=7};if($script:BuildFault -eq 'CreateThrow'){throw 'native create failed'}}
                    'build' {
                        $script:ObservedBuildArguments=@($argsCopy)
                        $file=$argsCopy[$argsCopy.IndexOf('--file')+1]
                        $script:ObservedScratch=Split-Path $file
                        $script:ObservedBuildText=[IO.File]::ReadAllText($file)
                        $script:ObservedBuildIgnore=if(Test-Path ($file+'.dockerignore')){[IO.File]::ReadAllText(($file+'.dockerignore'))}else{$null}
                        if($script:BuildFault -eq 'Build'){$exit=7}
                    }
                    'rm' {if($script:BuildFault -eq 'Cleanup'){$exit=7}}
                    default {throw 'Unexpected Docker build command'}
                }
                @{Outcome=$(if($exit){'Failed'}else{'Success'});ExitCode=$exit;Stdout=$text;Stderr=$(if($exit){'retained native cause'}else{''});Failure=$null}
            }
        }
        It 'loads its result, preserves ignore rules and reuses a local image by immutable OCI digest: <Mode>' -ForEach @(
            @{Mode='LocalArg'},@{Mode='LocalFrom'},@{Mode='Scratch'},@{Mode='Remote'},@{Mode='Override'}
        ) {
            $script:BuildFault=$Mode
            $extra=@()
            switch($Mode){
                'LocalFrom' {[IO.File]::WriteAllText($script:BuildFile,"FROM base:fixture`nRUN true`n")}
                'Scratch' {[IO.File]::WriteAllText($script:BuildFile,"FROM scratch`nCOPY value /value`n");Remove-Item -LiteralPath ($script:BuildFile+'.dockerignore')}
                'Override' {$extra=@('--build-arg','BASE_IMAGE=registry.invalid/pinned:fixture')}
            }
            $arguments=@('build','--retry','0','--layers','--jobs','1','--memory','512m','--memory-swap','512m','--cpu-period','100000','--cpu-quota','200000','--pull=missing','--file',$script:BuildFile)+$extra+@('--tag','result:fixture',$script:BuildDirectory)
            if($Mode -ne 'Scratch'){$arguments=@($arguments|Select-Object -SkipLast 1)+@('--ignorefile',($script:BuildFile+'.dockerignore'),$script:BuildDirectory)}
            $r=Invoke-MutatorDockerBuild $arguments $script:BuildDirectory 91 selected
            $r.Outcome|Should -BeExactly Success
            $report=Read-MutatorJson $r.BackendProof
            $report.Engine|Should -BeExactly Docker;$report.Cleanup|Should -BeExactly Success
            $report.Limits.MemoryBytes|Should -Be 512MB;$report.Limits.CpuQuota|Should -Be 200000
            $report.BuildxVersion|Should -BeLike '*v0.fixture*'
            $script:ObservedBuildArguments|Should -Contain '--load'
            $script:ObservedBuildArguments|Should -Contain '--pull=false'
            $script:ObservedBuildArguments|Should -Not -Contain '--retry'
            $script:ObservedBuildArguments|Should -Not -Contain '--ignorefile'
            $script:ObservedBuildArguments|Should -Not -Contain '--memory'
            $script:ObservedBuildArguments|Should -Not -Contain '--layers'
            if($Mode -in @('LocalArg','LocalFrom')){
                $report.LocalBase.ImageId|Should -BeExactly $script:DockerBuildFixture.ImageId
                $script:ObservedBuildArguments|Should -Contain '--build-context'
                if($Mode -eq 'LocalArg'){$script:ObservedBuildArguments|Should -Contain 'BASE_IMAGE=mutator_base'}
                else{$script:ObservedBuildText|Should -Match '^FROM mutator_base'}
            }
            if($Mode -eq 'Override'){$script:ObservedBuildArguments|Should -Contain 'BASE_IMAGE=registry.invalid/pinned:fixture'}
            if($Mode -ne 'Scratch'){$script:ObservedBuildIgnore|Should -BeExactly '**/Artifacts/**'}
            else{$script:ObservedBuildIgnore|Should -BeNullOrEmpty}
            Test-Path $script:ObservedScratch|Should -BeFalse
            @($script:DockerNativeCalls|Where-Object {$_.Command -cne 'docker'}).Count|Should -Be 0
            @($script:DockerNativeCalls|Where-Object {$_.Arguments[0] -cne '--context' -or $_.Arguments[1] -cne 'selected'}).Count|Should -Be 0
            @($script:DockerNativeCalls|Where-Object {$_.Arguments -contains '--use'}).Count|Should -Be 0
        }
        It 'refuses an unverified preparation stage and retains its proof: <Fault>' -ForEach @(
            @{Fault='Version';Expected='*Buildx is required*';Cleanup=0},@{Fault='BaseId';Expected='*immutable Linux base*';Cleanup=0},
            @{Fault='BaseOS';Expected='*immutable Linux base*';Cleanup=0},@{Fault='Save';Expected='*could not be exported*';Cleanup=0},
            @{Fault='NeverMissing';Expected='*policy forbids a pull*';Cleanup=0},@{Fault='Create';Expected='*could not be prepared*';Cleanup=1},
            @{Fault='CreateThrow';Expected='*native create failed*';Cleanup=1},@{Fault='Inspect';Expected='*limits could not be inspected*';Cleanup=1},
            @{Fault='Memory';Expected='*did not enforce*';Cleanup=1},@{Fault='Swap';Expected='*did not enforce*';Cleanup=1},
            @{Fault='Cpu';Expected='*did not enforce*';Cleanup=1},@{Fault='Period';Expected='*did not enforce*';Cleanup=1},
            @{Fault='Stopped';Expected='*did not enforce*';Cleanup=1},@{Fault='Cleanup';Expected='*builder could not be removed*';Cleanup=1}
        ) {
            $script:BuildFault=$Fault
            {Invoke-MutatorDockerBuild @('build','--file',$script:BuildFile,'--memory','512m','--memory-swap','512m','--pull=never',$script:BuildDirectory) $script:BuildDirectory 91 $null}|Should -Throw $Expected
            @($script:DockerNativeCalls|Where-Object {$_.Arguments.Count -gt 1 -and $_.Arguments[1] -ceq 'rm'}).Count|Should -Be $Cleanup
            $proofs=@(Get-ChildItem (Join-Path $script:MutatorRoot 'test/Artifacts/docker-builds') -Directory|Where-Object {$_.Name -notin $script:BuildProofBefore})
            $proofs.Count|Should -Be 1
            $report=Read-MutatorJson (Join-Path $proofs[0].FullName 'summary.json')
            $report.Outcome|Should -BeExactly Failed
            if($Fault -ne 'Cleanup'){$report.Error|Should -BeLike $Expected}
            if($script:ObservedScratch){Test-Path $script:ObservedScratch|Should -BeFalse}
        }
        It 'returns a failed build with its exit code and logs after cleaning up the owned builder' {
            $script:BuildFault='Build'
            $r=Invoke-MutatorDockerBuild @('build','--file',$script:BuildFile,'--memory','512m','--memory-swap','512m',$script:BuildDirectory) $script:BuildDirectory 91 $null
            $r.Outcome|Should -BeExactly Failed;$r.ExitCode|Should -Be 7
            (Read-MutatorJson $r.BackendProof).Cleanup|Should -BeExactly Success
            [IO.File]::ReadAllText((Join-Path (Split-Path $r.BackendProof) 'build.stderr.log'))|Should -BeExactly 'retained native cause'
        }
    }
}
Describe 'Docker build argument and cleanup contracts' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        It 'rejects unsupported or incomplete options without invoking a container: <Fault>' -ForEach @(
            @{Fault='Retry';Options=@('--retry','1');Expected='*do not automatically retry*'},
            @{Fault='RetryValue';Options=@('--retry');Expected='*do not automatically retry*'},
            @{Fault='MemoryValue';Options=@('--memory');Expected='*missing its value*'},
            @{Fault='FileValue';Options=@('--file');Expected='*missing its value*'},
            @{Fault='MissingFile';Options=@();Expected='*explicit Dockerfile*'},
            @{Fault='Ignore';Options=@('--file','Dockerfile','--ignorefile','other.ignore');Expected='*Dockerfile-specific*'},
            @{Fault='Pull';Options=@('--file','Dockerfile','--pull=always');Expected='*pull policy*'},
            @{Fault='Memory';Options=@('--file','Dockerfile','--memory','0');Expected='*memory limits*'},
            @{Fault='Cpu';Options=@('--file','Dockerfile','--cpu-quota','0');Expected='*positive integers*'}
        ) {
            {ConvertTo-MutatorDockerBuildOption (@('build')+$Options)}|Should -Throw $Expected
        }
        It 'converts Docker memory sizes without losing the byte budget: <Value>' -ForEach @(
            @{Value='1';Bytes=1},@{Value='2k';Bytes=2KB},@{Value='3m';Bytes=3MB},@{Value='4g';Bytes=4GB}
        ) {ConvertTo-MutatorDockerMemorySize $Value|Should -Be $Bytes}
        It 'refuses unbounded or malformed memory values' {{ConvertTo-MutatorDockerMemorySize '0'}|Should -Throw '*Invalid Docker memory size*'}
        It 'refuses scratch cleanup outside its exact owned temporary directory' {
            $outside=Join-Path $TestDrive 'outside';Write-MutatorJson (Join-Path $outside 'owner.json') @{Owner=('a'*32)}
            {Remove-MutatorDockerBuildScratch $outside ('a'*32)}|Should -Throw '*unowned path*'
            Test-Path (Join-Path $outside 'owner.json')|Should -BeTrue
        }
    }
}
