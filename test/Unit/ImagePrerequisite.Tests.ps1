BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Empty image store dependency graph' {
    It 'builds a known missing local base and never pulls its localhost reference' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $modules=Split-Path $script:MutatorRoot
            $runtime=Get-MutatorContainerRuntime $modules
            $dockerfile=Join-Path $Root 'Dockerfile'
            Set-Content $dockerfile ('ARG BASE_IMAGE='+$runtime.Images.Windows+"`n"+'FROM ${BASE_IMAGE}')
            Mock Invoke-MutatorContainerCommand { @{Outcome='Failed';ExitCode=125;Stdout='';Stderr='image not known'} }
            Mock New-MutatorContainerImage { @{Outcome='Success';ImageId=('a'*64)} }
            $result=@(Initialize-MutatorImagePrerequisite -Dockerfile $dockerfile -ModuleRoot $modules -OutputDirectory $Root -Connection fixture -MemoryMiB 1024 -Cpus 2 -TimeoutSeconds 60)
            $result.Count|Should -Be 1
            $result[0].Built|Should -BeTrue
            Should -Invoke New-MutatorContainerImage -Times 1 -ParameterFilter {$BaseVariant -ceq 'Windows' -and $MemoryMiB -eq 1024 -and $Connection -ceq 'fixture'}
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -ceq 'pull'}
        }
    }
    It 'rejects an unknown localhost dependency before invoking any native tool' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $dockerfile=Join-Path $Root 'Dockerfile';Set-Content $dockerfile 'ARG BASE_IMAGE=localhost/unknown:tag'
            Mock Invoke-MutatorContainerCommand { throw 'Must not pull unknown dependencies' }
            $options=@{Dockerfile=$dockerfile;ModuleRoot=(Split-Path $script:MutatorRoot);OutputDirectory=$Root;Connection='fixture';MemoryMiB=1024;Cpus=1;TimeoutSeconds=60}
            {Initialize-MutatorImagePrerequisite @options}|Should -Throw '*Unknown local build dependency*'
            Should -Invoke Invoke-MutatorContainerCommand -Times 0
        }
    }
}
