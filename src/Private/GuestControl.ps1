function Get-MutatorGuestControlResponse {
    <#
    .SYNOPSIS
    Serve health and stop data for an owned guest job.

    .DESCRIPTION
    Accepts canonical control paths and matching ownership. Returns explicit HTTP-style statuses for
    missing, foreign or unreadable requests.
    #>

    param([string]$Root,[string]$Owner,[string]$Path)
    if($Path -ceq '/health'){return @{Status=200;Data=@{RunId=$Owner;Ready=$true;PowerShell=$PSVersionTable.PSVersion.ToString()}}}
    if($Path -cnotmatch '^/jobs/(?<id>[a-f0-9]{32})/control$'){return @{Status=404;Data=$null}}
    $id=$Matches.id;$directory=Join-Path $Root $id
    try{
        $request=[IO.File]::ReadAllText((Join-Path $directory 'request.json'))|ConvertFrom-Json -AsHashtable -DateKind String
        if($request.RunId -cne $Owner -or $request.JobId -cne $id){return @{Status=403;Data=$null}}
        $stopPath=Join-Path $directory 'stop.json';$stopped=[IO.File]::Exists($stopPath)
        $stop=if($stopped){[IO.File]::ReadAllText($stopPath)|ConvertFrom-Json -AsHashtable -DateKind String}else{@{}}
        @{Status=200;Data=@{RunId=$Owner;JobId=$id;Stop=$stopped;Reason=$stop['Reason']}}
    }catch{@{Status=503;Data=$null}}
}
