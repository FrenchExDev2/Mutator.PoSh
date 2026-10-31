function Update-MutatorSupervisionDashboard {
    <#
    .SYNOPSIS
    Refresh the dashboard without turning a rendering error into a campaign failure.

    .DESCRIPTION
    Retains a masked diagnostic and attempts to persist dashboard-error.json. Records when even
    diagnostic retention fails.
    #>

    param([string]$RunDirectory,[Collections.IDictionary]$Run)
    try{Show-MutatorDashboard -RunRoot (Split-Path $RunDirectory)|Out-Null}
    catch{
        $Run.DashboardError=Protect-MutatorDiagnostic $_.Exception.Message
        try{Write-MutatorJson (Join-Path $RunDirectory 'dashboard-error.json') @{Error=$Run.DashboardError;Utc=[datetime]::UtcNow.ToString('O')}}
        catch{$Run.DashboardErrorRetained=$false}
    }
}
