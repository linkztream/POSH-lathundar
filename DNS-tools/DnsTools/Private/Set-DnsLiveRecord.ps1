function Set-DnsLiveRecord {
    <#
    .SYNOPSIS
        Changes the TTL and/or the data of one existing record in place on a live DNS server.

    .DESCRIPTION
        Set-DnsServerResourceRecord needs the record as it is (-OldInputObject) and
        as it should be (-NewInputObject). The usual way to get the second one,
        $old.Clone(), is a method call on a CIM instance: blocked in Constrained
        Language Mode and missing on PowerShell 7. So the record is fetched TWICE
        with Get-DnsServerResourceRecord -Node -RRType, which gives two independent
        objects; the one whose data matches -Data is picked from each, and only the
        second copy is changed (CONTRACTS.md sections 4.1 and 7.5):

          -NewTtl   TimeToLive = New-TimeSpan -Seconds <NewTtl>
          -NewData  RecordData.IPv4Address (A), IPv6Address (AAAA), HostNameAlias
                    (CNAME) or PtrDomainName (PTR), always as a string: the CIM
                    property is a string, and an [ipaddress] does not convert.
                    Addresses are written in canonical form; target names as an
                    FQDN with the trailing dot, the form the server returns.

        Then Set-DnsServerResourceRecord -ZoneName -OldInputObject -NewInputObject
        -WhatIf:$false -Confirm:$false, and the node is read again with
        Get-DnsLiveRecord: the returned Record is what the server stored, including
        the aging Timestamp that the caller logs as After.Timestamp.

        Returns @{ Record = <hashtable> | $null; Error = <string> | $null;
        ErrorId = <string> | $null; Unreachable = [bool] }.
        - Record is $null and Error says why when the record is not there, the new
          data is not valid for the type, or the server refuses the change, for
          example WIN32 9711 (DNS_ERROR_RECORD_ALREADY_EXISTS: another record at the
          node already has the new data) or 9707 (DNS_ERROR_CNAME_LOOP: the alias
          would point at itself); codes from winerror.h, CONTRACTS.md section 13.9.
        - ErrorId is the FullyQualifiedErrorId of the cmdlet error behind Error (a
          9714 when the node is gone), $null when the helper found the problem
          itself or nothing failed.
        - Unreachable is $true when that error says the server cannot be reached
          (Test-DnsConnectionError); the caller then ends the batch. $false
          otherwise.
        When the change succeeded but the record cannot be read back, Record and
        Error are both $null (Get-DnsLiveRecord reports the failed read). The
        cmdlets' own errors are kept out of the caller's error stream.

        Never prompts, never logs, never emits objects.

    .PARAMETER ServerParameter
        The splat from Get-DnsServerParameter.

    .PARAMETER ZoneName
        The zone that holds the record.

    .PARAMETER NodeName
        The node relative to the zone ('@' for the apex), with real characters.

    .PARAMETER RRType
        A, AAAA, CNAME or PTR.

    .PARAMETER Data
        The current data of the record to change (address or target name).

    .PARAMETER NewTtl
        The new TTL in seconds.

    .PARAMETER NewData
        The new address or target name.

    .OUTPUTS
        System.Collections.Hashtable

    .EXAMPLE
        Set-DnsLiveRecord -ServerParameter $serverParameters -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A -Data '10.0.16.20' -NewData '10.0.16.21'

        Moves the A record of srv01 from 10.0.16.20 to 10.0.16.21 in place.

    .EXAMPLE
        Set-DnsLiveRecord -ServerParameter $serverParameters -ZoneName 'contoso.local' -NodeName 'www' -RRType CNAME -Data 'web01.contoso.local' -NewTtl 300

        Lowers the TTL of the alias www to five minutes.
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
        [int]$NewTtl,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$NewData
    )

    $hasNewTtl = $PSBoundParameters.Keys -contains 'NewTtl'
    $hasNewData = $PSBoundParameters.Keys -contains 'NewData'
    if (-not $hasNewTtl -and -not $hasNewData) {
        throw 'Set-DnsLiveRecord: specify -NewTtl, -NewData or both.'
    }

    $zone = ConvertTo-DnsNormalizedName -Name $ZoneName
    $recordType = $RRType.ToUpperInvariant()
    $isAddress = $recordType -eq 'A' -or $recordType -eq 'AAAA'
    $dataProperties = @{ A = 'IPv4Address'; AAAA = 'IPv6Address'; CNAME = 'HostNameAlias'; PTR = 'PtrDomainName' }
    $dataProperty = $dataProperties[$recordType]
    $outcome = @{ Record = $null; Error = $null; ErrorId = $null; Unreachable = $false }

    if ($isAddress) {
        $wanted = ConvertTo-DnsNormalizedAddress -Address $Data
        if ($null -eq $wanted) {
            $wanted = $Data.Trim()
        }
    }
    else {
        $wanted = ConvertTo-DnsNormalizedName -Name $Data
    }

    # The value written into the second copy, and the data the record has afterwards.
    $finalData = $wanted
    $newValue = $null
    if ($hasNewData) {
        if ($isAddress) {
            $finalData = ConvertTo-DnsNormalizedAddress -Address $NewData
            $expectsColon = $recordType -eq 'AAAA'
            if ($null -eq $finalData -or (($finalData.IndexOf(':') -ge 0) -ne $expectsColon)) {
                $family = 'IPv4'
                if ($expectsColon) {
                    $family = 'IPv6'
                }
                $outcome['Error'] = "'$NewData' is not a valid $family address for the $recordType record '$NodeName' in zone '$zone'."
                return $outcome
            }
            $newValue = $finalData
        }
        else {
            $finalData = ConvertTo-DnsNormalizedName -Name $NewData
            if (-not $finalData) {
                $outcome['Error'] = "'$NewData' is not a valid target name for the $recordType record '$NodeName' in zone '$zone'."
                return $outcome
            }
            $newValue = $finalData + '.'
        }
    }

    # Two independent reads: the first copy stays as the server has it
    # (-OldInputObject), the second is changed (-NewInputObject).
    $copies = @{}
    foreach ($copyName in @('Old', 'New')) {
        Write-Verbose "Reading $recordType records of node '$NodeName' in zone '$zone' ($copyName copy, Get-DnsServerResourceRecord -Node)."
        $readErrors = $null
        $records = @(Get-DnsServerResourceRecord @ServerParameter -ZoneName $zone -Name $NodeName -Node -RRType $recordType -ErrorAction SilentlyContinue -ErrorVariable readErrors)
        foreach ($readError in @($readErrors)) {
            if ($null -eq $readError) {
                continue
            }
            $errorId = [string]$readError.FullyQualifiedErrorId
            $outcome['ErrorId'] = $errorId
            # A missing node or zone is reported below as a missing record, which
            # is what it is for the caller.
            if ($errorId -like '*9714*' -or [string]$readError.CategoryInfo.Category -eq 'ObjectNotFound') {
                $records = @()
                continue
            }
            $outcome['Error'] = "Could not read the $recordType records of '$NodeName' in zone '$zone': $($readError.Exception.Message)"
            $outcome['Unreachable'] = Test-DnsConnectionError -ErrorRecord $readError
            return $outcome
        }

        foreach ($record in $records) {
            if ($null -eq $record -or $null -eq $record.PSObject.Properties['RecordData'] -or $null -eq $record.RecordData) {
                continue
            }
            $valueProperty = $record.RecordData.PSObject.Properties[$dataProperty]
            if ($null -eq $valueProperty -or $null -eq $valueProperty.Value) {
                continue
            }
            if ($isAddress) {
                $value = ConvertTo-DnsNormalizedAddress -Address ([string]$valueProperty.Value)
            }
            else {
                $value = ConvertTo-DnsNormalizedName -Name ([string]$valueProperty.Value)
            }
            if ($value -eq $wanted) {
                $copies[$copyName] = $record
                break
            }
        }

        if ($null -eq $copies[$copyName]) {
            $outcome['Error'] = "The $recordType record '$NodeName' -> '$wanted' does not exist in zone '$zone'."
            return $outcome
        }
    }

    $newRecord = $copies['New']
    if ($hasNewTtl) {
        $newRecord.TimeToLive = New-TimeSpan -Seconds $NewTtl
    }
    if ($hasNewData) {
        $newRecord.RecordData.$dataProperty = $newValue
    }

    Write-Verbose "Changing $recordType record '$NodeName' -> '$wanted' in zone '$zone' (Set-DnsServerResourceRecord)."
    $setErrors = $null
    Set-DnsServerResourceRecord @ServerParameter -ZoneName $zone -OldInputObject $copies['Old'] -NewInputObject $newRecord -WhatIf:$false -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable setErrors
    foreach ($setError in @($setErrors)) {
        if ($null -ne $setError) {
            $outcome['Error'] = "Could not change the $recordType record '$NodeName' -> '$wanted' in zone '$zone': $($setError.Exception.Message)"
            $outcome['ErrorId'] = [string]$setError.FullyQualifiedErrorId
            $outcome['Unreachable'] = Test-DnsConnectionError -ErrorRecord $setError
            return $outcome
        }
    }

    # The server may change more than was asked (the aging timestamp); return what it stored.
    foreach ($record in @(Get-DnsLiveRecord -ServerParameter $ServerParameter -ZoneName $zone -NodeName $NodeName -RRType $recordType)) {
        if ($null -ne $record -and $record['Data'] -eq $finalData) {
            $outcome['Record'] = $record
            break
        }
    }
    # The change itself succeeded; a failed read-back is not a failed change.
    if ($null -eq $outcome['Record']) {
        Write-Verbose "The $recordType record '$NodeName' -> '$finalData' in zone '$zone' could not be read back after the change."
    }

    $outcome
}
