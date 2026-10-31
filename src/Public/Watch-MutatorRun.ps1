function Watch-MutatorRun {
    <#
    .SYNOPSIS
    Display the terminal view or return one structured snapshot.

    .DESCRIPTION
    Once avoids console access. Interactive detach/stop restores screen, cursor and key modes even on
    failure.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost','',Justification='Explicit interactive TUI uses Console VT rendering; redirected callers use the structured -Once mode instead.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[ValidateRange(1,60)][int]$RefreshSeconds=1,[switch]$Once)
    if($Once){Get-MutatorProgress -Path $Path;return}
    if(!(Test-MutatorTerminalInteractive)){throw 'Watch-MutatorRun requires an interactive terminal, or -Once for a structured snapshot.'}
    $consoleApi=Get-MutatorConsoleApi
    $escape=[char]27
    $previousControl=$consoleApi::TreatControlCAsInput
    try {
        $consoleApi::TreatControlCAsInput=$true
        $consoleApi::Write("$escape[?1049h$escape[?25l")
        $detach=$false
        do {
            $run=Get-MutatorRun -Path $Path
            $consoleApi::Write("$escape[H$escape[J"+(Format-MutatorTerminalFrame $run))
            if($run.Outcome -notin @('Running','Starting')){break}
            $next=(Get-MutatorUtcNow).AddSeconds($RefreshSeconds)
            while((Get-MutatorUtcNow) -lt $next){
                if($consoleApi::KeyAvailable){
                    $key=$consoleApi::ReadKey($true)
                    if($key.Key -eq 'Q'){$detach=$true;break}
                    if($key.Key -eq 'S' -or ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control))){$null=Stop-MutatorRun -Path $Path;break}
                }
                Start-Sleep -Milliseconds 50
            }
        }while(!$detach)
    } finally {
        $consoleApi::Write("$escape[?25h$escape[?1049l")
        $consoleApi::TreatControlCAsInput=$previousControl
    }
    Get-MutatorProgress -Path $Path
}
