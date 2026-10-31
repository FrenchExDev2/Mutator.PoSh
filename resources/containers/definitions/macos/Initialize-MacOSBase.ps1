#requires -Version 7.6
param([Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$ProvisioningUser,[string]$SharedRoot='/Volumes/shared/mutator',
    [string]$Root='/usr/local/lib/mutator',[string]$ProtectedRoot='/Library/Application Support/FrenchExDev',
    [string]$LaunchDaemonDirectory='/Library/LaunchDaemons')
$ErrorActionPreference='Stop'
if(!(Get-Command Invoke-MacOSBootstrapCommand -CommandType Function -ErrorAction Ignore)){. (Join-Path $PSScriptRoot 'Invoke-MacOSBootstrapCommand.ps1')}
$metadata=Get-Content (Join-Path $SharedRoot 'runtime.json') -Raw|ConvertFrom-Json -AsHashtable
if($PSVersionTable.PSVersion.ToString() -cne $metadata.PowerShell.Version){throw 'The installed PowerShell version does not match the prepared base.'}
[void][IO.Directory]::CreateDirectory((Join-Path $root 'workload'))
Copy-Item -LiteralPath (Join-Path $SharedRoot 'bootstrap') -Destination $root -Recurse -Force
& (Join-Path $root 'bootstrap/Initialize-Image.ps1')
$env:PATH='/usr/local/share/dotnet:/usr/local/bin:'+$env:PATH
$null=Get-Command dotnet -CommandType Application -ErrorAction Stop
$protected=$ProtectedRoot
[void][IO.Directory]::CreateDirectory($protected)
Copy-Item -LiteralPath (Join-Path $SharedRoot 'Initialize-MacOSModule.ps1') -Destination $protected -Force
Copy-Item -LiteralPath (Join-Path $SharedRoot 'Invoke-MacOSBootstrapCommand.ps1') -Destination $protected -Force
$proof=@{Outcome='Success';Fingerprint=$metadata.Fingerprint;ProvisioningUser=$ProvisioningUser;PowerShell=$PSVersionTable.PSVersion.ToString();InstalledUtc=[datetime]::UtcNow.ToString('O')}
[IO.File]::WriteAllText((Join-Path $root 'base-ready.json'),($proof|ConvertTo-Json))
$plist=@'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.frenchexdev.mutator.module</string><key>ProgramArguments</key><array><string>/usr/local/bin/pwsh</string><string>-NoProfile</string><string>-File</string><string>/Library/Application Support/FrenchExDev/Initialize-MacOSModule.ps1</string></array><key>RunAtLoad</key><true/><key>StandardOutPath</key><string>/usr/local/lib/mutator/module-agent.stdout.log</string><key>StandardErrorPath</key><string>/usr/local/lib/mutator/module-agent.stderr.log</string></dict></plist>
'@
$plist=$plist.Replace('/Library/Application Support/FrenchExDev/Initialize-MacOSModule.ps1',[Security.SecurityElement]::Escape((Join-Path $protected 'Initialize-MacOSModule.ps1')))
$plist=$plist.Replace('/usr/local/lib/mutator/module-agent.stdout.log',[Security.SecurityElement]::Escape((Join-Path $root 'module-agent.stdout.log')))
$plist=$plist.Replace('/usr/local/lib/mutator/module-agent.stderr.log',[Security.SecurityElement]::Escape((Join-Path $root 'module-agent.stderr.log')))
[void][IO.Directory]::CreateDirectory($LaunchDaemonDirectory)
[IO.File]::WriteAllText((Join-Path $LaunchDaemonDirectory 'com.frenchexdev.mutator.module.plist'),$plist)
if((Invoke-MacOSBootstrapCommand -FilePath /usr/sbin/chown -Arguments @('-R',($ProvisioningUser+':staff'),$root)) -ne 0){throw 'Cannot set the module workspace owner.'}
Copy-Item -LiteralPath (Join-Path $root 'base-ready.json') -Destination (Join-Path (Split-Path $SharedRoot) 'base-ready.json') -Force
