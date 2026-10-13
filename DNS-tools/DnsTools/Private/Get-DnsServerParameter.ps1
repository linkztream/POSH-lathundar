function Get-DnsServerParameter {
    <#
    .SYNOPSIS
        Returns the splat that targets a DNS server with the DnsServer cmdlets.

    .DESCRIPTION
        Every DnsServer cmdlet call in the module is splatted with the hashtable
        returned here, so that alternate credentials are honoured everywhere or
        nowhere.

        Without credentials the result is @{ ComputerName = <server> } and the
        cmdlets run as the logged-on user. With credentials the result is
        @{ CimSession = <session> } from Get-DnsCimSession. When credentials are
        given but no CIM session can be opened, this throws: silently falling back
        to the logged-on user could make changes under the wrong identity.

    .PARAMETER Server
        The DNS server name.

    .PARAMETER Credential
        Alternate credentials. $null (or a credential without a user name, such as
        [pscredential]::Empty) means the logged-on user.

    .PARAMETER TimeoutSec
        Passed on to Get-DnsCimSession.

    .EXAMPLE
        $serverParameters = Get-DnsServerParameter -Server 'dc01'
        Get-DnsServerZone @serverParameters

        Lists the zones on dc01 as the logged-on user.

    .EXAMPLE
        $serverParameters = Get-DnsServerParameter -Server 'dc01' -Credential $cred
        Get-DnsServerZone @serverParameters

        Lists the zones on dc01 through a CIM session that uses $cred, or throws
        when no session can be opened.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter()]
        [AllowNull()]
        [pscredential]$Credential,

        [Parameter()]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSec = 300
    )

    $hasCredential = ($null -ne $Credential) -and ('' -ne [string]$Credential.UserName)
    if (-not $hasCredential) {
        Write-Verbose "DnsServer cmdlets target '$Server' as the logged-on user."
        return @{ ComputerName = $Server }
    }

    $session = Get-DnsCimSession -Server $Server -Credential $Credential -TimeoutSec $TimeoutSec
    if ($null -eq $session) {
        throw "Could not open a CIM session to '$Server' as '$($Credential.UserName)' (tried WSMan and DCOM). Check that WinRM or DCOM is reachable and that the account may read DNS, or omit -Credential to run as the logged-on user."
    }

    Write-Verbose "DnsServer cmdlets target '$Server' through a CIM session as '$($Credential.UserName)'."
    @{ CimSession = $session }
}
