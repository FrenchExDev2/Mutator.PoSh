function Show-MutatorDashboard {
    <#
    .SYNOPSIS
    Generate a bounded localized dashboard from retained runs.

    .DESCRIPTION
    Escapes embedded data and optionally opens the HTML. Does not start, resume or modify completed
    campaigns.
    #>

    [CmdletBinding()]
    param([string]$RunRoot,[string]$Path,[switch]$Open,[ValidateRange(1,10000)][int]$MaxRuns=100)
    $root=Get-MutatorRunRoot $RunRoot
    if(!$Path){$Path=Join-Path (Split-Path $root) 'dashboard/index.html'}
    $runs=@(Get-MutatorRun -RunRoot $root -Limit $MaxRuns)
    $labels=@{}
    foreach($key in (Import-PowerShellDataFile -LiteralPath (Join-Path $script:MutatorRoot ('resources/localization/'+(Get-MutatorLanguage)+'.psd1'))).Keys){
        if($key.StartsWith('Dashboard.',[StringComparison]::Ordinal)){$labels[$key.Substring(10)]=Get-MutatorText $key}
    }
    $data=@{GeneratedUtc=[datetime]::UtcNow.ToString('O');Runs=$runs;Language=(Get-MutatorLanguage);Labels=$labels}
    $json=($data|ConvertTo-Json -Depth 30 -Compress).Replace('<','\u003c').Replace('>','\u003e').Replace('&','\u0026').Replace([string][char]0x2028,'\u2028').Replace([string][char]0x2029,'\u2029')
    $template=[IO.File]::ReadAllText((Join-Path $script:MutatorRoot 'resources/dashboard.html'))
    $template=$template.Replace('__MUTATOR_LANGUAGE__',[Net.WebUtility]::HtmlEncode($data.Language)).Replace('__MUTATOR_TITLE__',[Net.WebUtility]::HtmlEncode($labels.Title))
    [void][IO.Directory]::CreateDirectory((Split-Path $Path))
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temporary,$template.Replace('__MUTATOR_DATA__',$json),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary,$Path,$true)
    foreach($run in @($runs|Where-Object Outcome -In @('Running','Starting'))){
        $history=Join-Path $run.Path 'hourly.jsonl'
        $previous=$null
        if(Test-Path $history){$last=Get-Content $history -Tail 1;try{$previous=$last|ConvertFrom-Json -AsHashtable -DateKind String}catch{Write-MutatorJson (Join-Path $run.Path 'hourly-read-error.json') @{Utc=[datetime]::UtcNow.ToString('O');Message='The last hourly event is not valid JSON; the original event remains retained.'}}}
        $now=[datetime]::UtcNow
        if(!$previous -or ([datetime]$previous.Utc).ToUniversalTime().Date.AddHours(([datetime]$previous.Utc).ToUniversalTime().Hour) -lt $now.Date.AddHours($now.Hour)){
            $row=@{Utc=$now.ToString('O');CompletedPackages=$run.CompletedPackages;TotalPackages=$run.TotalPackages;EvaluatedMutants=$run.EvaluatedMutants;PlannedMutants=$run.PlannedMutants;FailedPackages=$run.FailedPackages;Outcome=$run.Outcome}
            [IO.File]::AppendAllText($history,($row|ConvertTo-Json -Compress)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        }
    }
    if($Open){Start-Process -FilePath $Path}
    [pscustomobject]@{Path=$Path;Runs=$runs.Count;GeneratedUtc=$data.GeneratedUtc}
}
