function Protect-MutatorDiagnostic {
    <#
    .SYNOPSIS
    Mask secrets before delivering a bounded diagnostic message.

    .DESCRIPTION
    Uses QuietCli protection before truncating to 2048 characters. Failed masking returns a closed
    notice rather than the original text.
    #>

    param([AllowNull()][string]$Message)
    if(!$Message){return $Message}
    try{
        Import-MutatorQuietCli
        $protection=@{Limited=$false;Redacted=$false}
        $masked=FrenchExDev.QuietCli.PoSh\Protect-QuietValue -Value $Message -State $protection
        if($protection.Limited -or $masked -isnot [string]){throw [InvalidOperationException]::new('QuietCli masking was incomplete.')}
        if($masked.Length -gt 2048){return $masked.Substring(0,2048)+'...'}
        $masked
    }catch{return "[Diagnostic retained in its local report; masking unavailable: $($_.Exception.GetType().Name).]"}
}
