<#
.SYNOPSIS
Expected behavior for the BranchCoverage tests.

.DESCRIPTION
Instrumented code must return the same results as original code, preserving short-circuiting,
fallthrough and scalar/null/collection enumeration. Early break must remain lazy and must not invent
an unobserved loop exit.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Branch probe semantics and exact outcomes' {
    It 'preserves branch results, short circuiting, loop values and switch fallthrough' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $path=Join-Path $Root 'subject.ps1'
            $source=@'
param([int]$Value)
$result=0
if($Value -gt 0 -and $Value -lt 3){$result=1}elseif($Value -eq 3){$result=2}else{$result=3}
foreach($item in @(1,2)){$result+=$item}
for($i=0;$i -lt 2;$i++){$result++}
while($result -lt 8){$result++}
switch($Value){1 {$result+=10};2 {$result+=20}}
$result
'@
            Set-Content $path $source
            $instrumented=ConvertTo-MutatorBranchSource $path 'subject.ps1'
            $out=Join-Path $Root 'instrumented.ps1';Set-Content $out $instrumented.Code
            $saved=@{Probe=$env:MUTATOR_BRANCH_PROBE;Directory=$env:MUTATOR_BRANCH_DIRECTORY;Run=$env:MUTATOR_BRANCH_RUN}
            try{
                $env:MUTATOR_BRANCH_PROBE=Join-Path $script:MutatorRoot 'resources/coverage/BranchProbe.ps1'
                $env:MUTATOR_BRANCH_DIRECTORY=Join-Path $Root 'records';$env:MUTATOR_BRANCH_RUN=[guid]::NewGuid().ToString('N')
                foreach($value in @(0,1,2,3)){@(& $out $value)|Should -Be @(& $path $value)}
                $records=@(Get-ChildItem $env:MUTATOR_BRANCH_DIRECTORY -Filter '*.jsonl'|Get-Content|ForEach-Object {$_|ConvertFrom-Json})
                $records.Count|Should -BeGreaterThan 0
                foreach($record in $records){$record.Id|Should -BeIn $instrumented.Branches.Id;$record.Run|Should -BeExactly $env:MUTATOR_BRANCH_RUN}
                @($records|Where-Object Outcome -EQ true).Count|Should -BeGreaterThan 0
                @($records|Where-Object Outcome -EQ false).Count|Should -BeGreaterThan 0
                @($records|Where-Object Outcome -EQ hit).Count|Should -BeGreaterThan 0
            }finally{$env:MUTATOR_BRANCH_PROBE=$saved.Probe;$env:MUTATOR_BRANCH_DIRECTORY=$saved.Directory;$env:MUTATOR_BRANCH_RUN=$saved.Run}
        }
    }
    It 'preserves scalar, null and collection enumeration and stops lazily on break' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $source='param($Values) foreach($item in $Values){$item;if($item -eq 2){break}}'
            $path=Join-Path $Root 'enumeration.ps1';Set-Content $path $source
            $converted=ConvertTo-MutatorBranchSource $path 'enumeration.ps1'
            $target=Join-Path $Root 'tracked.ps1';Set-Content $target $converted.Code
            $saved=@{Probe=$env:MUTATOR_BRANCH_PROBE;Directory=$env:MUTATOR_BRANCH_DIRECTORY;Run=$env:MUTATOR_BRANCH_RUN}
            try{
                $env:MUTATOR_BRANCH_PROBE=Join-Path $script:MutatorRoot 'resources/coverage/BranchProbe.ps1'
                $env:MUTATOR_BRANCH_DIRECTORY=Join-Path $Root 'enum-records';$env:MUTATOR_BRANCH_RUN=[guid]::NewGuid().ToString('N')
                foreach($values in @($null,'text',1,@(),@(1,2,3),@($null))){@(& $target -Values $values)|Should -Be @(& $path -Values $values)}
                $env:MUTATOR_BRANCH_RUN=[guid]::NewGuid().ToString('N')
                @(& $target -Values @(1,2,3))|Should -Be @(1,2)
                $loop=@($converted.Branches|Where-Object Kind -EQ Foreach)[0]
                $events=@(Get-ChildItem $env:MUTATOR_BRANCH_DIRECTORY -Filter '*.jsonl'|Get-Content|ForEach-Object {$_|ConvertFrom-Json}|Where-Object {$_.Run -eq $env:MUTATOR_BRANCH_RUN -and $_.Id -eq $loop.Id})
                @($events|Where-Object Outcome -EQ false).Count|Should -Be 0
            }finally{$env:MUTATOR_BRANCH_PROBE=$saved.Probe;$env:MUTATOR_BRANCH_DIRECTORY=$saved.Directory;$env:MUTATOR_BRANCH_RUN=$saved.Run}
        }
    }
}
