function Get-DnsReverseNodeName {
    <#
    .SYNOPSIS
        Returns the node name of a reverse lookup name relative to a reverse zone.

    .DESCRIPTION
        The DnsServer cmdlets address records by zone plus relative node name. This
        helper turns a full reverse name into that node name:

          5.16.0.10.in-addr.arpa in 16.0.10.in-addr.arpa -> '5'
          5.16.0.10.in-addr.arpa in 0.10.in-addr.arpa    -> '5.16'
          16.0.10.in-addr.arpa   in 16.0.10.in-addr.arpa -> '@'

        With -ClasslessHostLabel the zone is an RFC 2317 classless zone such as
        '0/25.16.0.10.in-addr.arpa'. The address name 5.16.0.10.in-addr.arpa is not
        a sub-name of that zone, but the record for it lives at node '5' (the host
        octet only). A name already written inside the classless zone
        ('5.0/25.16.0.10.in-addr.arpa') resolves to '5' with or without the switch.

        Names are compared case-insensitively and trailing dots are ignored.
        Returns $null when the name does not belong to the zone. Whether a classless
        zone actually covers the host octet is the caller's job (see
        Find-DnsZoneForName and ZoneInfo.ClasslessHostRange).

    .PARAMETER ReverseName
        The full reverse name, for example '5.16.0.10.in-addr.arpa'.

    .PARAMETER ZoneName
        The reverse zone that holds the record.

    .PARAMETER ClasslessHostLabel
        The zone is an RFC 2317 classless zone; return the host octet of the
        address name.

    .EXAMPLE
        Get-DnsReverseNodeName -ReverseName '5.16.0.10.in-addr.arpa' -ZoneName '0.10.in-addr.arpa'

        Returns '5.16'.

    .EXAMPLE
        Get-DnsReverseNodeName -ReverseName '5.16.0.10.in-addr.arpa' -ZoneName '0/25.16.0.10.in-addr.arpa' -ClasslessHostLabel

        Returns '5'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ReverseName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ZoneName,

        [Parameter()]
        [switch]$ClasslessHostLabel
    )

    $name = ConvertTo-DnsNormalizedName -Name $ReverseName
    $zone = ConvertTo-DnsNormalizedName -Name $ZoneName

    if ($name -eq $zone) {
        return '@'
    }

    $zoneSuffix = '.' + $zone
    if ($name.EndsWith($zoneSuffix)) {
        return $name.Substring(0, $name.Length - $zoneSuffix.Length)
    }

    if ($ClasslessHostLabel) {
        # The classless zone name and the address name share everything after their
        # first label: '0/25.16.0.10.in-addr.arpa' and '5.16.0.10.in-addr.arpa'.
        $zoneDot = $zone.IndexOf('.')
        $nameDot = $name.IndexOf('.')
        if ($zoneDot -gt 0 -and $nameDot -gt 0 -and $name.Substring($nameDot) -eq $zone.Substring($zoneDot)) {
            return $name.Substring(0, $nameDot)
        }
    }

    return $null
}
