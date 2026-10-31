function Update-MutatorSupervisionDashboard {
    param([string]$RunDirectory,[Collections.IDictionary]$Run)
    try{Show-MutatorDashboard -RunRoot (Split-Path $RunDirectory)|Out-Null}
    catch{
        $Run.DashboardError=Protect-MutatorDiagnostic $_.Exception.Message
        try{Write-MutatorJson (Join-Path $RunDirectory 'dashboard-error.json') @{Error=$Run.DashboardError;Utc=[datetime]::UtcNow.ToString('O')}}
        catch{$Run.DashboardErrorRetained=$false}
    }
}
