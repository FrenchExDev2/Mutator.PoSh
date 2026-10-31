#requires -Version 7.6
param([string]$Root='C:\mutator')
$ErrorActionPreference='Stop'
$metadata=Get-Content (Join-Path $Root 'image.json') -Raw|ConvertFrom-Json -AsHashtable
if($PSVersionTable.PSVersion.ToString() -cne $metadata.Runtime.Version){throw 'The installed PowerShell version differs from the pinned runtime.'}
$tools=@(foreach($tool in @(@('Pester','6.2.0'),@('PSMutant','0.6.0'),@('PSScriptAnalyzer','1.25.0'),@('powershell-yaml','0.4.12'))){
    Import-Module $tool[0] -RequiredVersion $tool[1] -ErrorAction Stop
    @{Name=$tool[0];Version=$tool[1]}
})
$expected=@($metadata.Platforms.Windows.Packages|Where-Object {$_ -like 'dotnet-sdk=*'})
if($expected.Count -ne 1){throw 'The Windows base must pin exactly one .NET SDK.'}
$sdk=(Get-Command dotnet -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
$start=[Diagnostics.ProcessStartInfo]::new($sdk)
$start.ArgumentList.Add('--version')
$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$process=[Diagnostics.Process]::new();$process.StartInfo=$start
try {
    [void]$process.Start()
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    if(!$process.WaitForExit(30000)){$process.Kill($true);throw 'The installed SDK version check timed out.'}
    $version=$stdout.GetAwaiter().GetResult().Trim()
    [IO.File]::WriteAllText((Join-Path $Root 'sdk-check.stderr.log'),$stderr.GetAwaiter().GetResult())
    if($process.ExitCode -ne 0 -or $version -cne $expected[0].Substring('dotnet-sdk='.Length)){throw 'The installed .NET SDK differs from the pinned version.'}
} finally {$process.Dispose()}
$proof=@{Outcome='Success';Fingerprint=$metadata.BaseFingerprint;PowerShell=$PSVersionTable.PSVersion.ToString();DotnetSdk=$version;Tools=$tools;VerifiedUtc=[datetime]::UtcNow.ToString('O')}
[IO.File]::WriteAllText((Join-Path $Root 'base-runtime.json'),($proof|ConvertTo-Json -Depth 5))
