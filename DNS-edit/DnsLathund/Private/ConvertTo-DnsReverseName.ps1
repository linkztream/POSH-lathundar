function ConvertTo-DnsReverseName {
    <#
    .SYNOPSIS
        Returns the reverse lookup name (in-addr.arpa or ip6.arpa) of an address.

    .DESCRIPTION
        Normalises the address with ConvertTo-DnsNormalizedAddress and returns a
        hashtable with three keys:

          Address     - the canonical address text
          Family      - 'IPv4' or 'IPv6'
          ReverseName - for IPv4 the reversed octets plus '.in-addr.arpa'
                        ('10.0.16.5' -> '5.16.0.10.in-addr.arpa'); for IPv6 all 32
                        nibbles, reversed, plus '.ip6.arpa'

        Returns $null when the text is not an address.

    .PARAMETER Address
        The IPv4 or IPv6 address.

    .EXAMPLE
        (ConvertTo-DnsReverseName -Address '10.0.16.5').ReverseName

        Returns '5.16.0.10.in-addr.arpa'.

    .EXAMPLE
        (ConvertTo-DnsReverseName -Address '2001:db8::1').ReverseName

        Returns '1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa'.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Address
    )

    $normalized = ConvertTo-DnsNormalizedAddress -Address $Address
    if ($null -eq $normalized) {
        return $null
    }

    if ($normalized.IndexOf(':') -lt 0) {
        $octets = $normalized.Split('.')
        return @{
            Address     = $normalized
            Family      = 'IPv4'
            ReverseName = '{0}.{1}.{2}.{3}.in-addr.arpa' -f $octets[3], $octets[2], $octets[1], $octets[0]
        }
    }

    $addressBytes = ([ipaddress]$normalized).GetAddressBytes()
    $hexPairs = foreach ($addressByte in $addressBytes) {
        '{0:x2}' -f $addressByte
    }
    $hexDigits = -join $hexPairs
    $nibbles = for ($index = $hexDigits.Length - 1; $index -ge 0; $index--) {
        $hexDigits[$index]
    }

    @{
        Address     = $normalized
        Family      = 'IPv6'
        ReverseName = ($nibbles -join '.') + '.ip6.arpa'
    }
}
