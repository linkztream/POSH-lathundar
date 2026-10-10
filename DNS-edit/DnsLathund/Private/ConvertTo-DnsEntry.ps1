function ConvertTo-DnsEntry {
    <#
    .SYNOPSIS
        Builds one DnsLathund.Entry object from a record and its PTR status.

    .DESCRIPTION
        Creates the DnsLathund.Entry of CONTRACTS.md section 12.1, with the 24
        properties in contract order, through New-DnsObject.

        The record comes either from a live lookup (-Record, a hashtable from
        Get-DnsLiveRecord) or from the snapshot index (-Owner plus -IndexValue, one
        "TYPE<tab>DATA<tab>TTL<tab>AGE<tab>ZONE" string of Index.Name). For index
        records the aging timestamp is computed from the export's AGE hours,
        NodeName is derived from the owner and the zone (the export does not keep
        the original spelling) and DistinguishedName is $null.

        The PTR fields (PtrStatus, ReverseZone, PtrTargets, PtrZoneFound,
        SharedWith) are copied from -PtrInfo (Resolve-DnsPtrStatus). A CNAME gets
        PtrStatus 'NotApplicable' and $null in the other PTR fields.

        The snapshot-derived fields need -Index: Aliases (CNAME owners pointing at
        the name) and ReferencedBy ('SRV:<owner>', 'NS:<owner>', 'MX:<owner>') from
        Index.RefBy, HasDhcid from Index.Dhcid, and for a CNAME TargetExists (the
        target owns an A, AAAA or CNAME in the snapshot). Without -Index they are
        $null, meaning "not evaluated"; with -Index an empty list is @() (CONTRACTS.md
        section 12).

        InDhcpRange is $true when the address of an A/AAAA record is in one of the
        -Network entries; pass only entries that were validated already, so that
        Test-DnsAddressInNetwork never warns per entry.

    .PARAMETER Record
        A record hashtable from Get-DnsLiveRecord (Owner, Zone, NodeName, Type, Data,
        Ttl, Timestamp, DistinguishedName).

    .PARAMETER Owner
        The owner FQDN of an index record (the Index.Name key).

    .PARAMETER IndexValue
        One value of Index.Name[Owner]: "TYPE<tab>DATA<tab>TTL<tab>AGE<tab>ZONE".

    .PARAMETER PtrInfo
        The hashtable from Resolve-DnsPtrStatus for an A/AAAA record; ignored for a
        CNAME.

    .PARAMETER Index
        The snapshot index used for Aliases, ReferencedBy, HasDhcid and TargetExists.

    .PARAMETER Network
        Validated CIDR networks (Get-DnsEntry -ExcludeNetwork) for InDhcpRange.

    .PARAMETER Source
        'Live' or 'Snapshot'.

    .PARAMETER Server
        The DNS server, lower case.

    .PARAMETER SnapshotAge
        Age of the oldest zone export behind the snapshot-derived fields, or $null
        when no snapshot was used.

    .EXAMPLE
        ConvertTo-DnsEntry -Record $liveRecord -PtrInfo $ptrInfo -Source Live -Server 'dc01'

        Builds an entry from a live record without snapshot data.

    .EXAMPLE
        ConvertTo-DnsEntry -Owner 'srv01.contoso.local' -IndexValue "A`t10.0.16.20`t3600`t0`tcontoso.local" -PtrInfo $ptrInfo -Index $index -Source Snapshot -Server 'dc01' -SnapshotAge $age

        Builds an entry from a snapshot index record.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Record')]
    [OutputType('DnsLathund.Entry')]
    param (
        [Parameter(Mandatory, ParameterSetName = 'Record')]
        [ValidateNotNull()]
        [hashtable]$Record,

        [Parameter(Mandatory, ParameterSetName = 'Index')]
        [ValidateNotNullOrEmpty()]
        [string]$Owner,

        [Parameter(Mandatory, ParameterSetName = 'Index')]
        [ValidateNotNullOrEmpty()]
        [string]$IndexValue,

        [Parameter()]
        [AllowNull()]
        [hashtable]$PtrInfo,

        [Parameter()]
        [AllowNull()]
        [hashtable]$Index,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Network,

        [Parameter(Mandatory)]
        [ValidateSet('Live', 'Snapshot')]
        [string]$Source,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter()]
        [AllowNull()]
        [object]$SnapshotAge
    )

    $tab = [char]9

    if ($PSCmdlet.ParameterSetName -eq 'Index') {
        # TYPE DATA TTL AGE ZONE
        $field = $IndexValue.Split($tab)
        $name = $Owner
        $type = $field[0]
        $data = $field[1]
        $ttl = $field[2] -as [int]
        $zone = $field[4]
        $ageHours = $field[3] -as [long]

        $timestamp = $null
        if ($ageHours -gt 0) {
            # [AGE:n] counts hours since 1601-01-01 UTC (the FILETIME epoch).
            $timestamp = [datetime]::FromFileTimeUtc(0).AddHours($ageHours).ToLocalTime()
        }

        if ($name -eq $zone) {
            $nodeName = '@'
        }
        elseif ($name.EndsWith('.' + $zone)) {
            $nodeName = $name.Substring(0, $name.Length - $zone.Length - 1)
        }
        else {
            $nodeName = $name
        }
        $distinguishedName = $null
    }
    else {
        $name = [string]$Record['Owner']
        $type = [string]$Record['Type']
        $data = $Record['Data']
        $ttl = $Record['Ttl']
        $zone = [string]$Record['Zone']
        $nodeName = $Record['NodeName']
        $timestamp = $Record['Timestamp']
        $distinguishedName = $Record['DistinguishedName']
    }

    $isAddress = $type -eq 'A' -or $type -eq 'AAAA'
    $isCname = $type -eq 'CNAME'

    # --- PTR fields ---
    $ptrStatus = $null
    $reverseZone = $null
    $ptrTargets = $null
    $ptrZoneFound = $null
    $sharedWith = $null
    if ($isCname) {
        $ptrStatus = 'NotApplicable'
    }
    elseif ($null -ne $PtrInfo) {
        $ptrStatus = $PtrInfo['PtrStatus']
        $reverseZone = $PtrInfo['ReverseZone']
        $ptrTargets = $PtrInfo['PtrTargets']
        $ptrZoneFound = $PtrInfo['PtrZoneFound']
        $sharedWith = $PtrInfo['SharedWith']
    }

    # --- Snapshot-derived fields: $null = not evaluated, @() = evaluated and empty ---
    $hasDhcid = $null
    $aliases = $null
    $referencedBy = $null
    $targetExists = $null
    if ($null -ne $Index) {
        $hasDhcid = $false
        if ($null -ne $Index['Dhcid']) {
            $hasDhcid = $Index['Dhcid'][$name] -eq $true
        }

        $references = $null
        if ($null -ne $Index['RefBy']) {
            $references = $Index['RefBy'][$name]
        }
        $seenAliases = @{}
        $aliases = [string[]]@(
            foreach ($reference in @($references)) {
                if ($null -eq $reference) {
                    continue
                }
                # TYPE OWNER ZONE
                $field = $reference.Split($tab)
                if ($field[0] -eq 'CNAME' -and -not $seenAliases.ContainsKey($field[1])) {
                    $seenAliases[$field[1]] = $true
                    $field[1]
                }
            }
        )
        $seenReferences = @{}
        $referencedBy = [string[]]@(
            foreach ($reference in @($references)) {
                if ($null -eq $reference) {
                    continue
                }
                $field = $reference.Split($tab)
                if ($field[0] -eq 'CNAME') {
                    continue
                }
                $text = $field[0] + ':' + $field[1]
                if (-not $seenReferences.ContainsKey($text)) {
                    $seenReferences[$text] = $true
                    $text
                }
            }
        )

        if ($isCname) {
            $targetExists = $false
            if ($data -and $null -ne $Index['Name']) {
                foreach ($targetEntry in @($Index['Name'][$data])) {
                    if ($null -eq $targetEntry) {
                        continue
                    }
                    $targetType = $targetEntry.Substring(0, $targetEntry.IndexOf($tab))
                    if ($targetType -eq 'A' -or $targetType -eq 'AAAA' -or $targetType -eq 'CNAME') {
                        $targetExists = $true
                        break
                    }
                }
            }
        }
    }

    $inDhcpRange = $false
    if ($isAddress -and $data -and $null -ne $Network -and $Network.Count -gt 0) {
        $inDhcpRange = Test-DnsAddressInNetwork -Address $data -Network $Network
    }

    $target = $null
    if ($isCname) {
        $target = $data
    }

    New-DnsObject -TypeName 'Entry' -Property ([ordered]@{
            Name              = $name
            Type              = $type
            Data              = $data
            TTL               = $ttl
            PtrStatus         = $ptrStatus
            Zone              = $zone
            NodeName          = $nodeName
            Timestamp         = $timestamp
            IsStatic          = $null -eq $timestamp
            HasDhcid          = $hasDhcid
            InDhcpRange       = $inDhcpRange
            ReverseZone       = $reverseZone
            PtrTargets        = $ptrTargets
            PtrZoneFound      = $ptrZoneFound
            SharedWith        = $sharedWith
            Aliases           = $aliases
            ReferencedBy      = $referencedBy
            Target            = $target
            TargetExists      = $targetExists
            DistinguishedName = $distinguishedName
            Owner             = $null
            Server            = $Server
            Source            = $Source
            SnapshotAge       = $SnapshotAge
        })
}
