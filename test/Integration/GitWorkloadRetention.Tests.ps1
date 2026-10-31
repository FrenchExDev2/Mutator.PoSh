<#
.SYNOPSIS
Expected behavior for the GitWorkloadRetention tests.

.DESCRIPTION
Failed workloads retain their sandbox and identity receipt; successful fixture workloads remove only
their owned sandbox. Uses a child process with a stub workload, not real Git qualification.

.NOTES
Run this suite explicitly with its documented runtime prerequisites. Its result covers the asserted
fixture scenarios and selected environment only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:RetentionModule=Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:RetentionModule 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}
Describe 'Git workload sandbox lifetime' {
    It 'retains a failed sandbox and removes a successful sandbox: <Mode>' -ForEach @(@{Mode='Failed';Retained=$true},@{Mode='Success';Retained=$false}) {
        $fixture=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $source=Join-Path $fixture 'source'
        $report=Join-Path $fixture 'reports'
        $module=Join-Path $source 'FrenchExDev.Mutator.PoSh'
        [void][IO.Directory]::CreateDirectory($module)
        [void][IO.Directory]::CreateDirectory((Join-Path $source 'FrenchExDev.DevPoSh.PoSh'))
        [void][IO.Directory]::CreateDirectory((Join-Path $source 'FrenchExDev.QuietCli.Git.PoSh/test'))
        [IO.File]::WriteAllText((Join-Path $source 'FrenchExDev.QuietCli.Git.PoSh/test/psmutant.config.json'),'{"sandboxSubtrees":["FrenchExDev.Mutator.PoSh"]}')
        $manifest="@{RootModule='stub.psm1';ModuleVersion='1.0.0';FunctionsToExport=@('*')}"
        [IO.File]::WriteAllText((Join-Path $module 'FrenchExDev.Mutator.PoSh.psd1'),$manifest)
        $stub=@'
function Get-MutatorSourceSnapshot {param([string]$Root) @{Sha256=('a'*64)}}
function Read-MutatorJson {param([string]$Path) Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json -AsHashtable}
function Write-MutatorJson {param([string]$Path,$Data) [void][IO.Directory]::CreateDirectory((Split-Path $Path));[IO.File]::WriteAllText($Path,($Data|ConvertTo-Json -Depth 10))}
function Get-MutatorSubtree {param($Root,$Configuration) 'FrenchExDev.Mutator.PoSh'}
function Copy-MutatorTree {
    param([string]$Source,[string]$Destination)
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach($item in Get-ChildItem -LiteralPath $Source -Force){Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force}
}
function Invoke-MutatorValidationWorkload {
    param([string]$Root,[string]$ReportRoot)
    $result=@{Outcome='__MODE__';FullGateSatisfied=$false;RetainSandbox=$false}
    Write-MutatorJson (Join-Path $ReportRoot 'result.json') $result
    return $result
}
Export-ModuleMember -Function *
'@
        [IO.File]::WriteAllText((Join-Path $module 'stub.psm1'),$stub.Replace('__MODE__',$Mode))
        $id=[guid]::NewGuid().ToString('N')
        $sandbox=Join-Path ([IO.Path]::GetTempPath()) ('mutator-git-'+$id)
        $script=Join-Path $script:RetentionModule 'resources/validation/Invoke-GitImageWorkload.ps1'
        try{
            $native=& (Get-Module FrenchExDev.Mutator.PoSh) {
                param($Script,$Source,$Report,$RunId)
                Invoke-MutatorNative (Join-Path $PSHOME 'pwsh') @('-NoProfile','-File',$Script,'-SourceRoot',$Source,'-ReportRoot',$Report,'-Platform','Linux','-RunId',$RunId,'-OriginalModuleSha256',('a'*64)) $script:MutatorRoot 30
            } $script $source $report $id
            if($Retained){
                $native.Outcome|Should -BeExactly Failed
                Test-Path -LiteralPath $sandbox|Should -BeTrue
                $proof=Get-Content (Join-Path $report 'retained-sandbox.json') -Raw|ConvertFrom-Json -AsHashtable
                $proof.Path|Should -BeExactly $sandbox
                $proof.RunId|Should -BeExactly $id
            }else{
                $native.Outcome|Should -BeExactly Success
                Test-Path -LiteralPath $sandbox|Should -BeFalse
                Test-Path (Join-Path $report 'retained-sandbox.json')|Should -BeFalse
            }
        }finally{
            if(Test-Path -LiteralPath $sandbox){
                if([IO.Path]::GetFullPath($sandbox) -cne [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('mutator-git-'+$id)))){throw 'Refusing fixture cleanup outside its owned sandbox.'}
                Remove-Item -LiteralPath $sandbox -Recurse -Force
            }
        }
    }
}
