function Get-DnsZoneTable {
    <#
    .SYNOPSIS
        Returns the cached table of zones hosted on a DNS server.

    .DESCRIPTION
        Reads every zone with Get-DnsServerZone, the aging settings of every
        exportable zone with Get-DnsServerZoneAging, and the server scavenging
        settings with Get-DnsServerScavenging, and returns one
        DnsLathund.ZoneTable object (CONTRACTS.md section 8). The table is cached
        per server in $script:ZoneTableCache for the life of the module; -Refresh
        reads it again.

        Each zone becomes a DnsLathund.ZoneInfo object. Reverse zones are detected
        from IsReverseLookupZone or from the in-addr.arpa / ip6.arpa suffix.

        RFC 2317 classless reverse zones (CONTRACTS.md section 8.3) have a first
        label '<first>/<n>' or '<first>-<n>':

          '/' form  n is always a prefix length, 25-32; the zone covers
                    first ... first + 2^(32-n) - 1 ('0/25' covers 0-127, '5/32'
                    covers 5 only). Any other n is not classless.
          '-' form  n of 25-32 is read as a prefix length too (the usual convention
                    where '/' is avoided: '0-26' covers 0-63, '0-31' covers 0-1).
                    When n >= first it could also be a last host, so a Verbose
                    line names both readings. Any other n is the last host octet (range form:
                    '10-20' covers 10-20, '64-127' covers 64-127).

        The covered hosts must satisfy first <= last <= 255; otherwise the zone is
        an ordinary reverse zone (Verbose). Classless zones get IsClassless,
        ClasslessHostRange (@(first, last)) and ClasslessNetwork: CIDR
        ('10.0.16.64/26') when the range is a power-of-two block aligned to its
        size, otherwise the range form ('10.0.16.10-20').

        Failure to list the zones is terminating: nothing else can work. A failed
        aging query leaves that zone's aging fields $null (Verbose); a failed
        scavenging query leaves ServerScavenging $null (Warning).

    .PARAMETER Server
        The DNS server name.

    .PARAMETER Credential
        Alternate credentials; all DnsServer calls then go through a CIM session.

    .PARAMETER TimeoutSec
        Timeout for opening the CIM session when -Credential is given.

    .PARAMETER Refresh
        Ignore the cached table and read the zones again.

    .EXAMPLE
        $zoneTable = Get-DnsZoneTable -Server 'dc01'
        $zoneTable.ZoneLookup['contoso.local'].DynamicUpdate

        Returns the dynamic update setting of contoso.local on dc01.

    .EXAMPLE
        Get-DnsZoneTable -Server 'dc01' -Refresh

        Re-reads the zone list after a zone was created or removed.
    #>
    [CmdletBinding()]
    [OutputType('DnsLathund.ZoneTable')]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter()]
        [AllowNull()]
        [pscredential]$Credential,

        [Parameter()]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSec = 300,

        [Parameter()]
        [switch]$Refresh
    )

    $serverKey = $Server.ToLowerInvariant()
    if (-not $Refresh -and $script:ZoneTableCache.ContainsKey($serverKey)) {
        Write-Verbose "Using the cached zone table of '$serverKey'."
        return $script:ZoneTableCache[$serverKey]
    }

    Import-DnsServerModule
    $serverParameters = Get-DnsServerParameter -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec

    try {
        Write-Verbose "Reading the zone list from '$serverKey' (Get-DnsServerZone)."
        $serverZones = @(Get-DnsServerZone @serverParameters -ErrorAction Stop)
    }
    catch {
        throw "Could not read the zone list from '$serverKey': $($_.Exception.Message) Check the server name, that the DNS Server service is running and that you may read its configuration, or specify another -Server."
    }

    $zoneProperties = @(
        'ZoneName', 'ZoneType', 'IsReverseLookupZone', 'IsDsIntegrated', 'ReplicationScope',
        'DirectoryPartitionName', 'DynamicUpdate', 'IsAutoCreated'
    )
    $agingProperties = @('AgingEnabled', 'NoRefreshInterval', 'RefreshInterval', 'ScavengeServers')
    $classlessPattern = '^(\d+)([/-])(\d+)\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.in-addr\.arpa$'

    $zoneLookup = @{}
    $zoneInfos = foreach ($serverZone in $serverZones) {
        if ($null -eq $serverZone) {
            continue
        }

        # Read optional properties defensively: strict mode throws on a missing one,
        # and the set differs between zone types and DnsServer versions.
        $raw = @{}
        foreach ($propertyName in $zoneProperties) {
            $property = $serverZone.PSObject.Properties[$propertyName]
            if ($null -ne $property) {
                $raw[$propertyName] = $property.Value
            }
            else {
                $raw[$propertyName] = $null
            }
        }

        $zoneName = ConvertTo-DnsNormalizedName -Name ([string]$raw['ZoneName'])
        if (-not $zoneName) {
            # The root zone '.' normalises to an empty string.
            $zoneName = '.'
        }

        $isReverse = ($raw['IsReverseLookupZone'] -eq $true) -or
            $zoneName.EndsWith('.in-addr.arpa') -or $zoneName.EndsWith('.ip6.arpa')
        $zoneType = [string]$raw['ZoneType']
        $isAutoCreated = $raw['IsAutoCreated'] -eq $true
        $isExportable = ($zoneType -eq 'Primary') -and -not $isAutoCreated -and ($zoneName -ne 'trustanchors')

        $replicationScope = $null
        if ($null -ne $raw['ReplicationScope'] -and '' -ne [string]$raw['ReplicationScope']) {
            $replicationScope = [string]$raw['ReplicationScope']
        }
        $directoryPartitionName = $null
        if ($null -ne $raw['DirectoryPartitionName'] -and '' -ne [string]$raw['DirectoryPartitionName']) {
            $directoryPartitionName = [string]$raw['DirectoryPartitionName']
        }
        $dynamicUpdate = $null
        if ($null -ne $raw['DynamicUpdate']) {
            $dynamicUpdate = [string]$raw['DynamicUpdate']
        }

        $aging = @{ AgingEnabled = $null; NoRefreshInterval = $null; RefreshInterval = $null; ScavengeServers = $null }
        if ($isExportable) {
            try {
                Write-Verbose "Reading aging settings of '$zoneName' on '$serverKey' (Get-DnsServerZoneAging)."
                $zoneAging = Get-DnsServerZoneAging -Name $zoneName @serverParameters -ErrorAction Stop
                foreach ($propertyName in $agingProperties) {
                    $property = $zoneAging.PSObject.Properties[$propertyName]
                    if ($null -ne $property) {
                        $aging[$propertyName] = $property.Value
                    }
                }
                if ($null -ne $aging['ScavengeServers']) {
                    $aging['ScavengeServers'] = [string[]]@(
                        foreach ($scavengeServer in @($aging['ScavengeServers'])) {
                            if ($null -ne $scavengeServer) {
                                [string]$scavengeServer
                            }
                        }
                    )
                }
            }
            catch {
                $aging = @{ AgingEnabled = $null; NoRefreshInterval = $null; RefreshInterval = $null; ScavengeServers = $null }
                Write-Verbose "Could not read aging settings of '$zoneName' on '$serverKey': $($_.Exception.Message)"
            }
        }

        $isClassless = $false
        $classlessNetwork = $null
        $classlessHostRange = $null
        if ($isReverse -and $zoneName -match $classlessPattern) {
            # -as [int] instead of a cast: an absurdly long digit run must not throw.
            $firstHost = $Matches[1] -as [int]
            $separator = $Matches[2]
            $secondNumber = $Matches[3] -as [int]
            $octetC = [int]$Matches[4]
            $octetB = [int]$Matches[5]
            $octetA = [int]$Matches[6]

            # '/' is always a prefix (25-32); '-' is a prefix for 25-32 by convention, otherwise the last host ('10-20', '64-127').
            $lastHost = -1
            $isAmbiguous = $false
            if ($null -ne $firstHost -and $null -ne $secondNumber) {
                if ($secondNumber -ge 25 -and $secondNumber -le 32) {
                    $lastHost = $firstHost + (1 -shl (32 - $secondNumber)) - 1
                    # Only a real ambiguity when the range reading would be valid too ('0-31' yes, '64-26' no).
                    $isAmbiguous = ($separator -eq '-') -and ($secondNumber -ge $firstHost)
                }
                elseif ($separator -eq '-') {
                    $lastHost = $secondNumber
                }
            }

            if ($lastHost -ge $firstHost -and $lastHost -le 255 -and $octetA -le 255 -and $octetB -le 255 -and $octetC -le 255) {
                $isClassless = $true
                if ($isAmbiguous) {
                    Write-Verbose ("Zone '{0}': '{1}-{2}' was read as prefix /{2} (hosts {1}-{3}); it could also mean the host range {1}-{2}." -f $zoneName, $firstHost, $secondNumber, $lastHost)
                }
                $classlessHostRange = @($firstHost, $lastHost)
                $classlessNetwork = '{0}.{1}.{2}.{3}-{4}' -f $octetA, $octetB, $octetC, $firstHost, $lastHost

                # CIDR only for a power-of-two block aligned to its size; any other range keeps the range form.
                $rangeSize = $lastHost - $firstHost + 1
                for ($prefixLength = 32; $prefixLength -ge 24; $prefixLength--) {
                    if ((1 -shl (32 - $prefixLength)) -eq $rangeSize -and ($firstHost % $rangeSize) -eq 0) {
                        $classlessNetwork = '{0}.{1}.{2}.{3}/{4}' -f $octetA, $octetB, $octetC, $firstHost, $prefixLength
                        break
                    }
                }
            }
            if (-not $isClassless) {
                Write-Verbose "Zone '$zoneName' looks like an RFC 2317 zone but its range is not valid; treated as an ordinary reverse zone."
            }
        }

        $zoneInfo = New-DnsObject -TypeName 'ZoneInfo' -Property ([ordered]@{
                ZoneName               = $zoneName
                IsReverse              = $isReverse
                ZoneType               = $zoneType
                IsDsIntegrated         = $raw['IsDsIntegrated'] -eq $true
                ReplicationScope       = $replicationScope
                DirectoryPartitionName = $directoryPartitionName
                DynamicUpdate          = $dynamicUpdate
                IsAutoCreated          = $isAutoCreated
                IsReadOnly             = ($zoneType -ne 'Primary') -or $isAutoCreated
                IsExportable           = $isExportable
                AgingEnabled           = $aging['AgingEnabled']
                NoRefreshInterval      = $aging['NoRefreshInterval']
                RefreshInterval        = $aging['RefreshInterval']
                ScavengeServers        = $aging['ScavengeServers']
                IsClassless            = $isClassless
                ClasslessNetwork       = $classlessNetwork
                ClasslessHostRange     = $classlessHostRange
            })

        $zoneLookup[$zoneName] = $zoneInfo
        $zoneInfo
    }
    $zoneInfos = @($zoneInfos)

    $forwardZones = [string[]]@(foreach ($zoneInfo in $zoneInfos) { if (-not $zoneInfo.IsReverse) { $zoneInfo.ZoneName } })
    $reverseZones = [string[]]@(foreach ($zoneInfo in $zoneInfos) { if ($zoneInfo.IsReverse) { $zoneInfo.ZoneName } })
    $classlessZones = @(foreach ($zoneInfo in $zoneInfos) { if ($zoneInfo.IsClassless) { $zoneInfo } })

    $serverScavenging = $null
    try {
        Write-Verbose "Reading scavenging settings of '$serverKey' (Get-DnsServerScavenging)."
        $scavenging = Get-DnsServerScavenging @serverParameters -ErrorAction Stop
        $scavengingValues = @{ ScavengingState = $null; ScavengingInterval = $null; LastScavengeTime = $null }
        foreach ($propertyName in @('ScavengingState', 'ScavengingInterval', 'LastScavengeTime')) {
            $property = $scavenging.PSObject.Properties[$propertyName]
            if ($null -ne $property) {
                $scavengingValues[$propertyName] = $property.Value
            }
        }
        $serverScavenging = New-DnsObject -TypeName 'ServerScavenging' -Property ([ordered]@{
                ScavengingState    = $scavengingValues['ScavengingState']
                ScavengingInterval = $scavengingValues['ScavengingInterval']
                LastScavengeTime   = $scavengingValues['LastScavengeTime']
            })
    }
    catch {
        Write-Warning "Could not read the scavenging settings of '$serverKey': $($_.Exception.Message) ServerScavenging is left empty."
    }

    $zoneTable = New-DnsObject -TypeName 'ZoneTable' -Property ([ordered]@{
            Server           = $serverKey
            RetrievedAt      = Get-Date
            Zones            = $zoneInfos
            ZoneLookup       = $zoneLookup
            ForwardZones     = $forwardZones
            ReverseZones     = $reverseZones
            ClasslessZones   = $classlessZones
            ServerScavenging = $serverScavenging
        })

    $script:ZoneTableCache[$serverKey] = $zoneTable
    $zoneTable
}
