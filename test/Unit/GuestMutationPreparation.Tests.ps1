BeforeAll {
    $script:MutationPreparationScript=Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'resources/containers/jobs/Invoke-GuestMutation.ps1'
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Preparing a Windows mutation job before invoking its package' {
    BeforeEach {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=(Join-Path $TestDrive ([guid]::NewGuid().ToString('N')));Script=$script:MutationPreparationScript} {
            param($Root,$Script)
            $script:GuestPreparationRoot=Join-Path $Root 'guest'
            $script:GuestPreparationJobs=Join-Path $Root 'jobs'
            $script:GuestPreparationId=[guid]::NewGuid().ToString('N')
            $script:GuestPreparationDirectory=Join-Path $script:GuestPreparationJobs $script:GuestPreparationId
            $script:GuestPreparationScript=$Script
            $script:GuestPreparationInput=Join-Path $script:GuestPreparationDirectory 'source'
            $module=Join-Path $script:GuestPreparationInput 'Fixture.Module'
            [void][IO.Directory]::CreateDirectory((Join-Path $module 'test'))
            [IO.File]::WriteAllText((Join-Path $module 'Value.ps1'),'function Get-Value { 42 }')
            [IO.File]::WriteAllText((Join-Path $module 'test/Value.Tests.ps1'),'Describe value { It exact { Get-Value | Should -Be 42 } }')
            $script:GuestPreparationConfiguration=@{coveredLinesOnly=$false;sandboxSubtrees=@('Fixture.Module');mutate=@('Fixture.Module/Value.ps1');tests=@{'Fixture.Module/Value.ps1'=@('Fixture.Module/test/Value.Tests.ps1')}}
            Write-MutatorJson (Join-Path $module 'test/psmutant.config.json') $script:GuestPreparationConfiguration
            $script:GuestPreparationDescriptor=@{SourceSha256=(Get-MutatorSourceSnapshot $script:GuestPreparationInput).Sha256
                Module='Fixture.Module';Configuration='Fixture.Module/test/psmutant.config.json';Name='Fixture.Module';Stryker=$true;TestOrder='FocusedFirst';ImageId=('a'*64)}
            Mock Import-Module {}
            Mock Invoke-MutatorPackage {
                param($RunDirectory,$Package)
                $Package|Should -BeExactly p0000
                Test-Path (Join-Path $RunDirectory 'run.json')|Should -BeTrue
            }
        }
    }
    It 'binds the staged source, runtime, stop path and full configuration to one package: <Stryker>' -ForEach @(@{Stryker=$false},@{Stryker=$true}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Stryker=$Stryker} {
            param($Stryker)
            $script:GuestPreparationDescriptor.Stryker=$Stryker
            Write-MutatorJson (Join-Path $script:GuestPreparationDirectory 'mutation.json') $script:GuestPreparationDescriptor
            & $script:GuestPreparationScript -JobDirectory $script:GuestPreparationDirectory -Root $script:GuestPreparationRoot -JobsDirectory $script:GuestPreparationJobs
            $local=Join-Path $script:GuestPreparationRoot ('mutation-jobs/'+$script:GuestPreparationId)
            $plan=Read-MutatorJson (Join-Path $local 'run/run.json')
            $plan.SourceRoot|Should -BeExactly (Join-Path $local 'source')
            $plan.StopPath|Should -BeExactly (Join-Path $local 'stop.json')
            $plan.ToolCacheRoot|Should -BeExactly (Join-Path $script:GuestPreparationRoot 'mutation-tools')
            $plan.Schedule.Workers|Should -Be 1
            $plan.TestOrder|Should -BeExactly FocusedFirst
            $plan.StrykerRuntime|Should -BeExactly Host
            $plan.ContainerImageId|Should -BeExactly ('a'*64)
            $plan.Packages.Count|Should -Be 1
            $entry=$plan.Packages[0]
            $entry.ModulePath|Should -BeExactly (Join-Path $plan.SourceRoot 'Fixture.Module')
            $entry.Configuration|Should -BeExactly (Join-Path $plan.SourceRoot 'Fixture.Module/test/psmutant.config.json')
            $entry.Stryker|Should -Be $Stryker
            $entry.ResumeFrom|Should -BeNullOrEmpty
            $entry.ContainerRecipe|Should -BeNullOrEmpty
            (Get-MutatorSourceSnapshot $plan.SourceRoot).Sha256|Should -BeExactly $script:GuestPreparationDescriptor.SourceSha256
            Should -Invoke Invoke-MutatorPackage -Times 1
            Should -Invoke Import-Module -Times 1 -ParameterFilter {$Name -eq (Join-Path $script:GuestPreparationRoot 'modules/FrenchExDev.Mutator.PoSh/FrenchExDev.Mutator.PoSh.psd1')}
        }
    }
    It 'refuses an existing local sandbox, a changed source or a malformed job directory: <Fault>' -ForEach @(@{Fault='existing'},@{Fault='fingerprint'},@{Fault='directory'},@{Fault='identifier'}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Fault=$Fault} {
            param($Fault)
            $directory=$script:GuestPreparationDirectory
            switch($Fault){
                existing {[void][IO.Directory]::CreateDirectory((Join-Path $script:GuestPreparationRoot ('mutation-jobs/'+$script:GuestPreparationId)))}
                fingerprint {$script:GuestPreparationDescriptor.SourceSha256='0'*64}
                directory {$script:GuestPreparationJobs=Split-Path $script:GuestPreparationJobs}
                identifier {$directory=Join-Path $script:GuestPreparationJobs 'foreign-job'}
            }
            Write-MutatorJson (Join-Path $script:GuestPreparationDirectory 'mutation.json') $script:GuestPreparationDescriptor
            {& $script:GuestPreparationScript -JobDirectory $directory -Root $script:GuestPreparationRoot -JobsDirectory $script:GuestPreparationJobs}|Should -Throw
            Should -Invoke Invoke-MutatorPackage -Times 0
        }
    }
    It 'rejects a descriptor path outside the staged source: <Field>/<Value>' -ForEach @(
        @{Field='Module';Value='../outside'},@{Field='Configuration';Value='../outside.json'},
        @{Field='Module';Value='.'},@{Field='Configuration';Value=''},@{Field='Module';Value='absolute'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Field=$Field;Value=$Value} {
            param($Field,$Value)
            $script:GuestPreparationDescriptor[$Field]=if($Value -eq 'absolute'){$script:GuestPreparationRoot}else{$Value}
            Write-MutatorJson (Join-Path $script:GuestPreparationDirectory 'mutation.json') $script:GuestPreparationDescriptor
            {& $script:GuestPreparationScript -JobDirectory $script:GuestPreparationDirectory -Root $script:GuestPreparationRoot -JobsDirectory $script:GuestPreparationJobs}|Should -Throw
            Should -Invoke Invoke-MutatorPackage -Times 0
        }
    }
    It 'requires explicit complete discovery and an explicit Boolean Stryker selection: <Fault>' -ForEach @(
        @{Fault='covered only'},@{Fault='missing discovery'},@{Fault='missing subtree'},@{Fault='missing Stryker'},@{Fault='string Stryker'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Fault=$Fault} {
            param($Fault)
            switch($Fault){
                'covered only' {$script:GuestPreparationConfiguration.coveredLinesOnly=$true}
                'missing discovery' {$script:GuestPreparationConfiguration.Remove('coveredLinesOnly')}
                'missing subtree' {$script:GuestPreparationConfiguration.sandboxSubtrees=@('Absent')}
                'missing Stryker' {$script:GuestPreparationDescriptor.Remove('Stryker')}
                'string Stryker' {$script:GuestPreparationDescriptor.Stryker='true'}
            }
            Write-MutatorJson (Join-Path $script:GuestPreparationInput 'Fixture.Module/test/psmutant.config.json') $script:GuestPreparationConfiguration
            $script:GuestPreparationDescriptor.SourceSha256=(Get-MutatorSourceSnapshot $script:GuestPreparationInput).Sha256
            Write-MutatorJson (Join-Path $script:GuestPreparationDirectory 'mutation.json') $script:GuestPreparationDescriptor
            {& $script:GuestPreparationScript -JobDirectory $script:GuestPreparationDirectory -Root $script:GuestPreparationRoot -JobsDirectory $script:GuestPreparationJobs}|Should -Throw
            Should -Invoke Invoke-MutatorPackage -Times 0
        }
    }
    It 'uses the target filesystem case rules when validating source containment' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $script:GuestPreparationDescriptor.Module='../SOURCE/Fixture.Module'
            Write-MutatorJson (Join-Path $script:GuestPreparationDirectory 'mutation.json') $script:GuestPreparationDescriptor
            if($IsWindows){
                & $script:GuestPreparationScript -JobDirectory $script:GuestPreparationDirectory -Root $script:GuestPreparationRoot -JobsDirectory $script:GuestPreparationJobs
                Should -Invoke Invoke-MutatorPackage -Times 1
            }else{
                {& $script:GuestPreparationScript -JobDirectory $script:GuestPreparationDirectory -Root $script:GuestPreparationRoot -JobsDirectory $script:GuestPreparationJobs}|Should -Throw '*escapes its source root*'
                Should -Invoke Invoke-MutatorPackage -Times 0
            }
        }
    }
    It 'copies a verified resume report and its context before invoking the package: <Fault>' -ForEach @(@{Fault='none'},@{Fault='report'},@{Fault='context'}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Fault=$Fault} {
            param($Fault)
            $report=Join-Path $script:GuestPreparationDirectory 'resume/mutation.json'
            Write-MutatorJson $report @{FixtureReport=$true}
            Write-MutatorJson ($report+'.context.json') @{FixtureContext=$true}
            $script:GuestPreparationDescriptor.ResumeReportSha256=(Get-FileHash $report).Hash
            $script:GuestPreparationDescriptor.ResumeContextSha256=(Get-FileHash ($report+'.context.json')).Hash
            if($Fault -eq 'report'){$script:GuestPreparationDescriptor.ResumeReportSha256='0'*64}
            if($Fault -eq 'context'){$script:GuestPreparationDescriptor.ResumeContextSha256='0'*64}
            Write-MutatorJson (Join-Path $script:GuestPreparationDirectory 'mutation.json') $script:GuestPreparationDescriptor
            if($Fault -ne 'none'){
                {& $script:GuestPreparationScript -JobDirectory $script:GuestPreparationDirectory -Root $script:GuestPreparationRoot -JobsDirectory $script:GuestPreparationJobs}|Should -Throw '*resume artifact fingerprint differs*'
                Should -Invoke Invoke-MutatorPackage -Times 0
            }else{
                & $script:GuestPreparationScript -JobDirectory $script:GuestPreparationDirectory -Root $script:GuestPreparationRoot -JobsDirectory $script:GuestPreparationJobs
                $local=Join-Path $script:GuestPreparationRoot ('mutation-jobs/'+$script:GuestPreparationId)
                $plan=Read-MutatorJson (Join-Path $local 'run/run.json')
                $resume=$plan.Packages[0].ResumeFrom
                (Get-FileHash $resume).Hash|Should -BeExactly $script:GuestPreparationDescriptor.ResumeReportSha256
                (Get-FileHash ($resume+'.context.json')).Hash|Should -BeExactly $script:GuestPreparationDescriptor.ResumeContextSha256
                Should -Invoke Invoke-MutatorPackage -Times 1
            }
        }
    }
}
