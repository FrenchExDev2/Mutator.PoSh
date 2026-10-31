#requires -Version 7.6
param()
# Entrypoint arguments belong to the launched application. A named Command
# parameter would consume pwsh's own -Command option before forwarding it.
$command=@($args)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
. (Join-Path $PSScriptRoot 'Environment.ps1')
Set-ImageToolEnvironment $root
if(!$command.Count){$command=@('pwsh','-NoLogo','-NoProfile')}
$application=Get-Command -Name $command[0] -CommandType Application -ErrorAction Stop | Select-Object -First 1
$arguments=if($command.Count -gt 1){@($command[1..($command.Count-1)])}else{@()}
& $application.Source @arguments
exit $LASTEXITCODE
