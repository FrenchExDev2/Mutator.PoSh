#requires -Version 7.6
param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Owner)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'modules/FrenchExDev.Mutator.PoSh/src/Private/GuestControl.ps1')
$listener=[Net.HttpListener]::new();$listener.Prefixes.Add('http://+:8765/')
try{
    $listener.Start()
    while($listener.IsListening){
        $context=$listener.GetContext()
        try{
            $reply=Get-MutatorGuestControlResponse -Root $Root -Owner $Owner -Path $context.Request.Url.AbsolutePath
            $body=[Text.Encoding]::UTF8.GetBytes(($reply.Data|ConvertTo-Json -Compress))
            $context.Response.StatusCode=$reply.Status;$context.Response.ContentType='application/json'
            $context.Response.Headers.Add('Cache-Control','no-store');$context.Response.ContentLength64=$body.Length
            $context.Response.OutputStream.Write($body,0,$body.Length)
        }finally{$context.Response.Close()}
    }
}finally{$listener.Close()}
