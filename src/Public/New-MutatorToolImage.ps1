function New-MutatorToolImage {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$RecipePath, [string]$BaseImage,
        [Parameter(Mandatory)][string]$OutputDirectory, [string]$Connection,
        [Alias('Engine')][ValidateSet('Podman','Docker')][string]$ContainerEngine)
    $recipe = Import-PowerShellDataFile -LiteralPath $RecipePath
    if ($recipe.Binary -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._+-]*$') { throw 'A container recipe requires a simple binary name.' }
    $packages = @($recipe.Packages)
    if (!$packages.Count -or @($packages | Where-Object { $_ -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._+~:=-]*$' }).Count) {
        throw 'A container recipe requires package names without shell syntax.'
    }
    if (!$PSCmdlet.ShouldProcess($OutputDirectory, 'Prepare a Linux image containing the binary and PowerShell')) { return }
    $ContainerEngine=Resolve-MutatorEngineSelection $ContainerEngine -UseContext
    if(!$PSBoundParameters.ContainsKey('Connection') -and $ContainerEngine -eq $script:MutatorContainerEngine){$Connection=$script:MutatorContainerConnection}
    $setting=if($ContainerEngine -eq $script:MutatorContainerEngine){$script:MutatorContainerSetting}else{$null}
    Set-MutatorContainerContext -Engine $ContainerEngine -Connection $Connection -Setting $setting
    $ContainerEngine=$script:MutatorContainerEngine
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    $sourceConnection=''
    if (!$BaseImage) { throw 'Custom recipes require -BaseImage explicitly; use New-MutatorContainerImage for generated module images.' }
    $inspect = Invoke-MutatorContainerCommand -Arguments @('image','inspect',$BaseImage) -Directory $OutputDirectory -Connection $Connection
    if($inspect.Outcome -ne 'Success'){
        $origin=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$BaseImage) -Directory $OutputDirectory -Connection $sourceConnection -DefaultConnection
        if($origin.Outcome -ne 'Success'){
            $sibling=Get-MutatorRootlessSiblingConnection -Directory $OutputDirectory -Connection $Connection
            if($sibling -and $sibling -cne $sourceConnection){
                $sourceConnection=$sibling
                $origin=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$BaseImage) -Directory $OutputDirectory -Connection $sourceConnection
            }
        }
        if($origin.Outcome -eq 'Success'){
            $originImage=@($origin.Stdout|ConvertFrom-Json -AsHashtable)[0]
            if($originImage.Os -ne 'linux' -or $originImage.Id -notmatch '^(sha256:)?[a-f0-9]{64}$'){throw 'Invalid origin runtime image.'}
            $archive=Join-Path $OutputDirectory ('runtime-'+[guid]::NewGuid().ToString('N')+'.tar')
            try{
                $save=Invoke-MutatorContainerCommand -Arguments @('save','--output',$archive,$originImage.Id) -Directory $OutputDirectory -TimeoutSeconds 1800 -Connection $sourceConnection -DefaultConnection:(!$sourceConnection)
                if($save.Outcome -ne 'Success'){throw 'Cannot export the prepared runtime from its source connection.'}
                $load=Invoke-MutatorContainerCommand -Arguments @('load','--input',$archive) -Directory $OutputDirectory -TimeoutSeconds 1800 -Connection $Connection
                if($load.Outcome -ne 'Success'){throw 'Cannot import the prepared runtime into the selected connection.'}
            }finally{if(Test-Path -LiteralPath $archive){Remove-Item -LiteralPath $archive -Force}}
            $BaseImage=$originImage.Id
            $inspect=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$BaseImage) -Directory $OutputDirectory -Connection $Connection
        }
    }
    if ($inspect.Outcome -ne 'Success') { throw 'The requested container base image is not available locally.' }
    $base = @($inspect.Stdout | ConvertFrom-Json -AsHashtable)[0]
    if ($base.Os -ne 'linux' -or $base.Id -notmatch '^(sha256:)?[0-9a-f]{64}$') { throw 'The Podman tool adapter requires a Linux base image with a complete image ID.' }
    $template = [IO.File]::ReadAllText((Join-Path $script:MutatorRoot 'resources/containers/Tool.Containerfile'))
    $manager = if ($recipe['PackageManager']) { $recipe.PackageManager } else { 'apk' }
    $install = switch ($manager) {
        'apk' { 'RUN ' + (@('apk','add','--no-cache') + $packages | ConvertTo-Json -Compress) }
        'apt' { 'RUN apt-get update && apt-get install -y --no-install-recommends ' + ($packages -join ' ') + ' && rm -rf /var/lib/apt/lists/*' }
        default { throw 'Supported container package managers are apk and apt.' }
    }
    $probe = '$ErrorActionPreference = ''Stop''; if ($PSVersionTable.PSVersion -lt [version]''7.6'') { throw ''PowerShell 7.6+ required'' }; $null = Get-Command ' + $recipe.Binary + ' -CommandType Application -ErrorAction Stop'
    $text = $template.Replace('__BASE__',$base.Id).Replace('__INSTALL__',$install).Replace('__PROBE__',(@('pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',$probe) | ConvertTo-Json -Compress))
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
    $image = 'localhost/frenchexdev-mutator-' + $recipe.Binary.ToLowerInvariant() + ':' + $hash.Substring(0,24)
    $file = Join-Path $OutputDirectory 'Containerfile'
    [IO.File]::WriteAllText($file,$text,[Text.UTF8Encoding]::new($false))
    $cached = Invoke-MutatorContainerCommand -Arguments @('image','inspect',$image) -Directory $OutputDirectory -Connection $Connection
    $reused = $cached.Outcome -eq 'Success'
    if (!$reused) {
        $build = Invoke-MutatorContainerCommand -Arguments @('build','--pull=never','--file',$file,'--tag',$image,$OutputDirectory) -Directory $OutputDirectory -TimeoutSeconds 1800 -Connection $Connection
        [IO.File]::WriteAllText((Join-Path $OutputDirectory 'build.stdout.log'),$build.Stdout)
        [IO.File]::WriteAllText((Join-Path $OutputDirectory 'build.stderr.log'),$build.Stderr)
        if ($build.Outcome -ne 'Success') { throw "Container build failed for $($recipe.Binary); see retained build logs in $OutputDirectory." }
        $cached = Invoke-MutatorContainerCommand -Arguments @('image','inspect',$image) -Directory $OutputDirectory -Connection $Connection
    }
    if ($cached.Outcome -ne 'Success') { throw 'The built container image could not be inspected.' }
    $built = @($cached.Stdout | ConvertFrom-Json -AsHashtable)[0]
    if ($built.Os -ne 'linux' -or $built.Id -notmatch '^(sha256:)?[0-9a-f]{64}$') { throw 'Invalid built Linux image identity.' }
    $receipt = @{Binary=$recipe.Binary;Image=$image;ImageId=$built.Id;BaseImageId=$base.Id;RecipeSha256=(Get-FileHash -LiteralPath $RecipePath).Hash
        ContainerfileSha256=$hash;Reused=$reused;Platform='linux';Connection=$Connection;ContainerEngine=$ContainerEngine;BaseSourceConnection=$sourceConnection;CreatedUtc=[datetime]::UtcNow.ToString('O')}
    Write-MutatorJson (Join-Path $OutputDirectory 'image.json') $receipt
    [pscustomobject]$receipt
}
