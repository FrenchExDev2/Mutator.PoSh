# Linux has no CimCmdlets transport. These signatures allow the same unit tests
# to validate the Windows requests through Pester mocks; they never perform I/O.
if (!(Get-Command Get-CimInstance -CommandType Cmdlet -ErrorAction SilentlyContinue)) {
    function script:Get-CimInstance {
        [CmdletBinding()]
        param([string]$ClassName, [string]$Filter)
        throw 'A Windows CIM contract must be mocked in this test.'
    }
}
if (!(Get-Command New-CimInstance -CommandType Cmdlet -ErrorAction SilentlyContinue)) {
    function script:New-CimInstance {
        [CmdletBinding()]
        param([string]$ClassName, [switch]$ClientOnly, [hashtable]$Property)
        throw 'A Windows CIM contract must be mocked in this test.'
    }
}
if (!(Get-Command Invoke-CimMethod -CommandType Cmdlet -ErrorAction SilentlyContinue)) {
    function script:Invoke-CimMethod {
        [CmdletBinding()]
        param([string]$ClassName, [string]$MethodName, [hashtable]$Arguments)
        throw 'A Windows CIM contract must be mocked in this test.'
    }
}
