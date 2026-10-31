# Objectif : Préparer PowerShell Core dans Windows Sandbox puis lancer le worker sans accès réseau.
#requires -Version 7.6
#requires -PSEdition Core
$ErrorActionPreference='Stop'
try {
    if(Test-Path -LiteralPath 'C:\MutatorRun\stop.json'){throw 'Stopped before runtime preparation.'}
    Copy-Item -LiteralPath 'C:\MutatorPayload\tools' -Destination 'C:\MutatorTools' -Recurse
    & 'C:\MutatorTools\pwsh\pwsh.exe' -NoLogo -NoProfile -NonInteractive -File 'C:\MutatorPayload\Invoke-Worker.ps1' 1>'C:\MutatorRun\worker.stdout.log' 2>'C:\MutatorRun\worker.stderr.log'
    if($LASTEXITCODE -ne 0){throw "PowerShell Core worker exited with code $LASTEXITCODE."}
    exit 0
} catch {
    @{Message=$_.Exception.Message;Utc=[datetime]::UtcNow.ToString('O')}|ConvertTo-Json -Compress|Set-Content -LiteralPath 'C:\MutatorRun\bootstrap-failure.json' -Encoding UTF8
    exit 1
}
