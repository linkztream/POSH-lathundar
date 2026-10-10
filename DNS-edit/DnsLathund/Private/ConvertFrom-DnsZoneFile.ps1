function ConvertFrom-DnsZoneFile {
    <#
    .SYNOPSIS
        Parses a Windows DNS zone export file into compact tab-separated rows.

    .DESCRIPTION
        Reads a file written by Export-DnsServerZone and returns a hashtable with
        one tab-separated string per resource record of the types the module
        works with (A, AAAA, CNAME, PTR, SRV, NS, MX, DHCID). Every other type
        (SOA, TXT, WINS, WINSR, DNSKEY, ...) is only counted in IgnoredTypes.

        Each row has exactly six fields, OWNER, TYPE, DATA, TTL, AGE and ADDR,
        joined with a tab (CONTRACTS.md section 9.2):
        - OWNER: FQDN, lower-case, no trailing dot, \DDD escapes decoded as octal
          (Windows writes \040 for a space); '@' is the current origin and
          continuation lines inherit the previous owner.
        - TYPE: upper-case.
        - DATA: canonical address for A/AAAA; target FQDN (normalised like OWNER)
          for CNAME, PTR, NS, SRV and MX; the base64 text as-is for DHCID.
        - TTL: seconds; the zone default when the line has none.
        - AGE: hours from "[AGE:n]", 0 for static records.
        - ADDR: for PTR the address encoded in the owner name, otherwise empty.

        The result also carries ZoneName, IsReverse, DefaultTtl, RecordCount,
        SkippedLines (record-like lines that could not be parsed; comments,
        blank lines and directives are not counted), IgnoredTypes and Warnings.

        The file is streamed with switch -Regex -File, which works in
        Constrained Language Mode and reads BOM-less exports as UTF-8 on Windows
        PowerShell 5.1. All per-line logic is inline because a function call per
        line costs minutes on a 550 000-record zone. This function has no
        dependency on any other module function.

    .PARAMETER Path
        The zone export file.

    .PARAMETER ZoneName
        The zone the file belongs to. Relative owners and '@' resolve against it
        until a $ORIGIN directive changes the origin.

    .PARAMETER ZoneInfo
        Optional DnsLathund.ZoneInfo (or any object or hashtable with the same
        property names). IsReverse, IsClassless, ClasslessNetwork and
        ClasslessHostRange are used when present; otherwise they are inferred from
        the zone name (CONTRACTS.md section 8.3).

    .EXAMPLE
        $parsed = ConvertFrom-DnsZoneFile -Path .\contoso.local.txt -ZoneName contoso.local

        Parses a forward zone export; $parsed.Rows holds one string per record.

    .EXAMPLE
        ConvertFrom-DnsZoneFile -Path .\rev.txt -ZoneName 0/25.16.0.10.in-addr.arpa -ZoneInfo $zoneTable.ZoneLookup['0/25.16.0.10.in-addr.arpa']

        Parses an RFC 2317 classless reverse zone; PTR rows get their ADDR from
        the host label and the classless network of the zone.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ZoneName,

        [object]$ZoneInfo
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Zone file '$Path' does not exist. Run Update-DnsSnapshot to export the zone again."
    }

    # switch -File expands wildcards in its path, so a literal '[' in a folder name
    # would break it; escaping keeps the path literal.
    $filePath = Convert-Path -LiteralPath $Path
    if ([WildcardPattern]::ContainsWildcardCharacters($filePath)) {
        $filePath = [WildcardPattern]::Escape($filePath)
    }

    $zone = $ZoneName.Trim().TrimEnd('.').ToLowerInvariant()
    $ordinal = [System.StringComparison]::Ordinal

    # --- Zone facts: from -ZoneInfo when given, inferred from the name otherwise ---

    # Copied into a hashtable so that a missing property never trips strict mode,
    # whether the caller passed a ZoneInfo object or a plain hashtable.
    $info = @{}
    if ($null -ne $ZoneInfo) {
        if ($ZoneInfo -is [System.Collections.IDictionary]) {
            foreach ($infoKey in $ZoneInfo.Keys) {
                $info[[string]$infoKey] = $ZoneInfo[$infoKey]
            }
        }
        else {
            foreach ($infoProperty in $ZoneInfo.PSObject.Properties) {
                $info[$infoProperty.Name] = $infoProperty.Value
            }
        }
    }

    if ($null -ne $info['IsReverse']) {
        $isReverse = [bool]$info['IsReverse']
    }
    else {
        $isReverse = $zone -match '(^|\.)(in-addr|ip6)\.arpa$'
    }
    $isIp6Zone = $zone -match '(^|\.)ip6\.arpa$'

    # RFC 2317 (section 8.3): owners directly below a classless zone are the host
    # octet only, so the address comes from the zone's network, not the owner.
    # The labels after the first one are always the reversed upper three octets,
    # whatever form the first label has (0/25, 0-25, range 10-20, /32).
    $isClassless = $false
    $classlessUpper = ''
    $classlessLow = 0
    $classlessHigh = -1
    if ($zone -match '^(\d{1,3})([/-])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.in-addr\.arpa$') {
        $classlessUpper = '{0}.{1}.{2}' -f $Matches[6], $Matches[5], $Matches[4]
        $firstHost = [int]$Matches[1]
        $secondValue = [int]$Matches[3]
        if ($secondValue -ge 25 -and $secondValue -le 32) {
            # Always a prefix after '/', and by convention after '-' too, so 0-31 is
            # /31 and not the range 0..31 (an accepted ambiguity, section 8.3).
            $classlessLow = $firstHost
            $classlessHigh = $firstHost + (1 -shl (32 - $secondValue)) - 1
            if ($Matches[2] -eq '-') {
                Write-Verbose "Zone '$zone': '$firstHost-$secondValue' is read as prefix length /$secondValue, not as the host range $firstHost..$secondValue."
            }
        }
        elseif ($Matches[2] -eq '-') {
            # Range form: the second value is the last host octet.
            $classlessLow = $firstHost
            $classlessHigh = $secondValue
        }
        $isClassless = $classlessHigh -ge $classlessLow -and $classlessHigh -le 255
    }
    if ($null -ne $info['IsClassless']) {
        $isClassless = [bool]$info['IsClassless']
    }
    if ($isClassless) {
        if ($classlessUpper -eq '') {
            # The zone name does not say which network this is; a ZoneInfo network
            # in CIDR ('10.0.16.0/25') or range form ('10.0.16.10-20') can.
            $network = [string]$info['ClasslessNetwork']
            if ($network -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}(/\d{1,2}|-\d{1,3})$') {
                $classlessUpper = $Matches[1]
            }
        }
        $hostRange = @($info['ClasslessHostRange'])
        if ($hostRange.Count -eq 2 -and $null -ne $hostRange[0] -and $null -ne $hostRange[1]) {
            $classlessLow = [int]$hostRange[0]
            $classlessHigh = [int]$hostRange[1]
        }
        if ($classlessUpper -eq '' -or $classlessHigh -lt $classlessLow) {
            # Neither the ZoneInfo nor the zone name tells which addresses this is.
            $isClassless = $false
        }
    }
    $classlessSuffix = ".$zone"

    # --- Constants, hoisted out of the line loop ---

    # [owner] [[AGE:n]] [ttl] [IN] TYPE rdata. The owner sits in column 0 (padded to
    # 24 characters by Windows); continuation lines start with whitespace. 'dot'
    # captures the trailing dot of an absolute owner; 'data' ends before a comment
    # and excludes trailing whitespace.
    $recordPattern = '^(?<o>[^\s;$](?:\S*[^\s.])?)?(?<dot>\.)?[ \t]+(?:\[AGE:(?<age>\d+)\][ \t]+)?(?:(?<ttl>\d+)[ \t]+)?(?:IN[ \t]+)?(?<type>[a-z][a-z0-9-]*)[ \t]+(?<data>[^\s;](?:[^;]*[^\s;])?)'
    $blankOrCommentPattern = '^[ \t]*(?:;|$)'
    $directivePattern = '^\$(?<dir>[a-z]+)[ \t]*(?<arg>[^\s;]*)'

    # Emitted types; the lookup also yields the canonical upper-case spelling.
    $emittedTypes = @{
        A     = 'A'
        AAAA  = 'AAAA'
        CNAME = 'CNAME'
        PTR   = 'PTR'
        SRV   = 'SRV'
        NS    = 'NS'
        MX    = 'MX'
        DHCID = 'DHCID'
    }

    $octet = '(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)'
    $canonicalIpv4 = [regex]"^$octet\.$octet\.$octet\.$octet$"
    $dottedQuadPattern = '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$'
    $srvPattern = '^\d+[ \t]+\d+[ \t]+\d+[ \t]+(\S+)$'
    $mxPattern = '^\d+[ \t]+(\S+)$'
    $ptrIpv4Pattern = "^$octet\.$octet\.$octet\.$octet\.in-addr\.arpa$"
    $ptrClasslessPattern = "^$octet\.$octet([/-])(\d{1,3})\.$octet\.$octet\.$octet\.in-addr\.arpa$"
    # 32 nibble labels; the replacement reverses them into eight colon-separated groups.
    $ptrIpv6Pattern = '^' + ('([0-9a-f])\.' * 32) + 'ip6\.arpa$'
    $ptrIpv6Replacement = (@(
            foreach ($group in 0..7) {
                $first = 32 - (4 * $group)
                '${' + $first + '}${' + ($first - 1) + '}${' + ($first - 2) + '}${' + ($first - 3) + '}'
            }
        ) -join ':')
    # Windows writes \DDD in OCTAL (\040 is a space), not the decimal of RFC 1035
    # (CONTRACTS.md section 7.4). The value is computed as d1*64 + d2*8 + d3 because
    # [Convert]::ToInt32(x, 8) is blocked in Constrained Language Mode.
    $escapeRegex = [regex]'\\([0-3][0-7]{2})'
    # Whole-token numbers only, so that digits inside 'ns1.contoso.local.' never count.
    $numberRegex = [regex]'(?<![^\s(])\d+(?![^\s)])'
    # Numeric (or hex nibble) labels collapse to '#', so warnings group owners by shape.
    $shapePattern = '(?<=^|\.)[0-9a-f]+(?=\.|$)'

    $progressId = 92
    $progressActivity = "Parsing zone file for '$zone'"
    $progressEvery = 10000
    $progressInterval = [timespan]::FromMilliseconds(500)

    # --- Parser state ---
    $origin = $zone
    $originSuffix = ".$zone"
    $owner = $null
    $defaultTtl = 3600
    $defaultTtlText = '3600'
    $ttlFromDirective = $false
    $inParen = $false
    $parenIsSoa = $false
    $soaNumbers = @{}
    $soaNumberCount = 0
    $skippedLines = 0
    $skippedSamples = @{}
    $ignoredTypes = @{}
    $ptrShapeCount = @{}
    $ptrShapeExample = @{}
    $notes = @{}
    $lineNumber = 0
    $nextProgressLine = $progressEvery
    $lastProgressAt = [datetime]::UtcNow
    $progressShown = $false

    # Rows are collected by assigning the switch statement's output; every other
    # statement inside the clauses must stay silent.
    $rowOutput = switch -Regex -File $filePath {
        $recordPattern {
            $lineNumber++

            if ($inParen) {
                # A line inside a multi-line ( ... ) record that happens to look like a
                # record. Same handling as in the default clause.
                $parenText = $_
                $commentAt = $parenText.IndexOf(';')
                if ($commentAt -ge 0) {
                    $parenText = $parenText.Substring(0, $commentAt)
                }
                if ($parenIsSoa) {
                    foreach ($number in $numberRegex.Matches($parenText)) {
                        $soaNumbers[$soaNumberCount] = $number.Value
                        $soaNumberCount++
                    }
                }
                if ($parenText.Contains(')')) {
                    $inParen = $false
                    if ($parenIsSoa -and $soaNumberCount -ge 5 -and -not $ttlFromDirective) {
                        $defaultTtl = [int]$soaNumbers[4]
                        $defaultTtlText = [string]$defaultTtl
                    }
                }
                continue
            }

            if ($lineNumber -ge $nextProgressLine) {
                # Checking the clock only every 10 000 lines keeps the loop cheap.
                $nextProgressLine = $lineNumber + $progressEvery
                $now = [datetime]::UtcNow
                if (($now - $lastProgressAt) -ge $progressInterval) {
                    Write-Progress -Id $progressId -Activity $progressActivity -Status "$lineNumber lines read"
                    $lastProgressAt = $now
                    $progressShown = $true
                }
            }

            $rawOwner = $Matches['o']
            if ($null -ne $rawOwner) {
                if ($null -ne $Matches['dot']) {
                    $owner = $rawOwner.ToLowerInvariant()
                }
                elseif ($rawOwner -eq '@') {
                    $owner = $origin
                }
                else {
                    $owner = $rawOwner.ToLowerInvariant() + $originSuffix
                }
                if ($rawOwner.Contains('\')) {
                    # Rare, so the decoding cost is paid only here. No [ref] or delegate
                    # (CLM): rebuild the string from the match positions.
                    $escapeAt = 0
                    $escapePieces = foreach ($escape in $escapeRegex.Matches($owner)) {
                        $owner.Substring($escapeAt, $escape.Index - $escapeAt)
                        [string][char](64 * [int]$escape.Value.Substring(1, 1) + 8 * [int]$escape.Value.Substring(2, 1) + [int]$escape.Value.Substring(3, 1))
                        $escapeAt = $escape.Index + $escape.Length
                    }
                    $owner = ((-join $escapePieces) + $owner.Substring($escapeAt)).ToLowerInvariant()
                }
            }
            elseif ($null -eq $owner) {
                # A continuation line before the first owner has nothing to inherit.
                $skippedLines++
                if ($skippedLines -le 5) {
                    $skippedSamples[$skippedLines] = $lineNumber
                }
                continue
            }

            $type = $emittedTypes[$Matches['type']]
            if ($null -eq $type) {
                $ignoredType = $Matches['type'].ToUpperInvariant()
                $ignoredTypes[$ignoredType]++
                $ignoredData = $Matches['data']
                if ($ignoredType -eq 'SOA') {
                    # MNAME and RNAME first, then serial, refresh, retry, expire and
                    # minimum; Windows labels the minimum "default TTL".
                    $soaNumbers = @{}
                    $soaNumberCount = 0
                    $soaRest = $ignoredData -replace '^\S+[ \t]+\S+', ''
                    foreach ($number in $numberRegex.Matches($soaRest)) {
                        $soaNumbers[$soaNumberCount] = $number.Value
                        $soaNumberCount++
                    }
                    if ($soaRest.Contains('(') -and -not $soaRest.Contains(')')) {
                        $inParen = $true
                        $parenIsSoa = $true
                    }
                    elseif ($soaNumberCount -ge 5 -and -not $ttlFromDirective) {
                        $defaultTtl = [int]$soaNumbers[4]
                        $defaultTtlText = [string]$defaultTtl
                    }
                }
                elseif ($ignoredData.Contains('(') -and -not $ignoredData.Contains(')')) {
                    # Some other multi-line record (DNSKEY and the like): skip its body.
                    $inParen = $true
                    $parenIsSoa = $false
                }
                continue
            }

            $data = $Matches['data']
            $ttl = $Matches['ttl']
            if ($null -eq $ttl) {
                $ttl = $defaultTtlText
            }
            $age = $Matches['age']
            if ($null -eq $age) {
                $age = '0'
            }

            if ($type -eq 'A') {
                if (-not $canonicalIpv4.IsMatch($data)) {
                    # Windows never writes leading zeros, but a hand-edited file might.
                    # The [ipaddress] cast would read '010' as octal, so normalise the
                    # decimal octets here instead.
                    $quad = $null
                    if ($data -match $dottedQuadPattern) {
                        $quad = '{0}.{1}.{2}.{3}' -f [int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4]
                    }
                    if ($null -eq $quad -or -not $canonicalIpv4.IsMatch($quad)) {
                        $skippedLines++
                        if ($skippedLines -le 5) {
                            $skippedSamples[$skippedLines] = $lineNumber
                        }
                        continue
                    }
                    $data = $quad
                }
                "$owner`tA`t$data`t$ttl`t$age`t"
                continue
            }

            if ($type -eq 'DHCID') {
                "$owner`tDHCID`t$data`t$ttl`t$age`t"
                continue
            }

            if ($type -eq 'AAAA') {
                $address = $null
                try {
                    $address = [ipaddress]$data
                }
                catch {
                    $address = $null
                }
                if ($null -eq $address -or [string]$address.AddressFamily -ne 'InterNetworkV6') {
                    $skippedLines++
                    if ($skippedLines -le 5) {
                        $skippedSamples[$skippedLines] = $lineNumber
                    }
                    continue
                }
                "$owner`tAAAA`t$($address.IPAddressToString)`t$ttl`t$age`t"
                continue
            }

            # CNAME, PTR, NS, SRV and MX carry a target name.
            $target = $data
            if ($type -eq 'SRV' -or $type -eq 'MX') {
                if ($type -eq 'SRV') {
                    $target = $data -replace $srvPattern, '$1'
                }
                else {
                    $target = $data -replace $mxPattern, '$1'
                }
                if ($target.Length -eq $data.Length) {
                    # The replace did not match: priority, weight or port is missing.
                    $skippedLines++
                    if ($skippedLines -le 5) {
                        $skippedSamples[$skippedLines] = $lineNumber
                    }
                    continue
                }
            }

            if ($target.EndsWith('.', $ordinal)) {
                $target = $target.Substring(0, $target.Length - 1).ToLowerInvariant()
            }
            elseif ($target -eq '@') {
                $target = $origin
            }
            else {
                $target = $target.ToLowerInvariant() + $originSuffix
            }
            if ($target.Contains('\')) {
                $escapeAt = 0
                $escapePieces = foreach ($escape in $escapeRegex.Matches($target)) {
                    $target.Substring($escapeAt, $escape.Index - $escapeAt)
                    [string][char](64 * [int]$escape.Value.Substring(1, 1) + 8 * [int]$escape.Value.Substring(2, 1) + [int]$escape.Value.Substring(3, 1))
                    $escapeAt = $escape.Index + $escape.Length
                }
                $target = ((-join $escapePieces) + $target.Substring($escapeAt)).ToLowerInvariant()
            }

            if ($type -ne 'PTR') {
                "$owner`t$type`t$target`t$ttl`t$age`t"
                continue
            }

            # PTR: derive the address from the owner name.
            $ptrAddress = ''
            if ($isClassless -and $owner.EndsWith($classlessSuffix, $ordinal)) {
                $hostLabel = $owner.Substring(0, $owner.Length - $classlessSuffix.Length)
                if ($hostLabel -match '^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$') {
                    $hostNumber = [int]$hostLabel
                    # A host outside the delegated block is unreachable through the
                    # parent's CNAMEs, so it is not reported as that address.
                    if ($hostNumber -ge $classlessLow -and $hostNumber -le $classlessHigh) {
                        $ptrAddress = "$classlessUpper.$hostNumber"
                    }
                }
            }
            elseif ($isIp6Zone) {
                $candidate = $owner -replace $ptrIpv6Pattern, $ptrIpv6Replacement
                if ($candidate.Length -ne $owner.Length) {
                    try {
                        $ptrAddress = ([ipaddress]$candidate).IPAddressToString
                    }
                    catch {
                        $ptrAddress = ''
                    }
                }
            }
            else {
                # A successful replace always shortens the string, which is cheaper
                # to test than comparing the strings.
                $candidate = $owner -replace $ptrIpv4Pattern, '$4.$3.$2.$1'
                if ($candidate.Length -ne $owner.Length) {
                    $ptrAddress = $candidate
                }
                elseif ($owner -match $ptrClasslessPattern) {
                    # A classless sub-name kept inside a normal reverse zone; same
                    # reading of the label as for a classless zone (section 8.3).
                    $hostNumber = [int]$Matches[1]
                    $blockLow = [int]$Matches[2]
                    $blockSecond = [int]$Matches[4]
                    $blockHigh = -1
                    if ($blockSecond -ge 25 -and $blockSecond -le 32) {
                        $blockHigh = $blockLow + (1 -shl (32 - $blockSecond)) - 1
                    }
                    elseif ($Matches[3] -eq '-' -and $blockSecond -ge $blockLow) {
                        $blockHigh = $blockSecond
                    }
                    if ($hostNumber -ge $blockLow -and $hostNumber -le $blockHigh -and $blockHigh -le 255) {
                        $ptrAddress = '{0}.{1}.{2}.{3}' -f $Matches[7], $Matches[6], $Matches[5], $hostNumber
                    }
                }
            }

            if ($ptrAddress -eq '') {
                $shape = $owner -replace $shapePattern, '#'
                if ($null -eq $ptrShapeCount[$shape]) {
                    $ptrShapeCount[$shape] = 1
                    $ptrShapeExample[$shape] = $owner
                }
                else {
                    $ptrShapeCount[$shape]++
                }
            }

            "$owner`tPTR`t$target`t$ttl`t$age`t$ptrAddress"
            continue
        }

        $blankOrCommentPattern {
            $lineNumber++
            continue
        }

        $directivePattern {
            $lineNumber++
            $directive = $Matches['dir'].ToUpperInvariant()
            $argument = $Matches['arg']
            if ($directive -eq 'ORIGIN' -and $argument -ne '') {
                if ($argument.EndsWith('.', $ordinal)) {
                    $origin = $argument.Substring(0, $argument.Length - 1).ToLowerInvariant()
                }
                elseif ($argument -eq '@') {
                    $origin = $zone
                }
                else {
                    $origin = $argument.ToLowerInvariant() + $originSuffix
                }
                if ($origin.Contains('\')) {
                    $escapeAt = 0
                    $escapePieces = foreach ($escape in $escapeRegex.Matches($origin)) {
                        $origin.Substring($escapeAt, $escape.Index - $escapeAt)
                        [string][char](64 * [int]$escape.Value.Substring(1, 1) + 8 * [int]$escape.Value.Substring(2, 1) + [int]$escape.Value.Substring(3, 1))
                        $escapeAt = $escape.Index + $escape.Length
                    }
                    $origin = ((-join $escapePieces) + $origin.Substring($escapeAt)).ToLowerInvariant()
                }
                $originSuffix = ".$origin"
            }
            elseif ($directive -eq 'TTL' -and $argument -match '^\d{1,9}$') {
                $defaultTtl = [int]$argument
                $defaultTtlText = [string]$defaultTtl
                $ttlFromDirective = $true
            }
            else {
                $notes["Directive `$$directive '$argument' on line $lineNumber is not supported and was ignored."] = $lineNumber
            }
            continue
        }

        default {
            $lineNumber++
            if ($inParen) {
                $parenText = $_
                $commentAt = $parenText.IndexOf(';')
                if ($commentAt -ge 0) {
                    $parenText = $parenText.Substring(0, $commentAt)
                }
                if ($parenIsSoa) {
                    foreach ($number in $numberRegex.Matches($parenText)) {
                        $soaNumbers[$soaNumberCount] = $number.Value
                        $soaNumberCount++
                    }
                }
                if ($parenText.Contains(')')) {
                    $inParen = $false
                    if ($parenIsSoa -and $soaNumberCount -ge 5 -and -not $ttlFromDirective) {
                        $defaultTtl = [int]$soaNumbers[4]
                        $defaultTtlText = [string]$defaultTtl
                    }
                }
                continue
            }
            $skippedLines++
            if ($skippedLines -le 5) {
                $skippedSamples[$skippedLines] = $lineNumber
            }
            continue
        }
    }

    if ($progressShown) {
        Write-Progress -Id $progressId -Activity $progressActivity -Completed
    }

    if ($null -eq $rowOutput) {
        $rows = [string[]]@()
    }
    else {
        $rows = [string[]]$rowOutput
    }
    $rowOutput = $null

    # One warning per distinct PTR owner shape, never one per line.
    $warnings = @(
        foreach ($shape in @($ptrShapeCount.Keys | Sort-Object)) {
            "$($ptrShapeCount[$shape]) PTR record(s) in zone '$zone' with owner shape '$shape' do not map to a single address; ADDR is empty. First owner: '$($ptrShapeExample[$shape])'."
        }
        if ($skippedLines -gt 0) {
            $sampleLines = @(foreach ($sampleIndex in 1..5) { if ($skippedSamples.ContainsKey($sampleIndex)) { $skippedSamples[$sampleIndex] } }) -join ', '
            "$skippedLines line(s) in '$Path' could not be parsed and were skipped (first at line(s) $sampleLines)."
        }
        if ($inParen) {
            "The file '$Path' ends inside an unterminated parenthesis."
        }
        foreach ($note in @($notes.Keys | Sort-Object)) {
            $note
        }
    )

    @{
        ZoneName     = $zone
        IsReverse    = $isReverse
        DefaultTtl   = $defaultTtl
        Rows         = $rows
        RecordCount  = $rows.Count
        SkippedLines = $skippedLines
        IgnoredTypes = $ignoredTypes
        Warnings     = [string[]]$warnings
    }
}
