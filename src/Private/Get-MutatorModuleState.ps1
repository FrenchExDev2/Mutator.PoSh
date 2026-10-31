function Get-MutatorModuleState {
    <#
    .SYNOPSIS
    Capture restorable variables and function definitions from a loaded module.

    .DESCRIPTION
    Clones supported state and records function identity for one mutant epoch. Unsupported state
    triggers the caller's fresh-import fallback.
    #>

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
