function Get-DnsLiveRecord {
    <#
    .SYNOPSIS
        Reads the records of one DNS node live from the server and returns them as hashtables.

    .DESCRIPTION
        Thin wrapper around Get-DnsServerResourceRecord -Node for one node of one
        zone. Each requested record type is one server round-trip; the records come
        back as plain hashtables, never as CIM instances, so callers stay free of
        CIM types (Constrained Language Mode, CONTRACTS.md section 4.1) and see the
        same normalised values as the snapshot index:

          Owner             owner FQDN, normalised with ConvertTo-DnsNormalizedName
          Zone              the zone, lower case
          NodeName          HostName exactly as the server returns it ('@', 'srv01')
          Type              record type, upper case
          Data              A/AAAA: canonical address (ConvertTo-DnsNormalizedAddress);
                            CNAME, PTR, NS, MX, SRV: target FQDN normalised like the
                            owner; DHCID: the base64 text as-is (CONTRACTS.md 9.2)
          Ttl               TTL in seconds
          Timestamp         aging timestamp, or $null for a static record
          DistinguishedName the AD object of the node, or $null

        -Node is always passed: without it the cmdlet also returns every record
        below the node, which for the apex of a 550 000-record zone is the whole
        zone.

        The cmdlet's own errors are silenced and classified, so they never reach
        the caller's error stream:
        - FullyQualifiedErrorId containing 9714 (DNS_ERROR_NAME_DOES_NOT_EXIST) or
          category ObjectNotFound (the node, or the zone, does not exist): no
          output, no error, one Verbose line. A missing record is an answer, not a
          failure.
        - Any other error (access denied, server unreachable, ...): a
          non-terminating error with the ErrorId
          DnsLathund.Get-DnsLiveRecord.LookupFailed and the original category
          (CONTRACTS.md section 5.2), and no output for that type, so the caller
          never reports a record as missing without saying why.
        PowerShell still records the silenced errors in $Error and in the
        -ErrorVariable of enclosing commands; only -ErrorAction Ignore would not.

    .PARAMETER ServerParameter
        The splat from Get-DnsServerParameter (@{ ComputerName = ... } or
        @{ CimSession = ... }).

    .PARAMETER ZoneName
        The zone that holds the node.

    .PARAMETER NodeName
        The node name relative to the zone ('@' for the apex, 'srv01', '5', or
        '5.16' in a /16 reverse zone), with real characters (a space, not \040).

    .PARAMETER RRType
        One or more record types; each is a separate query.

    .EXAMPLE
        Get-DnsLiveRecord -ServerParameter @{ ComputerName = 'dc01' } -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A, AAAA, CNAME

        Returns one hashtable per A, AAAA and CNAME record of srv01.contoso.local.

    .EXAMPLE
        Get-DnsLiveRecord -ServerParameter $serverParameters -ZoneName '16.0.10.in-addr.arpa' -NodeName '5' -RRType PTR

        Returns the PTR records of 10.0.16.5; Data is the target name.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$ServerParameter,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ZoneName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$RRType
    )

    $zone = ConvertTo-DnsNormalizedName -Name $ZoneName
    $serverName = 'the CIM session server'
    if ($ServerParameter['ComputerName']) {
        $serverName = [string]$ServerParameter['ComputerName']
    }
    elseif ($null -ne $ServerParameter['CimSession'] -and $null -ne $ServerParameter['CimSession'].PSObject.Properties['ComputerName']) {
        $serverName = [string]$ServerParameter['CimSession'].ComputerName
    }

    # The RecordData property that carries the value of each type.
    $dataProperties = @{
        A     = 'IPv4Address'
        AAAA  = 'IPv6Address'
        CNAME = 'HostNameAlias'
        PTR   = 'PtrDomainName'
        NS    = 'NameServer'
        MX    = 'MailExchange'
        SRV   = 'DomainName'
        DHCID = 'DHCID'
    }

    foreach ($requestedType in $RRType) {
        $recordType = $requestedType.Trim().ToUpperInvariant()

        Write-Verbose "Reading $recordType records of node '$NodeName' in zone '$zone' on '$serverName' (Get-DnsServerResourceRecord -Node)."
        # SilentlyContinue plus a local -ErrorVariable instead of -ErrorAction Stop in
        # try/catch: PowerShell appends a stopped-and-caught error to the
        # -ErrorVariable of every enclosing command once per nesting level (measured:
        # 4x to 7x more records than SilentlyContinue); only Ignore would append none.
        $lookupErrors = $null
        $records = @(Get-DnsServerResourceRecord @ServerParameter -ZoneName $zone -Name $NodeName -Node -RRType $recordType -ErrorAction SilentlyContinue -ErrorVariable lookupErrors)

        foreach ($lookupError in @($lookupErrors)) {
            if ($null -eq $lookupError) {
                continue
            }
            $category = $lookupError.CategoryInfo.Category
            # WIN32 9714 is DNS_ERROR_NAME_DOES_NOT_EXIST; ObjectNotFound also covers a
            # zone that is gone. Both mean "no records", not a failed lookup.
            if ([string]$lookupError.FullyQualifiedErrorId -like '*9714*' -or [string]$category -eq 'ObjectNotFound') {
                Write-Verbose "No $recordType records: node '$NodeName' or zone '$zone' does not exist on '$serverName'."
            }
            else {
                $records = @()
                Write-Error -Message ("Lookup of '{0}' ({1}) in zone '{2}' on '{3}' failed: {4}" -f $NodeName, $recordType, $zone, $serverName, $lookupError.Exception.Message) -Category $category -ErrorId 'DnsLathund.Get-DnsLiveRecord.LookupFailed' -TargetObject $NodeName
            }
        }

        foreach ($record in $records) {
            if ($null -eq $record) {
                continue
            }

            $hostName = ''
            if ($null -ne $record.PSObject.Properties['HostName']) {
                $hostName = [string]$record.HostName
            }
            if (-not $hostName) {
                $hostName = '@'
            }
            if ($hostName -eq '@') {
                $owner = $zone
            }
            else {
                $owner = ConvertTo-DnsNormalizedName -Name ($hostName + '.' + $zone)
            }

            $type = $recordType
            if ($null -ne $record.PSObject.Properties['RecordType'] -and $record.RecordType) {
                $type = ([string]$record.RecordType).ToUpperInvariant()
            }

            $rawData = $null
            $recordData = $null
            if ($null -ne $record.PSObject.Properties['RecordData']) {
                $recordData = $record.RecordData
            }
            $dataProperty = $dataProperties[$type]
            if ($null -ne $recordData -and $null -ne $dataProperty -and $null -ne $recordData.PSObject.Properties[$dataProperty]) {
                $rawData = $recordData.PSObject.Properties[$dataProperty].Value
            }

            $data = $null
            if ($null -ne $rawData) {
                if ($type -eq 'A' -or $type -eq 'AAAA') {
                    $data = ConvertTo-DnsNormalizedAddress -Address ([string]$rawData)
                }
                elseif ($type -eq 'DHCID') {
                    $data = [string]$rawData
                }
                else {
                    $data = ConvertTo-DnsNormalizedName -Name ([string]$rawData)
                }
            }

            $ttl = $null
            if ($null -ne $record.PSObject.Properties['TimeToLive'] -and $null -ne $record.TimeToLive) {
                $ttl = [int]([timespan]$record.TimeToLive).TotalSeconds
            }

            # Static records have no timestamp; some providers report the epoch instead.
            $timestamp = $null
            if ($null -ne $record.PSObject.Properties['Timestamp'] -and $record.Timestamp -is [datetime]) {
                if ($record.Timestamp.Year -gt 1601) {
                    $timestamp = $record.Timestamp
                }
            }

            $distinguishedName = $null
            if ($null -ne $record.PSObject.Properties['DistinguishedName'] -and $record.DistinguishedName) {
                $distinguishedName = [string]$record.DistinguishedName
            }

            @{
                Owner             = $owner
                Zone              = $zone
                NodeName          = $hostName
                Type              = $type
                Data              = $data
                Ttl               = $ttl
                Timestamp         = $timestamp
                DistinguishedName = $distinguishedName
            }
        }
    }
}
