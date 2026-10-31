BeforeAll {
    $script:MutatorTestRoot=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:MutatorTestRoot 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Mutation scope and resources' {
    It 'keeps the complete test association set while putting focused unit tests first' {
        $config=@{mutate=@('P/src/Parser.ps1');tests=@{'P/src/Parser.ps1'=@('P/test/Integration/Workload.Tests.ps1','P/test/Unit/Other.Tests.ps1','P/test/Unit/Parser.Tests.ps1')}}
        $before=@($config.tests['P/src/Parser.ps1'])
        $order=Set-MutatorTestOrder $config
        $config.tests['P/src/Parser.ps1'][0] | Should -BeExactly 'P/test/Unit/Parser.Tests.ps1'
        @($config.tests['P/src/Parser.ps1']|Sort-Object) | Should -Be @($before|Sort-Object)
        $order.Removed | Should -Be 0
    }
    It 'bounds package parallelism by CPU and memory reservations and rejects excess explicit workers' {
        $plan=New-MutatorSchedule -Packages @('a','b','c') -WorkerBudget 4 -ThrottleLimit 3 -MemoryBudgetMiB 2048
        $plan.Slots*$plan.Workers | Should -BeLessOrEqual 2
        $plan.ReservedMemoryMiB | Should -BeLessOrEqual 2048
        {New-MutatorSchedule -Packages a -Workers 5 -WorkerBudget 4} | Should -Throw '*exceed*'
        (New-MutatorSchedule -Packages @('a','b') -Serial).Slots | Should -Be 1
    }
    It 'stages only declared dependencies and refuses escapes and omitted test dependencies' {
        foreach($name in 'P','Dependency','Unrelated'){[void][IO.Directory]::CreateDirectory((Join-Path $TestDrive $name))}
        $config=@{sandboxSubtrees=@('P','Dependency');mutate=@('P/src/A.ps1');tests=@{'P/src/A.ps1'=@('P/test/A.Tests.ps1')}}
        @(Get-MutatorSubtree $TestDrive $config) | Should -Be @('Dependency','P')
        $config.tests['P/src/A.ps1']=@('Unrelated/A.Tests.ps1')
        {Get-MutatorSubtree $TestDrive $config} | Should -Throw '*outside*'
        $config.sandboxSubtrees=@('../outside')
        {Get-MutatorSubtree $TestDrive $config} | Should -Throw
    }
    It 'retains partial evidence and rejects a changed resume report or changed context' {
        $stage=Join-Path $TestDrive 'stage';$out=Join-Path $TestDrive 'out'
        [void][IO.Directory]::CreateDirectory($stage);[void][IO.Directory]::CreateDirectory($out)
        [IO.File]::WriteAllText((Join-Path $stage 'mutation.json'),'{"mode":"Partial","evaluated":1,"planned":2}')
        $context=@{Sha256='abc';Identity=@{Runtime='7.6.7'}}
        Save-MutatorArtifact $stage $out $context
        $path=Join-Path $out 'mutation.json'
        {Confirm-MutatorResume $path $context} | Should -Not -Throw
        {Confirm-MutatorResume $path @{Sha256='different'}} | Should -Throw '*differ*'
        [IO.File]::AppendAllText($path,' ')
        {Confirm-MutatorResume $path $context} | Should -Throw '*changed*'
    }
}
Describe 'Run dashboard and cancellation' {
    BeforeEach {
        $script:RunsRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:RunPath=Join-Path $script:RunsRoot 'test-run'
        $module=Get-Module FrenchExDev.Mutator.PoSh
        & $module {
            param($Path)
            Write-MutatorJson (Join-Path $Path 'run.json') @{Id='test-run';Outcome='Interrupted';CreatedUtc='2026-10-25T08:00:00Z';CompletedUtc='2026-10-25T09:00:00Z';Platform='windows';Runtime='7.6.7';Process=$null;Packages=@(@{Id='p0000';Name='<script>alert(1)</script>'});Error=$null}
            Write-MutatorJson (Join-Path $Path 'packages/p0000/state.json') @{Id='p0000';Name='<script>alert(1)</script>';Outcome='Success';Phase='Completed';PSMutant=@{Score=100;Total=2}}
        } $script:RunPath
    }
    It 'shows retained package evidence and escapes embedded data in an automatically refreshed dashboard' {
        $run=Get-MutatorRun -Path $script:RunPath
        $run.CompletedPackages | Should -Be 1
        $run.EvaluatedMutants | Should -Be 2
        $view=Show-MutatorDashboard -RunRoot $script:RunsRoot
        $html=[IO.File]::ReadAllText($view.Path)
        $html | Should -Not -Match '<script>alert\(1\)</script>'
        $html | Should -Match '\\u003cscript'
        $html | Should -Match 'http-equiv="refresh"'
        Test-Path (Join-Path $script:RunPath 'hourly.jsonl')|Should -BeFalse
        $null=Show-MutatorDashboard -RunRoot $script:RunsRoot
        Test-Path (Join-Path $script:RunPath 'hourly.jsonl')|Should -BeFalse
    }
    It 'records a cooperative stop without killing any other process' {
        $null=Stop-MutatorRun -Path $script:RunPath
        Test-Path (Join-Path $script:RunPath 'stop.json') | Should -BeTrue
        (Get-MutatorProgress -Path $script:RunPath).TotalPackages | Should -Be 1
    }
}
Describe 'Monitoring retained progress and interrupted supervisors' {
    BeforeEach {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $script:MonitorFixture=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $script:MonitorRun=@{Id='monitor';Outcome='Running';CreatedUtc='2026-01-01T00:00:00Z';CompletedUtc=$null;Platform=(Get-MutatorHostPlatform).ToLowerInvariant()
                HostName=[Environment]::MachineName;Runtime='7.6.0';Process=@{Pid=1234};Packages=@(@{Id='p0';Name='Fixture'});Error=$null;MemoryWatchdogPath=(Join-Path $script:MonitorFixture 'watchdog')
                ContainerEngine='Docker';ContainerSetting=@{Pipe='tcp://private-user:private-pass@fixture:2376'}}
            Write-MutatorJson (Join-Path $script:MonitorFixture 'run.json') $script:MonitorRun
            Mock Test-MutatorProcess {$true}
        }
    }
    It 'retains valid partial progress across a torn write and combines PowerShell and C# without claiming a score' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $state=Join-Path $script:MonitorFixture 'inner.json';Write-MutatorJson $state @{Phase='Preparation'}
            $ps=Join-Path $script:MonitorFixture 'ps.jsonl';$cs=Join-Path $script:MonitorFixture 'cs.jsonl'
            [IO.File]::WriteAllText($ps,"{`"Evaluated`":4,`"Planned`":12,`"Survived`":1}`n{unfinished")
            [IO.File]::WriteAllText($cs,"{`"Evaluated`":5,`"Planned`":8,`"Survived`":2}`n{unfinished")
            Write-MutatorJson (Join-Path $script:MonitorFixture 'packages/p0/state.json') @{Id='p0';Name='Fixture';Outcome='Running';Phase='Baseline';Container=@{ProgressPath=$ps;StrykerProgressPath=$cs;StatePath=$state}}
            $r=Get-MutatorRun -Path $script:MonitorFixture
            $r.Outcome|Should -BeExactly Running;$r.Packages[0].Phase|Should -BeExactly PSMutant
            $r.EvaluatedMutants|Should -Be 9;$r.PlannedMutants|Should -Be 20;$r.SurvivedMutants|Should -Be 3
            $r.Packages[0].CSharpEvaluatedMutants|Should -Be 5
            $r.Packages[0].ProgressReadError|Should -Match 'C# progress event'
            $r.ContainerEndpoint|Should -Not -Match 'private-user|private-pass'
            $r.CompletedPackages|Should -Be 0
        }
    }
    It 'retains the inner phase while a container has no completed progress event' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $state=Join-Path $script:MonitorFixture 'inner.json';Write-MutatorJson $state @{Phase='Installing'}
            Write-MutatorJson (Join-Path $script:MonitorFixture 'packages/p0/state.json') @{Id='p0';Name='Fixture';Outcome='Running';Phase='Baseline';Container=@{StatePath=$state}}
            (Get-MutatorRun -Path $script:MonitorFixture).Packages[0].Phase|Should -BeExactly Installing
        }
    }
    It 'marks a local startup failure separately from an interrupted supervisor: <Failure>' -ForEach @(@{Failure=$true},@{Failure=$false}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Failure=$Failure} {
            param($Failure)
            Mock Test-MutatorProcess {$false}
            if($Failure){Write-MutatorJson (Join-Path $script:MonitorFixture 'supervisor-failure.json') @{Error='supervisor failed'}}
            $r=Get-MutatorRun -Path $script:MonitorFixture
            $r.Outcome|Should -BeExactly $(if($Failure){'Failed'}else{'Interrupted'})
            if($Failure){$r.Error|Should -BeExactly 'supervisor failed'}
        }
    }
    It 'does not infer interruption by probing a foreign host process' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $script:MonitorRun.HostName='a-different-host'
            Write-MutatorJson (Join-Path $script:MonitorFixture 'run.json') $script:MonitorRun
            $r=Get-MutatorRun -Path $script:MonitorFixture
            $r.Outcome|Should -BeExactly Running;$r.ObserverLocal|Should -BeFalse
            Should -Invoke Test-MutatorProcess -Times 0
        }
    }
    It 'refuses an existing directory without a run receipt' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            [IO.File]::Delete((Join-Path $script:MonitorFixture 'run.json'))
            {Get-MutatorRun -Path $script:MonitorFixture}|Should -Throw '*No mutation run at*'
        }
    }
}
