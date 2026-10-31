<#
.SYNOPSIS
Expected behavior for the GuestJobExecution tests.

.DESCRIPTION
Bind each job to its owner, fixture/descriptor hashes and valid deadline; preserve argv, both
streams and actual exit. Do not replay completed jobs; cancellation/timeout and report mirroring
retain distinct proof.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {
    $script:GuestJobsRunner=Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'resources/containers/jobs/Invoke-GuestJobs.ps1'
    $script:GuestProcessRunner=Join-Path (Split-Path $script:GuestJobsRunner) 'Invoke-GuestJobProcess.ps1'
    function Save-GuestJobJson {
        <#
        .SYNOPSIS
        Write a guest-job fixture document at the requested test path.

        .DESCRIPTION
        Serializes controlled input/results for the job runner. The fixture caller owns the destination
        directory.
        #>
        param([string]$Path,[object]$Value);$Value|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $Path}
    function Invoke-GuestJobFixture {
        <#
        .SYNOPSIS
        Invoke the guest job runner with the current controlled test options.

        .DESCRIPTION
        Exercises job transport and lifecycle behavior using fixture payloads rather than a production
        mutation campaign.
        #>
        & $script:GuestJobsRunner @script:JobOptions}
    function Read-GuestJobResult {
        <#
        .SYNOPSIS
        Read the retained result of the current fixture job.

        .DESCRIPTION
        Preserves date strings while returning a mapping for exact outcome, ownership and cancellation
        assertions.
        #>
        Get-Content (Join-Path $script:JobDirectory 'result.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String}
}
Describe 'Guest job execution and retained reports' {
    BeforeEach {
        $script:JobSavedEnvironment=@{}
        foreach($name in @('MUTATOR_GUEST_FIXTURE_ROOT','MUTATOR_GUEST_FIXTURE_MODE','MUTATOR_GUEST_FIXTURE_EXIT')){
            $script:JobSavedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name,$null)
        }
        $script:JobCase=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:GuestJobRoot=Join-Path $script:JobCase 'guest space é '' $() ` marker'
        $script:JobsRoot=Join-Path $script:JobCase 'jobs'
        $script:JobId=[guid]::NewGuid().ToString('N')
        $script:JobDirectory=Join-Path $script:JobsRoot $script:JobId
        [void][IO.Directory]::CreateDirectory($script:JobDirectory)
        $module=Join-Path $script:GuestJobRoot 'modules/FrenchExDev.Mutator.PoSh'
        $script:GuestQualificationFixture=Join-Path $module 'resources/containers/probes/Test-WindowsAgImage.ps1'
        $script:GuestMutationFixture=Join-Path $module 'resources/containers/jobs/Invoke-GuestMutation.ps1'
        $child=@'
param([string]$ProofDirectory,[string]$JobDirectory,[string]$Root,[string]$JobsDirectory)
$ErrorActionPreference='Stop'
$directory=if($JobDirectory){$JobDirectory}else{$ProofDirectory}
@{Root=$Root;JobsDirectory=$JobsDirectory;Mutation=[bool]$JobDirectory}|ConvertTo-Json|Set-Content (Join-Path $directory 'invocation-arguments.json')
[IO.File]::AppendAllText((Join-Path $directory 'started.txt'),"owned child`n")
if($JobDirectory){
    $localRoot=Join-Path $env:MUTATOR_GUEST_FIXTURE_ROOT ('mutation-jobs/'+(Split-Path $JobDirectory -Leaf))
    $local=Join-Path $localRoot 'run/packages/p0000'
    [void][IO.Directory]::CreateDirectory((Join-Path $local 'stryker/reports'))
    [void][IO.Directory]::CreateDirectory((Join-Path $local 'sandbox'))
    [IO.File]::WriteAllText((Join-Path $local 'sandbox/not-a-report.txt'),'must not be mirrored')
    [IO.File]::WriteAllText((Join-Path $local 'state.json'),'{"Outcome":"Success","Fixture":true}')
    foreach($name in @('mutants.jsonl','stryker.jsonl','mutation.json','mutation.json.context.json')){[IO.File]::WriteAllText((Join-Path $local $name),'{"fixture":true}')}
    [IO.File]::WriteAllText((Join-Path $local 'stryker/reports/mutation-report.json'),'{"files":{}}')
    if($env:MUTATOR_GUEST_FIXTURE_MODE -eq 'wait-stop'){
        while(!(Test-Path (Join-Path $localRoot 'stop.json'))){Start-Sleep -Milliseconds 10}
    }
}
if($env:MUTATOR_GUEST_FIXTURE_MODE -eq 'slow'){Start-Sleep -Seconds 20}
[Console]::WriteLine('stdout é from owned child')
[Console]::Error.WriteLine('stderr é from owned child')
[IO.File]::WriteAllText((Join-Path $directory 'completed.txt'),'completed')
if($env:MUTATOR_GUEST_FIXTURE_EXIT){exit ([int]$env:MUTATOR_GUEST_FIXTURE_EXIT)}
'@
        foreach($path in @($script:GuestQualificationFixture,$script:GuestMutationFixture)){
            [void][IO.Directory]::CreateDirectory((Split-Path $path))
            [IO.File]::WriteAllText($path,$child,[Text.UTF8Encoding]::new($false))
        }
        $context=Join-Path $script:JobCase 'context.json'
        Save-GuestJobJson $context @{RunId='fixture-run'}
        $script:JobRequest=@{RunId='fixture-run';JobId=$script:JobId;Type='AgQualification';FixtureSha256=(Get-FileHash $script:GuestQualificationFixture).Hash}
        $script:JobOptions=@{Root=$script:GuestJobRoot;JobsDirectory=$script:JobsRoot;ContextPath=$context;Once=$true
            PowerShellExecutable=(Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'}));ControlBaseUri='http://127.0.0.1:1/'}
        $env:MUTATOR_GUEST_FIXTURE_ROOT=$script:GuestJobRoot
        Save-GuestJobJson (Join-Path $script:JobDirectory 'request.json') $script:JobRequest
    }
    AfterEach {
        foreach($entry in $script:JobSavedEnvironment.GetEnumerator()){[Environment]::SetEnvironmentVariable($entry.Key,$entry.Value)}
    }
    It 'initializes UTF-8 and forwards the selected named parameter: <ParameterName>' -ForEach @(@{ParameterName='ProofDirectory'},@{ParameterName='JobDirectory'}) {
        $previousEncoding=[Console]::OutputEncoding
        $previousExit=Get-Variable -Name LASTEXITCODE -ValueOnly -ErrorAction Ignore
        $env:MUTATOR_GUEST_FIXTURE_EXIT='7'
        try {
            & $script:GuestProcessRunner -ScriptFile $script:GuestQualificationFixture -ParameterName $ParameterName -Directory $script:JobDirectory
            [Console]::OutputEncoding.CodePage|Should -Be 65001
            Test-Path (Join-Path $script:JobDirectory 'completed.txt')|Should -BeTrue
            $local=Join-Path $script:GuestJobRoot ('mutation-jobs/'+$script:JobId+'/run/packages/p0000')
            Test-Path $local|Should -Be ($ParameterName -eq 'JobDirectory')
        } finally {
            [Console]::OutputEncoding=$previousEncoding
            Set-Variable -Name LASTEXITCODE -Scope Global -Value $previousExit
        }
    }
    It 'refuses an unsupported bootstrap parameter without running the selected fixture' {
        {& $script:GuestProcessRunner -ScriptFile $script:GuestQualificationFixture -ParameterName OtherParameter -Directory $script:JobDirectory}|Should -Throw '*ValidateSet*'
        Test-Path (Join-Path $script:JobDirectory 'started.txt')|Should -BeFalse
    }
    It 'retains both streams and a completed success receipt from the owned child' {
        Invoke-GuestJobFixture
        $result=Read-GuestJobResult
        $result.Outcome|Should -BeExactly Success
        $result.ExitCode|Should -Be 0
        $result.RunId|Should -BeExactly fixture-run
        $result.JobId|Should -BeExactly $script:JobId
        [datetimeoffset]::Parse($result.CompletedUtc)|Should -BeGreaterOrEqual ([datetimeoffset]::Parse($result.StartedUtc))
        (Get-Content (Join-Path $script:JobDirectory 'guest.stdout.log') -Raw)|Should -BeLike '*stdout é from owned child*'
        (Get-Content (Join-Path $script:JobDirectory 'guest.stderr.log') -Raw)|Should -BeLike '*stderr é from owned child*'
        Test-Path (Join-Path $script:JobDirectory 'result.json.tmp')|Should -BeFalse
    }
    It 'keeps a nonzero child exit distinct from a successful job' {
        $env:MUTATOR_GUEST_FIXTURE_EXIT='7'
        Invoke-GuestJobFixture
        $result=Read-GuestJobResult
        $result.Outcome|Should -BeExactly Failed
        $result.ExitCode|Should -Be 7
        Test-Path (Join-Path $script:JobDirectory 'completed.txt')|Should -BeTrue
    }
    It 'refuses a foreign request or changed fixture before starting a child: <Fault>' -ForEach @(
        @{Fault='run'},@{Fault='job'},@{Fault='type'},@{Fault='fixture'}
    ) {
        switch($Fault){
            run {$script:JobRequest.RunId='foreign'}
            job {$script:JobRequest.JobId='a'*32}
            type {$script:JobRequest.Type='ArbitraryScript'}
            fixture {$script:JobRequest.FixtureSha256='0'*64}
        }
        Save-GuestJobJson (Join-Path $script:JobDirectory 'request.json') $script:JobRequest
        Invoke-GuestJobFixture
        $result=Read-GuestJobResult
        $result.Outcome|Should -BeExactly Failed
        $result.Error|Should -Not -BeNullOrEmpty
        Test-Path (Join-Path $script:JobDirectory 'started.txt')|Should -BeFalse
    }
    It 'records malformed input and process-start failures without claiming execution: <Fault>' -ForEach @(@{Fault='json'},@{Fault='executable'}) {
        if($Fault -eq 'json'){[IO.File]::WriteAllText((Join-Path $script:JobDirectory 'request.json'),'invalid JSON')}
        else{$script:JobOptions.PowerShellExecutable=Join-Path $script:JobCase 'absent-executable'}
        Invoke-GuestJobFixture
        $result=Read-GuestJobResult
        $result.Outcome|Should -BeExactly Failed
        $result.Error|Should -Not -BeNullOrEmpty
        Test-Path (Join-Path $script:JobDirectory 'started.txt')|Should -BeFalse
    }
    It 'does not replay a completed job or launch missing and invalid directory requests' {
        Save-GuestJobJson (Join-Path $script:JobDirectory 'result.json') @{Outcome='Success';Marker='already-complete'}
        $before=(Get-FileHash (Join-Path $script:JobDirectory 'result.json')).Hash
        foreach($name in @(('A'*32),'not-a-job',[guid]::NewGuid().ToString('N'))){[void][IO.Directory]::CreateDirectory((Join-Path $script:JobsRoot $name))}
        Invoke-GuestJobFixture
        (Get-FileHash (Join-Path $script:JobDirectory 'result.json')).Hash|Should -BeExactly $before
        Test-Path (Join-Path $script:JobDirectory 'started.txt')|Should -BeFalse
        @(Get-ChildItem $script:JobsRoot -Filter 'started.txt' -Recurse).Count|Should -Be 0
    }
    It 'enforces an explicit qualification timeout and terminates only its child' {
        $env:MUTATOR_GUEST_FIXTURE_MODE='slow'
        $script:JobRequest.TimeoutSeconds=5
        Save-GuestJobJson (Join-Path $script:JobDirectory 'request.json') $script:JobRequest
        $elapsed=[Diagnostics.Stopwatch]::StartNew()
        Invoke-GuestJobFixture
        $elapsed.Stop()
        (Read-GuestJobResult).Outcome|Should -BeExactly TimedOut
        $elapsed.Elapsed.TotalSeconds|Should -BeLessThan 15
        Test-Path (Join-Path $script:JobDirectory 'started.txt')|Should -BeTrue
        Test-Path (Join-Path $script:JobDirectory 'completed.txt')|Should -BeFalse
    }
    It 'continues polling after a completed job in service mode' {
        $script:JobOptions.Once=$false
        Mock Start-Sleep {throw 'fixture-poll-complete'} -ParameterFilter {$Seconds -eq 2}
        {Invoke-GuestJobFixture}|Should -Throw '*fixture-poll-complete*'
        (Read-GuestJobResult).Outcome|Should -BeExactly Success
        Should -Invoke Start-Sleep -Times 1 -ParameterFilter {$Seconds -eq 2}
    }
    Describe 'PSMutant job transport' {
        BeforeEach {
            $script:JobRequest.Type='PSMutantPackage'
            $script:JobRequest.TimeoutSeconds=600
            $script:JobRequest.FixtureSha256=(Get-FileHash $script:GuestMutationFixture).Hash
            Save-GuestJobJson (Join-Path $script:JobDirectory 'mutation.json') @{Fixture=$true}
            $script:JobRequest.DescriptorSha256=(Get-FileHash (Join-Path $script:JobDirectory 'mutation.json')).Hash
            $script:JobMirror=Join-Path $script:JobDirectory 'run/packages/p0000'
            [void][IO.Directory]::CreateDirectory((Join-Path $script:JobMirror 'stryker/reports'))
            Save-GuestJobJson (Join-Path $script:JobDirectory 'request.json') $script:JobRequest
        }
        It 'mirrors final reports and contexts while keeping the sandbox local' {
            Invoke-GuestJobFixture
            (Read-GuestJobResult).Outcome|Should -BeExactly Success
            $arguments=Get-Content (Join-Path $script:JobDirectory 'invocation-arguments.json') -Raw|ConvertFrom-Json
            $arguments.Root|Should -BeExactly $script:GuestJobRoot
            $arguments.JobsDirectory|Should -BeExactly $script:JobsRoot
            $arguments.Mutation|Should -BeTrue
            $local=Join-Path $script:GuestJobRoot ('mutation-jobs/'+$script:JobId+'/run/packages/p0000')
            foreach($name in @('state.json','mutants.jsonl','stryker.jsonl','mutation.json','mutation.json.context.json','stryker/reports/mutation-report.json')){
                (Get-FileHash (Join-Path $script:JobMirror $name)).Hash|Should -BeExactly (Get-FileHash (Join-Path $local $name)).Hash
            }
            Test-Path (Join-Path $script:JobMirror 'sandbox')|Should -BeFalse
        }
        It 'refuses a changed descriptor before executing its script' {
            $script:JobRequest.DescriptorSha256='f'*64
            Save-GuestJobJson (Join-Path $script:JobDirectory 'request.json') $script:JobRequest
            Invoke-GuestJobFixture
            (Read-GuestJobResult).Error|Should -BeLike '*descriptor fingerprint differs*'
            Test-Path (Join-Path $script:JobDirectory 'started.txt')|Should -BeFalse
        }
        It 'rejects an invalid timeout before running a mutation: <Value>' -ForEach @(@{Value=0},@{Value=86401},@{Value='invalid'}) {
            $script:JobRequest.TimeoutSeconds=$Value
            Save-GuestJobJson (Join-Path $script:JobDirectory 'request.json') $script:JobRequest
            Invoke-GuestJobFixture
            (Read-GuestJobResult).Error|Should -BeLike '*Invalid Windows mutation timeout*'
            Test-Path (Join-Path $script:JobDirectory 'started.txt')|Should -BeFalse
        }
        It 'transports a cooperative stop and keeps cancellation distinct from timeout: <Reason>' -ForEach @(@{Reason='UserRequested'},@{Reason='TimedOut'}) {
            $env:MUTATOR_GUEST_FIXTURE_MODE='wait-stop'
            if($Reason -eq 'UserRequested'){Save-GuestJobJson (Join-Path $script:JobDirectory 'stop.json') @{Reason='UserRequested'}}
            else{$script:JobRequest.TimeoutSeconds=1;Save-GuestJobJson (Join-Path $script:JobDirectory 'request.json') $script:JobRequest}
            Invoke-GuestJobFixture
            $expected=if($Reason -eq 'TimedOut'){'TimedOut'}else{'Interrupted'}
            (Read-GuestJobResult).Outcome|Should -BeExactly $expected
            $stop=Join-Path $script:GuestJobRoot ('mutation-jobs/'+$script:JobId+'/stop.json')
            (Get-Content $stop -Raw|ConvertFrom-Json).Stop|Should -BeTrue
        }
        It 'refuses a missing host report destination instead of losing local reports' {
            $casePrefix=[IO.Path]::GetFullPath($script:JobCase)+[IO.Path]::DirectorySeparatorChar
            if(!([IO.Path]::GetFullPath($script:JobMirror)).StartsWith($casePrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'The fixture report destination escaped its owned case directory.'}
            Remove-Item -LiteralPath $script:JobMirror -Recurse -Force
            Invoke-GuestJobFixture
            $result=Read-GuestJobResult
            $result.Outcome|Should -BeExactly Failed
            $result.Error|Should -BeLike '*host did not prepare*'
        }
    }
}
