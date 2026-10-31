function Get-MutatorEngineConfigurationPath {
    <#
    .SYNOPSIS
    Resolve the Mutator engine configuration path.

    .DESCRIPTION
    Uses MUTATOR_CONFIG_PATH when supplied, otherwise the user's .mutator/config.yaml path. Does not
    read or create it.
    #>

    $path=[Environment]::GetEnvironmentVariable('MUTATOR_CONFIG_PATH')
    if($path){return $path}
    Join-Path $HOME '.mutator/config.yaml'
}

function Import-MutatorConfigurationYaml {
    <#
    .SYNOPSIS
    Load the YAML runtime supplied by the active QuietCli engine.

    .DESCRIPTION
    Reuses its YamlDotNet assembly to avoid binding compiled helpers to incompatible YAML library
    versions.
    #>

    # Use the library already distributed with our engine. Loading powershell-yaml
    # as well binds its compiled helpers to a different YamlDotNet assembly.
    Import-MutatorQuietCli
}

function Read-MutatorYamlDocument {
    <#
    .SYNOPSIS
    Read YAML with duplicate-key checking and typed scalar conversion.

    .DESCRIPTION
    Normalizes parsed values into PowerShell mappings while preserving date strings. Empty documents
    return an empty ordered mapping.
    #>

    param([string]$Path)
    Import-MutatorConfigurationYaml
    $text=[IO.File]::ReadAllText($Path)
    if([string]::IsNullOrWhiteSpace($text)){return ,([ordered]@{})}
    $value=[YamlDotNet.Serialization.DeserializerBuilder]::new().WithDuplicateKeyChecking().WithAttemptingUnquotedStringTypeDeserialization().Build().Deserialize[object]($text)
    # Normalize dictionaries to PowerShell mappings without interpreting date strings.
    return ,($value|ConvertTo-Json -Depth 100 -Compress|ConvertFrom-Json -AsHashtable -DateKind String)
}

function Read-MutatorEngineConfiguration {
    <#
    .SYNOPSIS
    Read and validate the top-level engine configuration.

    .DESCRIPTION
    Missing files return an empty mapping. Existing documents must contain only the canonical docker and
    podman sections.
    #>

    param([string]$Path)
    if(!(Test-Path -LiteralPath $Path)){return @{}}
    $document=Read-MutatorYamlDocument $Path
    if($document -isnot [Collections.IDictionary]){throw 'Configuration must be a mapping of sections.'}
    foreach($key in $document.get_Keys()){if($key -cnotin @('docker','podman')){throw "Unknown Mutator configuration section: $key"}}
    $document
}

function Write-MutatorEngineConfiguration {
    <#
    .SYNOPSIS
    Persist settings through a temporary YAML file and atomic replacement.

    .DESCRIPTION
    Uses the shared YAML runtime and UTF-8 without a BOM. Cleans up the temporary file even when
    replacement fails.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private atomic persistence runs inside the public configuration or migration ShouldProcess boundary.')]
    [CmdletBinding()]
    param([string]$Path,[Collections.IDictionary]$Document)
    Import-MutatorConfigurationYaml
    # JSON is a YAML subset and gives the serializer ordinary CLR dictionaries,
    # arrays and typed scalars instead of PowerShell wrappers.
    $plain=[YamlDotNet.Serialization.DeserializerBuilder]::new().WithAttemptingUnquotedStringTypeDeserialization().Build().Deserialize[object](($Document|ConvertTo-Json -Depth 100 -Compress))
    $text=[YamlDotNet.Serialization.SerializerBuilder]::new().Build().Serialize($plain)
    [void][IO.Directory]::CreateDirectory((Split-Path $Path))
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,$text,[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$Path,$true)
    }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
}

function ConvertTo-MutatorEngineSetting {
    <#
    .SYNOPSIS
    Normalize and validate one engine configuration section.

    .DESCRIPTION
    Supplies defaults and rejects unknown keys, non-Boolean flags and invalid endpoints. Returns a
    canonical setting object.
    #>

    param([string]$Name,[object]$Section)
    $setting=@{pipe=$null;enabled=$true;default=$false}
    if($null -ne $Section){
        if($Section -isnot [Collections.IDictionary]){throw "$Name must be a mapping."}
        foreach($key in $Section.get_Keys()){
            if($key -cnotin @('pipe','enabled','default')){throw "Unknown $Name setting: $key"}
            $setting[$key]=$Section[$key]
        }
    }
    if($setting.enabled -isnot [bool]){throw "$Name.enabled must be true or false."}
    if($setting.default -isnot [bool]){throw "$Name.default must be true or false."}
    if($null -ne $setting.pipe -and ($setting.pipe -isnot [string] -or [string]::IsNullOrWhiteSpace($setting.pipe))){throw "$Name.pipe must be a nonempty endpoint string or null."}
    [pscustomobject]@{Name=$Name;Pipe=$setting.pipe;Enabled=$setting.enabled;Default=$setting.default}
}

function Assert-MutatorEngineDefault {
    <#
    .SYNOPSIS
    Require at most one enabled default engine.

    .DESCRIPTION
    Throws for multiple defaults or a disabled default. A configuration without an explicit default is
    allowed.
    #>

    param([object[]]$Setting)
    $defaults=@($Setting|Where-Object Default)
    if($defaults.Count -gt 1){throw 'Only one container engine can have default: true.'}
    if($defaults.Count -eq 1 -and !$defaults[0].Enabled){throw 'The default container engine must be enabled.'}
}

