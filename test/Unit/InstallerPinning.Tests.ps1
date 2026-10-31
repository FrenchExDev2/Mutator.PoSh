BeforeAll {$script:InstallerPath=Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'resources/containers/definitions/bootstrap/Install-ImageTool.ps1'}
Describe 'Installer pinning before network or native commands' {
    It 'rejects missing version pins for <Method>' -ForEach @(@{Method='Go'},@{Method='Phpt'},@{Method='Release'},@{Method='Hashicorp'},@{Method='Artisan'}) {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
        @{Module='Fixture';Platforms=@{Linux=@{Method=$Method;Binary=$null;Packages=@()}}}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $root 'image.json')
        $saved=@{};foreach($name in @('TOOL_VERSION','TOOL_URL','TOOL_SHA256')){$saved[$name]=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,$null)}
        $scope=New-Module -Name MutatorPinningFixture -ScriptBlock {
            function Invoke-WebRequest {throw 'Unexpected download before pin validation'}
            function Invoke-RestMethod {throw 'Unexpected API request before pin validation'}
            function Invoke-Probe {param($Path,$Root);& $Path -Platform Linux -Root $Root}
            Export-ModuleMember Invoke-Probe
        }
        try{ {& $scope {param($Path,$Root) Invoke-Probe $Path $Root} $script:InstallerPath $root}|Should -Throw '*Pinned TOOL_VERSION*' }
        finally{foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])};Remove-Module $scope}
        Test-Path (Join-Path $root 'installed-tool.json')|Should -BeFalse
    }
}
