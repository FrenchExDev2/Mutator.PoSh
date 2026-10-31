<#
.SYNOPSIS
Expected behavior for the InstallerPinning tests.

.DESCRIPTION
Missing installer version pins must be rejected before any download or release API request.
Download/API sentinels deliberately fail if validation happens too late.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {$script:InstallerPath=Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'resources/containers/definitions/bootstrap/Install-ImageTool.ps1'}
Describe 'Installer pinning before network or native commands' {
    It 'rejects missing version pins for <Method>' -ForEach @(@{Method='Go'},@{Method='Phpt'},@{Method='Release'},@{Method='Hashicorp'},@{Method='Artisan'}) {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
        @{Module='Fixture';Platforms=@{Linux=@{Method=$Method;Binary=$null;Packages=@()}}}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $root 'image.json')
        $saved=@{};foreach($name in @('TOOL_VERSION','TOOL_URL','TOOL_SHA256')){$saved[$name]=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,$null)}
        $scope=New-Module -Name MutatorPinningFixture -ScriptBlock {
            function Invoke-WebRequest {
                <#
                .SYNOPSIS
                Fail if an unvalidated installer attempts a download.

                .DESCRIPTION
                This test sentinel proves pin validation happens before network access; any invocation is an
                unexpected test failure.
                #>
                throw 'Unexpected download before pin validation'}
            function Invoke-RestMethod {
                <#
                .SYNOPSIS
                Fail if an unvalidated installer attempts an API request.

                .DESCRIPTION
                This test sentinel proves missing pins are rejected before release discovery or other network
                access.
                #>
                throw 'Unexpected API request before pin validation'}
            function Invoke-Probe {
                <#
                .SYNOPSIS
                Execute the selected installer with the Linux fixture root.

                .DESCRIPTION
                Lets the pinning test assert rejection before the download/API sentinels can run.
                #>
                param($Path,$Root);& $Path -Platform Linux -Root $Root}
            Export-ModuleMember Invoke-Probe
        }
        try{ {& $scope {param($Path,$Root) Invoke-Probe $Path $Root} $script:InstallerPath $root}|Should -Throw '*Pinned TOOL_VERSION*' }
        finally{foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])};Remove-Module $scope}
        Test-Path (Join-Path $root 'installed-tool.json')|Should -BeFalse
    }
}
