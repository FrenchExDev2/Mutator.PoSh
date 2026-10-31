function Import-MutatorTool {
    [CmdletBinding()]
    param([string]$CacheRoot = (Join-Path $script:MutatorRoot '.cache/mutation-tools'), [string]$ProgressPath, [string]$StopPath)
    $installed = Get-Module -ListAvailable PSMutant | Where-Object Version -EQ '0.6.0' | Select-Object -First 1
    if (!$installed) { throw 'Pinned PSMutant 0.6.0 is unavailable.' }
    $files = @('PSMutation.Runner.ps1','PSMutation.Pester.ps1')
    $hashes = @($files | ForEach-Object { (Get-FileHash (Join-Path $installed.ModuleBase "src/$_")).Hash })
    $adapterHash = (Get-FileHash $PSCommandPath).Hash
    $target = Join-Path $CacheRoot ((($hashes + $adapterHash) -join '-').ToLowerInvariant())
    if (!(Test-Path (Join-Path $target 'adapter.json'))) {
        # Build privately: a second worker must never patch files already being imported.
        $cacheDirectory = [IO.Path]::GetFullPath($CacheRoot)
        $stage = [IO.Path]::GetFullPath((Join-Path $cacheDirectory ('.' + [guid]::NewGuid().ToString('N') + '.staging')))
        $prefix = $cacheDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (!$stage.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Tool staging must remain inside its cache directory.' }
        [void][IO.Directory]::CreateDirectory($stage)
        try {
        foreach ($item in Get-ChildItem $installed.ModuleBase -Force) { Copy-Item -LiteralPath $item.FullName -Destination $stage -Recurse -Force }
        $changed = 0
        foreach ($file in $files) {
            $path = Join-Path $stage "src/$file"
            $text = [IO.File]::ReadAllText($path)
            foreach ($variable in @('cfg','c')) {
                $needle = '$' + $variable + ' = New-PesterConfiguration'
                $changed += [regex]::Matches($text, [regex]::Escape($needle)).Count
                $replacement = $needle + "`n" + '$' + $variable + '.TestRegistry.Enabled = $false' + "`n" + '$' + $variable + '.Run.Parallel = $false' + "`n" + '$global:MutatorEpoch = [guid]::NewGuid().ToString(''N'')'
                $text = $text.Replace($needle, $replacement)
            }
            [IO.File]::WriteAllText($path, $text)
        }
        if ($changed -ne 3) { throw "Unexpected PSMutant configuration boundaries: $changed" }
        $runner = Join-Path $stage 'src/PSMutation.Runner.ps1'
        $text = [IO.File]::ReadAllText($runner)
        $loop = 'while ($schedule.Retired -lt $context.Total) {'
        $retire = '$Context.Sink.Add($done.Row)'
        if ([regex]::Matches($text,[regex]::Escape($loop)).Count -ne 1 -or [regex]::Matches($text,[regex]::Escape($retire)).Count -ne 1) { throw 'Unexpected PSMutant progress/cancellation boundaries.' }
        $guard = @'
        if ($script:MutatorControl -and $script:MutatorControl.Stop -and (Test-Path -LiteralPath $script:MutatorControl.Stop)) {
            throw [OperationCanceledException]::new('Mutation run stopped by request.')
        }
'@
        $progress = @'
        if ($script:MutatorControl -and $script:MutatorControl.Progress) {
            $status=[string]$done.Row.Status
            if(!$script:MutatorControl.Counts.ContainsKey($status)){$script:MutatorControl.Counts[$status]=0}
            $script:MutatorControl.Counts[$status]++
            $event = @{ Utc=[datetime]::UtcNow.ToString('O'); Evaluated=$Schedule.Retired; Planned=$Context.Total; Status=$status; File=[string]$done.Row.File; Id=$done.Row.Id; Survived=$script:MutatorControl.Counts['Survived'];StopPath=[string]$script:MutatorControl.Stop;StopRequested=[bool]($script:MutatorControl.Stop -and (Test-Path -LiteralPath $script:MutatorControl.Stop)) }
            [IO.File]::AppendAllText($script:MutatorControl.Progress, (($event|ConvertTo-Json -Compress)+[Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        }
'@
        $text = $text.Replace($loop, $loop + "`n" + $guard).Replace($retire, $retire + "`n" + $progress)
        [IO.File]::WriteAllText($runner, $text)
        $entry = Join-Path $stage 'PSMutant.psm1'
        [IO.File]::AppendAllText($entry, "`n" + '$script:MutatorControl = $null' + "`n")
        Write-MutatorJson (Join-Path $stage 'adapter.json') ([ordered]@{ Version='0.6.0'; SourceHashes=$hashes; AdapterSha256=$adapterHash; ConfigurationBoundaries=$changed; ProgressBoundary=1; CancellationBoundary=1 })
        try { [IO.Directory]::Move($stage, [IO.Path]::GetFullPath($target)) }
        catch [IO.IOException] {
            # Another worker can publish this exact immutable cache key first.
            # A missing completion marker is a genuine publication failure.
            if (!(Test-Path -LiteralPath (Join-Path $target 'adapter.json') -PathType Leaf)) { throw }
        }
        } finally {
            if ([IO.Directory]::Exists($stage)) { Remove-Item -LiteralPath $stage -Recurse -Force }
        }
    }
    $manifest = Join-Path $target 'PSMutant.psd1'
    $imported=@(Import-Module $manifest -Global -Force -PassThru -ErrorAction Stop)
    if($imported.Count -ne 1){throw 'The pinned PSMutant adapter did not import one unambiguous module.'}
    & $imported[0] { param($Progress,$Stop) $script:MutatorControl = @{ Progress=$Progress; Stop=$Stop; Counts=@{} } } $ProgressPath $StopPath
    [pscustomobject]@{ Version='0.6.0'; SourceHashes=$hashes; Path=$manifest; AdapterSha256=$adapterHash; Adapter='Pester6.TestRegistryOff.SerialPester.Epoch.Progress.Cancel' }
}
