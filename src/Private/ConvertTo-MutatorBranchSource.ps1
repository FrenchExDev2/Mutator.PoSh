function ConvertTo-MutatorBranchSource {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$RelativePath,
        [ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')][string]$ObserverNamespace)
    # Separate observation from a recorder that is itself a production test subject.
    # Only injected code uses these names; original source text is never renamed.
    $writeCommand='Write-MutatorBranch'+$ObserverNamespace
    $enumerableCommand='Get-MutatorBranch'+$ObserverNamespace+'Enumerable'
    $probeEnvironment='MUTATOR_BRANCH_PROBE'+$ObserverNamespace
    $text=[IO.File]::ReadAllText($Path)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($text,$Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Branch instrumentation requires parseable original source.'}
    $branches=[Collections.Generic.List[object]]::new()
    $edits=[Collections.Generic.List[object]]::new()
    $add={
        param($Node,$Kind,$Mode='Boolean')
        $key=$RelativePath+'|'+$Kind+'|'+$Node.Extent.StartOffset+'|'+$Node.Extent.EndOffset
        $id=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))).ToLowerInvariant()
        $branches.Add(@{Id=$id;File=$RelativePath;Kind=$Kind;Line=$Node.Extent.StartLineNumber;Column=$Node.Extent.StartColumnNumber;Outcomes=$(if($Mode -eq 'Hit'){@('hit')}else{@('true','false')})})
        if($Mode -eq 'Hit'){
            $edits.Add(@{Offset=($Node.Extent.StartOffset+1);Length=0;Text=("`n[void]("+$writeCommand+" -Id '"+$id+"' -Hit)`n")})
        }else{
            $opening=if($Mode -eq 'Enumerable'){"("+$enumerableCommand+" -Id '"+$id+"' -Value ("}else{"("+$writeCommand+" -Id '"+$id+"' -Value ([bool]("}
            $closing=if($Mode -eq 'Enumerable'){'))'}else{')))'}
            $edits.Add(@{Offset=$Node.Extent.StartOffset;Length=($Node.Extent.EndOffset-$Node.Extent.StartOffset);Text=$opening})
            $edits.Add(@{Offset=$Node.Extent.EndOffset;Length=0;Text=$closing})
        }
        $id
    }
    foreach($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.Ast]},$true)){
        if($node -is [Management.Automation.Language.IfStatementAst]){
            foreach($clause in $node.Clauses){$null=& $add $clause.Item1 If}
        }elseif($node -is [Management.Automation.Language.ForEachStatementAst]){
            $null=& $add $node.Condition Foreach Enumerable
        }elseif($node -is [Management.Automation.Language.LoopStatementAst] -and $node.Condition){
            $null=& $add $node.Condition Loop
        }elseif($node -is [Management.Automation.Language.TernaryExpressionAst]){
            $null=& $add $node.Condition Ternary
        }elseif($node -is [Management.Automation.Language.BinaryExpressionAst] -and $node.Operator -in @([Management.Automation.Language.TokenKind]::And,[Management.Automation.Language.TokenKind]::Or)){
            $null=& $add $node.Left LogicalLeft
            $null=& $add $node.Right LogicalRight
        }elseif($node -is [Management.Automation.Language.SwitchStatementAst]){
            foreach($clause in $node.Clauses){$null=& $add $clause.Item2 SwitchCase Hit}
            if($node.Default){$null=& $add $node.Default SwitchDefault Hit}
            else{
                $key=$RelativePath+'|SwitchDefault|'+$node.Extent.StartOffset
                $id=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))).ToLowerInvariant()
                $branches.Add(@{Id=$id;File=$RelativePath;Kind='SwitchDefault';Line=$node.Extent.StartLineNumber;Column=$node.Extent.StartColumnNumber;Outcomes=@('hit')})
                $edits.Add(@{Offset=($node.Extent.EndOffset-1);Length=0;Text=("`ndefault { [void]("+$writeCommand+" -Id '"+$id+"' -Hit) }`n")})
            }
        }
    }
    foreach($edit in $edits|Sort-Object @{e='Offset';Descending=$true},Length){$text=$text.Insert($edit.Offset,$edit.Text)}
    $parseTokens=$null;$parseErrors=$null
    $rewritten=[Management.Automation.Language.Parser]::ParseInput($text,$Path,[ref]$parseTokens,[ref]$parseErrors)
    if($parseErrors.Count){throw ('Instrumented source is invalid: '+$RelativePath+' : '+$parseErrors[0].Message)}
    # A forced module import can remove its global commands while leaving global
    # variables alive. Check the callable recorder instead of a stale readiness flag.
    $prolog="`nif (!(Get-Command -Name '"+$writeCommand+"' -CommandType Function -ErrorAction Ignore) -or !(Get-Command -Name '"+$enumerableCommand+"' -CommandType Function -ErrorAction Ignore)) { . `$env:"+$probeEnvironment+" }`n"
    $position=if($rewritten.ParamBlock){$rewritten.ParamBlock.Extent.EndOffset}elseif($rewritten.UsingStatements.Count){$rewritten.UsingStatements[-1].Extent.EndOffset}elseif($rewritten.EndBlock.Statements.Count){$rewritten.EndBlock.Statements[0].Extent.StartOffset}else{$text.Length}
    $text=$text.Insert($position,$prolog)
    @{Code=$text;Branches=$branches.ToArray();Sha256=(Get-FileHash -LiteralPath $Path).Hash;Path=$RelativePath}
}
