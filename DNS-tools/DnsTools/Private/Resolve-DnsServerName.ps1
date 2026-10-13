function Resolve-DnsServerName {
    <#
    .SYNOPSIS
        Returns the DNS server name to use, defaulting to the logon server.

    .DESCRIPTION
        Returns the given server name trimmed and in lower case (a leading "\\" is
        removed so that "\\DC01" works too). Without a name, the logon server from
        $env:LOGONSERVER is used, because that is the domain controller the current
        session already trusts and it runs DNS in an AD-integrated environment.
        Throws when no name is given and LOGONSERVER is empty; the public command
        cannot do anything useful without a server.

        The resolved name is written to the Verbose stream.

    .PARAMETER Server
        The DNS server name. Optional.

    .EXAMPLE
        Resolve-DnsServerName -Server 'DC01.contoso.local'

        Returns 'dc01.contoso.local'.

    .EXAMPLE
        Resolve-DnsServerName

        Returns the logon server, for example 'dc02', or throws when LOGONSERVER
        is not set.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Server
    )

    $candidate = ''
    if ($Server) {
        $candidate = $Server.Trim()
    }

    if (-not $candidate) {
        $logonServer = $env:LOGONSERVER
        if ($logonServer) {
            $candidate = $logonServer.Trim()
        }

        $candidate = $candidate -replace '^\\\\', ''
        if (-not $candidate) {
            throw 'No default DNS server (LOGONSERVER is not set). Specify -Server.'
        }

        Write-Verbose "No -Server given; using the logon server '$candidate'."
    }

    $resolved = ($candidate -replace '^\\\\', '').ToLowerInvariant()
    if (-not $resolved) {
        throw "'$Server' is not a valid DNS server name. Specify -Server."
    }

    Write-Verbose "DNS server: '$resolved'."
    $resolved
}
