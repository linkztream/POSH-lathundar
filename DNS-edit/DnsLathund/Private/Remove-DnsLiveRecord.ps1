function Remove-DnsLiveRecord {
    <#
    .SYNOPSIS
        Removes one resource record, identified by node, type and data, from a live DNS server.

    .DESCRIPTION
        Reads the node with Get-DnsServerResourceRecord -Node -RRType, keeps only the
        record whose normalised data equals -Data (a node can hold several A
        records; only the one asked for goes), and pipes it to
        Remove-DnsServerResourceRecord -ZoneName -Force -WhatIf:$false -Confirm:$false
        (CONTRACTS.md section 7.5).

        The pipeline form is the only one used: the -Name -RRType -RecordData form
        removes the record but reports a false error on Windows Server 2022 and
        2025. -WhatIf:$false and -Confirm:$false are always passed because the
        caller has already decided through Confirm-DnsAction; without them a
        caller's -WhatIf would reach the cmdlet by dynamic scoping.

        Returns @{ Removed = [bool]; AlreadyGone = [bool]; Error = <string> | $null;
        ErrorId = <string> | $null; Unreachable = [bool] }:
        - Removed: the record was there and the server removed it.
        - AlreadyGone: no record with that data exists. The read found no matching
          record, or the read or the removal reported WIN32 9701
          (DNS_ERROR_RECORD_DOES_NOT_EXIST: the node is there, the record is not) or
          9714 (DNS_ERROR_NAME_DOES_NOT_EXIST: the node is gone); on the removal that
          means the record vanished after the read (another administrator,
          scavenging). On the read the category ObjectNotFound counts too, which also
          covers a zone that is gone. The wanted state holds, so the caller reports
          AlreadyDone.
        - Error: the read or the removal failed for another reason (access denied,
          server unreachable, ...); Removed and AlreadyGone are both $false.
        - ErrorId: the FullyQualifiedErrorId of the cmdlet error that decided the
          outcome, including a 9701 or 9714 behind AlreadyGone; $null when no
          cmdlet error occurred.
        - Unreachable: $true when that error says the server cannot be reached
          (Test-DnsConnectionError); the caller then ends the batch (CONTRACTS.md
          section 13.9). $false otherwise.
        The codes follow winerror.h (CONTRACTS.md section 13.9). The cmdlets' own
        errors are kept out of the caller's error stream; the caller writes the
        per-item error and the Result.

        Never prompts, never logs, never emits objects.

    .PARAMETER ServerParameter
        The splat from Get-DnsServerParameter.

    .PARAMETER ZoneName
        The zone that holds the record.

    .PARAMETER NodeName
        The node relative to the zone ('@' for the apex), with real characters.

    .PARAMETER RRType
        The record type.

    .PARAMETER Data
        The record data to match: an address for A/AAAA, a target name for CNAME,
        PTR, NS, MX and SRV, the base64 text for DHCID. Compared in normalised form.

    .OUTPUTS
        System.Collections.Hashtable

    .EXAMPLE
        Remove-DnsLiveRecord -ServerParameter $serverParameters -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A -Data '10.0.16.20'

        Removes the A record 10.0.16.20 of srv01 and leaves its other A records alone.
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
        [ValidateSet('A', 'AAAA', 'CNAME', 'PTR', 'DHCID', 'NS', 'MX', 'SRV')]
        [string]$RRType,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Data
    )

    $zone = ConvertTo-DnsNormalizedName -Name $ZoneName
    $recordType = $RRType.ToUpperInvariant()
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
    $dataProperty = $dataProperties[$recordType]

    if ($recordType -eq 'A' -or $recordType -eq 'AAAA') {
        $wanted = ConvertTo-DnsNormalizedAddress -Address $Data
        if ($null -eq $wanted) {
            $wanted = $Data.Trim()
        }
    }
    elseif ($recordType -eq 'DHCID') {
        $wanted = $Data.Trim()
    }
    else {
        $wanted = ConvertTo-DnsNormalizedName -Name $Data
    }

    $outcome = @{ Removed = $false; AlreadyGone = $false; Error = $null; ErrorId = $null; Unreachable = $false }

    Write-Verbose "Reading $recordType records of node '$NodeName' in zone '$zone' before removing '$wanted' (Get-DnsServerResourceRecord -Node)."
    $readErrors = $null
    $records = @(Get-DnsServerResourceRecord @ServerParameter -ZoneName $zone -Name $NodeName -Node -RRType $recordType -ErrorAction SilentlyContinue -ErrorVariable readErrors)
    foreach ($readError in @($readErrors)) {
        if ($null -eq $readError) {
            continue
        }
        $errorId = [string]$readError.FullyQualifiedErrorId
        $outcome['ErrorId'] = $errorId
        # 9701 / 9714 / ObjectNotFound: the record, the node or the zone does not
        # exist, so the removal has nothing left to do.
        if ($errorId -like '*9701*' -or $errorId -like '*9714*' -or [string]$readError.CategoryInfo.Category -eq 'ObjectNotFound') {
            $records = @()
            continue
        }
        $outcome['Error'] = "Could not read the $recordType records of '$NodeName' in zone '$zone': $($readError.Exception.Message)"
        $outcome['Unreachable'] = Test-DnsConnectionError -ErrorRecord $readError
        return $outcome
    }

    $matchingRecords = @(
        foreach ($record in $records) {
            if ($null -eq $record -or $null -eq $record.PSObject.Properties['RecordData'] -or $null -eq $record.RecordData) {
                continue
            }
            $valueProperty = $record.RecordData.PSObject.Properties[$dataProperty]
            if ($null -eq $valueProperty -or $null -eq $valueProperty.Value) {
                continue
            }

            $rawValue = [string]$valueProperty.Value
            if ($recordType -eq 'A' -or $recordType -eq 'AAAA') {
                $value = ConvertTo-DnsNormalizedAddress -Address $rawValue
            }
            elseif ($recordType -eq 'DHCID') {
                $value = $rawValue.Trim()
            }
            else {
                $value = ConvertTo-DnsNormalizedName -Name $rawValue
            }

            # DHCID is base64 and therefore case-sensitive; names and addresses are not.
            if (($recordType -eq 'DHCID' -and $value -ceq $wanted) -or ($recordType -ne 'DHCID' -and $value -eq $wanted)) {
                $record
            }
        }
    )

    if ($matchingRecords.Count -eq 0) {
        Write-Verbose "No $recordType record '$wanted' at node '$NodeName' in zone '$zone'; nothing to remove."
        $outcome['AlreadyGone'] = $true
        return $outcome
    }

    Write-Verbose "Removing $recordType record '$wanted' of node '$NodeName' in zone '$zone' (Remove-DnsServerResourceRecord)."
    $removeErrors = $null
    $matchingRecords | Remove-DnsServerResourceRecord @ServerParameter -ZoneName $zone -Force -WhatIf:$false -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable removeErrors

    foreach ($removeError in @($removeErrors)) {
        if ($null -eq $removeError) {
            continue
        }
        $errorId = [string]$removeError.FullyQualifiedErrorId
        $outcome['ErrorId'] = $errorId
        # Gone between the read and the removal (another admin, scavenging): the
        # wanted state holds. Only these two codes count here, not the category:
        # the record was read a moment ago, so any other refusal is a real failure
        # and must never pass for AlreadyDone (CONTRACTS.md section 5.8).
        if ($errorId -like '*9701*' -or $errorId -like '*9714*') {
            $outcome['AlreadyGone'] = $true
            return $outcome
        }
        $outcome['Error'] = "Could not remove the $recordType record '$wanted' of '$NodeName' in zone '$zone': $($removeError.Exception.Message)"
        $outcome['Unreachable'] = Test-DnsConnectionError -ErrorRecord $removeError
        return $outcome
    }

    $outcome['Removed'] = $true
    $outcome
}
