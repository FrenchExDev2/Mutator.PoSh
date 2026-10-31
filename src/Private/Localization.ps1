function Get-MutatorLanguage {
    <#
    .SYNOPSIS
    Select the available localization catalog from MUTATOR_LANG.

    .DESCRIPTION
    Defaults to French and falls back to English for invalid or unsupported values. Does not change
    process UI culture.
    #>

    $value=[Environment]::GetEnvironmentVariable('MUTATOR_LANG')
    if([string]::IsNullOrWhiteSpace($value)){return 'fr-FR'}
    try{$culture=[Globalization.CultureInfo]::CreateSpecificCulture($value.Trim())}catch{return 'en-US'}
    if(Test-Path -LiteralPath (Join-Path $script:MutatorRoot ('resources/localization/'+$culture.Name+'.psd1'))){return $culture.Name}
    if($culture.TwoLetterISOLanguageName -eq 'fr'){return 'fr-FR'}
    'en-US'
}

function Get-MutatorText {
    <#
    .SYNOPSIS
    Read and format a required localized message.

    .DESCRIPTION
    Caches catalogs by language and applies formatting arguments. Missing keys throw instead of
    returning incomplete labels.
    #>

    param([Parameter(Mandatory)][string]$Key,[object[]]$ArgumentList=@())
    $language=Get-MutatorLanguage
    if(!$script:MutatorMessageCatalog.ContainsKey($language)){
        $script:MutatorMessageCatalog[$language]=Import-PowerShellDataFile -LiteralPath (Join-Path $script:MutatorRoot ('resources/localization/'+$language+'.psd1'))
    }
    $catalog=$script:MutatorMessageCatalog[$language]
    if(!$catalog.ContainsKey($Key)){throw "Missing Mutator translation: $language / $Key"}
    $text=[string]$catalog[$Key]
    if($ArgumentList.Count){return $text -f $ArgumentList}
    $text
}
