<#
.SYNOPSIS
Expected behavior for the ContainerRegeneration tests.

.DESCRIPTION
Generate bases before selected modules, preserve existing macOS definitions and report exact changed
paths. Reject foreign/empty selections and occupied report directories while retaining
failed-generation evidence.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:RegenerationModule=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:RegenerationModule 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
    function New-RegenerationFixture {
        <#
        .SYNOPSIS
        Prepare minimal runtime templates and contributor metadata for regeneration tests.

        .DESCRIPTION
        Keeps selected/generated files inside the test drive so idempotence, ownership and change reporting
        can be asserted without a build.
        #>

        param([string]$Root)
        $engine=Join-Path $Root 'FrenchExDev.Mutator.PoSh'
        [void][IO.Directory]::CreateDirectory((Join-Path $engine 'resources/containers/definitions'))
        foreach($file in @('runtime-versions.psd1','container-images.lock.json')){Copy-Item (Join-Path $script:RegenerationModule ('resources/containers/definitions/'+$file)) (Join-Path $engine ('resources/containers/definitions/'+$file))}
        $quiet=Join-Path $Root 'QuietCliEcosystem/FrenchExDev.QuietCli.PoSh'
        [void][IO.Directory]::CreateDirectory($quiet)
        [IO.File]::WriteAllText((Join-Path $quiet 'FrenchExDev.QuietCli.PoSh.psd1'),"@{ModuleVersion='1.0.0'}")
        foreach($key in @('Engine','Ag')){
            $name=if($key -eq 'Engine'){'FrenchExDev.Mutator.PoSh'}else{'FrenchExDev.Tools.Ag.PoSh'}
            $module=Join-Path $Root $name;[void][IO.Directory]::CreateDirectory($module)
            $commands=if($key -eq 'Ag'){"'ag'"}else{''}
            [IO.File]::WriteAllText((Join-Path $module ($name+'.psd1')),("@{ModuleVersion='1.0.0';PrivateData=@{Mutator=@{Commands=@("+$commands+")}}}"))
        }
    }
}
Describe 'Unified Dockerfile regeneration without an engine dependency' {
    BeforeEach {
        $script:RegenerationRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:RegenerationReports=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-RegenerationFixture $script:RegenerationRoot
        Mock Invoke-MutatorNative -ModuleName FrenchExDev.Mutator.PoSh {throw 'Generating Dockerfiles must not invoke a container engine.'}
    }
    It 'generates bases before modules, synchronizes existing macOS definitions and is idempotent' {
        $first=Update-MutatorContainerDefinition -ModuleRoot $script:RegenerationRoot -IncludeMacOS -OutputDirectory $script:RegenerationReports -UI
        $first.Outcome|Should -BeExactly Success;$first.Modules.Count|Should -Be 2
        $first.ChangedFiles.Count|Should -BeGreaterThan 0;$first.BuildExecuted|Should -BeFalse
        $second=Update-MutatorContainerDefinition -ModuleRoot $script:RegenerationRoot -OutputDirectory ($script:RegenerationReports+'-again')
        $second.Outcome|Should -BeExactly Success;$second.ChangedFiles.Count|Should -Be 0
        $second.Files|Should -Be $first.Files
        $metadata=Get-Content (Join-Path $script:RegenerationRoot 'FrenchExDev.Tools.Ag.PoSh/containers/image.json') -Raw|ConvertFrom-Json -AsHashtable
        $metadata.Platforms.Contains('MacOS')|Should -BeTrue
        $metadata.BaseFingerprint|Should -BeExactly $first.BaseFingerprint
        Should -Invoke Invoke-MutatorNative -ModuleName FrenchExDev.Mutator.PoSh -Times 0
    }
    It 'refreshes a selected generated file and reports its exact path without touching an unselected contributor' {
        $ag=Join-Path $script:RegenerationRoot 'FrenchExDev.Tools.Ag.PoSh'
        $first=Update-MutatorContainerDefinition -ModuleRoot $script:RegenerationRoot -ModulePath @($ag,$ag) -OutputDirectory $script:RegenerationReports
        $first.Modules|Should -Be @('FrenchExDev.Tools.Ag.PoSh')
        $file=Join-Path $ag 'containers/linux/Dockerfile';[IO.File]::WriteAllText($file,'obsolete generated content')
        $second=Update-MutatorContainerDefinition -ModuleRoot $script:RegenerationRoot -ModulePath $ag -OutputDirectory ($script:RegenerationReports+'-again')
        $second.ChangedFiles|Should -Be @('FrenchExDev.Tools.Ag.PoSh/containers/linux/Dockerfile')
        [IO.File]::ReadAllText($file)|Should -Match ':alpine-pwsh-'
        $metadata=Get-Content (Join-Path $ag 'containers/image.json') -Raw|ConvertFrom-Json -AsHashtable
        $metadata.Platforms.Contains('MacOS')|Should -BeFalse
        Test-Path (Join-Path $script:RegenerationRoot 'FrenchExDev.Mutator.PoSh/containers/image.json')|Should -BeFalse
    }
    It 'uses its standard report location when no output path is supplied' {
        $r=Update-MutatorContainerDefinition -ModuleRoot $script:RegenerationRoot
        $r.Path|Should -BeLike (Join-Path $script:RegenerationModule 'test/Artifacts/container-definitions/*')
        (Get-Content (Join-Path $r.Path 'summary.json') -Raw|ConvertFrom-Json).Outcome|Should -BeExactly Success
    }
    It 'does not write definitions or reports under WhatIf' {
        $null=Update-MutatorContainerDefinition -ModuleRoot $script:RegenerationRoot -OutputDirectory $script:RegenerationReports -WhatIf
        Test-Path $script:RegenerationReports|Should -BeFalse
        Test-Path (Join-Path $script:RegenerationRoot 'FrenchExDev.Mutator.PoSh/containers')|Should -BeFalse
    }
    It 'rejects empty discovery and an explicit empty selection' {
        $empty=Join-Path $TestDrive 'empty';[void][IO.Directory]::CreateDirectory($empty)
        {Update-MutatorContainerDefinition -ModuleRoot $empty}|Should -Throw '*discovery was empty*'
        {Update-MutatorContainerDefinition -ModuleRoot $script:RegenerationRoot -ModulePath @()}|Should -Throw '*discovery was empty*'
    }
    It 'rejects foreign or non-sibling module selections: <Kind>' -ForEach @(@{Kind='Foreign'},@{Kind='Outside'}) {
        $module=if($Kind -eq 'Foreign'){Join-Path $script:RegenerationRoot 'Foreign'}else{Join-Path $TestDrive 'FrenchExDev.Tools.Foreign.PoSh'}
        [void][IO.Directory]::CreateDirectory($module)
            {Update-MutatorContainerDefinition -ModuleRoot $script:RegenerationRoot -ModulePath $module}|Should -Throw '*only modules inside ModuleRoot*'
    }
    It 'preserves an occupied report directory and does not start generation' {
        [void][IO.Directory]::CreateDirectory($script:RegenerationReports)
        [IO.File]::WriteAllText((Join-Path $script:RegenerationReports 'keep.txt'),'keep')
        {Update-MutatorContainerDefinition -ModuleRoot $script:RegenerationRoot -OutputDirectory $script:RegenerationReports}|Should -Throw '*new or empty*'
        [IO.File]::ReadAllText((Join-Path $script:RegenerationReports 'keep.txt'))|Should -BeExactly keep
    }
    It 'retains an accurate failed report when template generation fails' {
        Mock Export-MutatorContainerBaseDefinition -ModuleName FrenchExDev.Mutator.PoSh {throw 'fixture generation failed'}
        {Update-MutatorContainerDefinition -ModuleRoot $script:RegenerationRoot -OutputDirectory $script:RegenerationReports -UI}|Should -Throw '*fixture generation failed*'
        $report=Get-Content (Join-Path $script:RegenerationReports 'summary.json') -Raw|ConvertFrom-Json -AsHashtable
        $report.Outcome|Should -BeExactly Failed;$report.Error|Should -BeExactly 'fixture generation failed'
        $report.BuildExecuted|Should -BeFalse;$report.CompletedUtc|Should -Not -BeNullOrEmpty
    }
}
