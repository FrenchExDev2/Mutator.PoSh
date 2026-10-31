BeforeAll {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking
}

Describe 'Container installation contracts generated from tool plans' {
    It 'selects the native installer and package for <Key>' -ForEach @(
        @{Key='Git';Binary='git';Linux='Apk';Windows='Chocolatey';Package='git'}
        @{Key='AstGrep';Binary='ast-grep';Linux='Npm';Windows='Npm';Package='@ast-grep/cli'}
        @{Key='Pytest';Binary='pytest';Linux='Pip';Windows='Pip';Package='pytest'}
        @{Key='Rspec';Binary='rspec';Linux='Gem';Windows='Gem';Package='rspec'}
        @{Key='Phpunit';Binary='phpunit';Linux='Composer';Windows='Composer';Package='phpunit/phpunit'}
        @{Key='Jira';Binary='jira';Linux='Go';Windows='Go';Package='github.com/ankitpokhrel/jira-cli/cmd/jira'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Key=$Key;Binary=$Binary;Linux=$Linux;Windows=$Windows;Package=$Package} {
            param($Key,$Binary,$Linux,$Windows,$Package)
            $profiles=Get-MutatorContainerProfile $Key $Binary
            $versions=Read-MutatorJson (Join-Path $script:MutatorRoot 'resources/containers/definitions/package-versions.json')
            $profiles.Linux.Method | Should -BeExactly $Linux
            $profiles.Windows.Method | Should -BeExactly $Windows
            $profiles.Linux.Distribution | Should -BeExactly Alpine
            foreach($platform in @('Linux','Windows')){
                $profile=$profiles[$platform]
                $profile.Binary | Should -BeExactly $Binary
                $profile.Status | Should -BeExactly Prepared
                $profile.BuildValidated | Should -BeFalse
                $profile.Packages.Count | Should -BeGreaterThan 0
                foreach($pin in $profile.Packages){
                    $parts=$pin.Split('=',2)
                    $parts.Count | Should -Be 2
                    $parts[1] | Should -BeExactly $versions[$platform][$parts[0]]
                    $parts[1] | Should -Not -BeNullOrEmpty
                }
                if($Key -eq 'Git'){$profile.Packages | Should -Be @('git='+$versions[$platform].git)}
                else{$profile.Package | Should -BeExactly $Package}
            }
        }
    }

    It 'keeps Unix userland binaries in the Git Windows distribution for <Key>' -ForEach @(
        @{Key='Cat';Binary='cat'},@{Key='Grep';Binary='grep'},@{Key='Find';Binary='find'},@{Key='Wc';Binary='wc'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Key=$Key;Binary=$Binary} {
            param($Key,$Binary)
            $profile=(Get-MutatorContainerProfile $Key $Binary).Windows
            $profile.Method | Should -BeExactly Chocolatey
            $profile.Binary | Should -BeExactly $Binary
            $version=(Read-MutatorJson (Join-Path $script:MutatorRoot 'resources/containers/definitions/package-versions.json')).Windows.git
            $profile.Packages | Should -Be @('git='+$version)
        }
    }

    It 'does not invent a native binary for infrastructure <Key>' -ForEach @(
        @{Key='Engine'},@{Key='Utility.Agent'},@{Key='Utility.Filters'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Key=$Key} {
            param($Key)
            $profiles=Get-MutatorContainerProfile $Key ignored
            foreach($platform in @('Linux','Windows')){
                $profiles[$platform].Method | Should -BeExactly None
                $profiles[$platform].Binary | Should -BeNullOrEmpty
                $profiles[$platform].Status | Should -BeExactly Prepared
                $profiles[$platform].BuildValidated | Should -BeFalse
            }
        }
    }

    It 'requires Debian for systemd clients without claiming a running systemd host: <Key>' -ForEach @(
        @{Key='Journalctl';Binary='journalctl'},@{Key='Systemctl';Binary='systemctl'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Key=$Key;Binary=$Binary} {
            param($Key,$Binary)
            $profiles=Get-MutatorContainerProfile $Key $Binary
            $profiles.Linux.Method | Should -BeExactly Apt
            $profiles.Linux.Distribution | Should -BeExactly Debian
            $profiles.Linux.Packages | Should -Be @('systemd')
            $profiles.Linux.Binary | Should -BeExactly $Binary
            $profiles.Linux.Constraints | Should -Match 'no systemd PID 1'
            $profiles.Windows.Method | Should -BeExactly Unsupported
            $profiles.Windows.Status | Should -BeExactly Unsupported
            $profiles.Windows.Reason | Should -Match 'no native Windows'
        }
    }

    It 'keeps browser and native Node tooling on glibc: <Key>' -ForEach @(@{Key='Playwright'},@{Key='Gt'}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Key=$Key} {
            param($Key)
            $profile=(Get-MutatorContainerProfile $Key $Key.ToLowerInvariant()).Linux
            $profile.Distribution | Should -BeExactly Debian
            $profile.Method | Should -BeExactly Npm
            $profile.Packages | Should -Be @('python3','build-essential','git')
            $node=(Read-MutatorJson (Join-Path $script:MutatorRoot 'resources/containers/definitions/package-versions.json')).Linux.nodejs -replace '-r\d+$',''
            $profile.NodeVersion | Should -BeExactly $node
            if($Key -eq 'Playwright'){$profile.Constraints | Should -BeExactly 'CLI installed on Debian; browser downloads remain a separate explicit build/run step.'}
        }
    }

    It 'refuses an unknown tool before claiming an installation profile' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            {Get-MutatorContainerProfile NotARegisteredTool missing} | Should -Throw '*Missing explicit Linux installer*'
        }
    }

    It 'preserves the reviewed installation recipe for <Key> on <Platform>' -ForEach @(
        @{Key='Ag';Platform='Windows';Expected=@{Method='AgWindows';Binary='ag';Sha256='02EAA63C03A291E391415705A463D6A4E1D5D99C8E3C8A2E5BD050616425E1BC';BinarySha256='6AA8F7AEAAD158841462119727EC7FAD287624D826913AC7EC0199B89074CD0D'}}
        @{Key='Tree';Platform='Windows';Expected=@{Method='None';Binary='tree'}}
        @{Key='Ping';Platform='Windows';Expected=@{Method='None';Binary='ping'}}
        @{Key='Psql';Platform='Windows';Expected=@{Method='Artifact';Binary='psql';Format='zip';Status='NeedsArtifact'}}
        @{Key='Swift';Platform='Windows';Expected=@{Method='Artifact';Binary='swift';Format='zip';Status='NeedsArtifact'}}
        @{Key='Swift';Platform='Linux';Expected=@{Method='None';Binary='swift';Distribution='Debian';BaseImage='docker.io/library/swift:6.4.1-bookworm'}}
        @{Key='Gcloud';Platform='Linux';Expected=@{Method='Artifact';Binary='gcloud';Format='tar.gz';Status='NeedsArtifact'}}
        @{Key='Bun';Platform='Linux';Expected=@{Method='Release';Binary='bun';Repository='oven-sh/bun';AssetPattern='^bun-linux-x64-musl\.zip$';Format='zip'}}
        @{Key='Jj';Platform='Windows';Expected=@{Method='Release';Binary='jj';Repository='jj-vcs/jj';AssetPattern='x86_64-pc-windows-msvc\.zip$';Format='zip'}}
        @{Key='Trunk';Platform='Windows';Expected=@{Method='Release';Binary='trunk';Repository='trunk-rs/trunk';AssetPattern='x86_64-pc-windows-msvc\.zip$';Format='zip'}}
        @{Key='Sbt';Platform='Linux';Expected=@{Method='Release';Binary='sbt';Repository='sbt/sbt';AssetPattern='^sbt-[0-9.]+\.tgz$';Format='tar.gz'}}
        @{Key='Liquibase';Platform='Linux';Expected=@{Method='Release';Binary='liquibase';Repository='liquibase/liquibase';AssetPattern='^liquibase-[0-9.]+\.tar\.gz$';Format='tar.gz'}}
        @{Key='Hadolint';Platform='Linux';Expected=@{Method='ImageCopy';Binary='hadolint';SourcePath='/bin/hadolint'}}
        @{Key='Terraform';Platform='Linux';Expected=@{Method='Hashicorp';Binary='terraform';Format='zip'}}
        @{Key='Brew';Platform='Linux';Expected=@{Method='Homebrew';Binary='brew';Distribution='Debian';User='linuxbrew';Packages=@('build-essential','procps','curl','file','git','bash','util-linux')}}
        @{Key='Quarto';Platform='Linux';Expected=@{Method='Release';Binary='quarto';Distribution='Debian';Repository='quarto-dev/quarto-cli';AssetPattern='^quarto-[0-9.]+-linux-amd64\.tar\.gz$';Format='tar.gz';Packages=@('python3','libglib2.0-0','libnss3','libasound2')}}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Key=$Key;Platform=$Platform;Expected=$Expected} {
            param($Key,$Platform,$Expected)
            $profile=(Get-MutatorContainerProfile $Key $Key.ToLowerInvariant())[$Platform]
            foreach($property in $Expected.Keys){$profile[$property] | Should -Be $Expected[$property] -Because "$Key/$Platform requires $property"}
            $profile.BuildValidated | Should -BeFalse
            if($profile.Method -eq 'Artifact'){$profile.Reason | Should -Match 'SHA256'}
            $versions=Read-MutatorJson (Join-Path $script:MutatorRoot 'resources/containers/definitions/package-versions.json')
            switch($Key){
                Hadolint {$profile.SourceImage | Should -BeExactly ('docker.io/hadolint/hadolint:'+$versions.Windows.hadolint+'-alpine')}
                Terraform {$profile.Version | Should -BeExactly $versions.Windows.terraform}
                Brew {$profile.BootstrapSha256 | Should -BeExactly $versions.Sources.HomebrewBootstrapSHA256}
            }
        }
    }

    It 'uses php as the launcher and pins matching PHP sources for <Key>' -ForEach @(@{Key='Artisan'},@{Key='Phpt'}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Key=$Key} {
            param($Key)
            $profiles=Get-MutatorContainerProfile $Key ignored
            $versions=Read-MutatorJson (Join-Path $script:MutatorRoot 'resources/containers/definitions/package-versions.json')
            foreach($platform in @('Linux','Windows')){
                $profiles[$platform].Method | Should -BeExactly $Key
                $profiles[$platform].Binary | Should -BeExactly php
                $profiles[$platform].Packages.Count | Should -BeGreaterThan 0
                $profiles[$platform].Constraints | Should -Match 'php|PHP'
            }
            if($Key -eq 'Phpt'){
                $profiles.Linux.PhpSourceRef | Should -BeExactly ('php-'+($versions.Linux.php85 -replace '-r\d+$',''))
                $profiles.Windows.PhpSourceRef | Should -BeExactly ('php-'+$versions.Windows.php)
            }
        }
    }

    It 'rejects Apple-only tools on both Linux and Windows' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $profiles=Get-MutatorContainerProfile Xcodebuild xcodebuild
            foreach($platform in @('Linux','Windows')){
                $profiles[$platform].Method | Should -BeExactly Unsupported
                $profiles[$platform].Status | Should -BeExactly Unsupported
                $profiles[$platform].Reason | Should -BeExactly 'xcodebuild is part of Apple Xcode and requires macOS.'
            }
        }
    }

    It 'rejects a package without a verified version before producing an install plan' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            Mock Read-MutatorJson { @{Linux=@{};Windows=@{}} }
            {Get-MutatorContainerProfile Git git} | Should -Throw '*No verified Linux package version for git (Git)*'
        }
    }
}
