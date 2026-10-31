function New-MutatorContainerWorkspace {
    <#
    .SYNOPSIS
    Create a controlled module workspace for container-definition tests.

    .DESCRIPTION
    Builds minimal contributor manifests from fixture profiles and generates definitions without
    qualifying a real image.
    #>

    param([Parameter(Mandatory)][string]$Path)
    $mutator=Split-Path (Split-Path $PSCommandPath)
    $mutator=Split-Path $mutator
    [void][IO.Directory]::CreateDirectory($Path)
    $profiles=Get-Content (Join-Path $mutator 'test/Fixtures/ContainerProfiles.json') -Raw|ConvertFrom-Json -AsHashtable
    foreach($row in $profiles){
        $directory=Join-Path $Path $row.Name
        [void][IO.Directory]::CreateDirectory($directory)
        $commands=@($row.Commands|ForEach-Object {"'"+$_.Replace("'","''")+"'"}) -join ','
        $dependencies=@($row.Dependencies|ForEach-Object {"'"+$_.Replace("'","''")+"'"}) -join ','
        $manifest="@{RootModule='$($row.Name).psm1';ModuleVersion='1.0.0';PrivateData=@{Mutator=@{Profile='$($row.Profile)';Commands=@($commands);Dependencies=@($dependencies)}}}"
        [IO.File]::WriteAllText((Join-Path $directory ($row.Name+'.psd1')),$manifest)
        [IO.File]::WriteAllText((Join-Path $directory ($row.Name+'.psm1')),"throw 'An inventory fixture must never be imported.'")
    }
    $engine=Join-Path $Path 'QuietCliEcosystem/FrenchExDev.QuietCli.PoSh'
    [void][IO.Directory]::CreateDirectory($engine)
    [IO.File]::WriteAllText((Join-Path $engine 'FrenchExDev.QuietCli.PoSh.psd1'),"@{ModuleVersion='1.0.0';PrivateData=@{Mutator=@{Profile='Engine'}}}")
    $owner=Join-Path $Path 'FrenchExDev.Mutator.PoSh'
    [void][IO.Directory]::CreateDirectory((Join-Path $owner 'resources/containers'))
    Copy-Item -LiteralPath (Join-Path $mutator 'resources/containers/definitions') -Destination (Join-Path $owner 'resources/containers/definitions') -Recurse
    $null=Export-MutatorContainerBaseDefinition -ModuleRoot $Path
    foreach($row in $profiles){$null=Export-MutatorContainerDefinition -ModulePath (Join-Path $Path $row.Name) -IncludeMacOS -Force}
    $Path
}
