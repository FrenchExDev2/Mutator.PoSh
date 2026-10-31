function Import-MutatorTestModule {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars','',Justification='The cache is local to one PSMutant runspace and epoch; explicit cross-module access is required by independent Pester containers.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Manifest,[string]$ModulePattern)
    $epoch = Get-Variable MutatorEpoch -Scope Global -ValueOnly -ErrorAction Ignore
    $existing = Get-Variable MutatorImports -Scope Global -ValueOnly -ErrorAction Ignore
    $paths = @($Manifest | ForEach-Object { [IO.Path]::GetFullPath($_) })
    $key = ($paths -join '|') + '|' + $ModulePattern
    if ($epoch -and $existing -and $existing.Epoch -ceq $epoch -and $existing.Key -ceq $key -and $existing.Reusable) {
        try {
            foreach ($state in $existing.States) { Restore-MutatorModuleState $state }
            # Dependencies imported by the preceding container must not leak to the next one.
            foreach ($module in @($(if ($existing.OwnsFamily) { Get-Module $existing.ModulePattern -All }))) {
                if ($module.ModuleBase -notin @($existing.States.Module.ModuleBase)) { Remove-Module $module -Force }
            }
            $existing.Restores++
            return
        } catch { $existing.Fallbacks++ }
    }
    $ownsFamily = ![string]::IsNullOrWhiteSpace($ModulePattern)
    if ($ownsFamily) {
        Get-Module $ModulePattern -All | Remove-Module -Force
    }
    foreach ($path in $paths) { Import-Module $path -Global -Force -DisableNameChecking -ErrorAction Stop }
    $cache = @{ Epoch = $epoch; Key = $key; Reusable = [bool]$epoch; States = @(); Loads = 1; Restores = 0; Fallbacks = 0; OwnsFamily = $ownsFamily; ModulePattern=$ModulePattern }
    if ($existing) { $cache.Loads += $existing.Loads; $cache.Restores = $existing.Restores; $cache.Fallbacks = $existing.Fallbacks }
    if ($epoch) {
        try {
            $cache.States = @(foreach ($path in $paths) {
                $name = [IO.Path]::GetFileNameWithoutExtension($path)
                $module = @(Get-Module $name -All | Where-Object { [IO.Path]::GetFullPath($_.ModuleBase) -ceq [IO.Path]::GetDirectoryName($path) })[-1]
                if (!$module) { throw 'The manifest did not load its expected module.' }
                Get-MutatorModuleState $module
            })
        } catch { $cache.Reusable = $false; $cache.Fallbacks++ }
    }
    $global:MutatorImports = $cache
}
