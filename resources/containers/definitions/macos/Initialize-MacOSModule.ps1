#requires -Version 7.6
param([string]$Root='/usr/local/lib/mutator',[string]$Share='/Volumes/shared/mutator',
    [string]$SharedVolume='/Volumes/shared',[ValidateRange(0,3600)][int]$WaitTimeoutSeconds=600)
$ErrorActionPreference='Stop'
if(!(Get-Command Invoke-MacOSBootstrapCommand -CommandType Function -ErrorAction Ignore)){. (Join-Path $PSScriptRoot 'Invoke-MacOSBootstrapCommand.ps1')}
if(!(Test-Path $SharedVolume)){if((Invoke-MacOSBootstrapCommand -FilePath /sbin/mount_9p -Arguments @('shared')) -ne 0){throw 'Cannot mount the module payload.'}}
$base=Get-Content (Join-Path $root 'base-ready.json') -Raw|ConvertFrom-Json -AsHashtable
$deadline=[datetime]::UtcNow.AddSeconds($WaitTimeoutSeconds)
while(!(Test-Path (Join-Path $share 'image.json'))){if([datetime]::UtcNow -gt $deadline){throw 'No module payload.'};Start-Sleep -Seconds 3}
$metadata=Get-Content (Join-Path $share 'image.json') -Raw|ConvertFrom-Json -AsHashtable
if($metadata.MacBaseFingerprint -cne $base.Fingerprint){throw 'The macOS base fingerprint differs.'}
$identity=(Get-FileHash (Join-Path $share 'image.json')).Hash+'-'+(Get-FileHash (Join-Path $share 'tool-inputs.txt')).Hash
$receipt=Join-Path $root 'module-ready.json'
if(Test-Path $receipt){$old=Get-Content $receipt -Raw|ConvertFrom-Json -AsHashtable;if($old.Identity -ceq $identity){return}}
try{
    foreach($part in @('bootstrap','modules')){Copy-Item -LiteralPath (Join-Path $share $part) -Destination $root -Recurse -Force}
    Copy-Item -LiteralPath (Join-Path $share 'image.json') -Destination $root -Force
    $values=[IO.File]::ReadAllLines((Join-Path $share 'tool-inputs.txt'));if($values.Count -ne 3){throw 'Invalid module input file.'}
    if((Invoke-MacOSBootstrapCommand -FilePath /usr/sbin/chown -Arguments @('-R',($base.ProvisioningUser+':staff'),$root)) -ne 0){throw 'Cannot set module ownership.'}
    $environment=@(('TOOL_VERSION='+$values[0]),('TOOL_URL='+$values[1]),('TOOL_SHA256='+$values[2]))
    $arguments=@('-H','-u',$base.ProvisioningUser,'/usr/bin/env')+$environment+@('/usr/local/bin/pwsh','-NoLogo','-NoProfile','-File',(Join-Path $root 'bootstrap/Install-ImageTool.ps1'),'-Platform','MacOS','-Root',$root)
    if((Invoke-MacOSBootstrapCommand -FilePath /usr/bin/sudo -Arguments $arguments -LogPath (Join-Path $root 'module-install.log')) -ne 0){throw 'macOS tool installation failed; see module-install.log.'}
    $proof=@{Module=$metadata.Module;Outcome='Success';Identity=$identity;BaseFingerprint=$base.Fingerprint;InstalledUtc=[datetime]::UtcNow.ToString('O')}
    [IO.File]::WriteAllText($receipt,($proof|ConvertTo-Json));Copy-Item -LiteralPath $receipt -Destination $share -Force
}catch{[IO.File]::WriteAllText((Join-Path $root 'module-failed.json'),(@{Module=$metadata.Module;Outcome='Failed';Error=$_.Exception.Message}|ConvertTo-Json));Copy-Item -LiteralPath (Join-Path $root 'module-failed.json') -Destination $share -Force;throw}
