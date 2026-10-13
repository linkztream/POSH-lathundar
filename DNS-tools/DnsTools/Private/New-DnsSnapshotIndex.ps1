function New-DnsSnapshotIndex {
    <#
    .SYNOPSIS
        Builds the in-memory lookup index for a server's zone snapshot.

    .DESCRIPTION
        Turns the parse results of ConvertFrom-DnsZoneFile (one per zone) into the
        hashtable described in CONTRACTS.md section 9.3: lookups by owner name
        (Name), by address (Addr, Ptr), by referenced target (RefBy), the DHCID
        and delegation sets, the searchable lists Names and Addrs, and per-zone
        metadata (Zones, OldestExportedAt).

        The build runs in three passes so that it stays linear and legal in
        Constrained Language Mode, where generic lists cannot be created and
        growing an array with += copies it every time (quadratic):
        1. split every row once into flat entry arrays (key, value, data, type),
           pre-sized to the total row count and filled by position;
        2. count the values per key, storing the count in the index hashtable
           itself;
        3. replace each count with an array allocated once at its final size and
           fill it in file order; only keys with more than one value need an
           entry in a position hashtable.

        Values are the strings that end up in the index, built once in pass 1;
        owner and type strings are shared between rows instead of being kept
        once per row. Both matter for the 500 MB budget on 550 000 + 200 000
        rows (CONTRACTS.md section 15).

        The index is internal and large, so it is a plain hashtable, not a typed
        object. ExportedAt per zone is read from an optional ExportedAt key that
        the caller adds to each parse result (it comes from meta.json, which the
        parser never sees); without it the zone's ExportedAt is $null.

        To stay inside the memory budget, each parse result's Rows is set to
        $null as soon as pass 1 has consumed it (CONTRACTS.md section 9.3), so the
        rows can be collected while the index grows; the other keys, including
        RecordCount, stay as they are. Use -KeepRows when the caller still needs
        the rows afterwards.

    .PARAMETER Server
        The DNS server the snapshot belongs to. Stored lower-case.

    .PARAMETER ParseResult
        One hashtable per zone as returned by ConvertFrom-DnsZoneFile, optionally
        with an added ExportedAt [datetime].

    .PARAMETER ZoneTable
        The server's zone table (Get-DnsZoneTable) or any object or hashtable with
        a ZoneLookup hashtable (zone name -> object with IsReverse). Used to tell
        delegations (NS owners that are not the apex of a hosted zone) from zone
        apexes, and as a fallback for IsReverse.

    .PARAMETER KeepRows
        Leave the Rows of every parse result in place. By default they are set to
        $null once consumed, which lowers the peak memory of a full snapshot load.

    .EXAMPLE
        $index = New-DnsSnapshotIndex -Server dc01 -ParseResult $parsed -ZoneTable (Get-DnsZoneTable -Server dc01)

        Builds the index from the parse results of every exported zone; afterwards
        $parsed[0].Rows is $null while $parsed[0].RecordCount is unchanged.

    .EXAMPLE
        $index = New-DnsSnapshotIndex -Server dc01 -ParseResult $parsed -ZoneTable $zoneTable -KeepRows

        Builds the index and keeps the parsed rows for further use.

    .EXAMPLE
        $index.Addr['10.0.16.5']

        Lists the owner names that have an A record for 10.0.16.5.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]]$ParseResult,

        [Parameter(Mandatory)]
        [object]$ZoneTable,

        [switch]$KeepRows
    )

    $zoneLookup = $null
    if ($ZoneTable -is [System.Collections.IDictionary]) {
        $zoneLookup = $ZoneTable['ZoneLookup']
    }
    elseif ($null -ne $ZoneTable.PSObject.Properties['ZoneLookup']) {
        $zoneLookup = $ZoneTable.ZoneLookup
    }
    if ($null -eq $zoneLookup) {
        $zoneLookup = @{}
    }

    $tab = [char]9
    # One instance per type, shared by every entry.
    $typeA = 'A'
    $typeAaaa = 'AAAA'
    $typeCname = 'CNAME'
    $typePtr = 'PTR'
    $typeSrv = 'SRV'
    $typeNs = 'NS'
    $typeMx = 'MX'
    $typeDhcid = 'DHCID'

    $progressId = 93
    $progressActivity = "Building the snapshot index for '$($Server.ToLowerInvariant())'"
    $progressInterval = [timespan]::FromMilliseconds(500)
    $lastProgressAt = [datetime]::UtcNow

    # --- Zone metadata and the total row count that sizes the flat arrays ---
    $zones = @{}
    $zoneIsReverse = @{}
    $oldestExportedAt = $null
    $totalRows = 0
    foreach ($result in $ParseResult) {
        if ($null -eq $result) {
            continue
        }
        $zoneName = ([string]$result['ZoneName']).ToLowerInvariant()

        $isReverse = $result['IsReverse']
        if ($null -eq $isReverse) {
            $zoneInfo = $zoneLookup[$zoneName]
            if ($zoneInfo -is [System.Collections.IDictionary]) {
                $isReverse = $zoneInfo['IsReverse']
            }
            elseif ($null -ne $zoneInfo -and $null -ne $zoneInfo.PSObject.Properties['IsReverse']) {
                $isReverse = $zoneInfo.IsReverse
            }
            if ($null -eq $isReverse) {
                $isReverse = $zoneName -match '(^|\.)(in-addr|ip6)\.arpa$'
            }
        }
        $zoneIsReverse[$zoneName] = [bool]$isReverse

        $exportedAt = $null
        if ($null -ne $result['ExportedAt']) {
            $exportedAt = [datetime]$result['ExportedAt']
            if ($null -eq $oldestExportedAt -or $exportedAt -lt $oldestExportedAt) {
                $oldestExportedAt = $exportedAt
            }
        }

        $zones[$zoneName] = @{
            ExportedAt  = $exportedAt
            DefaultTtl  = $result['DefaultTtl']
            RecordCount = $result['RecordCount']
            IsReverse   = [bool]$isReverse
        }

        # A lone string has no Count under strict mode; @() would copy a large array.
        $rows = $result['Rows']
        if ($rows -is [array]) {
            $totalRows = $totalRows + $rows.Count
        }
        elseif ($null -ne $rows) {
            $totalRows++
        }
    }
    # This local would otherwise keep the last zone's rows alive for the whole build.
    $rows = $null

    # Progress only pays off for large snapshots; tiny builds finish in milliseconds.
    $showProgress = $totalRows -ge 50000

    # --- Pass 1: split each row once into flat entry arrays, filled by position ---
    if ($showProgress) {
        Write-Progress -Id $progressId -Activity $progressActivity -Status "Pass 1 of 3: splitting $totalRows rows" -PercentComplete 0
        $lastProgressAt = [datetime]::UtcNow
    }

    # Entry i: key (owner, or address for PTR), value (the index string), data
    # (Addr/RefBy key, only where needed) and type. PTR rows without ADDR get no entry.
    $entryKeys = @($null) * $totalRows
    $entryValues = @($null) * $totalRows
    $entryData = @($null) * $totalRows
    $entryTypes = @($null) * $totalRows
    $entryCount = 0
    $dhcid = @{}
    $delegation = @{}

    $zoneRanges = foreach ($result in $ParseResult) {
        if ($null -eq $result -or $null -eq $result['Rows']) {
            continue
        }
        $zoneName = ([string]$result['ZoneName']).ToLowerInvariant()
        $rangeStart = $entryCount
        $lastOwner = ''

        foreach ($row in $result['Rows']) {
            # OWNER TYPE DATA TTL AGE ADDR
            $field = $row.Split($tab)
            $owner = $field[0]
            # Records of one node are adjacent; reusing the previous instance keeps
            # one copy of each owner name instead of one per row.
            if ($owner -ceq $lastOwner) {
                $owner = $lastOwner
            }
            else {
                $lastOwner = $owner
            }
            $type = $field[1]

            if ($type -eq 'PTR') {
                $address = $field[5]
                if ($address -ne '') {
                    $entryKeys[$entryCount] = $address
                    $entryValues[$entryCount] = "$zoneName`t$($field[2])`t$($field[3])`t$($field[4])`t$owner"
                    $entryTypes[$entryCount] = $typePtr
                    $entryCount++
                }
                continue
            }

            $data = $field[2]
            $entryKeys[$entryCount] = $owner
            $entryValues[$entryCount] = "$type`t$data`t$($field[3])`t$($field[4])`t$zoneName"
            if ($type -eq 'A') {
                $entryTypes[$entryCount] = $typeA
                $entryData[$entryCount] = $data
            }
            elseif ($type -eq 'DHCID') {
                # The base64 data is only needed inside the Name value.
                $entryTypes[$entryCount] = $typeDhcid
                $dhcid[$owner] = $true
            }
            elseif ($type -eq 'AAAA') {
                $entryTypes[$entryCount] = $typeAaaa
                $entryData[$entryCount] = $data
            }
            elseif ($type -eq 'CNAME') {
                $entryTypes[$entryCount] = $typeCname
                $entryData[$entryCount] = $data
            }
            elseif ($type -eq 'SRV') {
                $entryTypes[$entryCount] = $typeSrv
                $entryData[$entryCount] = $data
            }
            elseif ($type -eq 'NS') {
                $entryTypes[$entryCount] = $typeNs
                $entryData[$entryCount] = $data
                if ($owner -ne $zoneName -and -not $zoneLookup.ContainsKey($owner)) {
                    $delegation[$owner] = $true
                }
            }
            elseif ($type -eq 'MX') {
                $entryTypes[$entryCount] = $typeMx
                $entryData[$entryCount] = $data
            }
            else {
                # Not a type the parser emits; keep it findable by name only.
                $entryTypes[$entryCount] = $type
            }
            $entryCount++
        }

        # Every entry now holds its own strings, so the zone's rows can be collected
        # while passes 2 and 3 allocate the index (section 9.3, about 85 MB at peak).
        if (-not $KeepRows) {
            $result['Rows'] = $null
        }

        @{
            Start     = $rangeStart
            End       = $entryCount
            Zone      = $zoneName
            IsForward = -not $zoneIsReverse[$zoneName]
        }
    }

    # --- Pass 2: count values per key; Addrs in first-seen order ---
    if ($showProgress -and ([datetime]::UtcNow - $lastProgressAt) -ge $progressInterval) {
        Write-Progress -Id $progressId -Activity $progressActivity -Status 'Pass 2 of 3: counting' -PercentComplete 33
        $lastProgressAt = [datetime]::UtcNow
    }

    # The counts live in the index tables themselves; pass 3 replaces each count
    # with the key's array, so no separate count table is held in memory. A first
    # occurrence stores the literal 1, whose boxed instance PowerShell shares,
    # whereas ++ would allocate a new box for every key.
    $nameIndex = @{}
    $addrIndex = @{}
    $ptrIndex = @{}
    $refIndex = @{}

    $uniqueAddrs = for ($i = 0; $i -lt $entryCount; $i++) {
        $type = $entryTypes[$i]
        $key = $entryKeys[$i]
        if ($type -eq 'PTR') {
            $count = $ptrIndex[$key]
            if ($null -eq $count) {
                $ptrIndex[$key] = 1
            }
            else {
                $ptrIndex[$key] = $count + 1
            }
            continue
        }

        $count = $nameIndex[$key]
        if ($null -eq $count) {
            $nameIndex[$key] = 1
        }
        else {
            $nameIndex[$key] = $count + 1
        }

        $data = $entryData[$i]
        if ($null -eq $data -or $data -eq '') {
            continue
        }
        if ($type -eq 'A' -or $type -eq 'AAAA') {
            $count = $addrIndex[$data]
            if ($null -eq $count) {
                $addrIndex[$data] = 1
                $data
            }
            else {
                $addrIndex[$data] = $count + 1
            }
        }
        else {
            $count = $refIndex[$data]
            if ($null -eq $count) {
                $refIndex[$data] = 1
            }
            else {
                $refIndex[$data] = $count + 1
            }
        }
    }

    # --- Pass 3: allocate each key's array once and fill it in file order ---
    if ($showProgress -and ([datetime]::UtcNow - $lastProgressAt) -ge $progressInterval) {
        Write-Progress -Id $progressId -Activity $progressActivity -Status 'Pass 3 of 3: filling' -PercentComplete 66
        $lastProgressAt = [datetime]::UtcNow
    }

    # Position tables only hold keys with more than one value. $nameUnlisted holds
    # the few multi-valued owners whose first record is not A/AAAA/CNAME (zone
    # apex NS, delegations), so that Names needs no seen-table of its own.
    $namePosition = @{}
    $nameUnlisted = @{}
    $addrPosition = @{}
    $ptrPosition = @{}
    $refPosition = @{}

    $uniqueNames = foreach ($range in $zoneRanges) {
        $zoneName = $range['Zone']
        $isForward = $range['IsForward']

        for ($i = $range['Start']; $i -lt $range['End']; $i++) {
            $type = $entryTypes[$i]
            $key = $entryKeys[$i]
            $value = $entryValues[$i]

            if ($type -eq 'PTR') {
                $current = $ptrIndex[$key]
                if ($current -is [int]) {
                    if ($current -eq 1) {
                        $ptrIndex[$key] = [string[]]$value
                    }
                    else {
                        $values = [string[]](@($null) * $current)
                        $values[0] = $value
                        $ptrIndex[$key] = $values
                        $ptrPosition[$key] = 1
                    }
                }
                else {
                    $position = $ptrPosition[$key]
                    $current[$position] = $value
                    $ptrPosition[$key] = $position + 1
                }
                continue
            }

            # Name; Names gets every forward owner with an A, AAAA or CNAME once.
            $isListed = $isForward -and ($type -eq 'A' -or $type -eq 'AAAA' -or $type -eq 'CNAME')
            $current = $nameIndex[$key]
            if ($current -is [int]) {
                if ($current -eq 1) {
                    $nameIndex[$key] = [string[]]$value
                    if ($isListed) {
                        $key
                    }
                }
                else {
                    $values = [string[]](@($null) * $current)
                    $values[0] = $value
                    $nameIndex[$key] = $values
                    $namePosition[$key] = 1
                    if ($isListed) {
                        $key
                    }
                    else {
                        $nameUnlisted[$key] = $true
                    }
                }
            }
            else {
                $position = $namePosition[$key]
                $current[$position] = $value
                $namePosition[$key] = $position + 1
                if ($isListed -and $nameUnlisted.Count -gt 0 -and $nameUnlisted.ContainsKey($key)) {
                    $key
                    $nameUnlisted.Remove($key)
                }
            }

            $data = $entryData[$i]
            if ($null -eq $data -or $data -eq '') {
                continue
            }

            if ($type -eq 'A' -or $type -eq 'AAAA') {
                # Addr values are the owner instances already used as Name keys.
                $current = $addrIndex[$data]
                if ($current -is [int]) {
                    if ($current -eq 1) {
                        $addrIndex[$data] = [string[]]$key
                    }
                    else {
                        $values = [string[]](@($null) * $current)
                        $values[0] = $key
                        $addrIndex[$data] = $values
                        $addrPosition[$data] = 1
                    }
                }
                else {
                    $position = $addrPosition[$data]
                    $current[$position] = $key
                    $addrPosition[$data] = $position + 1
                }
                continue
            }

            # CNAME, SRV, NS, MX: RefBy. Few rows, so the value is built here.
            $value = "$type`t$key`t$zoneName"
            $current = $refIndex[$data]
            if ($current -is [int]) {
                if ($current -eq 1) {
                    $refIndex[$data] = [string[]]$value
                }
                else {
                    $values = [string[]](@($null) * $current)
                    $values[0] = $value
                    $refIndex[$data] = $values
                    $refPosition[$data] = 1
                }
            }
            else {
                $position = $refPosition[$data]
                $current[$position] = $value
                $refPosition[$data] = $position + 1
            }
        }
    }

    $entryKeys = $null
    $entryValues = $null
    $entryData = $null
    $entryTypes = $null
    $namePosition = $null
    $nameUnlisted = $null
    $addrPosition = $null
    $ptrPosition = $null
    $refPosition = $null

    if ($showProgress) {
        Write-Progress -Id $progressId -Activity $progressActivity -Completed
    }

    if ($null -eq $uniqueNames) {
        $names = [string[]]@()
    }
    else {
        $names = [string[]]$uniqueNames
    }
    if ($null -eq $uniqueAddrs) {
        $addrs = [string[]]@()
    }
    else {
        $addrs = [string[]]$uniqueAddrs
    }

    @{
        Server           = $Server.ToLowerInvariant()
        BuiltAt          = Get-Date
        Name             = $nameIndex
        Addr             = $addrIndex
        Ptr              = $ptrIndex
        RefBy            = $refIndex
        Dhcid            = $dhcid
        Delegation       = $delegation
        Names            = $names
        Addrs            = $addrs
        Zones            = $zones
        OldestExportedAt = $oldestExportedAt
    }
}
