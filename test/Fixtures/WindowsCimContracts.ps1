# Linux has no CimCmdlets transport. These signatures allow the same unit tests
# to validate the Windows requests through Pester mocks; they never perform I/O.
if (!(Get-Command Get-CimInstance -CommandType Cmdlet -ErrorAction SilentlyContinue)) {
    function script:Get-CimInstance {
        <#
        .SYNOPSIS
        Declare a mockable Windows CIM query boundary on other platforms.

        .DESCRIPTION
        Throws unless the test supplies a mock; it must never query a real host through this fixture.
        #>

        [CmdletBinding()]
        param([string]$ClassName, [string]$Filter)
        throw 'A Windows CIM contract must be mocked in this test.'
    }
}
if (!(Get-Command New-CimInstance -CommandType Cmdlet -ErrorAction SilentlyContinue)) {
    function script:New-CimInstance {
        <#
        .SYNOPSIS
        Declare a mockable CIM object-creation boundary.

        .DESCRIPTION
        Throws unless replaced by the test, preventing fixture setup from allocating real Windows resources.
        #>

        [CmdletBinding()]
        param([string]$ClassName, [switch]$ClientOnly, [hashtable]$Property)
        throw 'A Windows CIM contract must be mocked in this test.'
    }
}
if (!(Get-Command Invoke-CimMethod -CommandType Cmdlet -ErrorAction SilentlyContinue)) {
    function script:Invoke-CimMethod {
        <#
        .SYNOPSIS
        Declare a mockable CIM method boundary.

        .DESCRIPTION
        Throws unless replaced by the test, so simulated detached-launch assertions cannot create a real
        worker.
        #>

        [CmdletBinding()]
        param([string]$ClassName, [string]$MethodName, [hashtable]$Arguments)
        throw 'A Windows CIM contract must be mocked in this test.'
    }
}
