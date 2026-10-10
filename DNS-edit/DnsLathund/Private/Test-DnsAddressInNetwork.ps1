function Test-DnsAddressInNetwork {
    <#
    .SYNOPSIS
        Tests whether an address lies in any of a list of CIDR networks.

    .DESCRIPTION
        Used for -MarkDhcpRange (DHCP ranges): returns $true when the address is in
        at least one of the networks, otherwise $false. IPv4 and IPv6 are both
        supported; an address is never in a network of the other family.

        Each network is 'address/prefix' ('10.0.50.0/24', 'fd00::/8'). A bare
        address counts as a single-host network (/32 or /128). Host bits in the
        network address are ignored ('10.0.50.7/24' means 10.0.50.0/24).

        An entry that is not a valid network produces one warning per distinct entry
        per call and is treated as no match, so a typo in a long list does not stop
        the search. An address that is not valid returns $false.

    .PARAMETER Address
        The address to test.

    .PARAMETER Network
        One or more networks in CIDR notation.

    .EXAMPLE
        Test-DnsAddressInNetwork -Address '10.0.50.17' -Network '10.0.50.0/24', '10.0.60.0/24'

        Returns $true.

    .EXAMPLE
        Test-DnsAddressInNetwork -Address 'fd00::5' -Network '10.0.0.0/8'

        Returns $false: the families differ.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Address,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$Network
    )

    $normalizedAddress = ConvertTo-DnsNormalizedAddress -Address $Address
    if ($null -eq $normalizedAddress) {
        Write-Verbose "'$Address' is not an IP address; it is in none of the networks."
        return $false
    }

    $addressBytes = ([ipaddress]$normalizedAddress).GetAddressBytes()
    $isMatch = $false
    $warned = @{}

    foreach ($entry in @($Network)) {
        if ($null -eq $entry) {
            continue
        }

        $networkText = $entry.Trim()
        $prefixText = $null
        $slash = $networkText.IndexOf('/')
        if ($slash -ge 0) {
            $prefixText = $networkText.Substring($slash + 1)
            $networkText = $networkText.Substring(0, $slash)
        }

        $normalizedNetwork = ConvertTo-DnsNormalizedAddress -Address $networkText
        $prefixLength = -1
        if ($null -ne $normalizedNetwork) {
            $maximumPrefix = 32
            if ($normalizedNetwork.IndexOf(':') -ge 0) {
                $maximumPrefix = 128
            }

            if ($null -eq $prefixText) {
                $prefixLength = $maximumPrefix
            }
            elseif ($prefixText -match '^\d{1,3}$' -and [int]$prefixText -le $maximumPrefix) {
                $prefixLength = [int]$prefixText
            }
        }

        if ($prefixLength -lt 0) {
            if (-not $warned.ContainsKey($entry)) {
                $warned[$entry] = $true
                Write-Warning "'$entry' is not a valid network in CIDR notation (for example 10.0.50.0/24 or fd00::/8); it is ignored."
            }
            continue
        }

        if ($isMatch) {
            # Keep validating the remaining entries so every typo is reported.
            continue
        }

        $networkBytes = ([ipaddress]$normalizedNetwork).GetAddressBytes()
        if ($networkBytes.Count -ne $addressBytes.Count) {
            continue
        }

        $fullBytes = [int](($prefixLength - ($prefixLength % 8)) / 8)
        $remainingBits = $prefixLength % 8
        $inNetwork = $true

        for ($index = 0; $index -lt $fullBytes; $index++) {
            if ($addressBytes[$index] -ne $networkBytes[$index]) {
                $inNetwork = $false
                break
            }
        }

        if ($inNetwork -and $remainingBits -gt 0) {
            $mask = (0xFF -shl (8 - $remainingBits)) -band 0xFF
            if (($addressBytes[$fullBytes] -band $mask) -ne ($networkBytes[$fullBytes] -band $mask)) {
                $inNetwork = $false
            }
        }

        if ($inNetwork) {
            $isMatch = $true
        }
    }

    $isMatch
}
