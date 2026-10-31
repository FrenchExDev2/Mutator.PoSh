#requires -Version 7.6
param([string]$RunId,[string]$JobId,[Threading.CancellationToken]$CancellationToken,[string]$Root='C:\mutator',[uri]$ControlBaseUri='http://host.lan:8765/')
$ErrorActionPreference='Stop'
$client=[Net.Http.HttpClient]::new();$client.Timeout=[timespan]::FromSeconds(2)
$local=Join-Path $Root ('mutation-jobs/'+$JobId)
try{
    while(!$CancellationToken.IsCancellationRequested){
        try{
            $body=$client.GetStringAsync([uri]::new($ControlBaseUri,('jobs/'+$JobId+'/control'))).GetAwaiter().GetResult()|ConvertFrom-Json -AsHashtable -DateKind String
            if($body.RunId -cne $RunId -or $body.JobId -cne $JobId){throw 'Foreign guest cancellation response.'}
            if($body.Stop){
                [void][IO.Directory]::CreateDirectory($local)
                [IO.File]::WriteAllText((Join-Path $local 'stop.json'),($body|ConvertTo-Json -Compress))
                return
            }
        }catch{
            if(Test-Path $local){[IO.File]::WriteAllText((Join-Path $local 'control-error.txt'),$_.Exception.Message)}
        }
        [Threading.Thread]::Sleep(250)
    }
}finally{$client.Dispose()}
