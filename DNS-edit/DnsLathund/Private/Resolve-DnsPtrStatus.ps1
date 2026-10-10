function Resolve-DnsPtrStatus {
    <#
    .SYNOPSIS
        Works out the PTR status of one A/AAAA address (CONTRACTS.md section 12.1).

    .DESCRIPTION
        Applies the PtrStatus rules of CONTRACTS.md section 12.1 to one address and
        the name that owns the A/AAAA record, against the server's zone table:

        - No hosted reverse zone covers the address: NoReverseZone. Stub and
          conditional forwarder zones hold no records here and do not count.
        - The expected zone is the longest covering zone; RFC 2317 classless zones
          count as longer than their parent (Find-DnsZoneForName -Reverse returns
          them first). Its node for the address is examined first:
          - PTR record(s) there: Ok when a target equals -Name or another name with
            an A/AAAA for the same address (SharedWith); Multiple instead of Ok when
            there is more than one PTR; otherwise WrongTarget.
          - A CNAME there (the parent side of an RFC 2317 delegation): Delegated.
            PtrZoneFound is the hosted zone that holds the CNAME target (one hop),
            or $null when the target is not in a hosted zone.
          - With an index, the node lies at or below an NS delegation of the
            expected zone (Index.Delegation): Delegated, PtrZoneFound $null. The
            PTR is another server's business. Without an index this check is
            skipped.
          - Otherwise each shorter covering zone is examined: the first one with a
            PTR at the address's node gives Shadowed with PtrZoneFound; none at all
            gives Missing.

        With -ServerParameter the CNAME and PTR lookups are live (Get-DnsLiveRecord,
        one -Node query per type and zone). Without it they come from the snapshot
        index: Index.Ptr for PTR records and Index.Name for the CNAME at the node.
        SharedWith always comes from Index.Addr; without an index it is $null and
        the "target equals a SharedWith name" clause is skipped.

        Returns a hashtable:

          PtrStatus     Ok, Missing, WrongTarget, Shadowed, Delegated, Multiple or
                        NoReverseZone
          ReverseZone   the expected reverse zone, $null with NoReverseZone
          PtrTargets    string[] of the PTR targets at the address's node in the zone
                        that decided the status (expected zone, or PtrZoneFound when
                        Shadowed); @() when Missing; $null when not evaluated
                        (NoReverseZone, Delegated)
          PtrZoneFound  the zone where a PTR was found (Ok, Multiple, WrongTarget,
                        Shadowed), the zone of the CNAME target (Delegated), else $null
          SharedWith    string[] of the other names with an A/AAAA for the address
                        (index needed), @() when there are none, $null without index

        The helper knows nothing about Get-DnsEntry, so Test-DnsConsistency can reuse
        it.

    .PARAMETER Address
        The IPv4 or IPv6 address of the A/AAAA record.

    .PARAMETER Name
        The owner FQDN of the A/AAAA record.

    .PARAMETER ZoneTable
        The server's zone table from Get-DnsZoneTable.

    .PARAMETER Index
        The server's snapshot index (Get-DnsSnapshotIndex). Supplies Addr
        (SharedWith), Delegation and, without -ServerParameter, Ptr and Name.

    .PARAMETER ServerParameter
        The splat from Get-DnsServerParameter. When given, CNAME and PTR records are
        read live; when absent, from the index.

    .EXAMPLE
        Resolve-DnsPtrStatus -Address '10.0.16.20' -Name 'srv01.contoso.local' -ZoneTable $zoneTable -ServerParameter $serverParameters

        Checks the PTR of 10.0.16.20 live; SharedWith is $null.

    .EXAMPLE
        Resolve-DnsPtrStatus -Address '10.0.16.20' -Name 'srv01.contoso.local' -ZoneTable $zoneTable -Index $index

        Checks the PTR of 10.0.16.20 from the snapshot index only.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Address,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$ZoneTable,

        [Parameter()]
        [AllowNull()]
        [hashtable]$Index,

        [Parameter()]
        [AllowNull()]
        [hashtable]$ServerParameter
    )

    $tab = [char]9
    $ownerName = ConvertTo-DnsNormalizedName -Name $Name
    $result = @{
        PtrStatus    = 'NoReverseZone'
        ReverseZone  = $null
        PtrTargets   = $null
        PtrZoneFound = $null
        SharedWith   = $null
    }

    $reverse = ConvertTo-DnsReverseName -Address $Address
    if ($null -eq $reverse) {
        Write-Verbose "'$Address' is not an IP address; no reverse zone can cover it."
        return $result
    }
    $address = $reverse['Address']
    $reverseName = $reverse['ReverseName']
    $isLive = $null -ne $ServerParameter

    # --- SharedWith: the other owners of the address (snapshot only) ---
    $sharedNames = @{}
    if ($null -ne $Index) {
        $addrIndex = $Index['Addr']
        $owners = $null
        if ($null -ne $addrIndex) {
            $owners = $addrIndex[$address]
        }
        $result['SharedWith'] = [string[]]@(
            foreach ($owner in @($owners)) {
                if ($null -eq $owner -or $owner -eq $ownerName -or $sharedNames.ContainsKey($owner)) {
                    continue
                }
                $sharedNames[$owner] = $true
                $owner
            }
        )
    }

    # --- Covering zones that can hold records, longest (classless) first ---
    $zoneLookup = $ZoneTable.ZoneLookup
    $coveringZones = @(
        foreach ($zoneName in @(Find-DnsZoneForName -Name $reverseName -ZoneTable $ZoneTable -Reverse)) {
            $zoneInfo = $zoneLookup[$zoneName]
            if ($null -eq $zoneInfo) {
                continue
            }
            $zoneType = [string]$zoneInfo.ZoneType
            if ($zoneType -eq 'Stub' -or $zoneType -eq 'Forwarder') {
                continue
            }
            $zoneName
        }
    )
    if ($coveringZones.Count -eq 0) {
        return $result
    }
    $result['ReverseZone'] = $coveringZones[0]

    $ptrEntries = $null
    if (-not $isLive -and $null -ne $Index -and $null -ne $Index['Ptr']) {
        $ptrEntries = $Index['Ptr'][$address]
    }

    for ($zoneNumber = 0; $zoneNumber -lt $coveringZones.Count; $zoneNumber++) {
        $zoneName = $coveringZones[$zoneNumber]
        $isExpectedZone = $zoneNumber -eq 0
        $isClassless = $zoneLookup[$zoneName].IsClassless -eq $true
        $nodeName = Get-DnsReverseNodeName -ReverseName $reverseName -ZoneName $zoneName -ClasslessHostLabel:$isClassless
        if ($null -eq $nodeName) {
            continue
        }
        if ($nodeName -eq '@') {
            $nodeOwner = $zoneName
        }
        else {
            $nodeOwner = $nodeName + '.' + $zoneName
        }

        # --- PTR records at the node ---
        if ($isLive) {
            $targets = [string[]]@(
                foreach ($record in @(Get-DnsLiveRecord -ServerParameter $ServerParameter -ZoneName $zoneName -NodeName $nodeName -RRType 'PTR')) {
                    if ($record['Data']) {
                        $record['Data']
                    }
                }
            )
        }
        else {
            $targets = [string[]]@(
                foreach ($ptrEntry in @($ptrEntries)) {
                    if ($null -eq $ptrEntry) {
                        continue
                    }
                    # ZONE TARGET TTL AGE OWNER
                    $field = $ptrEntry.Split($tab)
                    if ($field[0] -eq $zoneName -and $field[4] -eq $nodeOwner) {
                        $field[1]
                    }
                }
            )
        }

        if (-not $isExpectedZone) {
            if ($targets.Count -gt 0) {
                $result['PtrStatus'] = 'Shadowed'
                $result['PtrZoneFound'] = $zoneName
                $result['PtrTargets'] = $targets
                return $result
            }
            continue
        }

        if ($targets.Count -gt 0) {
            $isMatch = $false
            foreach ($target in $targets) {
                if ($target -eq $ownerName -or $sharedNames.ContainsKey($target)) {
                    $isMatch = $true
                    break
                }
            }

            if (-not $isMatch) {
                $result['PtrStatus'] = 'WrongTarget'
            }
            elseif ($targets.Count -gt 1) {
                $result['PtrStatus'] = 'Multiple'
            }
            else {
                $result['PtrStatus'] = 'Ok'
            }
            $result['PtrZoneFound'] = $zoneName
            $result['PtrTargets'] = $targets
            return $result
        }

        # --- No PTR in the expected zone: a CNAME there delegates it (RFC 2317) ---
        # A node holds either a CNAME or other data, so this lookup is only needed
        # when no PTR was found.
        $cnameTarget = $null
        if ($isLive) {
            foreach ($record in @(Get-DnsLiveRecord -ServerParameter $ServerParameter -ZoneName $zoneName -NodeName $nodeName -RRType 'CNAME')) {
                if ($record['Data']) {
                    $cnameTarget = $record['Data']
                }
            }
        }
        elseif ($null -ne $Index -and $null -ne $Index['Name']) {
            foreach ($nameEntry in @($Index['Name'][$nodeOwner])) {
                if ($null -eq $nameEntry) {
                    continue
                }
                # TYPE DATA TTL AGE ZONE
                $field = $nameEntry.Split($tab)
                if ($field[0] -eq 'CNAME' -and $field[4] -eq $zoneName) {
                    $cnameTarget = $field[1]
                }
            }
        }

        if ($cnameTarget) {
            $result['PtrStatus'] = 'Delegated'
            foreach ($targetZone in @(Find-DnsZoneForName -Name $cnameTarget -ZoneTable $ZoneTable)) {
                $targetZoneInfo = $zoneLookup[$targetZone]
                if ($null -ne $targetZoneInfo -and [string]$targetZoneInfo.ZoneType -ne 'Stub' -and [string]$targetZoneInfo.ZoneType -ne 'Forwarder') {
                    $result['PtrZoneFound'] = $targetZone
                    break
                }
            }
            return $result
        }

        # --- An NS delegation at or above the node hands the PTR to another server ---
        if ($null -ne $Index -and $null -ne $Index['Delegation'] -and $Index['Delegation'].Count -gt 0) {
            $delegationIndex = $Index['Delegation']
            $zoneSuffix = '.' + $zoneName
            $candidate = $nodeOwner
            while ($candidate.EndsWith($zoneSuffix)) {
                if ($delegationIndex.ContainsKey($candidate)) {
                    Write-Verbose "The reverse name '$reverseName' is delegated at '$candidate' in zone '$zoneName'."
                    $result['PtrStatus'] = 'Delegated'
                    return $result
                }
                $candidate = $candidate.Substring($candidate.IndexOf('.') + 1)
            }
        }
    }

    $result['PtrStatus'] = 'Missing'
    $result['PtrTargets'] = [string[]]@()
    $result
}
