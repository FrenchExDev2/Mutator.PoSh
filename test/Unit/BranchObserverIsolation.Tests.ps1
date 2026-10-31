<#
.SYNOPSIS
Expected behavior for the BranchObserverIsolation tests.

.DESCRIPTION
Observer namespaces must not alter original source or branch identity. Reject executable identifier
syntax and preserve an enclosing observer when cloning an instrumented recorder.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Branch observation is isolated from its recorder test subject' {
    It 'preserves original code and branch identities while using a separate observer' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $subject=Join-Path $Root 'subject.ps1'
            $source=@'
param($Values)
function Write-MutatorBranch {throw 'The subject recorder must not observe itself.'}
function Get-MutatorBranchEnumerable {throw 'The subject enumerator must not observe itself.'}
'Write-MutatorBranch'
foreach($value in $Values){if($value -gt 0){$value}else{0};switch($value){1 {'one'}}}
'@
            Set-Content -LiteralPath $subject $source
            $namespace='Obs'+[guid]::NewGuid().ToString('N')
            $plain=ConvertTo-MutatorBranchSource $subject 'subject.ps1'
            $converted=ConvertTo-MutatorBranchSource $subject 'subject.ps1' -ObserverNamespace $namespace
            $converted.Sha256 | Should -BeExactly $plain.Sha256
            $converted.Branches.Id | Should -Be $plain.Branches.Id
            $converted.Code | Should -Match "'Write-MutatorBranch'"
            $observer=Join-Path $Root 'observer.ps1'
            $generated=New-MutatorBranchObserver -Path (Join-Path $script:MutatorRoot 'resources/coverage/BranchProbe.ps1') -Namespace $namespace
            [IO.File]::WriteAllText($observer,$generated.Code,[Text.UTF8Encoding]::new($false))
            $environment=@{}
            $settings=@{('MUTATOR_BRANCH_PROBE'+$namespace)=$observer;('MUTATOR_BRANCH_RUN'+$namespace)='outer-observer';('MUTATOR_BRANCH_DIRECTORY'+$namespace)=(Join-Path $Root 'outer-records')}
            foreach($key in $settings.Keys){$environment[$key]=[Environment]::GetEnvironmentVariable($key);[Environment]::SetEnvironmentVariable($key,$settings[$key])}
            try{
                $target=Join-Path $Root 'instrumented.ps1';Set-Content -LiteralPath $target $converted.Code
                @(& $target -Values @(-1,1,2)) | Should -Be @('Write-MutatorBranch',0,1,'one',2)
                # A readiness variable alone must not prevent reloading missing commands.
                Remove-Item -LiteralPath ('Function:global:Write-MutatorBranch'+$namespace)
                Get-Variable -Name ('MutatorBranch'+$namespace+'ProbeReady') -Scope Global | Should -Not -BeNullOrEmpty
                @(& $target -Values @(-1,1,2)) | Should -Be @(& $subject -Values @(-1,1,2))
                $events=@(Get-ChildItem -LiteralPath (Join-Path $Root 'outer-records') -File|Get-Content|ForEach-Object {$_|ConvertFrom-Json})
                $events.Count | Should -BeGreaterThan 0
                foreach($entry in $events){$entry.Run | Should -BeExactly outer-observer;$entry.Id | Should -BeIn $converted.Branches.Id}
                @($events|Where-Object Outcome -EQ true).Count | Should -BeGreaterThan 0
                @($events|Where-Object Outcome -EQ false).Count | Should -BeGreaterThan 0
                @($events|Where-Object Outcome -EQ hit).Count | Should -BeGreaterThan 0
            }finally{
                foreach($key in $environment.Keys){[Environment]::SetEnvironmentVariable($key,$environment[$key])}
                foreach($name in @(('Write-MutatorBranch'+$namespace),('Get-MutatorBranch'+$namespace+'Enumerable'))){Remove-Item -LiteralPath ('Function:global:'+$name) -ErrorAction SilentlyContinue}
                foreach($name in @(('MutatorBranch'+$namespace+'State'),('MutatorBranch'+$namespace+'ProbeReady'))){Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue}
            }
        }
    }
    It 'rejects executable syntax in observer identifiers' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $path=Join-Path $Root 'unmodified.ps1';Set-Content -LiteralPath $path 'if($true){1}'
            $before=(Get-FileHash -LiteralPath $path).Hash
            {ConvertTo-MutatorBranchSource $path 'unmodified.ps1' -ObserverNamespace 'bad;throw'} | Should -Throw
            (Get-FileHash -LiteralPath $path).Hash | Should -BeExactly $before
        }
    }
    It 'preserves the outer observer when cloning an already instrumented recorder' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $probe=Join-Path $script:MutatorRoot 'resources/coverage/BranchProbe.ps1'
            $tracked=ConvertTo-MutatorBranchSource $probe 'BranchProbe.ps1' -ObserverNamespace Outer
            $path=Join-Path $Root 'tracked-probe.ps1';Set-Content -LiteralPath $path $tracked.Code
            $observer=New-MutatorBranchObserver $path Inner
            $observer.Code | Should -Match '\bWrite-MutatorBranchOuter\b'
            $observer.Code | Should -Not -Match 'Write-MutatorBranchOuterInner'
            $observer.Code | Should -Match '\bWrite-MutatorBranchInner\b'
            $observer.Code | Should -Match '\bMutatorBranchInnerEnumerator\b'
            $observer.Code | Should -Match '\bMUTATOR_BRANCH_RUNInner\b'
            $observer.Code | Should -Match '\bMUTATOR_BRANCH_DIRECTORYInner\b'
            $observer.Code | Should -Match '\bMUTATOR_BRANCH_PROBEOuter\b'
            $observer.SourceSha256 | Should -BeExactly (Get-FileHash -LiteralPath $path).Hash
            $observer.Namespace | Should -BeExactly Inner
        }
    }
}
