function ConvertTo-DnsNormalizedName {
    <#
    .SYNOPSIS
        Normalises a DNS name for comparison and hashtable lookups.

    .DESCRIPTION
        Returns the name trimmed of surrounding whitespace, without the trailing
        root dot, with \DDD escapes decoded and in lower case. DNS names are
        case-insensitive, and every index and cache in the module is keyed by this
        form.

        Windows DNS writes \DDD escapes in OCTAL, not the decimal of RFC 1035: a
        zone export writes a space as \040 ('iO Sense' becomes 'iO\040Sense'), '('
        as \050 and a backslash as \134. Only a backslash followed by three octal
        digits starting with 0-3 (\000 to \377) is decoded; a backslash followed by
        anything else stays literal. Note that \032 is therefore character 26, not
        a space.

        An escaped dot at the end ("\.") is not treated as the root dot. An empty
        or whitespace-only name returns ''.

    .PARAMETER Name
        The DNS name: an FQDN with or without the trailing dot, a relative name or
        '@'.

    .EXAMPLE
        ConvertTo-DnsNormalizedName -Name 'Print\040Server.Contoso.LOCAL.'

        Returns 'print server.contoso.local'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Name
    )

    if (-not $Name) {
        return ''
    }

    $normalized = $Name.Trim()

    if ($normalized.EndsWith('.') -and -not $normalized.EndsWith('\.')) {
        $normalized = $normalized.Substring(0, $normalized.Length - 1)
    }

    if ($normalized.IndexOf('\') -ge 0) {
        # With a capture group, -split returns the captured digits at the odd indexes.
        # Octal by hand: [Convert]::ToInt32($s, 8) is blocked in Constrained Language Mode.
        $parts = $normalized -split '\\([0-3][0-7]{2})'
        $decoded = for ($index = 0; $index -lt $parts.Count; $index++) {
            $part = $parts[$index]
            if ($index % 2 -eq 0) {
                $part
                continue
            }

            $code = ([int][string]$part[0]) * 64 + ([int][string]$part[1]) * 8 + ([int][string]$part[2])
            [string][char]$code
        }
        $normalized = -join $decoded
    }

    $normalized.ToLowerInvariant()
}
