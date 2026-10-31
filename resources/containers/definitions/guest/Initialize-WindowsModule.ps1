#requires -Version 7.6
# Runs inside a cloned Windows guest. The common Windows/runtime base is already installed.
param(
    [string]$Root='C:\mutator',
    [string]$Share='\\host.lan\Data\mutator',
    [string]$PowerShellExecutable=(Join-Path $PSHOME 'pwsh.exe'),
    [ValidateSet('Machine','Process')][string]$EnvironmentTarget='Machine',
    [ValidateRange(0,86400)][int]$WaitTimeoutSeconds=600
)
$ErrorActionPreference='Stop'
$base=Get-Content (Join-Path $root 'base-ready.json') -Raw|ConvertFrom-Json -AsHashtable
$deadline=[datetime]::UtcNow.AddSeconds($WaitTimeoutSeconds)
while(!(Test-Path (Join-Path $share 'image.json'))){
    if([datetime]::UtcNow -ge $deadline){throw 'The module payload is not available on the dockurr shared folder.'}
    Start-Sleep -Seconds 3
}
$metadata=Get-Content (Join-Path $share 'image.json') -Raw|ConvertFrom-Json -AsHashtable
if($metadata.BaseFingerprint -cne $base.Fingerprint){throw 'The module and prepared Windows base fingerprints differ.'}
$identity=(Get-FileHash (Join-Path $share 'image.json')).Hash+'-'+(Get-FileHash (Join-Path $share 'tool-inputs.txt')).Hash
$receipt=Join-Path $root 'module-ready.json'
if(Test-Path $receipt){$previous=Get-Content $receipt -Raw|ConvertFrom-Json -AsHashtable;if($previous.Identity -ceq $identity){return}}
try{
    foreach($name in @('bootstrap','modules')){Copy-Item -LiteralPath (Join-Path $share $name) -Destination $root -Recurse -Force}
    Copy-Item -LiteralPath (Join-Path $share 'image.json') -Destination $root -Force
    $values=[IO.File]::ReadAllLines((Join-Path $share 'tool-inputs.txt'))
    if($values.Count -ne 3){throw 'Invalid module tool input file.'}
    $env:TOOL_VERSION=$values[0];$env:TOOL_URL=$values[1];$env:TOOL_SHA256=$values[2]
    & $PowerShellExecutable -NoLogo -NoProfile -File (Join-Path $root 'bootstrap/Install-ImageTool.ps1') -Platform Windows -Root $root *> (Join-Path $root 'module-install.log')
    if($LASTEXITCODE -ne 0){throw 'Module tool installation failed; see module-install.log in the guest.'}
    [Environment]::SetEnvironmentVariable('MUTATOR_MODULE',$metadata.Module,$EnvironmentTarget)
    $proof=@{Module=$metadata.Module;Identity=$identity;Outcome='Success';BaseFingerprint=$base.Fingerprint;InstalledUtc=[datetime]::UtcNow.ToString('O')}
    [IO.File]::WriteAllText($receipt,($proof|ConvertTo-Json))
    Copy-Item -LiteralPath $receipt -Destination (Join-Path $share 'module-ready.json') -Force
}catch{
    $failure=$_
    [IO.File]::WriteAllText((Join-Path $root 'module-failed.json'),(@{Module=$metadata.Module;Outcome='Failed';Error=$failure.Exception.Message}|ConvertTo-Json))
    try{Copy-Item -LiteralPath (Join-Path $root 'module-failed.json') -Destination (Join-Path $share 'module-failed.json') -Force -ErrorAction Stop}catch{Write-Verbose ('Module failure retained locally: '+$_.Exception.Message)}
    throw $failure
}
