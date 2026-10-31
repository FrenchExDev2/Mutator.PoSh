function Invoke-MutatorStryker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModulePath,[Parameter(Mandatory)][string]$Artifacts,[ValidateRange(1,64)][int]$Workers=2,[ValidateSet('Auto','Host')][string]$Runtime='Auto')
    Invoke-MutatorStrykerCore $ModulePath $Artifacts $Workers $Runtime
}
