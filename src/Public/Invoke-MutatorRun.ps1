function Invoke-MutatorRun {
    <#
    .SYNOPSIS
    Schedule selected modules for isolated mutation or recheck.

    .DESCRIPTION
    Validates scope, isolation and budgets before launch. Supports synchronous, interactive and detached
    monitoring with retained plans/evidence.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][Alias('Path')][string[]]$ModulePath, [string[]]$Include=@('*'), [string]$SourceRoot, [string]$RunRoot,
        [ValidateSet('Windows','Linux')][string]$OS,
        [ValidateRange(1,64)][int]$WorkerBudget = [math]::Min(4,[Environment]::ProcessorCount),
        [ValidateRange(1,64)][int]$ThrottleLimit = 2, [ValidateRange(1,64)][Nullable[int]]$Workers,
        [ValidateRange(1024,1048576)][int]$MemoryBudgetMiB = 4096,
        [ValidateSet('Configured','FocusedFirst')][string]$TestOrder = 'FocusedFirst',
        [string]$ResumeFrom,[string]$RecheckFrom, [switch]$Background, [switch]$SkipStryker,[switch]$UI,[switch]$Parallel,[ValidateSet('Auto','Host')][string]$StrykerRuntime='Auto',
        [string]$ContainerBaseImage, [string]$ContainerConnection,
        [Alias('Engine')][ValidateSet('Podman','Docker')][string]$ContainerEngine,
        [string]$WindowsGuestImage,[ValidateRange(1,1440)][int]$WindowsGuestTimeoutMinutes=120,[string]$Ram,
        [ValidateRange(1,86400)][Nullable[int]]$WindowsGuestJobTimeoutSeconds)
    if(!$OS){$OS=if($IsWindows){'Windows'}elseif($IsLinux){'Linux'}else{throw 'Select -OS Windows or Linux; mutation execution on the host is prohibited.'}}
    if($WindowsGuestImage){throw 'Windows PSMutant campaigns require Windows Sandbox on a Windows host. Use -OS Windows; the legacy KVM guest adapter is not a campaign runtime.'}
    if($ContainerEngine -and $ContainerEngine -ne 'Podman'){throw 'Linux PSMutant campaigns require Podman; Docker is not a campaign runtime.'}
    if($OS -eq 'Windows' -and !$IsWindows){throw 'Windows Sandbox requires a Windows host. Launch this campaign on Windows.'}
    $isolation=if($OS -eq 'Windows'){'WindowsSandbox'}else{'Podman'}
    $hostMemoryLimit=if($PSBoundParameters.ContainsKey('Ram')){ConvertTo-MutatorMemoryLimit $Ram}else{$null}
    $paths = @(foreach($inputPath in $ModulePath){
        $resolved=(Resolve-Path -LiteralPath $inputPath -ErrorAction Stop).ProviderPath
        if(Test-Path (Join-Path $resolved 'test/psmutant.config.json')){$resolved}
        else{Get-ChildItem -LiteralPath $resolved -Directory|Where-Object{Test-Path (Join-Path $_.FullName 'test/psmutant.config.json')}|ForEach-Object FullName}
    })
    $paths=@($paths|Where-Object{$name=Split-Path $_ -Leaf;@($Include|Where-Object{$name -like $_}).Count -gt 0}|Sort-Object -Unique)
    if(!$paths.Count){throw 'No module with a mutation configuration matches the selection.'}
    if (!$SourceRoot) { $SourceRoot = Get-MutatorModuleRoot $paths[0] }
    $SourceRoot = (Resolve-Path -LiteralPath $SourceRoot -ErrorAction Stop).ProviderPath
    if ($ResumeFrom -and $paths.Count -ne 1) { throw 'Resume requires one explicit module.' }
    if($RecheckFrom){
        if($ResumeFrom -or $paths.Count -ne 1){throw 'Recheck requires one explicit module and cannot be combined with resume.'}
        if($Workers -and $Workers -ne 1){throw 'Recheck uses one worker; do not request parallel mutation workers for a diagnostic recheck.'}
        $Workers=1
        $RecheckFrom=(Resolve-Path -LiteralPath $RecheckFrom -ErrorAction Stop).ProviderPath
        $prior=Read-MutatorJson $RecheckFrom
        if(!@($prior['survivors']).Count){throw 'Recheck requires recorded survivors.'}
    }
    $entries = @()
    foreach ($path in $paths) {
        $relative = [IO.Path]::GetRelativePath($SourceRoot,$path)
        if ($relative -eq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar) -or [IO.Path]::IsPathRooted($relative)) { throw 'All module paths must be inside SourceRoot.' }
        $configuration = Join-Path $path 'test/psmutant.config.json'
        if (!(Test-Path $configuration)) { throw "Missing mutation configuration: $configuration" }
        $data = Read-MutatorJson $configuration
        [void](Get-MutatorSubtree $SourceRoot $data)
        Confirm-MutatorEquivalence -ModulePath $path -Configuration $data
        if ($data.coveredLinesOnly -ne $false) { throw 'The complete mutation gate requires coveredLinesOnly: false.' }
        $recipe=if($OS -eq 'Linux'){Get-MutatorContainerRecipe $path -Required}
        $entries += @{ Id=('p{0:d4}' -f $entries.Count); Name=(Split-Path $path -Leaf); ModulePath=$path; Configuration=$configuration
            ResumeFrom=$ResumeFrom;RecheckFrom=$RecheckFrom;RecheckSha256=$(if($RecheckFrom){(Get-FileHash -LiteralPath $RecheckFrom).Hash}else{$null}); ContainerRecipe=$recipe; IsolationRuntime=$isolation; Platform=$OS.ToLowerInvariant(); Stryker=(!$RecheckFrom -and !$SkipStryker -and (Test-Path (Join-Path $path 'engine/dotnet-tools.json'))) }
    }
    if($Parallel -and !$PSBoundParameters.ContainsKey('ThrottleLimit')){$ThrottleLimit=[math]::Min($WorkerBudget,[Environment]::ProcessorCount)}
    $memoryPerWorker=if($OS -eq 'Windows'){2048}else{1024}
    $schedule = New-MutatorSchedule -Packages @($entries.Id) -Workers $Workers -WorkerBudget $WorkerBudget -ThrottleLimit $ThrottleLimit -MemoryBudgetMiB $MemoryBudgetMiB -MemoryPerWorkerMiB $memoryPerWorker
    if(!$RunRoot){
        if($paths.Count -gt 1){throw 'For multiple modules, supply -RunRoot explicitly to select the report directory.'}
        $RunRoot=Join-Path $paths[0] 'test/Artifacts/mutator'
    }
    $root = Get-MutatorRunRoot $RunRoot
    $id = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $directory = Join-Path $root $id
    if (!$PSCmdlet.ShouldProcess($directory,'Start a complete isolated mutation run')) { return }
    $ContainerEngine='Podman'
    if(!$PSBoundParameters.ContainsKey('ContainerConnection') -and $ContainerEngine -eq $script:MutatorPreferredContainerEngine){$ContainerConnection=$script:MutatorPreferredContainerConnection}
    $containerSetting=$null
    if($OS -eq 'Linux'){
        $containerSetting=Get-MutatorEngineSetting $ContainerEngine
        Set-MutatorContainerContext -Engine $ContainerEngine -Connection $ContainerConnection -Setting $containerSetting
    }
    if($UI -and ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected)){throw 'The live UI requires an interactive terminal. Use -Background and Get-MutatorProgress for redirected sessions.'}
    $watchdog=$null
    if($null -ne $hostMemoryLimit){
        $watchdogOptions=@{LimitGB=($hostMemoryLimit/1e9)}
        if($OS -eq 'Linux' -and $ContainerConnection -and $ContainerEngine -eq 'Podman'){
            $candidate=$ContainerConnection -creplace '-root$',''
            if($candidate -match '^[A-Za-z0-9][A-Za-z0-9_-]*$'){
                $machine=Invoke-MutatorNative podman @('machine','inspect',$candidate) $script:MutatorRoot 30
                if($machine.Outcome -ceq 'Success'){$watchdogOptions.PodmanMachine=$candidate}
            }
        }
        $watchdog=Start-MutatorMemoryWatchdog @watchdogOptions
    }
    $run = @{ SchemaVersion=1; Id=$id; Outcome='Starting'; CreatedUtc=[datetime]::UtcNow.ToString('O'); Platform=$(if($IsWindows){'windows'}elseif($IsMacOS){'macos'}else{'linux'})
        Runtime=$PSVersionTable.PSVersion.ToString(); HostName=[Environment]::MachineName; SourceRoot=$SourceRoot; Packages=$entries; Schedule=$schedule; TestOrder=$TestOrder; StrykerRuntime=$StrykerRuntime; ContainerBaseImage=$ContainerBaseImage; ContainerConnection=$ContainerConnection; WindowsGuestImage=$WindowsGuestImage; WindowsGuestTimeoutMinutes=$WindowsGuestTimeoutMinutes; Parallel=[bool]$Parallel; Process=$null; Error=$null }
    $run.TargetOS=$OS
    $run.Mode=if($RecheckFrom){'Recheck'}else{'Full'}
    $run.Isolation=$isolation
    $run.HostMemoryLimitBytes=$hostMemoryLimit
    $run.ContainerEngine=if($OS -eq 'Linux'){$ContainerEngine}else{$null}
    $run.ContainerSetting=$containerSetting
    $run.WindowsGuestJobTimeoutSeconds=$WindowsGuestJobTimeoutSeconds
    $run.MemoryWatchdogPath=if($watchdog){$watchdog.Path}else{$null}
    Write-MutatorJson (Join-Path $directory 'run.json') $run
    if ($Background -or $UI) { Write-MutatorJson (Join-Path $directory 'supervisor.json') (Start-MutatorWorker $directory) }
    else { Invoke-MutatorRunCore $directory }
    if($UI){Watch-MutatorRun -Path $directory;return}
    Get-MutatorRun -Path $directory
}
