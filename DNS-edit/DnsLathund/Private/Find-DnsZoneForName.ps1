function Find-DnsZoneForName {
    <#
    .SYNOPSIS
        Returns the hosted zones that contain a DNS name, longest first.

    .DESCRIPTION
        Strips labels from the left of the name and probes $ZoneTable.ZoneLookup
        for each remaining suffix, so the cost is one hashtable lookup per label
        regardless of how many zones the server hosts. Every hosted zone that is a
        suffix of the name (or equal to it) is returned, the most specific first:
        'test01.lab.contoso.local' returns 'lab.contoso.local' and then
        'contoso.local' when both are hosted.

        With -Reverse and an IPv4 address name ('5.16.0.10.in-addr.arpa'), RFC 2317
        classless zones that cover the address ('0/25.16.0.10.in-addr.arpa' covers
        hosts 0-127, '64-127.16.0.10.in-addr.arpa' hosts 64-127) are returned first,
        because they are more specific than their parent zone. Overlapping classless
        zones come smallest host range first; equal ranges keep zone table order.

        Returns nothing when no hosted zone contains the name. Callers that need an
        array must wrap the call in @(): under strict mode .Count on $null throws.

    .PARAMETER Name
        The name to look up, with or without the trailing dot.

    .PARAMETER ZoneTable
        A DnsLathund.ZoneTable object from Get-DnsZoneTable.

    .PARAMETER Reverse
        Also return classless reverse zones that cover an in-addr.arpa address name.

    .EXAMPLE
        @(Find-DnsZoneForName -Name 'srv01.contoso.local' -ZoneTable $zoneTable)

        Returns @('contoso.local') when contoso.local is hosted on the server.

    .EXAMPLE
        @(Find-DnsZoneForName -Name '5.16.0.10.in-addr.arpa' -ZoneTable $zoneTable -Reverse)

        Returns for example @('0/25.16.0.10.in-addr.arpa', '16.0.10.in-addr.arpa', '10.in-addr.arpa').
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$ZoneTable,

        [Parameter()]
        [switch]$Reverse
    )

    $normalizedName = ConvertTo-DnsNormalizedName -Name $Name
    if (-not $normalizedName) {
        return
    }

    $zoneLookup = $ZoneTable.ZoneLookup

    if ($Reverse -and $normalizedName -match '^(\d{1,3})\.(\d{1,3}\.\d{1,3}\.\d{1,3}\.in-addr\.arpa)$') {
        $hostOctet = [int]$Matches[1]
        $parentName = $Matches[2]

        $coveringZones = @(
            foreach ($classlessZone in @($ZoneTable.ClasslessZones)) {
                if ($null -eq $classlessZone) {
                    continue
                }

                $zoneName = $classlessZone.ZoneName
                $range = $classlessZone.ClasslessHostRange
                if ($zoneName.Substring($zoneName.IndexOf('.') + 1) -ne $parentName) {
                    continue
                }

                if ($hostOctet -ge $range[0] -and $hostOctet -le $range[1]) {
                    $classlessZone
                }
            }
        )

        # Smallest range (last - first) first; equal sizes keep zone table order.
        # Few classless zones ever overlap, so one pass per possible size is cheap
        # and, unlike Sort-Object on 5.1, guaranteed stable.
        if ($coveringZones.Count -gt 0) {
            for ($rangeSize = 0; $rangeSize -le 255; $rangeSize++) {
                foreach ($classlessZone in $coveringZones) {
                    $range = $classlessZone.ClasslessHostRange
                    if (($range[1] - $range[0]) -eq $rangeSize) {
                        $classlessZone.ZoneName
                    }
                }
            }
        }
    }

    $candidate = $normalizedName
    while ($true) {
        if ($zoneLookup.ContainsKey($candidate)) {
            $candidate
        }

        $dot = $candidate.IndexOf('.')
        if ($dot -lt 0) {
            break
        }
        $candidate = $candidate.Substring($dot + 1)
    }
}
