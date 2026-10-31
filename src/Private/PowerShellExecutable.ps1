function Get-MutatorPowerShellExecutable {
    $command=Get-Command pwsh -CommandType Application -ErrorAction Stop|Select-Object -First 1
    $command.Source
}
