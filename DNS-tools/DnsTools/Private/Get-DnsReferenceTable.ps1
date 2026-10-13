function Get-DnsReferenceTable {
    <#
    .SYNOPSIS
        Reads, with four WQL queries, which CNAME, SRV, NS and MX records of one zone point where.

    .DESCRIPTION
        Removing a name that SRV, NS or MX records point at breaks domain
        controllers, delegations or mail, and removing it leaves CNAME aliases
        dangling. When no fresh snapshot can answer that (Get-DnsReference), the
        DNS server's WMI provider can: one query per record type returns only the
        owner and the target of every such record in the zone, which is far cheaper
        than enumerating a 550 000-record zone with Get-DnsServerResourceRecord.

        Four Get-CimInstance calls in root\MicrosoftDNS (CONTRACTS.md section 7.5):

            SELECT OwnerName, PrimaryName   FROM MicrosoftDNS_CNAMEType WHERE ContainerName='<zone>'
            SELECT OwnerName, SRVDomainName FROM MicrosoftDNS_SRVType   WHERE ContainerName='<zone>'
            SELECT OwnerName, NSHost        FROM MicrosoftDNS_NSType    WHERE ContainerName='<zone>'
            SELECT OwnerName, MailExchange  FROM MicrosoftDNS_MXType    WHERE ContainerName='<zone>'

        Returns @{ Cname = @{}; Srv = @{}; Ns = @{}; Mx = @{} }, each mapping a
        target FQDN to the array of owner FQDNs that point at it. Targets come with
        a trailing dot and owners without one; both are normalised like every name
        in the module (lower case, no trailing dot, \DDD decoded).

        Returns $null when any of the four queries fails (no session, access
        denied, timeout, provider missing), with one Verbose line that names the
        reason: a partial table would silently report a referenced name as
        unreferenced. The errors are kept out of the caller's error stream; the
        caller reports the whole check as unavailable.

    .PARAMETER Zone
        The zone to read (ContainerName in WMI).

    .PARAMETER CimSession
        A CIM session to the DNS server (Get-DnsCimSession); $null gives $null.

    .PARAMETER TimeoutSec
        Operation timeout of each query in seconds. Default: 300.

    .OUTPUTS
        System.Collections.Hashtable, or $null.

    .EXAMPLE
        $table = Get-DnsReferenceTable -Zone 'contoso.local' -CimSession $session
        $table['Srv']['dc01.contoso.local']

        Returns the owners of the SRV records in contoso.local that point at dc01.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Zone,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$CimSession,

        [Parameter()]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSec = 300
    )

    $zoneName = ConvertTo-DnsNormalizedName -Name $Zone
    if ($null -eq $CimSession) {
        Write-Verbose "No reference table for zone '$zoneName': there is no CIM session to the DNS server."
        return $null
    }

    $definitions = @(
        @{ Kind = 'Cname'; Class = 'MicrosoftDNS_CNAMEType'; Property = 'PrimaryName' }
        @{ Kind = 'Srv'; Class = 'MicrosoftDNS_SRVType'; Property = 'SRVDomainName' }
        @{ Kind = 'Ns'; Class = 'MicrosoftDNS_NSType'; Property = 'NSHost' }
        @{ Kind = 'Mx'; Class = 'MicrosoftDNS_MXType'; Property = 'MailExchange' }
    )

    # WQL string literals escape backslash and quote with a backslash.
    $wqlZone = $zoneName.Replace('\', '\\').Replace("'", "\'")
    $table = @{}

    foreach ($definition in $definitions) {
        $targetProperty = $definition['Property']
        $query = "SELECT OwnerName, $targetProperty FROM $($definition['Class']) WHERE ContainerName='$wqlZone'"
        Write-Verbose "Querying root\MicrosoftDNS: $query"

        # SilentlyContinue plus a local -ErrorVariable, as in Get-DnsLiveRecord: a
        # stopped-and-caught error would be copied into every enclosing command's
        # -ErrorVariable. The catch is only for terminating errors such as a session
        # object that does not bind.
        $queryErrors = $null
        try {
            $rows = @(Get-CimInstance -CimSession $CimSession -Namespace 'root\MicrosoftDNS' -Query $query -OperationTimeoutSec $TimeoutSec -ErrorAction SilentlyContinue -ErrorVariable queryErrors)
        }
        catch {
            Write-Verbose "No reference table for zone '$zoneName': $query failed: $($_.Exception.Message)"
            return $null
        }
        foreach ($queryError in @($queryErrors)) {
            if ($null -ne $queryError) {
                Write-Verbose "No reference table for zone '$zoneName': $query failed: $($queryError.Exception.Message)"
                return $null
            }
        }

        # Normalised inline: a large zone has tens of thousands of CNAMEs, and a
        # function call per row would cost seconds. Only names with \DDD escapes
        # need ConvertTo-DnsNormalizedName.
        $pairs = @(
            foreach ($row in $rows) {
                if ($null -eq $row) {
                    continue
                }
                $ownerValue = $row.PSObject.Properties['OwnerName']
                $targetValue = $row.PSObject.Properties[$targetProperty]
                if ($null -eq $ownerValue -or $null -eq $targetValue -or $null -eq $ownerValue.Value -or $null -eq $targetValue.Value) {
                    continue
                }
                $row
            }
        )

        $targets = @(
            foreach ($row in $pairs) {
                $name = ([string]$row.PSObject.Properties[$targetProperty].Value).Trim()
                if ($name.IndexOf('\') -ge 0) {
                    ConvertTo-DnsNormalizedName -Name $name
                    continue
                }
                if ($name.EndsWith('.')) {
                    $name = $name.Substring(0, $name.Length - 1)
                }
                $name.ToLowerInvariant()
            }
        )
        $owners = @(
            foreach ($row in $pairs) {
                $name = ([string]$row.PSObject.Properties['OwnerName'].Value).Trim()
                if ($name.IndexOf('\') -ge 0) {
                    ConvertTo-DnsNormalizedName -Name $name
                    continue
                }
                if ($name.EndsWith('.')) {
                    $name = $name.Substring(0, $name.Length - 1)
                }
                $name.ToLowerInvariant()
            }
        )

        # Count, allocate, fill (CONTRACTS.md section 9.3): growing arrays with +=
        # would be quadratic.
        $counts = @{}
        foreach ($target in $targets) {
            $counts[$target] = [int]$counts[$target] + 1
        }
        $map = @{}
        $positions = @{}
        foreach ($target in @($counts.Keys)) {
            $map[$target] = @($null) * $counts[$target]
            $positions[$target] = 0
        }
        for ($index = 0; $index -lt $targets.Count; $index++) {
            $target = $targets[$index]
            $position = $positions[$target]
            $map[$target][$position] = $owners[$index]
            $positions[$target] = $position + 1
        }

        Write-Verbose ("Zone '{0}': {1} {2} record(s) pointing at {3} target(s)." -f $zoneName, $pairs.Count, $definition['Kind'].ToUpperInvariant(), $counts.Count)
        $table[$definition['Kind']] = $map
    }

    $table
}
