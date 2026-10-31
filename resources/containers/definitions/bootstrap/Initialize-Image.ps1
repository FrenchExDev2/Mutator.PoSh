#requires -Version 7.6
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
foreach($tool in @(@('Pester','6.2.0'),@('PSMutant','0.6.0'),@('PSScriptAnalyzer','1.25.0'),@('powershell-yaml','0.4.12'))){
    Install-Module -Name $tool[0] -RequiredVersion $tool[1] -Repository PSGallery -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
}
