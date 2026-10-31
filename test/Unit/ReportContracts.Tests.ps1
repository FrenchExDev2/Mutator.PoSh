BeforeAll {
    $script:ReportingModuleRoot=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:ReportingModuleRoot 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    Import-Module (Join-Path (Split-Path $script:ReportingModuleRoot) 'FrenchExDev.DevPoSh.PoSh/FrenchExDev.DevPoSh.PoSh.psd1') -Force -DisableNameChecking
    function Save-ReportFixtureJson {
        param([string]$Path,[object]$Data)
        [void][IO.Directory]::CreateDirectory((Split-Path $Path))
        [IO.File]::WriteAllText($Path,($Data|ConvertTo-Json -Depth 15))
    }
}

Describe 'Importing retained mutation evidence' {
    BeforeEach {
        $script:ReceiptRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:ReceiptPath=Join-Path $script:ReceiptRoot 'receipt.json'
        $script:ImportedRuns=Join-Path $script:ReceiptRoot 'runs'
        $script:Receipt=@{Platform='linux';Runtime='7.6.7';Outcome='Success';Expected=2;Completed=2;Missing=@();Reports=@(
            @{Package='Ag';Outcome='Success';Mutation=@{Total=1;Killed=1;Survived=0;Score=100};Assembly=$null},
            @{Package='Git';Outcome='Success';Mutation=@{Total=2;Killed=2;Survived=0;Score=100};Assembly=@{Mutation=@{Total=1;Detected=1;Undetected=0;Survived=0}}}
        )}
    }
    It 'imports two complete packages as read-only evidence without executing them' {
        Save-ReportFixtureJson $script:ReceiptPath $script:Receipt
        $view=Import-MutatorRun $script:ReceiptPath -RunRoot $script:ImportedRuns -Outcome Success
        $view.Outcome|Should -BeExactly Success
        $view.Origin|Should -BeExactly Imported
        $view.CompletedPackages|Should -Be 2
        $view.EvaluatedMutants|Should -Be 4
        $view.Packages[1].Stryker.Detected|Should -Be 1
        $plan=Get-Content (Join-Path $view.Path 'run.json') -Raw|ConvertFrom-Json
        $plan.ReadOnly|Should -BeTrue
        $plan.OriginalStartKnown|Should -BeFalse
        $plan.SourceReceiptSha256|Should -BeExactly (Get-FileHash $script:ReceiptPath).Hash
        $again=Import-MutatorRun $script:ReceiptPath -RunRoot $script:ImportedRuns -Outcome Success
        $again.Id|Should -BeExactly $view.Id
        @(Get-ChildItem $script:ImportedRuns -Directory).Count|Should -Be 1
    }
    It 'keeps missing packages pending and does not invent completed mutants' {
        $script:Receipt.Reports=@($script:Receipt.Reports[0]);$script:Receipt.Missing=@('Git')
        $script:Receipt.Completed=1;$script:Receipt.Outcome='Interrupted'
        Save-ReportFixtureJson $script:ReceiptPath $script:Receipt
        $view=Import-MutatorRun $script:ReceiptPath -RunRoot $script:ImportedRuns
        $view.Outcome|Should -BeExactly Interrupted
        $view.TotalPackages|Should -Be 2
        $view.CompletedPackages|Should -Be 1
        $view.Packages[1].Outcome|Should -BeExactly Pending
        $view.Packages[1].PSMutant|Should -BeNullOrEmpty
        $view.EvaluatedMutants|Should -Be 1
    }
    It 'honors WhatIf without creating imported evidence' {
        Save-ReportFixtureJson $script:ReceiptPath $script:Receipt
        $value=Import-MutatorRun $script:ReceiptPath -RunRoot $script:ImportedRuns -WhatIf
        $value|Should -BeNullOrEmpty
        Test-Path $script:ImportedRuns|Should -BeFalse
    }
    It 'rejects incomplete success and invalid package discovery: <Fault>' -ForEach @(
        @{Fault='missing reports'},@{Fault='missing count'},@{Fault='missing platform'},
        @{Fault='wrong outcome'},@{Fault='incomplete'},@{Fault='wrong discovery'},
        @{Fault='duplicate report'},@{Fault='foreign platform'},@{Fault='blank name'},@{Fault='numeric name'}
    ) {
        switch($Fault){
            'missing reports' {$script:Receipt.Reports=@()}
            'missing count' {$script:Receipt.Expected=0}
            'missing platform' {$script:Receipt.Platform=''}
            'wrong outcome' {$script:Receipt.Outcome='Failed'}
            incomplete {$script:Receipt.Completed=1}
            'wrong discovery' {$script:Receipt.Expected=3;$script:Receipt.Completed=3}
            'duplicate report' {$script:Receipt.Reports+=@($script:Receipt.Reports[0])}
            'foreign platform' {$script:Receipt.Platform='../../../foreign'}
            'blank name' {$script:Receipt.Reports[0].Package=' '}
            'numeric name' {$script:Receipt.Reports[0].Package=42}
        }
        Save-ReportFixtureJson $script:ReceiptPath $script:Receipt
        {Import-MutatorRun $script:ReceiptPath -RunRoot $script:ImportedRuns -Outcome Success}|Should -Throw
        @(Get-ChildItem $script:ReceiptRoot -Filter run.json -Recurse -ErrorAction Ignore).Count|Should -Be 0
    }
}

Describe 'Exporting source-bound package reports' {
    BeforeEach {
        $script:ExportRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:ExportModule=New-DevPoShModule -Name Fixture.Reporting -Path (Join-Path $script:ExportRoot 'modules') -Function Get-Value
        $script:ExportRun=Join-Path $script:ExportRoot 'run'
        $script:ExportPlatform=if($IsWindows){'windows'}elseif($IsMacOS){'macos'}else{'linux'}
        $sourceHash=& (Get-Module FrenchExDev.Mutator.PoSh) {param($Path) (Get-MutatorSourceSnapshot $Path).Sha256} $script:ExportModule.Path
        $script:ExportPlan=@{Id='fixture';Outcome='Success';Platform=$script:ExportPlatform;Runtime='7.6.9';CreatedUtc='2026-10-26T00:00:00Z';Packages=@(
            @{Id='p0000';Name='FrenchExDev.Tools.Git.PoSh';ModulePath=$script:ExportModule.Path;Stryker=$false}
        )}
        $script:ExportState=@{Id='p0000';Name='FrenchExDev.Tools.Git.PoSh';Outcome='Success';Phase='Completed';Error=$null;SourceSha256=$sourceHash
            PSMutant=@{Total=1;Killed=1;Survived=0;Score=100};Stryker=$null}
    }
    It 'exports the complete package files with a hash-bound source proof' {
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'run.json') $script:ExportPlan
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'packages/p0000/state.json') $script:ExportState
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'packages/p0000/mutation.json') @{total=1;killed=1}
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'packages/p0000/stryker/reports/mutation-report.json') @{schemaVersion='1'}
        $report=Export-MutatorReport $script:ExportRun -RunId 'release-1'
        $report.Package|Should -BeExactly Git
        $report.Outcome|Should -BeExactly Success
        $report.Provenance.Unchanged|Should -BeTrue
        $report.Provenance.SourceSha256|Should -BeExactly $script:ExportState.SourceSha256
        $report.Provenance.Sha256|Should -BeExactly (Get-FileHash $report.Provenance.Path).Hash
        Test-Path (Join-Path $report.ArtifactPath 'mutation.json')|Should -BeTrue
        Test-Path (Join-Path $report.ArtifactPath 'stryker/reports/mutation-report.json')|Should -BeTrue
        $saved=Get-Content (Join-Path $report.ArtifactPath 'summary.mutation.json') -Raw|ConvertFrom-Json
        $saved.Provenance.Unchanged|Should -BeTrue
        $saved.MutatorRun|Should -BeExactly $script:ExportRun
    }
    It 'maps canonical engine and agent names explicitly: <Name>' -ForEach @(
        @{Name='FrenchExDev.Mutator.PoSh';Expected='Mutator'},
        @{Name='FrenchExDev.Tools.Utility.Agent.PoSh';Expected='Agent'}
    ) {
        $script:ExportPlan.Packages[0].Name=$Name;$script:ExportState.Name=$Name
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'run.json') $script:ExportPlan
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'packages/p0000/state.json') $script:ExportState
        (Export-MutatorReport $script:ExportRun -RunId names).Package|Should -BeExactly $Expected
    }
    It 'records changed source bytes rather than presenting them as unchanged' {
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'run.json') $script:ExportPlan
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'packages/p0000/state.json') $script:ExportState
        Add-Content (Join-Path $script:ExportModule.Path 'src/Public/Get-Value.ps1') '# changed after mutation'
        $report=Export-MutatorReport $script:ExportRun -RunId changed
        $report.Provenance.Unchanged|Should -BeFalse
        $proof=Get-Content $report.Provenance.Path -Raw|ConvertFrom-Json
        $proof.AfterSha256|Should -Not -BeExactly $proof.SourceSha256
    }
    It 'distinguishes missing, complete and failing configured C# evidence: <Kind>' -ForEach @(
        @{Kind='not configured';Configured=$false;Assembly=$null;Expected=$null},
        @{Kind='missing';Configured=$true;Assembly=$null;Expected='Failed'},
        @{Kind='complete';Configured=$true;Assembly=@{Total=1;Detected=1;Undetected=0;Survived=0};Expected='Success'},
        @{Kind='survivor';Configured=$true;Assembly=@{Total=2;Detected=1;Undetected=1;Survived=1};Expected='Failed'},
        @{Kind='empty';Configured=$true;Assembly=@{Total=0;Detected=0;Undetected=0;Survived=0};Expected='Failed'}
    ) {
        $script:ExportPlan.Packages[0].Stryker=$Configured;$script:ExportState.Stryker=$Assembly
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'run.json') $script:ExportPlan
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'packages/p0000/state.json') $script:ExportState
        $report=Export-MutatorReport $script:ExportRun -RunId assembly
        if($null -eq $Expected){$report.Assembly|Should -BeNullOrEmpty}
        else{$report.Assembly.Outcome|Should -BeExactly $Expected}
    }
    It 'refuses a run identifier that would escape its artifact directory' {
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'run.json') $script:ExportPlan
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'packages/p0000/state.json') $script:ExportState
        {Export-MutatorReport $script:ExportRun -RunId '../foreign'}|Should -Throw
    }
    It 'does not export read-only imports as new source-bound executions' {
        $script:ExportPlan.ReadOnly=$true
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'run.json') $script:ExportPlan
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'packages/p0000/state.json') $script:ExportState
        {Export-MutatorReport $script:ExportRun -RunId imported}|Should -Throw '*read-only*'
        Test-Path (Join-Path $script:ExportModule.Path 'test/Artifacts')|Should -BeFalse
    }
    It 'rejects retained metadata that redirects the export outside test/Artifacts: <Field>' -ForEach @(
        @{Field='Runtime';Value='../../../foreign'},@{Field='Platform';Value='../../foreign'}
    ) {
        $script:ExportPlan[$Field]=$Value
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'run.json') $script:ExportPlan
        Save-ReportFixtureJson (Join-Path $script:ExportRun 'packages/p0000/state.json') $script:ExportState
        {Export-MutatorReport $script:ExportRun -RunId redirected}|Should -Throw '*artifact directory*'
        Test-Path (Join-Path $script:ExportModule.Path 'foreign')|Should -BeFalse
    }
}
