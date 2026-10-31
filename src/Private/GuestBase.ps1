function Read-MutatorGuestRun {
    <#
    .SYNOPSIS
    Load a retained managed guest identity from a directory or receipt.

    .DESCRIPTION
    Requires a recognized kind and run ID. Returns the receipt path and parsed run for ownership checks.
    #>

    param([string]$Path)
    $resolved=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $file=if(Test-Path -LiteralPath $resolved -PathType Container){Join-Path $resolved 'guest.json'}else{$resolved}
    $run=Read-MutatorJson $file
    if(!$run -or $run['Kind'] -notin @('WindowsBase','WindowsModule') -or !$run['RunId']){throw 'A retained Mutator Windows guest run is required.'}
    @{File=$file;Run=$run}
}

function Get-MutatorOwnedGuest {
    <#
    .SYNOPSIS
    Inspect a guest and verify its retained ownership.

    .DESCRIPTION
    Restores engine context and requires exact container ID and matching run label. Foreign or
    unavailable containers are refused.
    #>

    param([Collections.IDictionary]$Run)
    if(!$Run['ContainerId']){throw 'The guest run has no created container identity.'}
    Restore-MutatorContainerContext $Run
    $inspect=Invoke-MutatorContainerCommand -Arguments @('inspect',$Run.ContainerId) -Directory $script:MutatorRoot -Connection $Run.Connection
    if($inspect.Outcome -ne 'Success'){throw 'The owned guest container cannot be inspected.'}
    $identity=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
    if($identity.Id -cne $Run.ContainerId -or $identity.Config.Labels['org.frenchexdev.mutator.guest-run'] -cne $Run.RunId){throw 'The container no longer belongs to this guest run.'}
    $identity
}

function Test-MutatorGuestReadiness {
    <#
    .SYNOPSIS
    Check readiness against the expected pinned guest runtime.

    .DESCRIPTION
    Requires success, matching fingerprint, exact PowerShell/SDK versions and one entry for every tool.
    Duplicate or unknown tools fail.
    #>

    param([Collections.IDictionary]$Run,[Collections.IDictionary]$Proof)
    if($Proof['Outcome'] -cne 'Success' -or $Proof['Fingerprint'] -cne $Run.Fingerprint -or
        $Proof['PowerShell'] -cne $Run.ExpectedPowerShell -or $Proof['DotnetSdk'] -cne $Run.ExpectedDotnetSdk){return $false}
    $expected=@{Pester='6.2.0';PSMutant='0.6.0';PSScriptAnalyzer='1.25.0';'powershell-yaml'='0.4.12'}
    if(@($Proof['Tools']).Count -ne $expected.Count){return $false}
    foreach($tool in $Proof.Tools){
        if($tool -isnot [Collections.IDictionary] -or !$expected.ContainsKey([string]$tool['Name']) -or $expected[[string]$tool['Name']] -cne $tool['Version']){return $false}
        $expected.Remove([string]$tool['Name'])
    }
    $expected.Count -eq 0
}
