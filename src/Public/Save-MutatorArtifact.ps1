function Save-MutatorArtifact {
    param([string]$StageReportDirectory, [string]$Artifacts, [object]$Context)
    if (!(Test-Path -LiteralPath $StageReportDirectory)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $StageReportDirectory -File -Filter 'mutation*.json') {
        $destination = Join-Path $Artifacts $file.Name
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        $receipt = @{ Sha256 = $Context.Sha256; Identity = $Context.Identity; ReportSha256 = (Get-FileHash -LiteralPath $destination).Hash }
        [IO.File]::WriteAllText(($destination + '.context.json'), ($receipt | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    }
}
