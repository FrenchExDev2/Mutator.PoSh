BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Private pinned PSMutant adapter' {
    BeforeEach {
        $script:Installed=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Cache=Join-Path $TestDrive 'cache'
        [void][IO.Directory]::CreateDirectory((Join-Path $script:Installed 'src'))
        [IO.File]::WriteAllText((Join-Path $script:Installed 'src/PSMutation.Runner.ps1'),'$cfg = New-PesterConfiguration' + "`n" + 'while ($schedule.Retired -lt $context.Total) {'+"`n"+'$Context.Sink.Add($done.Row)'+"`n}")
        [IO.File]::WriteAllText((Join-Path $script:Installed 'src/PSMutation.Pester.ps1'),'$c = New-PesterConfiguration'+"`n"+'$c = New-PesterConfiguration')
        [IO.File]::WriteAllText((Join-Path $script:Installed 'PSMutant.psd1'),"@{ModuleVersion='0.6.0'}")
        [IO.File]::WriteAllText((Join-Path $script:Installed 'PSMutant.psm1'),'# fixture')
        $global:MutatorAdapterFixture=$script:Installed
        $global:MutatorAdapterModule=New-Module -Name AdapterControlFixture -ScriptBlock {}
        Mock Get-Module -ModuleName FrenchExDev.Mutator.PoSh {[pscustomobject]@{Version=[version]'0.6.0';ModuleBase=$global:MutatorAdapterFixture}} -ParameterFilter {$ListAvailable -and $Name -eq 'PSMutant'}
        Mock Get-Module -ModuleName FrenchExDev.Mutator.PoSh {$global:MutatorAdapterModule} -ParameterFilter {!$ListAvailable -and $Name -eq 'PSMutant'}
        Mock Import-Module -ModuleName FrenchExDev.Mutator.PoSh {$global:MutatorAdapterModule} -ParameterFilter {$Name -like '*PSMutant.psd1'}
    }
    AfterEach {Remove-Variable MutatorAdapterFixture,MutatorAdapterModule -Scope Global -ErrorAction Ignore}
    It 'patches three configurations and one progress/stop boundary without changing the installed tool' {
        $result=Import-MutatorTool -CacheRoot $script:Cache
        $root=Split-Path $result.Path
        $adapter=Get-Content (Join-Path $root 'adapter.json') -Raw|ConvertFrom-Json
        $adapter.ConfigurationBoundaries | Should -Be 3
        $adapter.ProgressBoundary | Should -Be 1
        $adapter.CancellationBoundary | Should -Be 1
        [IO.File]::ReadAllText((Join-Path $script:Installed 'PSMutant.psm1')) | Should -BeExactly '# fixture'
        $runner=[IO.File]::ReadAllText((Join-Path $root 'src/PSMutation.Runner.ps1'))
        $runner | Should -Match 'OperationCanceledException'
        $runner | Should -Match 'AppendAllText'
        $runner | Should -Match 'MutatorEpoch'
        (Import-MutatorTool -CacheRoot $script:Cache).Path | Should -BeExactly $result.Path
    }
    It 'refuses an unexpected tool layout before loading its compatibility copy' {
        [IO.File]::WriteAllText((Join-Path $script:Installed 'src/PSMutation.Pester.ps1'),'$c = New-PesterConfiguration')
        {Import-MutatorTool -CacheRoot $script:Cache} | Should -Throw '*boundaries: 2*'
        Should -Invoke Import-Module -ModuleName FrenchExDev.Mutator.PoSh -Times 0
    }
    It 'initializes exactly the imported adapter when other PSMutant instances are visible' {
        Mock Get-Module -ModuleName FrenchExDev.Mutator.PoSh {@($global:MutatorAdapterModule,$global:MutatorAdapterModule)} -ParameterFilter {!$ListAvailable -and $Name -eq 'PSMutant'}
        $progress=Join-Path $TestDrive 'events.jsonl'
        $null=Import-MutatorTool -CacheRoot $script:Cache -ProgressPath $progress
        & $global:MutatorAdapterModule {$script:MutatorControl.Progress}|Should -BeExactly $progress
    }

    It 'uses a concurrently published complete copy without overwriting the winner' {
        $winner=Import-MutatorTool -CacheRoot (Join-Path $TestDrive 'winner-cache')
        $winnerRoot=Split-Path $winner.Path
        $cache=Join-Path $TestDrive ('competing-cache-'+[guid]::NewGuid().ToString('N'))
        $target=Join-Path $cache (Split-Path $winnerRoot -Leaf)
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Winner=$winnerRoot;Target=$target;Cache=$cache} {
            param($Winner,$Target,$Cache)
            $script:CompetingAdapterWinner=$Winner
            $script:CompetingAdapterTarget=$Target
            $script:OriginalAdapterJsonWriter=(Get-Command Write-MutatorJson).ScriptBlock
            try {
                Mock Write-MutatorJson {
                    param($Path,$Data)
                    & $script:OriginalAdapterJsonWriter $Path $Data
                    if(!(Test-Path -LiteralPath $script:CompetingAdapterTarget)){
                        Copy-Item -LiteralPath $script:CompetingAdapterWinner -Destination $script:CompetingAdapterTarget -Recurse
                    }
                }
                $before=Get-MutatorSourceSnapshot $Winner
                $tool=Import-MutatorTool -CacheRoot $Cache
                $tool.Path|Should -BeExactly (Join-Path $Target 'PSMutant.psd1')
                (Get-MutatorSourceSnapshot $Target).Sha256|Should -BeExactly $before.Sha256
                @(Get-ChildItem -LiteralPath $Cache -Directory -Filter '*.staging' -Force).Count|Should -Be 0
                Should -Invoke Write-MutatorJson -Times 1 -Scope It -ParameterFilter {$Path -like '*.staging*adapter.json'}
            } finally {Remove-Variable CompetingAdapterWinner,CompetingAdapterTarget,OriginalAdapterJsonWriter -Scope Script -ErrorAction Ignore}
        }
    }

    It 'retains an incomplete conflicting target and refuses to import it' {
        $winner=Import-MutatorTool -CacheRoot (Join-Path $TestDrive 'key-cache')
        $cache=Join-Path $TestDrive ('incomplete-cache-'+[guid]::NewGuid().ToString('N'))
        $target=Join-Path $cache (Split-Path (Split-Path $winner.Path) -Leaf)
        [void][IO.Directory]::CreateDirectory($target)
        $evidence=Join-Path $target 'incomplete.txt'
        [IO.File]::WriteAllText($evidence,'original evidence')
        {Import-MutatorTool -CacheRoot $cache}|Should -Throw
        [IO.File]::ReadAllText($evidence)|Should -BeExactly 'original evidence'
        Test-Path -LiteralPath (Join-Path $target 'adapter.json')|Should -BeFalse
        @(Get-ChildItem -LiteralPath $cache -Directory -Filter '*.staging' -Force).Count|Should -Be 0
        Should -Invoke Import-Module -ModuleName FrenchExDev.Mutator.PoSh -Times 1
    }

    It 'removes the private failed build and permits a later valid installation' {
        [IO.File]::WriteAllText((Join-Path $script:Installed 'src/PSMutation.Pester.ps1'),'$c = New-PesterConfiguration')
        {Import-MutatorTool -CacheRoot $script:Cache}|Should -Throw '*boundaries: 2*'
        @(Get-ChildItem -LiteralPath $script:Cache -Directory -Filter '*.staging' -Force).Count|Should -Be 0
        [IO.File]::WriteAllText((Join-Path $script:Installed 'src/PSMutation.Pester.ps1'),'$c = New-PesterConfiguration'+"`n"+'$c = New-PesterConfiguration')
        $tool=Import-MutatorTool -CacheRoot $script:Cache
        Test-Path -LiteralPath $tool.Path|Should -BeTrue
    }

    It 'refuses a staging path outside its owned cache before creating or removing it' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Cache=(Join-Path $TestDrive ('safe-cache-'+[guid]::NewGuid().ToString('N')));Outside=(Join-Path $TestDrive 'foreign.staging')} {
            param($Cache,$Outside)
            $script:ForeignAdapterStage=$Outside
            try {
                Mock Join-Path {param([string]$Path,[string]$ChildPath) [IO.Path]::Combine($Path,$ChildPath)}
                Mock Join-Path {$script:ForeignAdapterStage} -ParameterFilter {$ChildPath -like '*.staging'}
                {Import-MutatorTool -CacheRoot $Cache}|Should -Throw '*inside its cache directory*'
                Test-Path -LiteralPath $Outside|Should -BeFalse
                Should -Invoke Import-Module -Times 0
            } finally {Remove-Variable ForeignAdapterStage -Scope Script -ErrorAction Ignore}
        }
    }

    It 'refuses missing or duplicated progress/cancellation boundaries: <Fault>' -ForEach @(
        @{Fault='missing loop'},@{Fault='duplicated loop'},@{Fault='missing retirement'},@{Fault='duplicated retirement'}
    ) {
        $path=Join-Path $script:Installed 'src/PSMutation.Runner.ps1'
        $text=[IO.File]::ReadAllText($path)
        switch($Fault){
            'missing loop' {$text=$text.Replace('while ($schedule.Retired -lt $context.Total) {','while ($unexpected) {')}
            'duplicated loop' {$text+='while ($schedule.Retired -lt $context.Total) { }'}
            'missing retirement' {$text=$text.Replace('$Context.Sink.Add($done.Row)','$Context.Sink.Clear()')}
            'duplicated retirement' {$text+='$Context.Sink.Add($done.Row)'}
        }
        [IO.File]::WriteAllText($path,$text)
        {Import-MutatorTool -CacheRoot $script:Cache}|Should -Throw '*progress/cancellation boundaries*'
        Should -Invoke Import-Module -ModuleName FrenchExDev.Mutator.PoSh -Times 0
        @(Get-ChildItem -LiteralPath $script:Cache -Directory -Filter '*.staging' -Force).Count|Should -Be 0
    }

    It 'requires exactly one imported module: <Count>' -ForEach @(@{Count=0},@{Count=2}) {
        if($Count -eq 0){Mock Import-Module -ModuleName FrenchExDev.Mutator.PoSh {} -ParameterFilter {$Name -like '*PSMutant.psd1'}}
        else{Mock Import-Module -ModuleName FrenchExDev.Mutator.PoSh {@($global:MutatorAdapterModule,$global:MutatorAdapterModule)} -ParameterFilter {$Name -like '*PSMutant.psd1'}}
        {Import-MutatorTool -CacheRoot $script:Cache}|Should -Throw '*one unambiguous module*'
    }

    It 'refuses to substitute another version for the pinned unavailable tool' {
        Mock Get-Module -ModuleName FrenchExDev.Mutator.PoSh {} -ParameterFilter {$ListAvailable -and $Name -eq 'PSMutant'}
        {Import-MutatorTool -CacheRoot $script:Cache}|Should -Throw '*PSMutant 0.6.0 is unavailable*'
        Should -Invoke Import-Module -ModuleName FrenchExDev.Mutator.PoSh -Times 0
    }
}
