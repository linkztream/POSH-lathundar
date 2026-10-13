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

        A non-ASCII character is written as one escape per byte of its UTF-8 form
        ('räksmörgås' becomes 'r\303\244ksm\303\266rg\303\245s'), so consecutive
        escapes that form a well-formed UTF-8 sequence (RFC 3629) are decoded
        together into one character, or into a surrogate pair above U+FFFF. Any
        other escape is one character on its own, so a byte that is not part of a
        well-formed sequence (a Latin-1 '\344') becomes that character and nothing
        is lost.

        An escaped dot at the end ("\.") is not treated as the root dot. An empty
        or whitespace-only name returns ''.

    .PARAMETER Name
        The DNS name: an FQDN with or without the trailing dot, a relative name or
        '@'.

    .EXAMPLE
        ConvertTo-DnsNormalizedName -Name 'Print\040Server.Contoso.LOCAL.'

        Returns 'print server.contoso.local'.

    .EXAMPLE
        ConvertTo-DnsNormalizedName -Name 'R\303\244ksm\303\266rg\303\245s.contoso.local.'

        Returns 'räksmörgås.contoso.local'.
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
        # One token is either a well-formed UTF-8 sequence of two to four escaped
        # bytes (RFC 3629 section 4; \2DD is a continuation byte, 0x80-0xBF) or a
        # single escape. The same pattern as in ConvertFrom-DnsZoneFile. Only the
        # outer group captures, so -split returns the tokens at the odd indexes.
        $escapePattern = '(' +
            '\\3(?:0[2-7]|[1-3][0-7])\\2[0-7]{2}' +
            '|(?:\\340\\2[4-7][0-7]|\\3(?:4[1-7]|5[0-4]|5[67])\\2[0-7]{2}|\\355\\2[0-3][0-7])\\2[0-7]{2}' +
            '|(?:\\360\\2[2-7][0-7]|\\36[1-3]\\2[0-7]{2}|\\364\\2[01][0-7])(?:\\2[0-7]{2}){2}' +
            '|\\[0-3][0-7]{2})'
        $parts = $normalized -split $escapePattern
        $decoded = for ($index = 0; $index -lt $parts.Count; $index++) {
            $part = $parts[$index]
            if ($index % 2 -eq 0) {
                $part
                continue
            }

            # Octal and UTF-8 by hand: [Convert]::ToInt32($s, 8) and
            # [System.Text.Encoding] methods are blocked in Constrained Language Mode.
            $code = ([int][string]$part[1]) * 64 + ([int][string]$part[2]) * 8 + ([int][string]$part[3])
            if ($part.Length -gt 4) {
                # The payload bits of the lead byte (5, 4 or 3 for a sequence of 2, 3
                # or 4 bytes), then six bits per continuation byte \2DD: 8 * D + D.
                $code = $code -band (0x7F -shr ($part.Length / 4))
                for ($digitAt = 6; $digitAt -lt $part.Length; $digitAt += 4) {
                    $code = ($code -shl 6) -bor (([int][string]$part[$digitAt]) * 8 + ([int][string]$part[$digitAt + 1]))
                }
            }
            if ($code -gt 0xFFFF) {
                # Beyond U+FFFF a [char] cannot hold it: a UTF-16 surrogate pair.
                $code = $code - 0x10000
                [string][char](0xD800 + ($code -shr 10))
                [string][char](0xDC00 + ($code -band 0x3FF))
            }
            else {
                [string][char]$code
            }
        }
        $normalized = -join $decoded
    }

    $normalized.ToLowerInvariant()
}
