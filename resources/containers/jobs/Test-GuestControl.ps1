#requires -Version 7.6
param([Parameter(Mandatory)][string]$Owner)
$ErrorActionPreference='Stop'
$last=$null
for($attempt=0;$attempt -lt 20;$attempt++){
    try{
        $status=Invoke-RestMethod 'http://127.0.0.1:8765/health' -TimeoutSec 2 -NoProxy
        if($status.RunId -cne $Owner -or !$status.Ready -or [version]$status.PowerShell -lt [version]'7.6'){throw 'The guest control endpoint has a foreign owner or runtime.'}
        return
    }catch{$last=$_.Exception.Message;Start-Sleep -Milliseconds 250}
}
throw ('The PowerShell guest controller did not become healthy: '+$last)
