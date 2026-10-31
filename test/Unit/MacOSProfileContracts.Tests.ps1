<#
.SYNOPSIS
Expected behavior for the MacOSProfileContracts tests.

.DESCRIPTION
Use the explicit macOS installer and launcher, including manual constraints. Infrastructure must not
gain an invented binary; unknown recipes and host-service substitutions are refused.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'macOS recipe contracts, without claiming guest qualification' {
    It 'selects the explicit installation and launch recipe for <Key>' -ForEach @(
        @{Key='Ag';Binary='ag';Expected=@{Method='Brew';Packages=@('the_silver_searcher')}}
        @{Key='Gcloud';Binary='gcloud';Expected=@{Method='BrewCask';Packages=@('gcloud-cli')}}
        @{Key='Quarto';Binary='quarto';Expected=@{Method='BrewCask';Packages=@('quarto')}}
        @{Key='Jest';Binary='jest';Expected=@{Method='Npm';Package='jest';Packages=@('node')}}
        @{Key='Pytest';Binary='pytest';Expected=@{Method='Pip';Package='pytest';Packages=@('python@3.14')}}
        @{Key='Rspec';Binary='rspec';Expected=@{Method='Gem';Package='rspec';Packages=@('ruby')}}
        @{Key='Phpunit';Binary='phpunit';Expected=@{Method='Composer';Package='phpunit/phpunit';Packages=@('php','composer')}}
        @{Key='Jira';Binary='jira';Expected=@{Method='Go';Package='github.com/ankitpokhrel/jira-cli/cmd/jira';Packages=@('go','git')}}
        @{Key='Git';Binary='git';Expected=@{Method='None';Packages=@()}}
        @{Key='Dotnet';Binary='dotnet';Expected=@{Method='None';Packages=@()}}
        @{Key='Psql';Binary='ignored';Expected=@{Method='Brew';Binary='psql';Packages=@('libpq');ExtraPath=@('/usr/local/opt/libpq/bin')}}
        @{Key='Java';Binary='java';Expected=@{Method='Brew';Packages=@('openjdk@21');ExtraPath=@('/usr/local/opt/openjdk@21/bin')}}
        @{Key='Gcc';Binary='ignored';Expected=@{Method='Brew';Binary='gcc';GnuCompiler=$true;Packages=@('gcc')}}
        @{Key='Gpp';Binary='ignored';Expected=@{Method='Brew';Binary='g++';GnuCompiler=$true;Packages=@('gcc')}}
        @{Key='Python';Binary='python';Expected=@{Method='Brew';Packages=@('python@3.14')}}
        @{Key='Pip';Binary='pip';Expected=@{Method='Brew';Packages=@('python@3.14')}}
        @{Key='Artisan';Binary='ignored';Expected=@{Method='Artisan';Binary='php';Packages=@('php','composer')}}
        @{Key='Phpt';Binary='ignored';Expected=@{Method='Phpt';Binary='php';Packages=@('php','composer');PhpSourceRef='php-8.5.12'}}
        @{Key='Fail2banClient';Binary='fail2ban-client';Expected=@{Method='Pip';Package='fail2ban';Packages=@('python')}}
        @{Key='Oc';Binary='oc';Expected=@{Method='Brew';Packages=@('openshift-cli')}}
        @{Key='Xcodebuild';Binary='xcodebuild';Expected=@{Method='Xcode';Packages=@();Status='NeedsManualSetup'}}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Key=$Key;Binary=$Binary;Expected=$Expected} {
            param($Key,$Binary,$Expected)
            $profile=Get-MutatorMacOSProfile $Key $Binary
            foreach($property in $Expected.Keys){$profile[$property] | Should -Be $Expected[$property] -Because "$Key requires $property"}
            if(!$Expected.ContainsKey('Binary')){$profile.Binary | Should -BeExactly $Binary}
            if(!$Expected.ContainsKey('Status')){$profile.Status | Should -BeExactly Prepared}
            $profile.Backend | Should -BeExactly Dockurr
            $profile.ContainerOS | Should -BeExactly Linux
            $profile.GuestOS | Should -BeExactly macOS
            $profile.Installation | Should -BeExactly OnCloneBoot
            $profile.VirtualMachine | Should -BeTrue
            $profile.HardwareRequirement | Should -BeExactly 'Apple hardware'
            $profile.BuildValidated | Should -BeFalse
            if($Key -eq 'Xcodebuild'){$profile.Constraints | Should -Match 'full Xcode.*Command Line Tools alone are insufficient'}
        }
    }
    It 'does not substitute a macOS host service for <Key>' -ForEach @(
        @{Key='Journalctl';Reason='journalctl requires systemd; use the Debian image.'}
        @{Key='Systemctl';Reason='systemctl requires systemd; use the Debian image.'}
        @{Key='Iptables';Reason='iptables requires Linux netfilter.'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Key=$Key;Reason=$Reason} {
            param($Key,$Reason)
            $profile=Get-MutatorMacOSProfile $Key native
            $profile.Method | Should -BeExactly Unsupported
            $profile.Status | Should -BeExactly Unsupported
            $profile.Reason | Should -BeExactly $Reason
            $profile.BuildValidated | Should -BeFalse
        }
    }
    It 'keeps infrastructure free of an invented native executable: <Key>' -ForEach @(
        @{Key='Engine'},@{Key='Utility.Agent'},@{Key='Utility.Filters'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Key=$Key} {
            param($Key)
            $profile=Get-MutatorMacOSProfile $Key ignored
            $profile.Binary | Should -BeNullOrEmpty
            $profile.Method | Should -BeExactly None
            $profile.Packages | Should -Be @()
        }
    }
    It 'refuses a missing recipe instead of constructing a successful placeholder' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            {Get-MutatorMacOSProfile MissingTool missing} | Should -Throw '*No explicit macOS installation recipe for MissingTool*'
        }
    }
}
