function New-MutatorContext {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Pure context factory: reads fingerprints and returns data without changing system state.')]
    [CmdletBinding()]
    param([string]$SourceRoot, [string[]]$Subtrees, [string]$ConfigurationPath, [object]$Tool, [string]$ContainerImageId)
    $dependencies = foreach ($entry in $Subtrees) {
        $snapshot = Get-MutatorSourceSnapshot (Join-Path $SourceRoot $entry)
        [ordered]@{ Path = $entry; Sha256 = $snapshot.Sha256 }
    }
    $pester = Get-Module Pester | Select-Object -First 1
    if (!$pester) { throw 'Pester must be imported before capturing a mutation context.' }
    $identity = [ordered]@{ SchemaVersion = 1; Runtime = $PSVersionTable.PSVersion.ToString(); OS = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        Framework = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription; Architecture = [string][Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
        ConfigurationSha256 = (Get-FileHash -LiteralPath $ConfigurationPath).Hash
        Dependencies = @($dependencies); Tool = $Tool; PesterVersion = [string]$pester.Version
        PesterSha256 = (Get-MutatorSourceSnapshot $pester.ModuleBase).Sha256 }
    # Absolute cache paths must not determine identity; executable bytes and tool options do.
    $identity.Tool = [ordered]@{ Version = $Tool.Version; SourceHashes = @($Tool.SourceHashes); AdapterSha256 = $Tool.AdapterSha256; FilesSha256 = (Get-MutatorSourceSnapshot (Split-Path $Tool.Path)).Sha256 }
    if ($ContainerImageId) { $identity['ContainerImageId'] = $ContainerImageId }
    $json = $identity | ConvertTo-Json -Depth 10 -Compress
    @{ Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))); Identity = $identity }
}
