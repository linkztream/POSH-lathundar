function ConvertTo-DnsNormalizedAddress {
    <#
    .SYNOPSIS
        Returns the canonical text form of an IPv4 or IPv6 address, or $null.

    .DESCRIPTION
        Addresses are compared and indexed as text, so every address has to be in
        one canonical form.

        IPv4 must be a dotted quad (four decimal octets 0-255). Leading zeros are
        read as decimal ('010.0.0.1' becomes '10.0.0.1'); the [ipaddress] cast
        would read them as octal ('8.0.0.1') and would also accept shorthand such as
        '10.1' or '12345', which are host names rather than addresses here.

        IPv6 (anything containing a colon) goes through [ipaddress] and comes back
        compressed and in lower case ('2001:0DB8::0001' becomes '2001:db8::1').

        Anything else, including an empty string, returns $null.

    .PARAMETER Address
        The address text to normalise.

    .EXAMPLE
        ConvertTo-DnsNormalizedAddress -Address '010.000.016.005'

        Returns '10.0.16.5'.

    .EXAMPLE
        ConvertTo-DnsNormalizedAddress -Address 'srv01'

        Returns $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Address
    )

    if (-not $Address) {
        return $null
    }

    $text = $Address.Trim()

    if ($text -match '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') {
        $octets = foreach ($groupIndex in 1..4) {
            [int]$Matches[$groupIndex]
        }
        foreach ($octet in $octets) {
            if ($octet -gt 255) {
                return $null
            }
        }
        return ($octets -join '.')
    }

    if ($text.IndexOf(':') -lt 0) {
        return $null
    }

    try {
        $parsed = [ipaddress]$text
    }
    catch {
        return $null
    }

    if ([string]$parsed.AddressFamily -ne 'InterNetworkV6') {
        return $null
    }

    $parsed.IPAddressToString.ToLowerInvariant()
}
