#requires -Version 7.6
param(
    [string]$Root='/opt/mutator',
    [ValidateSet('linux-x64','linux-arm64','linux-musl-x64','linux-musl-arm64','win-x64','win-arm64','osx-x64','osx-arm64')]
    [string]$RuntimeIdentifier=[Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier
)
$ErrorActionPreference='Stop'
$directory=Join-Path $Root 'modules/QuietCliEcosystem/FrenchExDev.QuietCli.PoSh/resources/runtime'
$name=if($RuntimeIdentifier.StartsWith('win-')){'e_sqlite3.dll'}elseif($RuntimeIdentifier.StartsWith('osx-')){'libe_sqlite3.dylib'}else{'libe_sqlite3.so'}
$source=Join-Path $directory ('runtimes/'+$RuntimeIdentifier+'/native/'+$name)
if(!(Test-Path -LiteralPath $source -PathType Leaf)){throw "Missing SQLite dependency for $RuntimeIdentifier : $source"}
# Assembly.LoadFrom resolves native libraries beside the managed provider. The
# source checkout may have been prepared on Windows or glibc; select the image RID.
Copy-Item -LiteralPath $source -Destination (Join-Path $directory $name) -Force
@{RuntimeIdentifier=$RuntimeIdentifier;NativeLibrary=$name;Sha256=(Get-FileHash -LiteralPath $source).Hash}|
    ConvertTo-Json|Set-Content (Join-Path $Root 'module-runtime.json')
