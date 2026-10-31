function Confirm-MutatorWindowsResumeSource {
    param([string]$Path,[string]$SourceRoot,[string[]]$Subtrees)
    $receipt=Read-MutatorJson ($Path+'.context.json')
    $dependencies=@($receipt.Identity.Dependencies)
    if(!$dependencies.Count -or $dependencies.Count -ne $Subtrees.Count){throw 'Windows resume refused: the declared dependency set differs.'}
    foreach($subtree in $Subtrees){
        $previous=@($dependencies|Where-Object Path -CEQ $subtree)
        if($previous.Count -ne 1 -or (Get-MutatorSourceSnapshot (Join-Path $SourceRoot $subtree)).Sha256 -cne $previous[0].Sha256){throw 'Windows resume refused: source, test or dependency bytes differ.'}
    }
}
