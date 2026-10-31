#requires -Version 7.6
param([Parameter(Mandatory)][string]$Platform,[Parameter(Mandatory)][string]$Root)
$ErrorActionPreference='Stop'
# The immutable base startup task calls this staged adapter. Keep its original
# installer unchanged and start the owned test worker only after installation.
& (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Install-ImageTool.Original.ps1') -Platform $Platform -Root $Root
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
$worker=Join-Path $PSScriptRoot 'Invoke-GuestJobs.ps1'
$action=New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'pwsh.exe') -Argument ('-NoLogo -NoProfile -NonInteractive -File "'+$worker+'"')
$trigger=New-ScheduledTaskTrigger -AtStartup
$principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::Zero)
$null=Register-ScheduledTask -TaskName Mutator-GuestJobs -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
Start-ScheduledTask -TaskName Mutator-GuestJobs
