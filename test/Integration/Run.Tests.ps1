BeforeAll {
    $script:ModuleRoot=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:ModuleRoot 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    Import-Module (Join-Path (Split-Path $script:ModuleRoot) 'FrenchExDev.DevPoSh.PoSh/FrenchExDev.DevPoSh.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Real isolated mutation run' {
    It 'overlaps two package processes while respecting the shared worker budget' {
        $modules=@()
        foreach($name in 'Fixture.ParallelA','Fixture.ParallelB'){
            $module=New-DevPoShModule -Name $name -Path $TestDrive -Function Get-ParallelValue -Mutation
            [IO.File]::WriteAllText((Join-Path $module.Path 'src/Public/Get-ParallelValue.ps1'),'function Get-ParallelValue { 1 }')
            $test=@'
BeforeAll { $r=Split-Path (Split-Path $PSScriptRoot); Import-Module (Join-Path $r ((Split-Path $r -Leaf)+'.psd1')) -Force }
Describe 'Parallel fixture' { It 'checks an exact value' { Start-Sleep -Milliseconds 250; Get-ParallelValue | Should -Be 1 } }
'@
            [IO.File]::WriteAllText((Join-Path $module.Path 'test/Unit/Value.Tests.ps1'),$test)
            $null=New-MutatorConfiguration -ModulePath $module.Path -Force
            $modules+=$module.Path
        }
        $run=Invoke-MutatorRun -ModulePath $modules -RunRoot (Join-Path $TestDrive 'parallel-runs') -Parallel -ThrottleLimit 2 -Workers 1 -WorkerBudget 2 -MemoryBudgetMiB 2048
        $run.Outcome | Should -BeExactly Success -Because ($run|ConvertTo-Json -Depth 5 -Compress)
        $run.CompletedPackages | Should -Be 2
        $run.Schedule.Slots | Should -Be 2
        $run.Schedule.Slots*$run.Schedule.Workers | Should -BeLessOrEqual 2
        $a=$run.Packages[0];$b=$run.Packages[1]
        ([datetime]$a.StartedUtc) | Should -BeLessThan ([datetime]$b.CompletedUtc)
        ([datetime]$b.StartedUtc) | Should -BeLessThan ([datetime]$a.CompletedUtc)
        $a.Process.Id | Should -Not -Be $b.Process.Id
    }
    It 'drives a complete small PSMutant scope and keeps per-mutant progress and a successful dashboard run' {
        $module=New-DevPoShModule -Name Fixture.Tiny -Path $TestDrive -Function Get-Sample
        [IO.File]::WriteAllText((Join-Path $module.Path 'src/Public/Get-Sample.ps1'),'function Get-Sample { param([bool]$Enabled) if ($Enabled) { 1 } else { 2 } }')
        [IO.File]::WriteAllText((Join-Path $module.Path 'test/Unit/Sample.Tests.ps1'),@'
BeforeAll { $r=Split-Path (Split-Path $PSScriptRoot); Import-Module (Join-Path $r 'Fixture.Tiny.PoSh.psd1') -Force }
Describe 'Tiny behavior' {
    It 'keeps both branches exact' { Get-Sample $true | Should -Be 1; Get-Sample $false | Should -Be 2 }
}
'@)
        $config=@{workers=1;coveredLinesOnly=$false;mutate=@('Fixture.Tiny.PoSh/src/Public/Get-Sample.ps1','Fixture.Tiny.PoSh/Fixture.Tiny.PoSh.psm1');tests=@{
            'Fixture.Tiny.PoSh/src/Public/Get-Sample.ps1'=@('Fixture.Tiny.PoSh/test/Unit/Sample.Tests.ps1');'Fixture.Tiny.PoSh/Fixture.Tiny.PoSh.psm1'=@('Fixture.Tiny.PoSh/test/Unit/Sample.Tests.ps1')}
            thresholds=@{high=100;low=100;break=100};sandboxSubtrees=@('Fixture.Tiny.PoSh');reportPath='Fixture.Tiny.PoSh/test/Artifacts/mutation.json'}
        $config|ConvertTo-Json -Depth 8|Set-Content (Join-Path $module.Path 'test/psmutant.config.json')
        $run=Invoke-MutatorRun -ModulePath $module.Path -RunRoot (Join-Path $TestDrive 'runs') -Workers 1 -WorkerBudget 1
        $proof=Join-Path $script:ModuleRoot 'test/Artifacts/development/latest-real-run.json'
        [void][IO.Directory]::CreateDirectory((Split-Path $proof))
        $run|ConvertTo-Json -Depth 12|Set-Content $proof
        $run.Outcome | Should -BeExactly Success -Because ($run|ConvertTo-Json -Depth 6 -Compress)
        $run.CompletedPackages | Should -Be 1
        $run.Packages[0].PSMutant.Score | Should -Be 100
        $run.Packages[0].PSMutant.Total | Should -BeGreaterThan 0
        $run.EvaluatedMutants | Should -Be $run.PlannedMutants
        $run.EvaluatedMutants | Should -BeGreaterThan 0
        Test-Path (Join-Path $run.Path 'packages/p0000/mutation.json.context.json') | Should -BeTrue
        Test-Path (Join-Path $run.Path 'packages/p0000/stage') | Should -BeFalse
        (Show-MutatorDashboard -RunRoot (Join-Path $TestDrive 'runs')).Runs | Should -Be 1
    }
    It 'stops cooperatively, retains a partial scope and resumes it with identical inputs' {
        $module=New-DevPoShModule -Name Fixture.Resume -Path $TestDrive -Function Get-Values
        [IO.File]::WriteAllText((Join-Path $module.Path 'src/Public/Get-Values.ps1'),'function Get-Values { @(1,2,3,4,5,6,7,8) }')
        [IO.File]::WriteAllText((Join-Path $module.Path 'test/Unit/Values.Tests.ps1'),@'
BeforeAll { $r=Split-Path (Split-Path $PSScriptRoot); Import-Module (Join-Path $r 'Fixture.Resume.PoSh.psd1') -Force }
Describe 'Exact values' { It 'keeps every value' { Start-Sleep -Milliseconds 200; @(Get-Values) | Should -Be @(1,2,3,4,5,6,7,8) } }
'@)
        $config=@{workers=1;coveredLinesOnly=$false;mutate=@('Fixture.Resume.PoSh/src/Public/Get-Values.ps1');tests=@{'Fixture.Resume.PoSh/src/Public/Get-Values.ps1'=@('Fixture.Resume.PoSh/test/Unit/Values.Tests.ps1')};thresholds=@{high=100;low=100;break=100};sandboxSubtrees=@('Fixture.Resume.PoSh');reportPath='Fixture.Resume.PoSh/test/Artifacts/mutation.json'}
        $config|ConvertTo-Json -Depth 8|Set-Content (Join-Path $module.Path 'test/psmutant.config.json')
        $run=Invoke-MutatorRun -ModulePath $module.Path -RunRoot (Join-Path $TestDrive 'resume-runs') -Workers 1 -WorkerBudget 1 -Background
        try {
            $events=Join-Path $run.Path 'packages/p0000/mutants.jsonl'
            $deadline=[datetime]::UtcNow.AddSeconds(40)
            while(!(Test-Path $events) -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
            Test-Path $events | Should -BeTrue
            $null=Stop-MutatorRun -Path $run.Path
            do {$view=Get-MutatorRun -Path $run.Path;if($view.Outcome -notin @('Running','Starting')){break};Start-Sleep -Milliseconds 100}while([datetime]::UtcNow -lt $deadline)
            $view.Outcome | Should -BeExactly Interrupted
            $partial=Get-Content (Join-Path $run.Path 'packages/p0000/mutation.json') -Raw|ConvertFrom-Json -AsHashtable
            $partial.mode | Should -BeExactly Partial
            $partial.evaluated | Should -BeGreaterThan 0
            $partial.evaluated | Should -BeLessThan $partial.planned
            $partial.Contains('mutationScore') | Should -BeFalse
            $resumed=Resume-MutatorRun -Path $run.Path -ModulePath $module.Path -RunRoot (Join-Path $TestDrive 'resume-runs')
            $resumed.Outcome | Should -BeExactly Success
            $resumed.Packages[0].PSMutant.Score | Should -Be 100
            $resumed.Packages[0].PSMutant.Total | Should -Be $partial.planned
        } finally {
            $current=Get-MutatorRun -Path $run.Path
            if($current.Outcome -in @('Running','Starting')){$null=Stop-MutatorRun -Path $run.Path -Force}
        }
    }
}
