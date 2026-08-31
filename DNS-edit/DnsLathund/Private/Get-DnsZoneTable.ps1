function Get-DnsZoneTable {
    <#
        .SYNOPSIS
            Hämtar och cachar zontabellen för en DNS-server.

        .DESCRIPTION
            Läser zonerna en gång per server och cachar resultatet i
            $script:DnsZoneCache (nyckel: servernamn i gemener). Returnerar ett
            objekt med AllZones, ForwardZones och ReverseZones där de två
            sistnämnda är strängarrayer med zonnamn.

            Get-DnsServerZone saknar -Credential. När -Credential anges körs
            anropet därför via en CIM-session från Get-DnsCimSession; går det
            inte kastas ett tydligt fel.

        .EXAMPLE
            $zones = Get-DnsZoneTable -ComputerName 'dc01'
            $zones.ReverseZones

            Listar reverse-zonerna på dc01.

        .EXAMPLE
            Get-DnsZoneTable -ComputerName 'dc01' -Force

            Läser om zontabellen och förbigår cachen.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential,

        [Parameter()]
        [switch]$Force
    )

    $cacheKey = $ComputerName.ToLowerInvariant()

    if (-not $Force -and $script:DnsZoneCache.ContainsKey($cacheKey)) {
        return $script:DnsZoneCache[$cacheKey]
    }

    Assert-DnsServerModule

    # Utanför try-blocket med flit: hjälparens fel om en saknad CIM-session är
    # redan tydligt och ska inte packas om till "Kunde inte läsa DNS-zoner".
    $serverParameters = Get-DnsServerParameter -ComputerName $ComputerName -Credential $Credential

    try {
        $zones = @(Get-DnsServerZone @serverParameters -ErrorAction Stop)
    }
    catch {
        throw [System.InvalidOperationException]::new(
            "Kunde inte läsa DNS-zoner från '$ComputerName': $($_.Exception.Message)",
            $_.Exception
        )
    }

    $forwardZones = @(
        $zones |
            Where-Object {
                $_.ZoneName -notlike '*.in-addr.arpa' -and
                $_.ZoneName -notlike '*.ip6.arpa' -and
                -not $_.IsReverseLookupZone
            } |
            Select-Object -ExpandProperty ZoneName
    )

    $reverseZones = @(
        $zones |
            Where-Object {
                $_.ZoneName -like '*.in-addr.arpa' -or
                $_.IsReverseLookupZone
            } |
            Select-Object -ExpandProperty ZoneName
    )

    $table = [PSCustomObject]@{
        AllZones     = $zones
        ForwardZones = [string[]]$forwardZones
        ReverseZones = [string[]]$reverseZones
    }

    $script:DnsZoneCache[$cacheKey] = $table

    return $table
}
