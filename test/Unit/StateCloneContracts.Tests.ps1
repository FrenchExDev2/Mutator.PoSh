<#
.SYNOPSIS
Expected behavior for the StateCloneContracts tests.

.DESCRIPTION
Clone supported nested collections while preserving comparers and immutable identities. Unsupported,
computed, cyclic or excessive-depth state must fail rather than sharing partially copied mutable
graphs.

.NOTES
Unit-level contract evidence. Filesystem and child-process fixtures may run locally; mocked
platform/tool boundaries remain simulations. A pass covers the asserted scenarios only.
Each It case states its scenario-specific expectation. Every expanded -ForEach case must pass.
#>

BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Cloning mutable module state between Pester containers' {
    It 'retains immutable values and statically bound callables without changing their identity' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $method=[Math].GetMethod('Abs',[type[]]@([double]))
            $delegate=[Delegate]::CreateDelegate([Func[double,double]],$method)
            $values=@($null,'é',42,$true,[datetime]'2026-10-27T00:00:00Z',[version]'1.2.3',[uri]'https://example.invalid/',[regex]'needle',[StringComparer]::Ordinal,$delegate,[scriptblock]::Create('42'))
            foreach($value in $values){
                $copy=(Copy-MutatorStateValue $value).Value
                if($null -eq $value){$copy|Should -BeNullOrEmpty}
                elseif($value.GetType().IsValueType){$copy|Should -Be $value;$copy.GetType()|Should -Be $value.GetType()}
                else{[object]::ReferenceEquals($copy,$value)|Should -BeTrue}
            }
            $delegate.Invoke(-2)|Should -Be 2
        }
    }
    It 'clones dictionaries deeply while preserving key comparison and source contents: <Kind>' -ForEach @(@{Kind='hashtable'},@{Kind='ordered'},@{Kind='generic'}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Kind=$Kind} {
            param($Kind)
            $original=switch($Kind){
                hashtable {,[hashtable]::new([StringComparer]::Ordinal)}
                ordered {,[Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)}
                generic {,[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)}
            }
            $original['Key']=@{Count=1}
            $original['key']=@{Count=2}
            $copy=(Copy-MutatorStateValue $original).Value
            $copy.GetType()|Should -Be $original.GetType()
            [object]::ReferenceEquals($copy,$original)|Should -BeFalse
            $copy['Key'].Count=99
            $copy['key'].Count|Should -Be 2
            $original['Key'].Count|Should -Be 1
            $original['key'].Count|Should -Be 2
            $copy['New']='independent'
            $contains=if($Kind -eq 'generic'){$original.ContainsKey('New')}else{$original.Contains('New')}
            $contains|Should -BeFalse
        }
    }
    It 'preserves a hash set comparer while isolating later additions' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            $original=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            [void]$original.Add('Value')
            $copy=(Copy-MutatorStateValue $original).Value
            $copy.Contains('VALUE')|Should -BeTrue
            [void]$copy.Add('other')
            $original.Contains('other')|Should -BeFalse
            [object]::ReferenceEquals($copy.Comparer,$original.Comparer)|Should -BeTrue
        }
    }
    It 'clones typed arrays lists and note-property objects without sharing nested mutable values: <Kind>' -ForEach @(@{Kind='array'},@{Kind='arraylist'},@{Kind='list'},@{Kind='object'}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Kind=$Kind} {
            param($Kind)
            $nested=@{Value=1}
            $original=switch($Kind){
                array {,[object[]]@($nested)}
                arraylist {$list=[Collections.ArrayList]::new();[void]$list.Add($nested);,$list}
                list {$list=[Collections.Generic.List[object]]::new();$list.Add($nested);,$list}
                object {[pscustomobject]@{Nested=$nested}}
            }
            $copy=(Copy-MutatorStateValue $original).Value
            $copy.GetType()|Should -Be $original.GetType()
            [object]::ReferenceEquals($copy,$original)|Should -BeFalse
            if($Kind -eq 'object'){$copy.Nested.Value=2}else{$copy[0].Value=2}
            $nested.Value|Should -Be 1
            $empty=(Copy-MutatorStateValue ([int[]]@())).Value
            $empty.GetType()|Should -Be ([int[]])
            $empty.Length|Should -Be 0
        }
    }
    It 'refuses unsupported state instead of reusing a partially copied graph: <Kind>' -ForEach @(
        @{Kind='closure'},@{Kind='key'},@{Kind='readonly'},@{Kind='multidimensional'},@{Kind='computed'},@{Kind='stream'}
    ) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Kind=$Kind} {
            param($Kind)
            $original=switch($Kind){
                closure {{$captured}.GetNewClosure()}
                key {@{42='not a string key'}}
                readonly {([Collections.Specialized.OrderedDictionary]::new()).AsReadOnly()}
                multidimensional {,[int[,]]::new(2,2)}
                computed {$value=[pscustomobject]@{};$value|Add-Member -MemberType ScriptProperty -Name Computed -Value {throw 'A computed property must not be evaluated.'};$value}
                stream {[IO.MemoryStream]::new()}
            }
            try {{Copy-MutatorStateValue $original}|Should -Throw '*fresh module*'}
            finally{if($original -is [IDisposable]){$original.Dispose()}}
        }
    }
    It 'bounds graph depth and rejects cyclic state before attempting import reuse' {
        InModuleScope FrenchExDev.Mutator.PoSh {
            (Copy-MutatorStateValue value -Depth 24).Value|Should -BeExactly value
            {Copy-MutatorStateValue value -Depth 25}|Should -Throw '*cyclic or too deep*'
            $graph='leaf'
            foreach($level in 1..24){$graph=@{Nested=$graph}}
            $copy=(Copy-MutatorStateValue $graph).Value
            foreach($level in 1..24){$copy=$copy.Nested}
            $copy|Should -BeExactly leaf
            {Copy-MutatorStateValue @{Nested=$graph}}|Should -Throw '*cyclic or too deep*'
            $cycle=@{};$cycle.Self=$cycle
            {Copy-MutatorStateValue $cycle}|Should -Throw '*cyclic or too deep*'
        }
    }
}
