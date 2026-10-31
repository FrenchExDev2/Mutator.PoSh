function Restore-MutatorModuleState {
    param([object]$State)
    $module = $State.Module
    $loaded = @(Get-Module -Name $module.Name -All | Where-Object { [object]::ReferenceEquals($_, $module) })
    if ($loaded.Count -ne 1) { throw 'A test removed or replaced the cached module.' }
    $definitions = & $module { @(Get-Command -Name '*' -CommandType Function | Where-Object ModuleName -CEQ $ExecutionContext.SessionState.Module.Name | Sort-Object Name | ForEach-Object { $_.Name + ':' + $_.Definition }) -join "`n" }
    if ($definitions -cne $State.Definition) { throw 'A test replaced module functions; reload the original mutant.' }
    $fresh = (Copy-MutatorStateValue $State.Variables).Value
    & $module {
        param($Values)
        $automatic = @('args','Error','false','true','null','foreach','MyInvocation','PSCommandPath','PSScriptRoot','PSDefaultParameterValues','PSBoundParameters','input','_','PSItem')
        foreach ($variable in @(Get-Variable -Scope Script)) {
            if ($variable.Name -notin $automatic -and !$Values.ContainsKey($variable.Name) -and !($variable.Options -band [Management.Automation.ScopedItemOptions]::Constant)) {
                Remove-Variable -Name $variable.Name -Scope Script -Force
            }
        }
        foreach ($name in $Values.Keys) { Set-Variable -Name $name -Value $Values[$name] -Scope Script -Force }
    } $fresh
}
