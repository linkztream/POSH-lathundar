function Add-DnsLiveRecord {
    <#
    .SYNOPSIS
        Creates one static A, AAAA, CNAME or PTR record on a live DNS server and reads it back.

    .DESCRIPTION
        Calls the typed DnsServer cmdlet for the record type
        (Add-DnsServerResourceRecordA, -AAAA, -CName or -Ptr) with
        -WhatIf:$false -Confirm:$false, then re-reads the node with
        Get-DnsLiveRecord and returns the record as the server stored it
        (CONTRACTS.md section 7.5).

        - -TimeToLive is passed only when -Ttl is given; otherwise the zone default
          applies, exactly as when the record is created by hand.
        - -CreatePtr is never passed: PTR records are created by the caller as
          separate, logged sub-operations in the right reverse zone.
        - -AgeRecord is never passed: records created by DnsTools are static, so
          scavenging never removes them.
        - -NodeName must be relative to the zone. A name that ends with the zone
          name throws, because the cmdlet would append the zone again and create
          'srv01.contoso.local.contoso.local'.

        Returns @{ Record; Reason; Error; ErrorId; Unreachable }:
          Reason 'Added'          the record was created; Record is the re-read record
          Reason 'AlreadyExists'  the identical record exists (WIN32 9711,
                                  DNS_ERROR_RECORD_ALREADY_EXISTS); Record is the
                                  existing record, so the caller can compare its TTL
          Reason 'CnameConflict'  the node is a CNAME (WIN32 9708,
                                  DNS_ERROR_NODE_IS_CNAME), or a CNAME cannot join a
                                  node that has other records (WIN32 9709,
                                  DNS_ERROR_CNAME_COLLISION); Record $null
          Reason 'Failed'         anything else, for example 9712 (secondary zone)
                                  or 5 (access denied); Error carries the cmdlet's
                                  message
          ErrorId                 the FullyQualifiedErrorId of the cmdlet error that
                                  decided Reason; $null when the add succeeded. The
                                  caller reads codes that are not a Reason of their
                                  own from it (9712 -> Skipped).
          Unreachable             $true when that error says the server cannot be
                                  reached (Test-DnsConnectionError); the caller then
                                  ends the batch. $false otherwise.
        The codes follow winerror.h (CONTRACTS.md section 13.9); which cmdlet raises
        which one is confirmed in the live test. The cmdlets' own errors are kept out
        of the caller's error stream.

        Never prompts, never logs, never emits objects.

    .PARAMETER ServerParameter
        The splat from Get-DnsServerParameter.

    .PARAMETER ZoneName
        The zone that gets the record.

    .PARAMETER NodeName
        The node relative to the zone ('@' for the apex).

    .PARAMETER RRType
        A, AAAA, CNAME or PTR.

    .PARAMETER Data
        The IPv4 address (A), IPv6 address (AAAA), alias target FQDN (CNAME) or PTR
        target FQDN (PTR).

    .PARAMETER Ttl
        TTL in seconds. Without it the zone default applies.

    .OUTPUTS
        System.Collections.Hashtable

    .EXAMPLE
        Add-DnsLiveRecord -ServerParameter $serverParameters -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A -Data '10.0.16.20' -Ttl 1200

        Creates a static A record for srv01.contoso.local with a TTL of 20 minutes.
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
        [ValidateSet('A', 'AAAA', 'CNAME', 'PTR')]
        [string]$RRType,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Data,

        [Parameter()]
        [ValidateRange(0, 2147483647)]
        [int]$Ttl
    )

    $zone = ConvertTo-DnsNormalizedName -Name $ZoneName
    $node = $NodeName.Trim()
    $normalizedNode = ConvertTo-DnsNormalizedName -Name $node
    if ($normalizedNode -eq $zone -or $normalizedNode.EndsWith('.' + $zone)) {
        throw "Add-DnsLiveRecord: NodeName '$NodeName' ends with the zone name '$zone'. Pass the name relative to the zone ('srv01', or '@' for the apex); the DnsServer cmdlet would append the zone again."
    }

    $recordType = $RRType.ToUpperInvariant()
    if ($recordType -eq 'A' -or $recordType -eq 'AAAA') {
        $value = ConvertTo-DnsNormalizedAddress -Address $Data
        if ($null -eq $value) {
            $value = $Data.Trim()
        }
    }
    else {
        $value = ConvertTo-DnsNormalizedName -Name $Data
    }

    # Optional parameters go through a splat so that a missing -Ttl really means
    # "no -TimeToLive" rather than a TTL of 0.
    $optional = @{}
    if ($PSBoundParameters.Keys -contains 'Ttl') {
        $optional['TimeToLive'] = New-TimeSpan -Seconds $Ttl
    }

    Write-Verbose "Adding $recordType record '$node' -> '$value' in zone '$zone' (Add-DnsServerResourceRecord$recordType)."
    $addErrors = $null
    switch ($recordType) {
        'A' {
            Add-DnsServerResourceRecordA @ServerParameter @optional -ZoneName $zone -Name $node -IPv4Address $value -WhatIf:$false -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable addErrors
        }
        'AAAA' {
            Add-DnsServerResourceRecordAAAA @ServerParameter @optional -ZoneName $zone -Name $node -IPv6Address $value -WhatIf:$false -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable addErrors
        }
        'CNAME' {
            Add-DnsServerResourceRecordCName @ServerParameter @optional -ZoneName $zone -Name $node -HostNameAlias $value -WhatIf:$false -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable addErrors
        }
        'PTR' {
            Add-DnsServerResourceRecordPtr @ServerParameter @optional -ZoneName $zone -Name $node -PtrDomainName $value -WhatIf:$false -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable addErrors
        }
    }

    $outcome = @{ Record = $null; Reason = 'Added'; Error = $null; ErrorId = $null; Unreachable = $false }
    foreach ($addError in @($addErrors)) {
        if ($null -eq $addError) {
            continue
        }
        # One add, one error: the first one decides. Codes from winerror.h
        # (CONTRACTS.md section 13.9).
        $errorId = [string]$addError.FullyQualifiedErrorId
        $outcome['ErrorId'] = $errorId
        if ($errorId -like '*9711*') {
            # The wanted record is already there; it is read below so that the
            # caller can tell AlreadyDone from a TTL that still differs.
            $outcome['Reason'] = 'AlreadyExists'
            break
        }

        $outcome['Error'] = $addError.Exception.Message
        if ($errorId -like '*9708*' -or $errorId -like '*9709*') {
            $outcome['Reason'] = 'CnameConflict'
        }
        else {
            $outcome['Reason'] = 'Failed'
            $outcome['Unreachable'] = Test-DnsConnectionError -ErrorRecord $addError
        }
        return $outcome
    }

    # Read back what the server stored (TTL, timestamp, DN) instead of assuming it.
    foreach ($record in @(Get-DnsLiveRecord -ServerParameter $ServerParameter -ZoneName $zone -NodeName $node -RRType $recordType)) {
        if ($null -ne $record -and $record['Data'] -eq $value) {
            $outcome['Record'] = $record
            break
        }
    }
    if ($null -eq $outcome['Record']) {
        Write-Verbose "The $recordType record '$node' -> '$value' in zone '$zone' could not be read back after the add."
    }

    $outcome
}
