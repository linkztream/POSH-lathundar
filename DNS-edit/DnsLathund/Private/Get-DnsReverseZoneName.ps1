function Get-DnsReverseZoneName {
    <#
    .SYNOPSIS
        Returns the reverse lookup zone name for a network in CIDR form.

    .DESCRIPTION
        A reverse zone covers whole labels of the reverse name: one octet per label
        in in-addr.arpa, one hex digit (4 bits) per label in ip6.arpa. So only
        prefixes on a label boundary have a zone of their own (CONTRACTS.md
        section 7.5):

          IPv4  /8, /16, /24         '10.0.16.0/24'      -> '16.0.10.in-addr.arpa'
          IPv6  /4 ... /124 step 4   '2001:db8:0:1::/64' -> '1.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa'

        Any other prefix throws with the nearest allowed prefixes as a hint;
        classless IPv4 zones (RFC 2317, /25 to /32) are not created by DnsLathund.

        Host bits are ignored, so '10.0.16.5/24' gives the same zone as
        '10.0.16.0/24'. Returns @{ ZoneName; Family = 'IPv4'|'IPv6'; Prefix = [int];
        Network }, where Network is the network with the host bits cleared, in
        canonical form ('10.0.16.0/24', '2001:db8:0:1::/64'): the value to pass to
        Add-DnsServerPrimaryZone -NetworkId, whose derived zone name must equal
        ZoneName (checked in the live test).

    .PARAMETER NetworkId
        The network, as address/prefix ('10.0.16.0/24', '2001:db8:0:1::/64').

    .OUTPUTS
        System.Collections.Hashtable

    .EXAMPLE
        (Get-DnsReverseZoneName -NetworkId '10.0.16.0/24').ZoneName

        Returns '16.0.10.in-addr.arpa'.

    .EXAMPLE
        Get-DnsReverseZoneName -NetworkId '10.0.16.0/23'

        Throws: /23 has no zone of its own; use /16 or /24.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NetworkId
    )

    $text = $NetworkId.Trim()
    if ($text -notmatch '^([^/\s]+)/(\d{1,3})$') {
        throw "'$NetworkId' is not a network in CIDR form. Give the network address and the prefix length, for example 10.0.16.0/24 or 2001:db8:0:1::/64."
    }
    $addressText = $Matches[1]
    $prefix = [int]$Matches[2]

    $address = ConvertTo-DnsNormalizedAddress -Address $addressText
    if ($null -eq $address) {
        throw "'$addressText' in '$NetworkId' is not an IPv4 or IPv6 address. Give the network address and the prefix length, for example 10.0.16.0/24 or 2001:db8:0:1::/64."
    }

    if ($address.IndexOf(':') -lt 0) {
        $allowedPrefixes = @(8, 16, 24)
        if ($allowedPrefixes -notcontains $prefix) {
            # Nearest by distance; a tie (for example /12) names both neighbours.
            $distances = @{}
            foreach ($allowed in $allowedPrefixes) {
                $distance = $allowed - $prefix
                if ($distance -lt 0) {
                    $distance = -$distance
                }
                $distances[$allowed] = $distance
            }
            $smallest = 999
            foreach ($allowed in $allowedPrefixes) {
                if ($distances[$allowed] -lt $smallest) {
                    $smallest = $distances[$allowed]
                }
            }
            $nearest = @(foreach ($allowed in $allowedPrefixes) { if ($distances[$allowed] -eq $smallest) { "/$allowed" } })
            $classless = ''
            if ($prefix -gt 24 -and $prefix -le 32) {
                $classless = ' Classless (RFC 2317) reverse zones for networks smaller than /24 are not created by DnsLathund.'
            }
            throw ("An IPv4 reverse zone covers a /8, /16 or /24 network; '{0}' has prefix /{1}. Use {2} instead.{3}" -f $NetworkId, $prefix, ($nearest -join ' or '), $classless)
        }

        $octets = $address.Split('.')
        $octetCount = [int]($prefix / 8)
        $networkOctets = for ($index = 0; $index -lt 4; $index++) {
            if ($index -lt $octetCount) {
                $octets[$index]
            }
            else {
                '0'
            }
        }
        $labels = for ($index = $octetCount - 1; $index -ge 0; $index--) {
            $octets[$index]
        }

        return @{
            ZoneName = ($labels -join '.') + '.in-addr.arpa'
            Family   = 'IPv4'
            Prefix   = $prefix
            Network  = ($networkOctets -join '.') + '/' + $prefix
        }
    }

    if ($prefix -lt 4 -or $prefix -gt 124 -or ($prefix % 4) -ne 0) {
        $lower = $prefix - ($prefix % 4)
        $upper = $lower + 4
        $nearest = @(
            foreach ($candidate in @($lower, $upper)) {
                if ($candidate -lt 4) {
                    $candidate = 4
                }
                if ($candidate -gt 124) {
                    $candidate = 124
                }
                "/$candidate"
            }
        ) | Select-Object -Unique
        throw ("An IPv6 reverse zone needs a prefix that is a multiple of 4 between /4 and /124 (one ip6.arpa label per hex digit); '{0}' has prefix /{1}. Use {2} instead." -f $NetworkId, $prefix, (@($nearest) -join ' or '))
    }

    $addressBytes = ([ipaddress]$address).GetAddressBytes()
    $hexPairs = foreach ($addressByte in $addressBytes) {
        '{0:x2}' -f $addressByte
    }
    $hexDigits = -join $hexPairs
    $nibbleCount = [int]($prefix / 4)

    $labels = for ($index = $nibbleCount - 1; $index -ge 0; $index--) {
        $hexDigits[$index]
    }

    # Clear the host bits and let [ipaddress] write the canonical compressed form.
    $networkHex = $hexDigits.Substring(0, $nibbleCount) + ('0' * (32 - $nibbleCount))
    $groups = for ($group = 0; $group -lt 8; $group++) {
        $networkHex.Substring($group * 4, 4)
    }
    $networkAddress = ConvertTo-DnsNormalizedAddress -Address ($groups -join ':')

    @{
        ZoneName = ($labels -join '.') + '.ip6.arpa'
        Family   = 'IPv6'
        Prefix   = $prefix
        Network  = $networkAddress + '/' + $prefix
    }
}
