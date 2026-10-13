function Set-DnsLiveRecord {
    <#
    .SYNOPSIS
        Changes the TTL and/or the data of one existing record in place on a live DNS server.

    .DESCRIPTION
        Two paths, because of what the DNS server does to PTR records (verified on
        Windows Server 2025 on 2026-10-13, CONTRACTS.md section 7.5):
        Set-DnsServerResourceRecord on an A or AAAA record, a TTL change as well as
        a data change, makes the server delete the PTR record that points at the
        record's name. The WMI method Modify of the record's class in
        root\MicrosoftDNS changes the TTL alone without touching that PTR.

        -NewTtl without -NewData (WMI):
          The record is read once with Get-DnsServerResourceRecord -Node -RRType;
          it must exist, and the read tells whether the node holds several records
          of the type. Its WMI instance is then selected over -CimSession with

            SELECT * FROM MicrosoftDNS_<AType|AAAAType|CNAMEType|PTRType>
              WHERE ContainerName='<zone>' AND OwnerName='<owner FQDN>'
              [AND <IPAddress|IPv6Address|PrimaryName|PTRDomainName>='<data>']

          where the data condition is added only when the node holds several
          records of the type (addresses in canonical form, target names with the
          trailing dot, the form the provider returns). Of the instances returned,
          the one whose data equals -Data is changed with
          Invoke-CimMethod -MethodName Modify -Arguments @{ TTL = [uint32]<NewTtl> }.
          Without -CimSession, or when the provider refuses the query or the
          method or does not return the record, nothing is changed and the outcome
          carries the ErrorId DnsTools.Set-DnsLiveRecord.WmiUnavailable; the caller
          may then call again with -UseDnsServerCmdlet. A server that cannot be
          reached is reported as Unreachable instead.

        -NewData, or -UseDnsServerCmdlet (DnsServer cmdlet):
          Set-DnsServerResourceRecord needs the record as it is (-OldInputObject)
          and as it should be (-NewInputObject). The usual way to get the second
          one, $old.Clone(), is a method call on a CIM instance: blocked in
          Constrained Language Mode and missing on PowerShell 7. So the record is
          fetched TWICE with Get-DnsServerResourceRecord -Node -RRType, which gives
          two independent objects; the one whose data matches -Data is picked from
          each, and only the second copy is changed (CONTRACTS.md sections 4.1 and
          7.5):

            -NewTtl   TimeToLive = New-TimeSpan -Seconds <NewTtl>
            -NewData  RecordData.IPv4Address (A), IPv6Address (AAAA), HostNameAlias
                      (CNAME) or PtrDomainName (PTR), always as a string: the CIM
                      property is a string, and an [ipaddress] does not convert.
                      Addresses are written in canonical form; target names as an
                      FQDN with the trailing dot, the form the server returns.

          Then Set-DnsServerResourceRecord -ZoneName -OldInputObject
          -NewInputObject -WhatIf:$false -Confirm:$false. The server deletes the PTR
          of a changed A or AAAA record here; the caller removes the old PTR before
          an address change and re-creates a PTR after a TTL change (Set-DnsEntry,
          CONTRACTS.md section 13.6), so no PTR disappears unlogged.

        Neither path keeps the aging timestamp: every change makes the record
        static. Afterwards the node is read again with Get-DnsLiveRecord: the
        returned Record is what the server stored, including the Timestamp that
        the caller logs as After.Timestamp.

        Returns @{ Record = <hashtable> | $null; Error = <string> | $null;
        ErrorId = <string> | $null; Unreachable = [bool] }.
        - Record is $null and Error says why when the record is not there, the new
          data is not valid for the type, WMI is not available for a TTL change,
          or the server refuses the change, for example WIN32 9711
          (DNS_ERROR_RECORD_ALREADY_EXISTS: another record at the node already has
          the new data); codes from winerror.h, CONTRACTS.md section 13.9.
        - ErrorId is the FullyQualifiedErrorId of the cmdlet error behind Error (a
          9714 when the node is gone), DnsTools.Set-DnsLiveRecord.WmiUnavailable
          for the WMI path, and $null when the helper found the problem itself or
          nothing failed.
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

    .PARAMETER CimSession
        A CIM session to the DNS server (Get-DnsCimSession; the change commands
        keep one per batch in $Batch.CimSession). Needed for -NewTtl without
        -NewData; not used otherwise.

    .PARAMETER UseDnsServerCmdlet
        Change a TTL with Set-DnsServerResourceRecord instead of WMI, for servers
        whose root\MicrosoftDNS namespace cannot be used. On an A or AAAA record
        the server then deletes the PTR record that points at the name.

    .OUTPUTS
        System.Collections.Hashtable

    .EXAMPLE
        Set-DnsLiveRecord -ServerParameter $serverParameters -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A -Data '10.0.16.20' -NewData '10.0.16.21'

        Moves the A record of srv01 from 10.0.16.20 to 10.0.16.21 in place. The
        server deletes the PTR of 10.0.16.20 that points at srv01.

    .EXAMPLE
        Set-DnsLiveRecord -ServerParameter $serverParameters -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A -Data '10.0.16.20' -NewTtl 300 -CimSession $session

        Lowers the TTL of that A record to five minutes through WMI; its PTR record
        stays.
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
        [string]$NewData,

        [Parameter()]
        [AllowNull()]
        [object]$CimSession,

        [Parameter()]
        [switch]$UseDnsServerCmdlet
    )

    $hasNewTtl = $PSBoundParameters.Keys -contains 'NewTtl'
    $hasNewData = $PSBoundParameters.Keys -contains 'NewData'
    if (-not $hasNewTtl -and -not $hasNewData) {
        throw 'Set-DnsLiveRecord: specify -NewTtl, -NewData or both.'
    }
    # A TTL change alone goes through WMI: the DnsServer cmdlet would delete the PTR.
    $useWmi = $hasNewTtl -and -not $hasNewData -and -not $UseDnsServerCmdlet

    $zone = ConvertTo-DnsNormalizedName -Name $ZoneName
    $recordType = $RRType.ToUpperInvariant()
    $isAddress = $recordType -eq 'A' -or $recordType -eq 'AAAA'
    $dataProperties = @{ A = 'IPv4Address'; AAAA = 'IPv6Address'; CNAME = 'HostNameAlias'; PTR = 'PtrDomainName' }
    $dataProperty = $dataProperties[$recordType]
    $outcome = @{ Record = $null; Error = $null; ErrorId = $null; Unreachable = $false }
    $wmiUnavailableId = 'DnsTools.Set-DnsLiveRecord.WmiUnavailable'

    $serverName = 'the DNS server'
    if ($ServerParameter['ComputerName']) {
        $serverName = [string]$ServerParameter['ComputerName']
    }
    elseif ($null -ne $ServerParameter['CimSession'] -and $null -ne $ServerParameter['CimSession'].PSObject.Properties['ComputerName']) {
        $serverName = [string]$ServerParameter['CimSession'].ComputerName
    }

    if ($useWmi -and $null -eq $CimSession) {
        $outcome['Error'] = "TTL changes go through WMI (root\MicrosoftDNS) because Set-DnsServerResourceRecord deletes the record's PTR; no WMI session to '$serverName' could be opened."
        $outcome['ErrorId'] = $wmiUnavailableId
        return $outcome
    }

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

    # The cmdlet path reads twice: the first copy stays as the server has it
    # (-OldInputObject), the second is changed (-NewInputObject). The WMI path
    # reads once, to know that the record exists and how many records of its type
    # the node holds.
    $copyNames = @('Old', 'New')
    if ($useWmi) {
        $copyNames = @('Old')
    }
    $copies = @{}
    $sameTypeCount = 0
    foreach ($copyName in $copyNames) {
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

        $sameTypeCount = 0
        foreach ($record in $records) {
            if ($null -eq $record -or $null -eq $record.PSObject.Properties['RecordData'] -or $null -eq $record.RecordData) {
                continue
            }
            $valueProperty = $record.RecordData.PSObject.Properties[$dataProperty]
            if ($null -eq $valueProperty -or $null -eq $valueProperty.Value) {
                continue
            }
            $sameTypeCount++
            if ($isAddress) {
                $value = ConvertTo-DnsNormalizedAddress -Address ([string]$valueProperty.Value)
            }
            else {
                $value = ConvertTo-DnsNormalizedName -Name ([string]$valueProperty.Value)
            }
            if ($value -eq $wanted -and $null -eq $copies[$copyName]) {
                $copies[$copyName] = $record
            }
        }

        if ($null -eq $copies[$copyName]) {
            $outcome['Error'] = "The $recordType record '$NodeName' -> '$wanted' does not exist in zone '$zone'."
            return $outcome
        }
    }

    if ($useWmi) {
        $wmiClasses = @{ A = 'MicrosoftDNS_AType'; AAAA = 'MicrosoftDNS_AAAAType'; CNAME = 'MicrosoftDNS_CNAMEType'; PTR = 'MicrosoftDNS_PTRType' }
        $wmiProperties = @{ A = 'IPAddress'; AAAA = 'IPv6Address'; CNAME = 'PrimaryName'; PTR = 'PTRDomainName' }
        $wmiProperty = $wmiProperties[$recordType]
        $owner = $zone
        if ($NodeName -ne '@') {
            $owner = $NodeName + '.' + $zone
        }
        $wmiData = $wanted
        if (-not $isAddress) {
            $wmiData = $wanted + '.'
        }

        # WQL string literals escape backslash and quote with a backslash.
        $wqlZone = $zone.Replace('\', '\\').Replace("'", "\'")
        $wqlOwner = $owner.Replace('\', '\\').Replace("'", "\'")
        $query = "SELECT * FROM $($wmiClasses[$recordType]) WHERE ContainerName='$wqlZone' AND OwnerName='$wqlOwner'"
        if ($sameTypeCount -gt 1) {
            $wqlData = $wmiData.Replace('\', '\\').Replace("'", "\'")
            $query = $query + " AND $wmiProperty='$wqlData'"
        }
        $wmiLabel = "the $recordType record '$NodeName' -> '$wanted' in zone '$zone' over WMI (root\MicrosoftDNS on '$serverName')"
        Write-Verbose "Selecting $wmiLabel with: $query"

        # SilentlyContinue plus a local -ErrorVariable, as in Get-DnsLiveRecord; the
        # catch is for terminating errors such as a session object that does not
        # bind. An unreachable server keeps its own error id (the caller ends the
        # batch); any other refusal is WmiUnavailable (the caller may fall back).
        $wmiError = $null
        $queryErrors = $null
        $instances = @()
        try {
            $instances = @(Get-CimInstance -CimSession $CimSession -Namespace 'root\MicrosoftDNS' -Query $query -ErrorAction SilentlyContinue -ErrorVariable queryErrors)
        }
        catch {
            $wmiError = $_
        }
        foreach ($queryError in @($queryErrors)) {
            if ($null -ne $queryError -and $null -eq $wmiError) {
                $wmiError = $queryError
            }
        }
        if ($null -ne $wmiError) {
            $outcome['Error'] = "Could not read $wmiLabel`: $($wmiError.Exception.Message)"
            $outcome['Unreachable'] = Test-DnsConnectionError -ErrorRecord $wmiError
            $outcome['ErrorId'] = $wmiUnavailableId
            if ($outcome['Unreachable']) {
                $outcome['ErrorId'] = [string]$wmiError.FullyQualifiedErrorId
            }
            return $outcome
        }

        # The data condition (or the single record of the type) already selects
        # one instance; comparing the normalised data guards against a record that
        # changed between the two reads.
        $instance = $null
        foreach ($candidate in $instances) {
            if ($null -eq $candidate) {
                continue
            }
            $candidateProperty = $candidate.PSObject.Properties[$wmiProperty]
            if ($null -eq $candidateProperty -or $null -eq $candidateProperty.Value) {
                continue
            }
            if ($isAddress) {
                $candidateValue = ConvertTo-DnsNormalizedAddress -Address ([string]$candidateProperty.Value)
            }
            else {
                $candidateValue = ConvertTo-DnsNormalizedName -Name ([string]$candidateProperty.Value)
            }
            if ($candidateValue -eq $wanted) {
                $instance = $candidate
                break
            }
        }
        if ($null -eq $instance) {
            $outcome['Error'] = "Could not find $wmiLabel, although Get-DnsServerResourceRecord returns it; its TTL was not changed."
            $outcome['ErrorId'] = $wmiUnavailableId
            return $outcome
        }

        Write-Verbose "Changing the TTL of $wmiLabel to $NewTtl s (Modify)."
        $modifyErrors = $null
        try {
            $null = Invoke-CimMethod -InputObject $instance -MethodName 'Modify' -Arguments @{ TTL = [uint32]$NewTtl } -WhatIf:$false -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable modifyErrors
        }
        catch {
            $wmiError = $_
        }
        foreach ($modifyError in @($modifyErrors)) {
            if ($null -ne $modifyError -and $null -eq $wmiError) {
                $wmiError = $modifyError
            }
        }
        if ($null -ne $wmiError) {
            $outcome['Error'] = "Could not change the TTL of $wmiLabel`: $($wmiError.Exception.Message)"
            $outcome['Unreachable'] = Test-DnsConnectionError -ErrorRecord $wmiError
            $outcome['ErrorId'] = $wmiUnavailableId
            if ($outcome['Unreachable']) {
                $outcome['ErrorId'] = [string]$wmiError.FullyQualifiedErrorId
            }
            return $outcome
        }
    }
    else {
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
    }

    # The server changes more than was asked (it clears the aging timestamp); return what it stored.
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
