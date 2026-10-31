#requires -Version 7.6
param([Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$root=Split-Path (Split-Path $PSScriptRoot)
Import-Module (Join-Path $root 'FrenchExDev.Mutator.PoSh.psd1') -DisableNameChecking
$proof=Join-Path $root ('test/Artifacts/rechecks/devposh-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
trap {
    $failure=@{Mode='Recheck';Outcome='Failed';Error=$_.Exception.Message;ErrorId=$_.FullyQualifiedErrorId;Stack=$_.ScriptStackTrace;Proof=$proof}
    if(Test-Path -LiteralPath $proof){$failure|ConvertTo-Json -Depth 5|Set-Content (Join-Path $proof 'launcher-error.json')}
    $failure|ConvertTo-Json -Depth 5 -Compress
    exit 1
}
@{Mode='Recheck';Phase='Starting';Proof=$proof}|ConvertTo-Json -Compress
$result=Invoke-MutatorRecheck -ModulePath (Join-Path (Split-Path $root) 'FrenchExDev.DevPoSh.PoSh') -ReportPath $ReportPath -OutputDirectory $proof
$result|Select-Object Mode,Outcome,Rechecked,NowKilled,Survived,FullGateSatisfied,Error,Proof,Report|ConvertTo-Json -Depth 4 -Compress
if($result.Outcome -eq 'Failed'){exit 1}
