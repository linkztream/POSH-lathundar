function Get-DnsCimSession {
    <#
    .SYNOPSIS
        Returns a cached, verified CIM session to a DNS server, or $null.

    .DESCRIPTION
        The DnsServer cmdlets have no -Credential parameter, so alternate
        credentials can only be used through a CIM session. This helper opens one
        with WSMan first and DCOM as fallback (DCOM still works where WinRM is
        blocked), and verifies it by querying MicrosoftDNS_Server in the
        root\MicrosoftDNS namespace: a session that opens but cannot see the DNS
        provider is useless for the DnsServer cmdlets.

        Results are cached per server in $script:CimSessionCache. A server where no
        session could be opened is cached as 'Unavailable' so that every later call
        fails fast instead of waiting for two more timeouts. The module's OnRemove
        handler closes cached sessions.

        Returns $null when no session can be opened; the caller decides whether that
        is fatal (Get-DnsServerParameter throws when credentials were given).

    .PARAMETER Server
        The DNS server name.

    .PARAMETER Credential
        Alternate credentials for the session. Without it the session runs as the
        logged-on user.

    .PARAMETER TimeoutSec
        Operation timeout for opening and verifying the session.

    .EXAMPLE
        Get-DnsCimSession -Server 'dc01' -Credential $cred

        Returns a CIM session to dc01, or $null when neither WSMan nor DCOM works.
    #>
    [CmdletBinding()]
    [OutputType('Microsoft.Management.Infrastructure.CimSession')]
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

    $cacheKey = $Server.ToLowerInvariant()
    if ($script:CimSessionCache.ContainsKey($cacheKey)) {
        $cachedSession = $script:CimSessionCache[$cacheKey]
        if ($cachedSession -is [string]) {
            Write-Verbose "No CIM session to '$cacheKey' (an earlier attempt failed in this session)."
            return $null
        }

        Write-Verbose "Reusing the cached CIM session to '$cacheKey'."
        return $cachedSession
    }

    foreach ($protocol in @('Wsman', 'Dcom')) {
        $sessionParameters = @{
            ComputerName        = $Server
            SessionOption       = New-CimSessionOption -Protocol $protocol
            OperationTimeoutSec = $TimeoutSec
            ErrorAction         = 'Stop'
        }
        if ($null -ne $Credential) {
            $sessionParameters['Credential'] = $Credential
        }

        $session = $null
        try {
            Write-Verbose "Opening a $protocol CIM session to '$Server'."
            $session = New-CimSession @sessionParameters
        }
        catch {
            Write-Verbose "$protocol CIM session to '$Server' failed: $($_.Exception.Message)"
            continue
        }

        try {
            Write-Verbose "Verifying root\MicrosoftDNS on '$Server' over $protocol."
            $null = Get-CimInstance -CimSession $session -Namespace 'root\MicrosoftDNS' -Query 'SELECT Name FROM MicrosoftDNS_Server' -OperationTimeoutSec $TimeoutSec -ErrorAction Stop
        }
        catch {
            Write-Verbose "$protocol CIM session to '$Server' cannot read root\MicrosoftDNS: $($_.Exception.Message)"
            try {
                Remove-CimSession -CimSession $session -ErrorAction Stop
            }
            catch {
                Write-Verbose "Could not close the unusable $protocol session to '$Server': $($_.Exception.Message)"
            }
            continue
        }

        $script:CimSessionCache[$cacheKey] = $session
        return $session
    }

    $script:CimSessionCache[$cacheKey] = 'Unavailable'
    return $null
}
