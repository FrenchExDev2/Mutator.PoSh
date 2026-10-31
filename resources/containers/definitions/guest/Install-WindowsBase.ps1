#requires -Version 5.1
# dockurr runs this bootstrap only after Windows installation, inside the guest.
param(
    [string]$Root='C:\mutator',
    [string]$Source=(Join-Path $PSScriptRoot 'mutator'),
    [string]$Share='\\host.lan\Data',
    [string]$PowerShellDirectory='C:\Program Files\PowerShell\7',
    [string]$PowerShellExecutable,
    [string]$ValidationScript=(Join-Path $PSScriptRoot 'Test-WindowsBase.ps1'),
    [ValidateSet('Machine','Process')][string]$EnvironmentTarget='Machine'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[void][IO.Directory]::CreateDirectory($root)
$metadata=[pscustomobject]@{Module=$null}
function Write-BaseProgress {
    param([string]$Stage)
    $path=Join-Path $root 'base-progress.json'
    [IO.File]::WriteAllText($path,(@{Stage=$Stage;Utc=[datetime]::UtcNow.ToString('O')}|ConvertTo-Json))
    try{Copy-Item -LiteralPath $path -Destination (Join-Path $Share 'base-progress.json') -Force -ErrorAction Stop}catch{Write-Verbose ('Base progress retained locally: '+$_.Exception.Message)}
}
try{
Copy-Item -Path (Join-Path $source '*') -Destination $root -Recurse -Force
$metadata=Get-Content (Join-Path $root 'image.json') -Raw|ConvertFrom-Json
$runtime=$metadata.Runtime
$archive=Join-Path $root 'powershell.zip'
Write-BaseProgress 'DownloadingPowerShell'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -Uri $runtime.WindowsUri -OutFile $archive
if((Get-FileHash $archive).Hash -ne $runtime.WindowsSHA256){throw 'PowerShell guest archive SHA256 mismatch.'}
$destination=$PowerShellDirectory
[void][IO.Directory]::CreateDirectory($destination)
Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force
Remove-Item -LiteralPath $archive
$pwsh=if($PowerShellExecutable){$PowerShellExecutable}else{Join-Path $destination 'pwsh.exe'}
$separator=[IO.Path]::PathSeparator
$pathVariable=if($separator -eq ';'){'Path'}else{'PATH'}
$prefix=$destination+$separator+(Join-Path $root 'bin')+$separator
$env:PATH=$prefix+$env:PATH
[Environment]::SetEnvironmentVariable($pathVariable,$prefix+[Environment]::GetEnvironmentVariable($pathVariable,$EnvironmentTarget),$EnvironmentTarget)
[Environment]::SetEnvironmentVariable('MUTATOR_MODULE',$metadata.Module,$EnvironmentTarget)
$modulePaths=@((Join-Path $root 'modules'),(Join-Path (Split-Path $destination) 'Modules'),(Join-Path $destination 'Modules'),[Environment]::GetEnvironmentVariable('PSModulePath',$EnvironmentTarget))
[Environment]::SetEnvironmentVariable('PSModulePath',($modulePaths -join $separator),$EnvironmentTarget)
$env:PSModulePath=[Environment]::GetEnvironmentVariable('PSModulePath',$EnvironmentTarget)
$inputs=Join-Path $root 'tool-inputs.txt'
if(Test-Path -LiteralPath $inputs){
    $values=[IO.File]::ReadAllLines($inputs)
    if($values.Count -ne 3){throw 'Invalid guest tool input file.'}
    $env:TOOL_VERSION=$values[0];$env:TOOL_URL=$values[1];$env:TOOL_SHA256=$values[2]
}
$log=Join-Path $root 'guest-install.log'
    Write-BaseProgress 'InstallingPowerShellTools'
    & $pwsh -NoLogo -NoProfile -File (Join-Path $root 'bootstrap/Initialize-Image.ps1') *> $log
    if($LASTEXITCODE -ne 0){throw 'PowerShell tools bootstrap failed; see guest-install.log.'}
    Write-BaseProgress 'InstallingDotnet'
    & $pwsh -NoLogo -NoProfile -File (Join-Path $root 'bootstrap/Install-ImageTool.ps1') -Platform Windows -Root $root *>> $log
    if($LASTEXITCODE -ne 0){throw 'Native tool bootstrap failed; see guest-install.log.'}
    $env:PATH=[Environment]::GetEnvironmentVariable($pathVariable,$EnvironmentTarget)+$separator+$env:PATH
    Write-BaseProgress 'VerifyingRuntime'
    & $pwsh -NoLogo -NoProfile -File $ValidationScript -Root $root *>> $log
    if($LASTEXITCODE -ne 0){throw 'The installed common runtime failed verification; see guest-install.log.'}
    $paths=@(foreach($part in @('bin','python/Scripts','composer/vendor/bin','gems/bin','tool','tool/bin')){Join-Path $root $part})+@('C:\Program Files\Git\usr\bin')
    if(Test-Path (Join-Path $root 'tool-path.json')){$paths+=@(Get-Content (Join-Path $root 'tool-path.json') -Raw|ConvertFrom-Json)}
    [Environment]::SetEnvironmentVariable($pathVariable,($paths -join $separator)+$separator+[Environment]::GetEnvironmentVariable($pathVariable,$EnvironmentTarget),$EnvironmentTarget)
    $initializer=Join-Path $root 'bootstrap/Initialize-WindowsModule.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Initialize-WindowsModule.ps1') -Destination $initializer -Force
    $action=New-ScheduledTaskAction -Execute $pwsh -Argument ('-NoLogo -NoProfile -File "'+$initializer+'" -Root "'+$root+'" -Share "'+(Join-Path $Share 'mutator')+'" -EnvironmentTarget '+$EnvironmentTarget)
    $trigger=New-ScheduledTaskTrigger -AtStartup
    $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    $null=Register-ScheduledTask -TaskName 'Mutator-InstallModule' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
    $proof=Get-Content (Join-Path $root 'base-runtime.json') -Raw|ConvertFrom-Json
    [IO.File]::WriteAllText((Join-Path $root 'base-ready.json'),($proof|ConvertTo-Json -Depth 5))
    Copy-Item -LiteralPath (Join-Path $root 'base-ready.json') -Destination (Join-Path $Share 'base-ready.json') -Force
    Write-BaseProgress 'Ready'
}catch{
    $failure=$_
    [IO.File]::WriteAllText((Join-Path $root 'guest-failed.json'),(@{Module=$(if($metadata){$metadata.Module}else{$null});Outcome='Failed';Error=$failure.Exception.Message}|ConvertTo-Json))
    try{Copy-Item -LiteralPath (Join-Path $root 'guest-failed.json') -Destination (Join-Path $Share 'guest-failed.json') -Force -ErrorAction Stop}catch{Write-Verbose ('Base failure retained locally: '+$_.Exception.Message)}
    throw $failure
}
