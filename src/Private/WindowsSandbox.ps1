function New-MutatorSandboxConfiguration {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Pure XML factory; no process or filesystem mutation.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Mappings,[int]$MemoryMiB=4096)
    $folders=foreach($mapping in $Mappings){
        $hostPath=[Security.SecurityElement]::Escape([string]$mapping.HostPath)
        $guestPath=[Security.SecurityElement]::Escape([string]$mapping.GuestPath)
        $readOnly=if($mapping.ReadOnly){'true'}else{'false'}
        "<MappedFolder><HostFolder>$hostPath</HostFolder><SandboxFolder>$guestPath</SandboxFolder><ReadOnly>$readOnly</ReadOnly></MappedFolder>"
    }
    '<Configuration><Networking>Disable</Networking><VGpu>Disable</VGpu><ClipboardRedirection>Disable</ClipboardRedirection><MemoryInMB>'+[string]$MemoryMiB+'</MemoryInMB><MappedFolders>'+($folders -join '')+'</MappedFolders></Configuration>'
}

function Invoke-MutatorSandboxCommand {
    param([string[]]$Arguments,[string]$Directory,[int]$TimeoutSeconds=120)
    if(!(Get-Command wsb -CommandType Application -ErrorAction Ignore)){throw 'Windows Sandbox CLI (wsb.exe) is required; execution on the host is prohibited.'}
    $encoding=[Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage).WebName
    $result=Invoke-MutatorNative wsb (@('--raw')+$Arguments) $Directory $TimeoutSeconds -Encoding $encoding
    # wsb exec has no process I/O transport. The guest retains its own logs and reports.
    $log=Join-Path $Directory ('wsb-'+$Arguments[0]+'-'+[guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText(($log+'.stdout.log'),[string]$result.Stdout)
    [IO.File]::WriteAllText(($log+'.stderr.log'),[string]$result.Stderr)
    if($result.Outcome -ne 'Success'){throw ('Windows Sandbox '+$Arguments[0]+' failed ('+$result.Outcome+'); see retained wsb logs in '+$Directory+'. No host fallback is permitted.')}
    $result
}

function Copy-MutatorSandboxRuntime {
    param([string]$Destination)
    if(!$IsWindows){throw 'The portable Windows runtime must be prepared on Windows.'}
    Copy-MutatorTree $PSHOME (Join-Path $Destination 'pwsh')
    foreach($spec in @(@{Name='Pester';Version='6.2.0'},@{Name='PSMutant';Version='0.6.0'})){
        $installed=Get-Module -ListAvailable $spec.Name | Where-Object Version -EQ $spec.Version | Select-Object -First 1
        if(!$installed){throw ('Pinned '+$spec.Name+' '+$spec.Version+' is unavailable; no installation is performed.')}
        Copy-MutatorTree $installed.ModuleBase (Join-Path $Destination ('modules/'+$spec.Name+'/'+$spec.Version))
    }
    # Development test suites can use these optional installed tools. No downloads run in the guest.
    foreach($name in @('PSScriptAnalyzer','powershell-yaml')){
        $installed=Get-Module -ListAvailable $name | Sort-Object Version -Descending | Select-Object -First 1
        if($installed){Copy-MutatorTree $installed.ModuleBase (Join-Path $Destination ('modules/'+$name+'/'+$installed.Version))}
    }
}

function Stop-MutatorWindowsSandbox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private cleanup runs inside the public campaign or Stop-MutatorRun ShouldProcess boundary and targets only the owned ID.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id,[string]$Directory)
    $parsed=[guid]::Empty
    if(![guid]::TryParse($Id,[ref]$parsed)){throw 'Refusing to stop a Windows Sandbox without a valid owned ID.'}
    $null=Invoke-MutatorSandboxCommand -Arguments @('stop','--id',$Id) -Directory $Directory
}

function Invoke-MutatorWindowsSandboxPackage {
    param([string]$RunDirectory,[Collections.IDictionary]$Run,[Collections.IDictionary]$Entry,
        [Collections.IDictionary]$State,[string]$StatePath)
    if(!$IsWindows){throw 'Windows Sandbox requires a Windows host.'}
    if(!(Get-Command wsb -CommandType Application -ErrorAction Ignore)){throw 'Windows Sandbox CLI (wsb.exe) is required; execution on the host is prohibited.'}
    if($Entry.Stryker){throw 'The Windows Sandbox adapter currently supports PSMutant only. Select -SkipStryker for this campaign.'}
    $artifacts=Split-Path $StatePath
    $payload=Join-Path $artifacts 'sandbox-payload'
    $directory=Join-Path $artifacts 'sandbox-run'
    [void][IO.Directory]::CreateDirectory($payload)
    [void][IO.Directory]::CreateDirectory($directory)
    $State.Phase='Preparing Windows Sandbox';$State.Platform='windows'
    Write-MutatorJson $StatePath $State
    Copy-MutatorSandboxRuntime (Join-Path $payload 'tools')
    $sourceRoot='C:\MutatorSource'
    $moduleRelative=[IO.Path]::GetRelativePath($Run.SourceRoot,$Entry.ModulePath)
    $mutatorRelative=[IO.Path]::GetRelativePath($Run.SourceRoot,$script:MutatorRoot)
    foreach($relative in @($moduleRelative,$mutatorRelative)){
        if([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar)){throw 'The sandbox source root must contain Mutator and the selected module.'}
    }
    $innerEntry=@{Id=$Entry.Id;Name=$Entry.Name;ModulePath=(Join-Path $sourceRoot $moduleRelative)
        Configuration=(Join-Path $sourceRoot ([IO.Path]::GetRelativePath($Run.SourceRoot,$Entry.Configuration)));ResumeFrom=$null;Stryker=$false}
    $mappings=@(
        @{HostPath=$Run.SourceRoot;GuestPath='C:\MutatorInput';ReadOnly=$true},
        @{HostPath=$payload;GuestPath='C:\MutatorPayload';ReadOnly=$true},
        @{HostPath=$directory;GuestPath='C:\MutatorRun';ReadOnly=$false})
    $configuration=Read-MutatorJson $Entry.Configuration
    $subtrees=@(Get-MutatorSubtree $Run.SourceRoot $configuration)
    $mutatorSubtree=[IO.Path]::GetRelativePath($Run.SourceRoot,$script:MutatorRoot)
    $quietSubtree=[IO.Path]::GetRelativePath($Run.SourceRoot,(Join-Path (Split-Path $script:MutatorRoot) 'QuietCliEcosystem/FrenchExDev.QuietCli.PoSh'))
    $copySubtrees=@(@($subtrees)+@($mutatorSubtree,$quietSubtree)|Sort-Object -Unique)
    foreach($subtree in $copySubtrees){
        $resolved=[IO.Path]::GetFullPath($subtree,$Run.SourceRoot)
        $prefix=[IO.Path]::GetFullPath($Run.SourceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'A sandbox source subtree escapes SourceRoot.'}
    }
    if($Entry.ResumeFrom){
        $resume=(Resolve-Path -LiteralPath $Entry.ResumeFrom -ErrorAction Stop).ProviderPath
        $mappings+=@{HostPath=(Split-Path $resume);GuestPath='C:\MutatorResume';ReadOnly=$true}
        $innerEntry.ResumeFrom=Join-Path 'C:\MutatorResume' (Split-Path $resume -Leaf)
    }
    if($Entry['RecheckFrom']){
        $baseline=(Resolve-Path -LiteralPath $Entry.RecheckFrom -ErrorAction Stop).ProviderPath
        $snapshot=Join-Path $payload 'recheck-input.json'
        Copy-Item -LiteralPath $baseline -Destination $snapshot
        if((Get-FileHash -LiteralPath $snapshot).Hash -cne $Entry.RecheckSha256){throw 'The selected recheck baseline changed since scheduling.'}
        $innerEntry.RecheckFrom='C:\MutatorPayload\recheck-input.json'
        $innerEntry.RecheckSha256=$Entry.RecheckSha256
    }
    $innerRun=@{SourceRoot=$sourceRoot;Packages=@($innerEntry);Schedule=$Run.Schedule;TestOrder=$Run.TestOrder
        StrykerRuntime='Host';StopPath='C:\MutatorRun\stop.json';ToolCacheRoot='C:\MutatorRun\tools';ContainerImageId=$null;IsolationBoundary='WindowsSandbox'}
    Write-MutatorJson (Join-Path $directory 'run.json') $innerRun
    Write-MutatorJson (Join-Path $payload 'request.json') @{Package=$Entry.Id;MutatorRelative=$mutatorRelative;Subtrees=$copySubtrees}
    Copy-Item -LiteralPath (Join-Path $script:MutatorRoot 'resources/WindowsSandbox/Start-Worker.ps1') -Destination (Join-Path $payload 'Start-Worker.ps1')
    Copy-Item -LiteralPath (Join-Path $script:MutatorRoot 'resources/WindowsSandbox/Invoke-Worker.ps1') -Destination (Join-Path $payload 'Invoke-Worker.ps1')
    $xml=New-MutatorSandboxConfiguration -Mappings $mappings -MemoryMiB ([math]::Max(2048,[int]($Run.Schedule.ReservedMemoryMiB/$Run.Schedule.Slots)))
    [IO.File]::WriteAllText((Join-Path $artifacts 'sandbox.wsb'),$xml)
    $id=[guid]::NewGuid().ToString()
    $State.Container=@{Engine='WindowsSandbox';Id=$id;Started=$false;JobPath=$directory;Connection=$id
        HostReportDirectory=$artifacts;HostExchangeDirectory=$directory;GuestExchangeDirectory='C:\MutatorRun'
        StatePath=(Join-Path $directory ('packages/'+$Entry.Id+'/state.json'));ProgressPath=(Join-Path $directory ('packages/'+$Entry.Id+'/mutants.jsonl'))
        ResourceLimits=@{Memory=$true;MemoryMiB=([xml]$xml).Configuration.MemoryInMB;Cpu=$false}}
    $State.Phase='Starting Windows Sandbox'
    Write-MutatorJson $StatePath $State
    if(Test-Path -LiteralPath (Join-Path $RunDirectory 'stop.json')){throw [OperationCanceledException]::new('Mutation run stopped before Windows Sandbox startup.')}
    $attempted=$false
    try{
        # The generated ID is retained before launch. Never attach to or stop another user's session.
        $attempted=$true
        $null=Invoke-MutatorSandboxCommand -Arguments @('start','--id',$id,'--config',$xml) -Directory $artifacts -TimeoutSeconds 180
        $State.Container.Started=$true
        $State.Phase='Preparation';Write-MutatorJson $StatePath $State
        if(Test-Path -LiteralPath (Join-Path $RunDirectory 'stop.json')){Write-MutatorJson (Join-Path $directory 'stop.json') @{Reason='UserRequested'}}
        $command='C:\MutatorPayload\tools\pwsh\pwsh.exe -NoLogo -NoProfile -NonInteractive -File C:\MutatorPayload\Start-Worker.ps1'
        $null=Invoke-MutatorSandboxCommand -Arguments @('exec','--id',$id,'--command',$command,'--run-as','System','--working-directory','C:\MutatorRun') -Directory $artifacts -TimeoutSeconds 604800
        $inner=Read-MutatorJson $State.Container.StatePath
        $boot=Read-MutatorJson (Join-Path $directory 'bootstrap-failure.json')
        if($boot){throw ('Windows Sandbox bootstrap failed: '+[string]$boot.Message)}
        if(!$inner -or $inner.Outcome -in @('Running','Pending')){throw 'Windows Sandbox exited without a final package report.'}
        foreach($key in @('Outcome','Phase','PSMutant','Stryker','Recheck','Error','ContextSha256','SourceSha256','FailedPhase')){$State[$key]=$inner[$key]}
    }finally{
        # Retain available full/partial evidence even if exec or the guest failed.
        $reports=Join-Path $directory ('packages/'+$Entry.Id)
        Copy-MutatorIsolatedReport -Source $reports -Destination $artifacts
        if($attempted){
            try{Stop-MutatorWindowsSandbox -Id $id -Directory $artifacts;$State.Container.Stopped=$true}
            catch{$State.Container.CleanupError=$_.Exception.Message;throw}
        }
    }
}
