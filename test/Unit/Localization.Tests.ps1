<#
.SYNOPSIS
Expected behavior for the Localization tests.

.DESCRIPTION
French/English catalogs must share keys and translate labels without changing counts, module names
or endpoints. Unknown discovery, completion and enforced-versus-reserved memory remain semantically
accurate.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Environment-selected Mutator translations' {
    InModuleScope FrenchExDev.Mutator.PoSh {
        BeforeEach {$script:SavedMutatorLanguage=$env:MUTATOR_LANG}
        AfterEach {$env:MUTATOR_LANG=$script:SavedMutatorLanguage}
        It 'selects a catalog without changing the UI culture: <Language>' -ForEach @(
            @{Language='';Expected='fr-FR';State='ETAT'},@{Language='fr';Expected='fr-FR';State='ETAT'},
            @{Language='fr-CA';Expected='fr-FR';State='ETAT'},@{Language='en';Expected='en-US';State='STATE'},
            @{Language='en-US';Expected='en-US';State='STATE'},@{Language='de-DE';Expected='en-US';State='STATE'},
            @{Language='not_@_a_culture';Expected='en-US';State='STATE'}
        ) {
            $culture=[Globalization.CultureInfo]::CurrentUICulture.Name
            $env:MUTATOR_LANG=$Language
            Get-MutatorLanguage|Should -BeExactly $Expected
            Get-MutatorText Header.State|Should -BeExactly $State
            [Globalization.CultureInfo]::CurrentUICulture.Name|Should -BeExactly $culture
        }
        It 'requires the same keys in both declarative catalogs and formats values without changing counts' {
            $fr=Import-PowerShellDataFile (Join-Path $script:MutatorRoot 'resources/localization/fr-FR.psd1')
            $en=Import-PowerShellDataFile (Join-Path $script:MutatorRoot 'resources/localization/en-US.psd1')
            @($fr.Keys|Sort-Object)|Should -Be @($en.Keys|Sort-Object)
            foreach($key in $fr.Keys){$fr[$key]|Should -BeOfType string;$fr[$key]|Should -Not -BeNullOrEmpty;$en[$key]|Should -Not -BeNullOrEmpty}
            $env:MUTATOR_LANG='en';Get-MutatorText Memory.Maximum @(512)|Should -BeExactly '512 MiB max'
            $env:MUTATOR_LANG='fr';Get-MutatorText Memory.Maximum @(512)|Should -BeExactly '512 Mio max'
            {Get-MutatorText Missing.Translation}|Should -Throw '*Missing Mutator translation*'
        }
        It 'translates the complete terminal header and keeps module names, endpoints and numeric totals intact' {
            $run=[pscustomobject]@{Id='locale-run';Platform='linux';Outcome='Running';ProcessedPackages=0;TotalPackages=1;CompletedPackages=0;FailedPackages=0;ErrorPercent=0;InterruptedPackages=0;EvaluatedMutants=0;PlannedMutants=0;SurvivedMutants=0;CreatedUtc=[datetime]::UtcNow.ToString('O');CompletedUtc=$null;Path='proof';ContainerEngine='Docker';Packages=@(@{Name='Fixture.Module';Phase='PSMutant';Outcome='Running';Container=@{Engine='Docker';Connection='context-kept';ResourceLimits=@{Memory=$true;MemoryMiB=512}}})}
            $env:MUTATOR_LANG='en';$english=Format-MutatorTerminalFrame $run
            $english|Should -Match 'STATE\s+MUTANTS\s+PLATFORM\s+RAM\s+CONNECTION\s+ENGINE'
            $english|Should -Match 'not started';$english|Should -Match '512 MiB max';$english|Should -Match 'context-kept\s+Docker'
            $env:MUTATOR_LANG='fr';$french=Format-MutatorTerminalFrame $run
            $french|Should -Match 'ETAT\s+MUTANTS\s+PLATEFORME\s+RAM\s+CONNEXION\s+MOTEUR'
            $french|Should -Match 'non demarre';$french|Should -Match 'Fixture.Module'
            $run.PlannedMutants|Should -Be 0;$run.Packages[0].Container.Connection|Should -BeExactly context-kept
        }
        It 'does not report completion for an empty run or invent a discovered mutation scope' {
            $env:MUTATOR_LANG='en'
            $run=[pscustomobject]@{Id='empty';Platform='linux';Outcome='Pending';ProcessedPackages=0;TotalPackages=0;CompletedPackages=0;FailedPackages=0;ErrorPercent=0;InterruptedPackages=0;EvaluatedMutants=0;PlannedMutants=0;SurvivedMutants=0;CreatedUtc='2026-01-01T00:00:00Z';CompletedUtc='2026-01-01T00:00:00Z';Path='proof';Packages=@()}
            $frame=Format-MutatorTerminalFrame $run
            $frame|Should -Match '0[.,]0%\s+0/0 processed'
            $frame|Should -Match '0/0 \(0[.,]0% of discovered scopes\)'
            $frame|Should -Not -Match '100[.,]0%'
        }
        It 'generates a translated dashboard with complete safe labels: <Language>' -ForEach @(
            @{Language='en';Expected='en-US';State='State';Placeholder='Search for a run or module'},
            @{Language='fr';Expected='fr-FR';State='État';Placeholder='Rechercher un run ou un module'}
        ) {
            $env:MUTATOR_LANG=$Language
            Mock Get-MutatorRun {@()}
            $path=Join-Path $TestDrive ($Expected+'/index.html')
            $r=Show-MutatorDashboard -RunRoot $TestDrive -Path $path
            $html=[IO.File]::ReadAllText($r.Path)
            $html|Should -Match ('<html lang="'+$Expected+'">')
            $html|Should -Not -Match '__MUTATOR_(DATA|TITLE|LANGUAGE)__'
            $json=[regex]::Match($html,'<script id="data" type="application/json">(?<data>.*?)</script>').Groups['data'].Value|ConvertFrom-Json -AsHashtable
            $json.Language|Should -BeExactly $Expected;$json.Labels.State|Should -BeExactly $State
            $json.Labels.SearchPlaceholder|Should -BeExactly $Placeholder
            foreach($match in [regex]::Matches($html,'data-i18n="(?<key>[^"]+)"|labels\.(?<key>[A-Za-z]+)')){
                $json.Labels[$match.Groups['key'].Value]|Should -Not -BeNullOrEmpty
            }
            $r.Runs|Should -Be 0
        }
        It 'distinguishes enforced and reserved memory in localized rows: <Expected>' -ForEach @(
            @{Language='en';Enforced=$true;MiB=1024;Expected='1024 MiB max'},
            @{Language='en';Enforced=$true;MiB=0;Expected='limit active'},
            @{Language='en';Enforced=$false;MiB=512;Expected='512 MiB reserved'},
            @{Language='en';Enforced=$false;MiB=0;Expected='reservation'},
            @{Language='fr';Enforced=$true;MiB=0;Expected='plafond actif'},
            @{Language='fr';Enforced=$false;MiB=512;Expected='512 Mio res.'}
        ) {
            $env:MUTATOR_LANG=$Language
            $run=[pscustomobject]@{Id='fixture';Platform='macos';Outcome='Failed';ProcessedPackages=1;TotalPackages=1;CompletedPackages=0;FailedPackages=1;ErrorPercent=100;InterruptedPackages=0
                EvaluatedMutants=6;PlannedMutants=12;SurvivedMutants=1;CreatedUtc='2026-01-01T00:00:00Z';CompletedUtc='2026-01-01T01:02:03Z';Path='proof';Error='retained error'
                ContainerEngine='Docker';ContainerEndpoint='npipe:////./pipe/docker-fixture';ActivePackages=0;Schedule=@{Slots=2;Workers=1;WorkerBudget=2;ReservedMemoryMiB=2048}
                HostMemory=@{UsedGB=$null;LimitGB=40;TriggerGB=38;Running=$false;Outcome='Stopped'}
                Packages=@(@{Name='very-long-module-name-'+('x'*50);Phase='Completed';Outcome='Failed';Platform='macos';PlannedMutants=12;EvaluatedMutants=6;Container=@{ResourceLimits=@{Memory=$Enforced;MemoryMiB=$MiB}}},
                    @{Name='already-successful';Phase='Completed';Outcome='Success'})}
            $frame=Format-MutatorTerminalFrame $run
            $frame|Should -Match ([regex]::Escape($Expected))
            $frame|Should -Match '6/12';$frame|Should -Match '01:02:03';$frame|Should -Match 'retained error'
            $frame|Should -Match 'macOS';$frame|Should -Match 'npipe:////./pipe/docker-fixture\s+Docker'
            $frame|Should -Not -Match 'already-successful'
            $frame|Should -Match 'very-long-module-name-.*\.\.\.'
            $frame|Should -Match $(if($Language -eq 'en'){'Host RAM\s+\? / 40 GB'}else{'RAM poste\s+\? / 40 Go'})
        }
    }
}
