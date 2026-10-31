function Set-ImageToolEnvironment {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private image bootstrap updates only the current container process environment; no host or persistent configuration is changed.')]
    [CmdletBinding()]
    param([string]$Root)
    $paths=@((Join-Path $Root 'bin'),(Join-Path $Root 'python/Scripts'),(Join-Path $Root 'python/bin'),(Join-Path $Root 'tool'),(Join-Path $Root 'tool/bin'),(Join-Path $Root 'tool/cmd'),(Join-Path $Root 'composer/vendor/bin'),(Join-Path $Root 'gems/bin'))
    $file=Join-Path $Root 'tool-path.json'
    if(Test-Path -LiteralPath $file){$paths=@(Get-Content -LiteralPath $file -Raw|ConvertFrom-Json)+$paths}
    if($IsWindows){
        $paths+=@('C:/ProgramData/chocolatey/bin','C:/Program Files/Git/usr/bin','C:/Program Files/Git/cmd')
        $paths+=@([Environment]::GetEnvironmentVariable('Path','Machine'),[Environment]::GetEnvironmentVariable('Path','User'))
        foreach($pattern in @('C:/Python*/','C:/tools/ruby*/')){foreach($directory in Get-Item $pattern -ErrorAction Ignore){$paths+=$directory.FullName;$paths+=Join-Path $directory.FullName 'bin'}}
    }
    elseif($IsMacOS){$paths+=@('/usr/local/bin','/usr/local/share/dotnet','/usr/local/opt/ruby/bin','/usr/local/opt/python@3.14/libexec/bin','/usr/local/opt/openjdk@21/bin')}
    $separator=[IO.Path]::PathSeparator
    $env:PATH=(@($paths|Where-Object{$_}) -join $separator)+$separator+$env:PATH
    $env:COMPOSER_HOME=Join-Path $Root 'composer'
    $env:GEM_HOME=Join-Path $Root 'gems'
    $env:GOBIN=Join-Path $Root 'bin'
    $env:NPM_CONFIG_PREFIX=if($IsWindows){Join-Path $Root 'bin'}else{$Root}
}
