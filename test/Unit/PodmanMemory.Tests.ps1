<#
.SYNOPSIS
Expected behavior for the PodmanMemory tests.

.DESCRIPTION
Act only on the verified running machine with substantial clean cache or available pages. Record
whether compaction actually ran; unavailable kernel controls cannot be reported as enforced
recovery.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Podman file cache under host RAM pressure' {
    It 'reclaims only a verified running machine with substantial clean cache' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Mock Invoke-MutatorNative {
                param($Arguments)
                if($Arguments[1] -eq 'inspect'){return @{Outcome='Success';Stdout='[{"Name":"fixture","State":"running"}]'}}
                if($Arguments -contains '/proc/meminfo'){return @{Outcome='Success';Stdout="Cached: 2000000 kB`nSReclaimable: 100000 kB"}}
                @{Outcome='Success';Stdout='compacted'}
            }
            $result=Invoke-MutatorPodmanCacheRecovery fixture
            $result.Outcome|Should -BeExactly CacheReclaimed
            $result.CachedBytes|Should -Be 2150400000L
            $result.Compacted|Should -BeTrue
            Should -Invoke Invoke-MutatorNative -Times 1 -ParameterFilter {$Arguments[-1] -like '*drop_caches*' -and $Arguments[-1] -like '*compact_memory*'}
        }
    }
    It 'does not reclaim a foreign or stopped machine' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Mock Invoke-MutatorNative { @{Outcome='Success';Stdout='[{"Name":"foreign","State":"running"}]'} }
            {Invoke-MutatorPodmanCacheRecovery fixture}|Should -Throw '*not running*'
            Should -Invoke Invoke-MutatorNative -Times 0 -ParameterFilter {$Arguments -contains 'ssh'}
        }
    }
    It 'compacts already free VM pages even when its file cache was previously reclaimed' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Mock Invoke-MutatorNative {
                if($Arguments[1] -ceq 'inspect'){@{Outcome='Success';Stdout='[{"Name":"fixture","State":"running"}]'}}
                elseif($Arguments -contains '/proc/meminfo'){@{Outcome='Success';Stdout="Cached: 1000 kB`nMemAvailable: 10000000 kB"}}
                else{@{Outcome='Success';Stdout='compacted'}}
            }
            $r=Invoke-MutatorPodmanCacheRecovery fixture
            $r.Outcome|Should -Be MemoryCompacted
            $r.AvailableBytes|Should -Be 10240000000L
            Should -Invoke Invoke-MutatorNative -Times 1 -Exactly -ParameterFilter {$Arguments[-1] -like '*compact_memory*' -and $Arguments[-1] -notlike '*drop_caches*'}
        }
    }
    It 'does not claim compaction when the kernel does not expose it' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Mock Invoke-MutatorNative {
                if($Arguments[1] -ceq 'inspect'){@{Outcome='Success';Stdout='[{"Name":"fixture","State":"running"}]'}}
                elseif($Arguments -contains '/proc/meminfo'){@{Outcome='Success';Stdout="Cached: 1000 kB`nMemAvailable: 10000000 kB"}}
                else{@{Outcome='Success';Stdout=''}}
            }
            $r=Invoke-MutatorPodmanCacheRecovery fixture
            $r.Outcome|Should -Be InsufficientReclaimableCache
            $r.Compacted|Should -BeFalse
        }
    }
    It 'leaves a VM without substantial available or cached memory alone' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Mock Invoke-MutatorNative {
                if($Arguments[1] -ceq 'inspect'){@{Outcome='Success';Stdout='[{"Name":"fixture","State":"running"}]'}}
                else{@{Outcome='Success';Stdout="Cached: 1000 kB`nMemAvailable: 100000 kB"}}
            }
            (Invoke-MutatorPodmanCacheRecovery fixture).Outcome|Should -Be InsufficientReclaimableCache
            Should -Invoke Invoke-MutatorNative -Times 0 -Exactly -ParameterFilter {$Arguments[-1] -like '*compact_memory*'}
        }
    }
}
