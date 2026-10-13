<#
.SYNOPSIS
    Writes a synthetic Windows DNS zone export file for tests and benchmarks.

.DESCRIPTION
    Developer tool, not module code (Full language is fine here). Produces a file
    in the grammar that Export-DnsServerZone writes on Windows Server, so the
    parser and the snapshot index can be tested and benchmarked without a domain
    controller and without real names:

    - no BOM, CRLF line endings, UTF-8 content
    - header comment block, SOA with parentheses spanning six lines, zone NS records
    - owner column padded to 24 characters (a single space after longer owners)
    - "[AGE:n]" plus an explicit TTL on a configurable share of records (dynamic
      records); static records carry no TTL or, sometimes, an explicit one
    - continuation lines (no owner) for multi-record nodes: DHCID after a
      DHCP-registered A record, AAAA, round-robin A, SRV with several targets
    - $ORIGIN for the zone and for a relative sub-domain block, absolute owners
    - SRV (rdata with spaces), MX, NS, CNAME, DHCID, WINS, TXT, a wildcard owner
      "*", an owner with a "\040" escape (Windows writes \DDD in octal, so
      this is a space) and owners with "åäö"
    - optionally a "Delegated sub-zone" comment block with its NS record

    The output is deterministic for a given -Seed on both Windows PowerShell 5.1
    and PowerShell 7 (System.Random with a seed uses the same legacy algorithm on
    .NET Framework and .NET).

    -RecordCount is the number of rows the parser is expected to emit (A, AAAA,
    CNAME, PTR, SRV, NS, MX, DHCID). Ignored types (SOA, WINS, WINSR, TXT) come on
    top. The returned object lists the expected counts so that tests can compare
    the parser result against them.

.PARAMETER Path
    The file to write. An existing file is overwritten; the folder is created.

.PARAMETER ZoneName
    The zone name. Defaults to contoso.local for forward zones and to the reverse
    zone of -Network for -Reverse.

.PARAMETER RecordCount
    Number of rows the parser should emit for this file.

.PARAMETER Seed
    Seed for the pseudo-random choices. The same seed gives the same file.

.PARAMETER Reverse
    Generate a reverse (in-addr.arpa) zone with PTR records for -Network instead
    of a forward zone.

.PARAMETER Network
    IPv4 network as CIDR with a /8, /16 or /24 prefix. Forward zones take their A
    record addresses from it; reverse zones are named after it.

.PARAMETER TargetZone
    Forward zone used for PTR, NS and SOA targets. Default contoso.local.

.PARAMETER IncludeDelegatedSubZone
    Add a "Delegated sub-zone" comment block with an NS record, the way Windows
    writes a delegation.

.PARAMETER NonAsciiRatio
    Share (0..1) of client host names that contain Swedish letters (åäö).

.PARAMETER AgingRatio
    Share (0..1) of client records written as dynamic, that is with "[AGE:n]" and
    a TTL (and, for forward zones, a DHCID record on a continuation line).

.EXAMPLE
    & .\New-SyntheticZoneFile.ps1 -Path "$env:TEMP\big.txt" -RecordCount 550000 -IncludeDelegatedSubZone

    Writes a 550 000-row forward zone for contoso.local.

.EXAMPLE
    & .\New-SyntheticZoneFile.ps1 -Path "$env:TEMP\rev.txt" -RecordCount 200000 -Reverse -Network 10.0.0.0/8

    Writes a 200 000-row reverse zone 10.in-addr.arpa.
#>
[CmdletBinding()]
[OutputType([psobject])]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [ValidateNotNullOrEmpty()]
    [string]$ZoneName,

    [Parameter(Mandatory)]
    [ValidateRange(1, 16000000)]
    [int]$RecordCount,

    [int]$Seed = 20261009,

    [switch]$Reverse,

    [ValidateNotNullOrEmpty()]
    [string]$Network = '10.0.0.0/8',

    [ValidateNotNullOrEmpty()]
    [string]$TargetZone = 'contoso.local',

    [switch]$IncludeDelegatedSubZone,

    [ValidateRange(0.0, 1.0)]
    [double]$NonAsciiRatio = 0.01,

    [ValidateRange(0.0, 1.0)]
    [double]$AgingRatio = 0.6
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Network -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(8|16|24)$') {
    throw "Network '$Network' must be an IPv4 CIDR with a /8, /16 or /24 prefix."
}
$netOctets = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
$prefixLength = [int]$Matches[5]
$networkLabelCount = $prefixLength / 8
$hostLabelCount = 4 - $networkLabelCount
$hostSpace = ([long]1 -shl (32 - $prefixLength)) - 2
$netBase = ([long]$netOctets[0] -shl 24) + ([long]$netOctets[1] -shl 16) + ([long]$netOctets[2] -shl 8) + [long]$netOctets[3]
$netBase = $netBase - ($netBase % ([long]1 -shl (32 - $prefixLength)))

if (-not $ZoneName) {
    if ($Reverse) {
        $networkLabels = @($netOctets[0..($networkLabelCount - 1)])
        [array]::Reverse($networkLabels)
        $ZoneName = ($networkLabels -join '.') + '.in-addr.arpa'
    }
    else {
        $ZoneName = 'contoso.local'
    }
}
$zone = $ZoneName.ToLowerInvariant().TrimEnd('.')
$targetSuffix = $TargetZone.ToLowerInvariant().TrimEnd('.')

$fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
$folder = [System.IO.Path]::GetDirectoryName($fullPath)
if (-not [System.IO.Directory]::Exists($folder)) {
    [void][System.IO.Directory]::CreateDirectory($folder)
}

$rng = New-Object System.Random $Seed
$pad24 = ' ' * 24
# Real AGE values are hours since 1601-01-01; 3 731 000 is mid-2026.
$ageBase = 3731000

# Expected parser results, maintained while writing.
$typeCounts = @{}
$ignoredCounts = @{}
$rowCount = 0
$lineCount = 0
$addressCursor = 0

# The loop bodies below are inlined (no helper function per record) so that the
# 550 000-row benchmark file is written in seconds on Windows PowerShell 5.1.

# UTF8Encoding($false): Set-Content -Encoding UTF8 on 5.1 would write a BOM, and
# real exports have none.
$encoding = New-Object System.Text.UTF8Encoding $false
$writer = New-Object System.IO.StreamWriter -ArgumentList $fullPath, $false, $encoding, 1048576
$writer.NewLine = "`r`n"

try {
    $serial = 100000 + $rng.Next(0, 800000)

    # --- Header, SOA, zone NS: identical layout for forward and reverse zones ---
    $header = @(
        ';'
        ";  Database file (null) for Default zone scope in zone $zone."
        ";      Zone version:  $serial"
        ';'
        ''
        "@                       IN  SOA dc01.$targetSuffix. hostmaster.$targetSuffix. ("
        "$pad24`t`t$(([string]$serial).PadRight(13)); serial number"
        "$pad24`t`t900          ; refresh"
        "$pad24`t`t600          ; retry"
        "$pad24`t`t86400        ; expire"
        "$pad24`t`t3600       ) ; default TTL"
        ''
        ';'
        ';  Zone NS records'
        ';'
        ''
        "@                       NS`tdc01.$targetSuffix."
        "@                       NS`tdc02.$targetSuffix."
        ''
        ';'
        ';  Zone records'
        ';'
        ''
        "`$ORIGIN $zone."
    )
    foreach ($line in $header) { $writer.WriteLine($line) }
    $lineCount = $lineCount + $header.Count
    $ignoredCounts['SOA'] = 1
    $typeCounts['NS'] = 2
    $rowCount = 2

    if ($Reverse) {
        if ($RecordCount - $rowCount -gt $hostSpace) {
            throw "Network '$Network' has room for $hostSpace PTR records; RecordCount $RecordCount is too large."
        }

        # WINSR is an ignored type; Windows keeps it at the apex of reverse zones.
        $writer.WriteLine("@                       WINSR`tL1 C2 $targetSuffix.")
        $ignoredCounts['WINSR'] = 1
        $lineCount++

        $delegatedLabel = $null
        if ($IncludeDelegatedSubZone -and $hostLabelCount -gt 1 -and $rowCount -lt $RecordCount) {
            # The highest child label; the PTR loop skips it so that no PTR lives
            # below the delegation.
            $delegatedLabel = '254'
            $block = @(
                ''
                ';'
                ";  Delegated sub-zone:  $delegatedLabel.$zone."
                ';'
                "$($delegatedLabel.PadRight(23)) NS`tdc09.$targetSuffix."
                ';  End delegation'
                ''
            )
            foreach ($line in $block) { $writer.WriteLine($line) }
            $lineCount = $lineCount + $block.Count
            $typeCounts['NS'] = $typeCounts['NS'] + 1
            $rowCount++
        }

        $ptrCount = 0
        $hostIndex = 0
        while ($rowCount -lt $RecordCount) {
            $hostIndex++
            if ($hostIndex -gt $hostSpace) {
                throw "Network '$Network' ran out of addresses after $ptrCount PTR records."
            }
            $value = $netBase + $hostIndex
            $o4 = $value -band 255
            # .0 and .255 are skipped, like a DHCP scope would.
            if ($o4 -eq 0 -or $o4 -eq 255) { continue }
            $o3 = ($value -shr 8) -band 255
            $o2 = ($value -shr 16) -band 255
            if ($hostLabelCount -eq 3) {
                if ($null -ne $delegatedLabel -and $o2 -eq 254) { continue }
                $owner = "$o4.$o3.$o2"
            }
            elseif ($hostLabelCount -eq 2) {
                if ($null -ne $delegatedLabel -and $o3 -eq 254) { continue }
                $owner = "$o4.$o3"
            }
            else {
                $owner = "$o4"
            }

            if ($rng.NextDouble() -lt $AgingRatio) {
                $writer.WriteLine("$($owner.PadRight(23)) [AGE:$($ageBase + $rng.Next(0, 400))]`t1200`tPTR`tws-$hostIndex.$targetSuffix.")
            }
            else {
                $writer.WriteLine("$($owner.PadRight(23)) PTR`tsrv$hostIndex.$targetSuffix.")
            }
            $ptrCount++
            $rowCount++
            $lineCount++
        }
        $typeCounts['PTR'] = $ptrCount
    }
    else {
        foreach ($type in 'A', 'AAAA', 'CNAME', 'SRV', 'MX', 'DHCID') { $typeCounts[$type] = 0 }
        $ignoredCounts['TXT'] = 0
        $ignoredCounts['WINS'] = 0

        # Apex: '@' repeated on every line like the real export, round-robin A, AAAA, MX, TXT, WINS.
        $apexLines = @(
            @('A', "[AGE:$($ageBase + 340)]`t600`t"),
            @('A', "[AGE:$($ageBase + 333)]`t600`t"),
            @('AAAA', "[AGE:$($ageBase + 341)]`t600`t"),
            @('MX', ''),
            @('TXT', ''),
            @('WINS', '')
        )
        foreach ($apex in $apexLines) {
            $type = $apex[0]
            if ($type -eq 'TXT') {
                $writer.WriteLine("@                       TXT`t`"v=spf1 mx -all; synthetic`"")
                $ignoredCounts['TXT']++
                $lineCount++
                continue
            }
            if ($type -eq 'WINS') {
                $writer.WriteLine("@                       WINS`tL1 C2 ( 10.0.0.10 10.0.0.11 )")
                $ignoredCounts['WINS']++
                $lineCount++
                continue
            }
            if ($rowCount -ge $RecordCount) { continue }
            if ($type -eq 'A') {
                $addressCursor = ($addressCursor % $hostSpace) + 1
                $v = $netBase + $addressCursor
                $data = "$(($v -shr 24) -band 255).$(($v -shr 16) -band 255).$(($v -shr 8) -band 255).$($v -band 255)"
            }
            elseif ($type -eq 'AAAA') { $data = 'fd00:db8::1' }
            else { $data = "10 mail.$zone." }
            $writer.WriteLine("@                       $($apex[1])$type`t$data")
            $typeCounts[$type]++
            $rowCount++
            $lineCount++
        }

        if ($IncludeDelegatedSubZone -and $rowCount -lt $RecordCount) {
            $block = @(
                ''
                ';'
                ";  Delegated sub-zone:  lab.$zone."
                ';'
                "lab                     NS`tdc09.$targetSuffix."
                ';  End delegation'
                ''
            )
            foreach ($line in $block) { $writer.WriteLine($line) }
            $lineCount = $lineCount + $block.Count
            $typeCounts['NS']++
            $rowCount++
        }

        # AD-style SRV nodes, some with owners longer than the 24-character column.
        foreach ($srv in @(
                @('_ldap._tcp.Default-First-Site-Name._sites', '389'),
                @('_kerberos._tcp.Default-First-Site-Name._sites', '88'),
                @('_ldap._tcp', '389'),
                @('_kerberos._udp', '88'),
                @('_gc._tcp', '3268'))) {
            $srvOwner = $srv[0]
            $column = $srvOwner.PadRight(23) + ' '
            if ($rowCount -lt $RecordCount) {
                $writer.WriteLine("$column[AGE:$($ageBase + 340)]`t600`tSRV`t0 100 $($srv[1])`tdc01.$targetSuffix.")
                $typeCounts['SRV']++
                $rowCount++
                $lineCount++
            }
            if ($rowCount -lt $RecordCount) {
                $writer.WriteLine("$pad24[AGE:$($ageBase + 339)]`t600`tSRV`t0 100 $($srv[1])`tdc02.$targetSuffix.")
                $typeCounts['SRV']++
                $rowCount++
                $lineCount++
            }
        }

        # Special owners: wildcard, an octal \040 escape (a space, as Windows writes it) and åäö.
        foreach ($special in @('*', 'print\040room', 'kontor-åäö')) {
            if ($rowCount -ge $RecordCount) { break }
            $addressCursor = ($addressCursor % $hostSpace) + 1
            $v = $netBase + $addressCursor
            $writer.WriteLine("$($special.PadRight(23)) A`t$(($v -shr 24) -band 255).$(($v -shr 16) -band 255).$(($v -shr 8) -band 255).$($v -band 255)")
            $typeCounts['A']++
            $rowCount++
            $lineCount++
        }

        $hostIndex = 0
        $subDomainAt = [int]($RecordCount / 2)
        $subDomainDone = $false
        $aliasTargets = New-Object 'System.Collections.Generic.List[string]'
        $dhcidBytes = New-Object byte[] 35

        while ($rowCount -lt $RecordCount) {
            $hostIndex++

            if (-not $subDomainDone -and $rowCount -ge $subDomainAt) {
                # A relative sub-domain block under its own $ORIGIN, then back to the zone.
                $subDomainDone = $true
                $writer.WriteLine("`$ORIGIN branch.$zone.")
                $lineCount++
                for ($kiosk = 1; $kiosk -le 20 -and $rowCount -lt $RecordCount; $kiosk++) {
                    $addressCursor = ($addressCursor % $hostSpace) + 1
                    $v = $netBase + $addressCursor
                    $writer.WriteLine("$("kiosk$kiosk".PadRight(23)) [AGE:$($ageBase + $rng.Next(0, 400))]`t1200`tA`t$(($v -shr 24) -band 255).$(($v -shr 16) -band 255).$(($v -shr 8) -band 255).$($v -band 255)")
                    $typeCounts['A']++
                    $rowCount++
                    $lineCount++
                }
                if ($rowCount -lt $RecordCount) {
                    $writer.WriteLine("@                       CNAME`tkiosk1.branch.$zone.")
                    $typeCounts['CNAME']++
                    $rowCount++
                    $lineCount++
                }
                $writer.WriteLine("`$ORIGIN $zone.")
                $lineCount++
                continue
            }

            $roll = $rng.NextDouble()

            if ($roll -lt 0.05 -and $aliasTargets.Count -gt 0) {
                # CNAME to an existing host; one in ten is written with an absolute owner.
                $target = $aliasTargets[$rng.Next(0, $aliasTargets.Count)]
                $owner = "alias-$hostIndex"
                if ($rng.NextDouble() -lt 0.1) { $owner = "$owner.$zone." }
                $writer.WriteLine("$($owner.PadRight(23)) CNAME`t$target.$zone.")
                $typeCounts['CNAME']++
                $rowCount++
                $lineCount++
                continue
            }

            if ($roll -lt 0.055) {
                # Extra SRV node with two targets on a continuation line.
                $srvOwner = "_sip._tcp.site$hostIndex"
                $column = $srvOwner.PadRight(23) + ' '
                $writer.WriteLine("$($column)SRV`t10 50 5060`tsip1.$zone.")
                $typeCounts['SRV']++
                $rowCount++
                $lineCount++
                if ($rowCount -lt $RecordCount) {
                    $writer.WriteLine("$($pad24)SRV`t20 50 5060`tsip2.$zone.")
                    $typeCounts['SRV']++
                    $rowCount++
                    $lineCount++
                }
                continue
            }

            $addressCursor = ($addressCursor % $hostSpace) + 1
            $v = $netBase + $addressCursor
            $address = "$(($v -shr 24) -band 255).$(($v -shr 16) -band 255).$(($v -shr 8) -band 255).$($v -band 255)"

            if ($roll -lt 0.20) {
                # Static server: no AGE, usually no TTL; some get a second A, an MX or a TXT.
                $owner = "srv$hostIndex"
                $ttlPart = ''
                if ($rng.NextDouble() -lt 0.2) { $ttlPart = "300`t" }
                $writer.WriteLine("$($owner.PadRight(23)) $($ttlPart)A`t$address")
                $typeCounts['A']++
                $rowCount++
                $lineCount++
                $aliasTargets.Add($owner)
                $extra = $rng.NextDouble()
                if ($extra -lt 0.03 -and $rowCount -lt $RecordCount) {
                    $addressCursor = ($addressCursor % $hostSpace) + 1
                    $v = $netBase + $addressCursor
                    $writer.WriteLine("$($pad24)A`t$(($v -shr 24) -band 255).$(($v -shr 16) -band 255).$(($v -shr 8) -band 255).$($v -band 255)")
                    $typeCounts['A']++
                    $rowCount++
                    $lineCount++
                }
                elseif ($extra -lt 0.04 -and $rowCount -lt $RecordCount) {
                    $writer.WriteLine("$($pad24)MX`t10 $owner.$zone.")
                    $typeCounts['MX']++
                    $rowCount++
                    $lineCount++
                }
                elseif ($extra -lt 0.05) {
                    $writer.WriteLine("$($pad24)TXT`t`"owner=it-ops; ticket=$hostIndex`"")
                    $ignoredCounts['TXT']++
                    $lineCount++
                }
                continue
            }

            # DHCP-registered client: A, then DHCID when dynamic, sometimes AAAA.
            $nameRoll = $rng.NextDouble()
            if ($nameRoll -lt $NonAsciiRatio) { $owner = "dator-åäö-$hostIndex" }
            elseif ($nameRoll -lt $NonAsciiRatio + 0.01) { $owner = "printer-floor03-building-a-$hostIndex" }
            else { $owner = "ws-$hostIndex" }
            $column = $owner.PadRight(23) + ' '

            $prefixPart = ''
            if ($rng.NextDouble() -lt $AgingRatio) {
                $prefixPart = "[AGE:$($ageBase + $rng.Next(0, 400))]`t1200`t"
            }
            $writer.WriteLine("$($column)$($prefixPart)A`t$address")
            $typeCounts['A']++
            $rowCount++
            $lineCount++
            if ($hostIndex % 7 -eq 0) { $aliasTargets.Add($owner) }

            if ($prefixPart -ne '' -and $rowCount -lt $RecordCount) {
                $rng.NextBytes($dhcidBytes)
                $writer.WriteLine("$pad24$($prefixPart)DHCID`t$([System.Convert]::ToBase64String($dhcidBytes))")
                $typeCounts['DHCID']++
                $rowCount++
                $lineCount++
            }
            if ($rowCount -lt $RecordCount -and $rng.NextDouble() -lt 0.05) {
                $writer.WriteLine("$pad24$($prefixPart)AAAA`tfd00:db8:$('{0:x}' -f ($hostIndex % 65536))::$('{0:x}' -f $rng.Next(1, 65535))")
                $typeCounts['AAAA']++
                $rowCount++
                $lineCount++
            }
        }
    }
}
finally {
    $writer.Dispose()
}

[pscustomobject]@{
    Path                 = $fullPath
    ZoneName             = $zone
    IsReverse            = [bool]$Reverse
    Lines                = $lineCount
    ExpectedRowCount     = $rowCount
    ExpectedTypeCounts   = $typeCounts
    ExpectedIgnoredTypes = $ignoredCounts
}
