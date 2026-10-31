function Get-MutatorModuleState {
    param([Management.Automation.PSModuleInfo]$Module)
    $variables = & $Module {
        $automatic = @('args','Error','false','true','null','foreach','MyInvocation','PSCommandPath','PSScriptRoot','PSDefaultParameterValues','PSBoundParameters','input','_','PSItem')
        @(Get-Variable -Scope Script | Where-Object { $_.Name -notin $automatic -and !($_.Options -band [Management.Automation.ScopedItemOptions]::Constant) })
    }
    $values = @{}
    foreach ($variable in $variables) { $values[$variable.Name] = (Copy-MutatorStateValue $variable.Value).Value }
    $definitions = & $Module { @(Get-Command -Name '*' -CommandType Function | Where-Object ModuleName -CEQ $ExecutionContext.SessionState.Module.Name | Sort-Object Name | ForEach-Object { $_.Name + ':' + $_.Definition }) -join "`n" }
    @{ Module = $Module; Variables = $values; Definition = $definitions }
}
