#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
# Pure unit tests for ConvertFrom-DnsZoneFile: only that file is dot-sourced, so the
# parser is proven to have no dependency on the rest of the module.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path $PSScriptRoot '..\Private\ConvertFrom-DnsZoneFile.ps1')

    $script:FixtureRoot = Join-Path $PSScriptRoot 'Fixtures'
    $script:Generator = Join-Path $PSScriptRoot 'Tools\New-SyntheticZoneFile.ps1'

    # 'åäö' built from code points, so the expectation does not depend on how this
    # test file itself is decoded.
    $script:Aao = "$([char]0xE5)$([char]0xE4)$([char]0xF6)"

    # Writes lines as BOM-less UTF-8 with CRLF, byte for byte like a real export.
    function script:New-ZoneFile {
        param (
            [string]$Name,
            [string[]]$Line
        )
        $path = Join-Path $TestDrive $Name
        $encoding = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllBytes($path, $encoding.GetBytes(($Line -join "`r`n") + "`r`n"))
        $path
    }

    function script:Get-Row {
        param (
            [hashtable]$Result,
            [string]$Owner
        )
        # The comma keeps a one-row result an array for the caller.
        , @($Result.Rows | Where-Object { $_.Split("`t")[0] -ceq $Owner })
    }

    $script:Soa = @(
        '@                       IN  SOA dc01.contoso.local. hostmaster.contoso.local. ('
        "                        `t`t1            ; serial number"
        "                        `t`t900          ; refresh"
        "                        `t`t600          ; retry"
        "                        `t`t86400        ; expire"
        "                        `t`t3600       ) ; default TTL"
    )
}

Describe 'ConvertFrom-DnsZoneFile result shape' {
    BeforeAll {
        $script:Sample = ConvertFrom-DnsZoneFile -Path (Join-Path $FixtureRoot 'export-sample.txt') -ZoneName 'Contoso.Local.'
    }

    It 'returns a hashtable with exactly the contract keys' {
        $Sample | Should -BeOfType [hashtable]
        @($Sample.Keys | Sort-Object) | Should -Be @('DefaultTtl', 'IgnoredTypes', 'IsReverse', 'RecordCount', 'Rows', 'SkippedLines', 'Warnings', 'ZoneName')
    }

    It 'normalises the zone name to lower case without a trailing dot' {
        $Sample.ZoneName | Should -BeExactly 'contoso.local'
        $Sample.IsReverse | Should -BeFalse
    }

    It 'returns Rows and Warnings as string arrays' {
        , $Sample.Rows | Should -BeOfType [string[]]
        , $Sample.Warnings | Should -BeOfType [string[]]
    }

    It 'emits rows with exactly six tab-separated fields' {
        foreach ($row in $Sample.Rows) {
            $row.Split("`t").Count | Should -Be 6 -Because $row
        }
    }

    It 'counts RecordCount as the number of rows' {
        $Sample.RecordCount | Should -Be $Sample.Rows.Count
        $Sample.RecordCount | Should -Be 39
    }

    It 'skips nothing in a well-formed export' {
        $Sample.SkippedLines | Should -Be 0
        $Sample.Warnings.Count | Should -Be 0
    }
}

Describe 'ConvertFrom-DnsZoneFile on the export-sample fixture' {
    BeforeAll {
        $script:Sample = ConvertFrom-DnsZoneFile -Path (Join-Path $FixtureRoot 'export-sample.txt') -ZoneName 'contoso.local'
    }

    It 'emits every row with the exact OWNER, TYPE, DATA, TTL, AGE and ADDR' {
        $expected = @(
            "contoso.local`tNS`tdc01.contoso.local`t3600`t0`t"
            "contoso.local`tNS`tdc02.contoso.local`t3600`t0`t"
            "contoso.local`tA`t10.0.16.1`t600`t3731340`t"
            "contoso.local`tA`t10.0.16.2`t600`t3731333`t"
            "contoso.local`tAAAA`tfd00:db8:0:16::1`t600`t3731341`t"
            "contoso.local`tMX`tmail01.contoso.local`t3600`t0`t"
            "lab.contoso.local`tNS`tdc03.lab.contoso.local`t3600`t0`t"
            "_msdcs.contoso.local`tNS`tdc01.contoso.local`t3600`t0`t"
            "_ldap._tcp.default-first-site-name._sites.contoso.local`tSRV`tdc01.contoso.local`t600`t3731340`t"
            "_ldap._tcp.default-first-site-name._sites.contoso.local`tSRV`tdc02.contoso.local`t600`t3731339`t"
            "_kerberos._tcp.contoso.local`tSRV`tdc01.contoso.local`t600`t3731340`t"
            "_kerberos._tcp.contoso.local`tSRV`tdc02.contoso.local`t600`t3731339`t"
            "*.contoso.local`tA`t10.0.16.99`t3600`t0`t"
            "alias01.contoso.local`tCNAME`tsrv01.contoso.local`t3600`t0`t"
            "app server.contoso.local`tA`t10.0.16.77`t3600`t0`t"
            "dc01.contoso.local`tA`t10.0.16.10`t3600`t0`t"
            "dc01.contoso.local`tAAAA`tfd00:db8:0:16::10`t3600`t0`t"
            "dc02.contoso.local`tA`t10.0.16.11`t3600`t0`t"
            "domaindnszones.contoso.local`tA`t10.0.16.10`t600`t3731333`t"
            "domaindnszones.contoso.local`tA`t10.0.16.11`t600`t3731340`t"
            "kontor-$Aao.contoso.local`tA`t10.0.8.17`t900`t3731322`t"
            "kontor-$Aao.contoso.local`tDHCID`tAAIBqu7IM9Z2I1UVMaqmiXbT3crwOxh27q34yqpCQldN7Pg=`t900`t3731322`t"
            "laptop-0042.contoso.local`tA`t10.0.8.42`t900`t3731363`t"
            "laptop-0042.contoso.local`tDHCID`tAAEBiWNjeNak5P4I34d3ZzNzbjCShtlF0ae/VtuOdlxXMHw=`t900`t3731363`t"
            "laptop-0042.contoso.local`tAAAA`tfd00:db8:0:8::42`t900`t3731363`t"
            "mail01.contoso.local`tA`t10.0.16.25`t3600`t0`t"
            "printer-floor03-building-a-17.contoso.local`tA`t10.0.64.17`t900`t3731350`t"
            "printer-floor03-building-a-17.contoso.local`tDHCID`tAAABadIXvjbmeouVqVpu+YhjoBjJ0GofGWidA2NtgqyA2t8=`t900`t3731350`t"
            "sip.contoso.local`tCNAME`tsip.example.net`t3600`t0`t"
            "srv01.contoso.local`tA`t10.0.16.20`t300`t0`t"
            "srv02.contoso.local`tA`t10.0.16.21`t3600`t0`t"
            "srv02.contoso.local`tA`t10.0.16.22`t3600`t0`t"
            "srv02.contoso.local`tMX`tmail01.contoso.local`t3600`t0`t"
            "web.contoso.local`tCNAME`tsrv01.contoso.local`t3600`t0`t"
            "fs01.contoso.local`tA`t10.0.16.40`t3600`t0`t"
            "branch.contoso.local`tCNAME`tkiosk1.branch.contoso.local`t3600`t0`t"
            "kiosk1.branch.contoso.local`tA`t10.20.0.11`t1200`t3731218`t"
            "kiosk2.branch.contoso.local`tA`t10.20.0.12`t3600`t0`t"
            "zz-static.contoso.local`tA`t10.0.16.200`t7200`t0`t"
        )
        $Sample.Rows.Count | Should -Be $expected.Count
        for ($i = 0; $i -lt $expected.Count; $i++) {
            $Sample.Rows[$i] | Should -BeExactly $expected[$i]
        }
    }

    It 'counts ignored types instead of emitting them' {
        $Sample.IgnoredTypes['SOA'] | Should -Be 1
        $Sample.IgnoredTypes['TXT'] | Should -Be 2
        $Sample.IgnoredTypes['WINS'] | Should -Be 1
        $Sample.IgnoredTypes.Count | Should -Be 3
        @($Sample.Rows | Where-Object { $_ -match "^[^\t]*\t(SOA|TXT|WINS)\t" }).Count | Should -Be 0
    }

    It 'takes the default TTL from the SOA and applies it to rows without a TTL' {
        $Sample.DefaultTtl | Should -Be 3600
        (Get-Row $Sample 'mail01.contoso.local')[0].Split("`t")[3] | Should -Be '3600'
    }

    It 'lets continuation lines inherit the previous owner' {
        $laptop = Get-Row $Sample 'laptop-0042.contoso.local'
        @($laptop | ForEach-Object { $_.Split("`t")[1] }) | Should -Be @('A', 'DHCID', 'AAAA')
        @((Get-Row $Sample 'srv02.contoso.local') | ForEach-Object { $_.Split("`t")[1] }) | Should -Be @('A', 'A', 'MX')
    }

    It 'keeps the owner for continuation lines after an ignored type' {
        $path = New-ZoneFile 'continuation.txt' @(
            "host`t`t`tA`t10.0.0.1"
            "`t`t`tTXT`t`"note; with semicolon`""
            "`t`t`tA`t10.0.0.2"
        )
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $result.Rows | Should -Be @(
            "host.contoso.local`tA`t10.0.0.1`t3600`t0`t"
            "host.contoso.local`tA`t10.0.0.2`t3600`t0`t"
        )
        $result.IgnoredTypes['TXT'] | Should -Be 1
    }

    It 'resolves the apex @ to the zone name' {
        (Get-Row $Sample 'contoso.local').Count | Should -Be 6
    }

    It 'keeps absolute owners as written and appends the origin to relative ones' {
        (Get-Row $Sample 'fs01.contoso.local').Count | Should -Be 1
        (Get-Row $Sample 'fs01.contoso.local.contoso.local').Count | Should -Be 0
        (Get-Row $Sample 'srv01.contoso.local').Count | Should -Be 1
    }

    It 'switches the origin with $ORIGIN, including the apex @ under the new origin' {
        (Get-Row $Sample 'kiosk1.branch.contoso.local').Count | Should -Be 1
        (Get-Row $Sample 'branch.contoso.local')[0] | Should -BeExactly "branch.contoso.local`tCNAME`tkiosk1.branch.contoso.local`t3600`t0`t"
        # Back to the zone origin afterwards.
        (Get-Row $Sample 'zz-static.contoso.local').Count | Should -Be 1
    }

    It 'reads owners longer than the 24-character column' {
        (Get-Row $Sample 'printer-floor03-building-a-17.contoso.local').Count | Should -Be 2
        (Get-Row $Sample '_ldap._tcp.default-first-site-name._sites.contoso.local').Count | Should -Be 2
    }

    It 'maps [AGE:n] to AGE and a missing AGE to 0' {
        (Get-Row $Sample 'kiosk1.branch.contoso.local')[0].Split("`t")[4] | Should -Be '3731218'
        (Get-Row $Sample 'kiosk2.branch.contoso.local')[0].Split("`t")[4] | Should -Be '0'
    }

    It 'reads an explicit TTL with and without AGE' {
        (Get-Row $Sample 'srv01.contoso.local')[0].Split("`t")[3] | Should -Be '300'
        (Get-Row $Sample 'zz-static.contoso.local')[0].Split("`t")[3] | Should -Be '7200'
        (Get-Row $Sample "kontor-$Aao.contoso.local")[0].Split("`t")[3] | Should -Be '900'
    }

    It 'extracts the SRV target and drops priority, weight and port' {
        $srv = Get-Row $Sample '_kerberos._tcp.contoso.local'
        @($srv | ForEach-Object { $_.Split("`t")[2] }) | Should -Be @('dc01.contoso.local', 'dc02.contoso.local')
    }

    It 'extracts the MX exchange and drops the preference' {
        (Get-Row $Sample 'srv02.contoso.local')[2].Split("`t")[2] | Should -BeExactly 'mail01.contoso.local'
    }

    It 'normalises CNAME targets: lower case, no trailing dot, relative targets completed' {
        (Get-Row $Sample 'alias01.contoso.local')[0].Split("`t")[2] | Should -BeExactly 'srv01.contoso.local'
        (Get-Row $Sample 'web.contoso.local')[0].Split("`t")[2] | Should -BeExactly 'srv01.contoso.local'
        (Get-Row $Sample 'sip.contoso.local')[0].Split("`t")[2] | Should -BeExactly 'sip.example.net'
    }

    It 'passes DHCID base64 data through unchanged' {
        (Get-Row $Sample 'laptop-0042.contoso.local')[1].Split("`t")[2] | Should -BeExactly 'AAEBiWNjeNak5P4I34d3ZzNzbjCShtlF0ae/VtuOdlxXMHw='
    }

    It 'decodes the octal \040 escape in owner names to a space' {
        (Get-Row $Sample 'app server.contoso.local').Count | Should -Be 1
    }

    It 'lower-cases mixed-case owners' {
        (Get-Row $Sample 'dc02.contoso.local').Count | Should -Be 1
        (Get-Row $Sample 'domaindnszones.contoso.local').Count | Should -Be 2
    }

    It 'leaves ADDR empty for every non-PTR row' {
        foreach ($row in $Sample.Rows) {
            $row.Split("`t")[5] | Should -BeExactly '' -Because $row
        }
    }
}

Describe 'ConvertFrom-DnsZoneFile encoding' {
    It 'reads a BOM-less UTF-8 export as UTF-8 (non-ASCII owner round-trip)' {
        # Explicit bytes: 'kontor-' + C3 A5 C3 A4 C3 B6 (UTF-8 for the three letters).
        $bytes = [System.Collections.Generic.List[byte]]::new()
        $bytes.AddRange([System.Text.Encoding]::ASCII.GetBytes("@                       NS`tdc01.contoso.local.`r`nkontor-"))
        $bytes.AddRange([byte[]](0xC3, 0xA5, 0xC3, 0xA4, 0xC3, 0xB6))
        $bytes.AddRange([System.Text.Encoding]::ASCII.GetBytes("              A`t10.0.8.17`r`n"))
        $path = Join-Path $TestDrive 'utf8-nobom.txt'
        [System.IO.File]::WriteAllBytes($path, $bytes.ToArray())
        [System.IO.File]::ReadAllBytes($path)[0] | Should -Not -Be 0xEF

        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'

        $owner = $result.Rows[1].Split("`t")[0]
        $owner | Should -BeExactly "kontor-$Aao.contoso.local"
        $owner.Length | Should -Be ('kontor-xxx.contoso.local'.Length)
        $result.SkippedLines | Should -Be 0
    }

    It 'reads the fixtures without a BOM and with CRLF line endings' {
        foreach ($name in 'export-sample.txt', 'reverse-classless.txt', 'reverse-ipv6.txt') {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $FixtureRoot $name))
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse -Because "$name must not start with a BOM"
            for ($i = 0; $i -lt $bytes.Length; $i++) {
                if ($bytes[$i] -eq 10) {
                    $bytes[$i - 1] | Should -Be 13 -Because "$name must use CRLF (byte $i)"
                }
            }
        }
    }
}

Describe 'ConvertFrom-DnsZoneFile default TTL' {
    It 'uses the $TTL directive over the SOA minimum' {
        $path = New-ZoneFile 'ttl-directive.txt' (@('$TTL 7200') + $Soa + @("host`t`t`tA`t10.0.0.1", "other`t300`tA`t10.0.0.2"))
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $result.DefaultTtl | Should -Be 7200
        $result.Rows[0] | Should -BeExactly "host.contoso.local`tA`t10.0.0.1`t7200`t0`t"
        $result.Rows[1].Split("`t")[3] | Should -Be '300'
    }

    It 'uses the SOA minimum when there is no $TTL' {
        $result = ConvertFrom-DnsZoneFile -Path (Join-Path $FixtureRoot 'reverse-classless.txt') -ZoneName '0/25.16.0.10.in-addr.arpa'
        $result.DefaultTtl | Should -Be 1200
        $result.Rows[0] | Should -BeExactly "0/25.16.0.10.in-addr.arpa`tNS`tdc01.contoso.local`t1200`t0`t"
    }

    It 'reads the SOA minimum from a single-line SOA without parentheses' {
        $path = New-ZoneFile 'soa-one-line.txt' @('@ IN SOA ns1.contoso.local. host.contoso.local. 7 900 600 86400 1800', "host`tA`t10.0.0.1")
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $result.DefaultTtl | Should -Be 1800
        $result.Rows[0].Split("`t")[3] | Should -Be '1800'
    }

    It 'falls back to 3600 without $TTL and SOA' {
        $path = New-ZoneFile 'no-soa.txt' @("host`t`t`tA`t10.0.0.1")
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $result.DefaultTtl | Should -Be 3600
        $result.Rows[0].Split("`t")[3] | Should -Be '3600'
        $result.IgnoredTypes.Count | Should -Be 0
    }
}

Describe 'ConvertFrom-DnsZoneFile $ORIGIN handling' {
    It 'resolves relative and absolute $ORIGIN directives and owners' {
        $path = New-ZoneFile 'origin.txt' @(
            "a`tA`t10.0.0.1"
            '$ORIGIN sub'
            "b`tA`t10.0.0.2"
            "@`tA`t10.0.0.3"
            "c.contoso.local.`tA`t10.0.0.4"
            '$ORIGIN Other.Example.'
            "d`tCNAME`te"
            '$ORIGIN @'
            "f`tA`t10.0.0.6"
        )
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        @($result.Rows | ForEach-Object { $_.Split("`t")[0] }) | Should -Be @(
            'a.contoso.local'
            'b.sub.contoso.local'
            'sub.contoso.local'
            'c.contoso.local'
            'd.other.example'
            'f.contoso.local'
        )
        $result.Rows[4].Split("`t")[2] | Should -BeExactly 'e.other.example'
    }
}

Describe 'ConvertFrom-DnsZoneFile grammar edge cases' {
    It 'accepts the class IN, lower-case types and trailing comments on record lines' {
        $path = New-ZoneFile 'class.txt' @(
            "host`t3600`tIN`tA`t10.0.0.1"
            "low`t`t`ta`t10.0.0.2 ; a comment"
            "nsx`tns`tns1.contoso.local.   ; trailing comment"
        )
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $result.Rows | Should -Be @(
            "host.contoso.local`tA`t10.0.0.1`t3600`t0`t"
            "low.contoso.local`tA`t10.0.0.2`t3600`t0`t"
            "nsx.contoso.local`tNS`tns1.contoso.local`t3600`t0`t"
        )
    }

    It 'normalises A records with leading zeros as decimal octets' {
        $path = New-ZoneFile 'leading-zero.txt' @("host`tA`t010.000.016.005")
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $result.Rows[0].Split("`t")[2] | Should -BeExactly '10.0.16.5'
    }

    It 'normalises AAAA data through [ipaddress]' {
        $path = New-ZoneFile 'aaaa.txt' @("host`tAAAA`tFD00:0DB8:0000:0000:0000:0000:0000:0042")
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $result.Rows[0].Split("`t")[2] | Should -BeExactly 'fd00:db8::42'
    }

    It 'decodes octal \DDD escapes in targets and decodes before lower-casing' {
        # Windows writes \DDD in octal: \101 is 'A' (65), \040 is a space (32).
        $path = New-ZoneFile 'escape.txt' @(
            "my\101pp`tA`t10.0.0.1"
            "20`tCNAME`tiO\040Sense.contoso.local."
        )
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $result.Rows[0].Split("`t")[0] | Should -BeExactly 'myapp.contoso.local'
        $result.Rows[1].Split("`t")[2] | Should -BeExactly 'io sense.contoso.local'
    }

    It 'reads \DDD as octal, not decimal: \050 is "(" and \032 is char 26, not a space' {
        $path = New-ZoneFile 'escape-octal.txt' @(
            "paren\050x`tA`t10.0.0.1"
            "ctrl\032x`tA`t10.0.0.2"
            "max\377x`tA`t10.0.0.3"
            "notoctal\400x\9`tA`t10.0.0.4"
        )
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $owners = @($result.Rows | ForEach-Object { $_.Split("`t")[0] })
        $owners[0] | Should -BeExactly 'paren(x.contoso.local'
        $owners[1] | Should -BeExactly "ctrl$([char]26)x.contoso.local"
        $owners[1] | Should -Not -BeExactly 'ctrl x.contoso.local'
        $owners[2] | Should -BeExactly "max$([char]255)x.contoso.local"
        # \400 is out of octal range and \9 is not an escape: both stay as written.
        $owners[3] | Should -BeExactly 'notoctal\400x\9.contoso.local'
    }

    It 'decodes octal escapes in $ORIGIN' {
        $path = New-ZoneFile 'escape-origin.txt' @(
            '$ORIGIN Site\040B.contoso.local.'
            "host`tA`t10.0.0.1"
        )
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $result.Rows[0].Split("`t")[0] | Should -BeExactly 'host.site b.contoso.local'
    }

    It 'skips the body of a multi-line record of an ignored type' {
        $path = New-ZoneFile 'dnskey.txt' @(
            "@`tDNSKEY`t257 3 8 ("
            '                        AwEAAb3x A 10'
            '                        AwEAAc7y ) ; key id'
            "host`tA`t10.0.0.1"
        )
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $result.IgnoredTypes['DNSKEY'] | Should -Be 1
        $result.SkippedLines | Should -Be 0
        $result.Rows | Should -Be @("host.contoso.local`tA`t10.0.0.1`t3600`t0`t")
    }

    It 'warns about unsupported directives without counting them as skipped' {
        $path = New-ZoneFile 'include.txt' @('$INCLUDE other.txt', "host`tA`t10.0.0.1")
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $result.SkippedLines | Should -Be 0
        $result.RecordCount | Should -Be 1
        @($result.Warnings | Where-Object { $_ -like '*INCLUDE*' }).Count | Should -Be 1
    }

    It 'counts malformed lines in SkippedLines and keeps parsing' {
        $path = New-ZoneFile 'malformed.txt' @(
            "`t`t`tA`t10.0.0.9"
            "first`tA`t10.0.0.1"
            'garbage-without-type'
            "badip`tA`t10.0.0.300"
            "badv6`tAAAA`tnot:an:address:zz"
            "badsrv`tSRV`tdc01.contoso.local."
            "badmx`tMX`tmail.contoso.local."
            "last`tA`t10.0.0.2"
        )
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $result.SkippedLines | Should -Be 6
        $result.Rows | Should -Be @(
            "first.contoso.local`tA`t10.0.0.1`t3600`t0`t"
            "last.contoso.local`tA`t10.0.0.2`t3600`t0`t"
        )
        $warning = @($result.Warnings | Where-Object { $_ -like '*could not be parsed*' })
        $warning.Count | Should -Be 1
        $warning[0] | Should -BeLike '*6 line(s)*first at line(s) 1, 3, 4, 5, 6*'
    }

    It 'returns an empty result for an empty file' {
        $path = New-ZoneFile 'empty.txt' @()
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $result.RecordCount | Should -Be 0
        , $result.Rows | Should -BeOfType [string[]]
        $result.Rows.Count | Should -Be 0
    }

    It 'throws when the file does not exist' {
        { ConvertFrom-DnsZoneFile -Path (Join-Path $TestDrive 'missing.txt') -ZoneName 'contoso.local' } | Should -Throw '*does not exist*'
    }

    It 'reads a path that contains wildcard characters literally' {
        $folder = Join-Path $TestDrive 'snap[1]'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $path = Join-Path $folder 'zone.txt'
        Copy-Item -LiteralPath (Join-Path $FixtureRoot 'forward-zone.txt') -Destination $path
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName 'contoso.local'
        $result.RecordCount | Should -Be 18
    }
}

Describe 'ConvertFrom-DnsZoneFile existing fixtures' {
    It 'parses forward-zone.txt including the delegated sub-zone block and IN on a record' {
        $result = ConvertFrom-DnsZoneFile -Path (Join-Path $FixtureRoot 'forward-zone.txt') -ZoneName 'contoso.local'
        $result.RecordCount | Should -Be 18
        $result.SkippedLines | Should -Be 0
        $result.IgnoredTypes['SOA'] | Should -Be 1
        $result.IgnoredTypes['WINS'] | Should -Be 1
        (Get-Row $result 'mail01.contoso.local')[0] | Should -BeExactly "mail01.contoso.local`tA`t10.0.16.55`t3600`t0`t"
        (Get-Row $result 'print01.contoso.local').Count | Should -Be 2
        (Get-Row $result 'test02.lab.contoso.local')[0] | Should -BeExactly "test02.lab.contoso.local`tA`t10.0.16.61`t3600`t3636290`t"
    }
}

Describe 'ConvertFrom-DnsZoneFile PTR address derivation' {
    It 'derives ADDR in a /24 zone, also for absolute owners' {
        $result = ConvertFrom-DnsZoneFile -Path (Join-Path $FixtureRoot 'reverse-zone.txt') -ZoneName '16.0.10.in-addr.arpa'
        $result.IsReverse | Should -BeTrue
        $result.RecordCount | Should -Be 14
        $result.IgnoredTypes['WINSR'] | Should -Be 1
        (Get-Row $result '11.16.0.10.in-addr.arpa')[0] | Should -BeExactly "11.16.0.10.in-addr.arpa`tPTR`tdc02.contoso.local`t3600`t3636304`t10.0.16.11"
        (Get-Row $result '99.16.0.10.in-addr.arpa')[0].Split("`t")[5] | Should -BeExactly '10.0.16.99'
        $result.Warnings.Count | Should -Be 0
    }

    It 'derives ADDR in a /16 zone and warns once per shape that has no single address' {
        $path = New-ZoneFile 'rev16.txt' @(
            "5.16`tPTR`thost5.contoso.local."
            "16`tPTR`tnet16.contoso.local."
            "17`tPTR`tnet17.contoso.local."
            "*.16`tPTR`twild.contoso.local."
        )
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName '0.10.in-addr.arpa'
        @($result.Rows | ForEach-Object { $_.Split("`t")[5] }) | Should -Be @('10.0.16.5', '', '', '')
        $result.Warnings.Count | Should -Be 2
        @($result.Warnings | Where-Object { $_.StartsWith('2 PTR record(s)') -and $_.Contains("shape '#.#.#.in-addr.arpa'") }).Count | Should -Be 1
        @($result.Warnings | Where-Object { $_.StartsWith('1 PTR record(s)') -and $_.Contains("shape '*.#.#.#.in-addr.arpa'") }).Count | Should -Be 1
    }

    It 'derives ADDR in a /8 zone' {
        $path = New-ZoneFile 'rev8.txt' @(
            "5.16.0`tPTR`thost5.contoso.local."
            "16.0`tPTR`tnet.contoso.local."
        )
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName '10.in-addr.arpa'
        $result.Rows[0] | Should -BeExactly "5.16.0.10.in-addr.arpa`tPTR`thost5.contoso.local`t3600`t0`t10.0.16.5"
        $result.Rows[1].Split("`t")[5] | Should -BeExactly ''
        $result.Warnings.Count | Should -Be 1
    }

    It 'derives ADDR in a classless zone from the host label and the zone network' {
        $result = ConvertFrom-DnsZoneFile -Path (Join-Path $FixtureRoot 'reverse-classless.txt') -ZoneName '0/25.16.0.10.in-addr.arpa'
        $result.IsReverse | Should -BeTrue
        $result.Rows | Should -Be @(
            "0/25.16.0.10.in-addr.arpa`tNS`tdc01.contoso.local`t1200`t0`t"
            "5.0/25.16.0.10.in-addr.arpa`tPTR`tsrv05.contoso.local`t1200`t0`t10.0.16.5"
            "10.0/25.16.0.10.in-addr.arpa`tPTR`tws-10.contoso.local`t1200`t3731340`t10.0.16.10"
            "11.0/25.16.0.10.in-addr.arpa`tPTR`tws-11.contoso.local`t1200`t3731341`t10.0.16.11"
            "127.0/25.16.0.10.in-addr.arpa`tPTR`tedge-127.contoso.local`t1200`t0`t10.0.16.127"
            "200.0/25.16.0.10.in-addr.arpa`tPTR`toutside.contoso.local`t1200`t0`t"
        )
        $result.Warnings.Count | Should -Be 1
    }

    It 'uses ClasslessNetwork and ClasslessHostRange from -ZoneInfo (hashtable)' {
        $info = @{ IsReverse = $true; IsClassless = $true; ClasslessNetwork = '10.0.16.0/26'; ClasslessHostRange = @(0, 63) }
        $result = ConvertFrom-DnsZoneFile -Path (Join-Path $FixtureRoot 'reverse-classless.txt') -ZoneName '0/25.16.0.10.in-addr.arpa' -ZoneInfo $info
        @($result.Rows | ForEach-Object { $_.Split("`t")[5] }) | Should -Be @('', '10.0.16.5', '10.0.16.10', '10.0.16.11', '', '')
    }

    It 'uses -ZoneInfo given as an object, and an object without the classless properties' {
        $info = New-Object PSObject -Property @{ ZoneName = '0/25.16.0.10.in-addr.arpa'; IsReverse = $true; IsClassless = $true; ClasslessNetwork = '10.0.16.0/25'; ClasslessHostRange = @(0, 127) }
        $result = ConvertFrom-DnsZoneFile -Path (Join-Path $FixtureRoot 'reverse-classless.txt') -ZoneName '0/25.16.0.10.in-addr.arpa' -ZoneInfo $info
        $result.Rows[4].Split("`t")[5] | Should -BeExactly '10.0.16.127'

        $partial = New-Object PSObject -Property @{ IsReverse = $true }
        $result = ConvertFrom-DnsZoneFile -Path (Join-Path $FixtureRoot 'reverse-classless.txt') -ZoneName '0/25.16.0.10.in-addr.arpa' -ZoneInfo $partial
        $result.Rows[1].Split("`t")[5] | Should -BeExactly '10.0.16.5'
    }

    It 'derives ADDR in a range-form classless zone from the zone name alone' {
        $result = ConvertFrom-DnsZoneFile -Path (Join-Path $FixtureRoot 'reverse-classless-range.txt') -ZoneName '10-20.16.0.10.in-addr.arpa'
        $result.IsReverse | Should -BeTrue
        $result.RecordCount | Should -Be 6
        @($result.Rows | ForEach-Object { $_.Split("`t")[5] }) | Should -Be @('', '', '10.0.16.10', '10.0.16.15', '10.0.16.20', '')
        $result.Rows[3] | Should -BeExactly "15.10-20.16.0.10.in-addr.arpa`tPTR`tws-15.contoso.local`t1200`t3731340`t10.0.16.15"
        $result.Warnings.Count | Should -Be 1
        $result.Warnings[0] | Should -BeLike "2 PTR record(s)*shape '#.10-20.#.#.#.in-addr.arpa'*"
    }

    It 'uses a range-form ClasslessNetwork and ClasslessHostRange from -ZoneInfo' {
        $path = Join-Path $FixtureRoot 'reverse-classless-range.txt'
        $info = @{ IsReverse = $true; IsClassless = $true; ClasslessNetwork = '10.0.16.10-20'; ClasslessHostRange = @(10, 20) }
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName '10-20.16.0.10.in-addr.arpa' -ZoneInfo $info
        @($result.Rows | ForEach-Object { $_.Split("`t")[5] }) | Should -Be @('', '', '10.0.16.10', '10.0.16.15', '10.0.16.20', '')

        # ClasslessHostRange wins over the range in the name.
        $narrow = @{ IsReverse = $true; IsClassless = $true; ClasslessNetwork = '10.0.16.10-15'; ClasslessHostRange = @(10, 15) }
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName '10-20.16.0.10.in-addr.arpa' -ZoneInfo $narrow
        @($result.Rows | ForEach-Object { $_.Split("`t")[5] }) | Should -Be @('', '', '10.0.16.10', '10.0.16.15', '', '')
    }

    It 'takes the upper octets from a range-form ClasslessNetwork when the zone name has no classless label' {
        $info = New-Object PSObject -Property @{ IsReverse = $true; IsClassless = $true; ClasslessNetwork = '10.0.16.10-20'; ClasslessHostRange = @(10, 20) }
        $result = ConvertFrom-DnsZoneFile -Path (Join-Path $FixtureRoot 'reverse-classless-range.txt') -ZoneName 'range.16.0.10.in-addr.arpa' -ZoneInfo $info
        $result.Rows[2] | Should -BeExactly "10.range.16.0.10.in-addr.arpa`tPTR`tfirst-in-range.contoso.local`t3600`t0`t10.0.16.10"
        @($result.Rows | ForEach-Object { $_.Split("`t")[5] }) | Should -Be @('', '', '10.0.16.10', '10.0.16.15', '10.0.16.20', '')
    }

    It 'derives ADDR in a /32 classless zone, written with a slash or a hyphen' {
        $path = New-ZoneFile 'rev32.txt' @(
            "5`tPTR`tonly.contoso.local."
            "6`tPTR`tother.contoso.local."
        )
        foreach ($zoneName in '5/32.16.0.10.in-addr.arpa', '5-32.16.0.10.in-addr.arpa') {
            $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName $zoneName
            @($result.Rows | ForEach-Object { $_.Split("`t")[5] }) | Should -Be @('10.0.16.5', '') -Because $zoneName
        }
    }

    It 'reads the hyphen form as a prefix for 25-32 and as the last host otherwise (<Zone>)' -ForEach @(
        @{ Zone = '0-31.16.0.10.in-addr.arpa'; Expected = @('10.0.16.0', '10.0.16.1', '', '', '', '', '', '') }
        @{ Zone = '0-26.16.0.10.in-addr.arpa'; Expected = @('10.0.16.0', '10.0.16.1', '10.0.16.5', '10.0.16.20', '10.0.16.26', '10.0.16.63', '', '') }
        @{ Zone = '0-24.16.0.10.in-addr.arpa'; Expected = @('10.0.16.0', '10.0.16.1', '10.0.16.5', '10.0.16.20', '', '', '', '') }
        @{ Zone = '64-127.16.0.10.in-addr.arpa'; Expected = @('', '', '', '', '', '', '10.0.16.64', '10.0.16.100') }
        @{ Zone = '0/24.16.0.10.in-addr.arpa'; Expected = @('', '', '', '', '', '', '', '') }
        @{ Zone = '30-20.16.0.10.in-addr.arpa'; Expected = @('', '', '', '', '', '', '', '') }
        @{ Zone = '0-300.16.0.10.in-addr.arpa'; Expected = @('', '', '', '', '', '', '', '') }
    ) {
        $path = New-ZoneFile 'rev-hyphen.txt' @(
            foreach ($hostOctet in 0, 1, 5, 20, 26, 63, 64, 100) { "$hostOctet`tPTR`th$hostOctet.contoso.local." }
        )
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName $Zone
        @($result.Rows | ForEach-Object { $_.Split("`t")[5] }) | Should -Be $Expected
    }

    It 'applies the same reading to classless sub-names inside a normal reverse zone' {
        $path = New-ZoneFile 'rev-sub-range.txt' @(
            "12.10-20`tPTR`tin-range.contoso.local."
            "25.10-20`tPTR`tout-of-range.contoso.local."
            "1.0-31`tPTR`tslash31.contoso.local."
            "5.0-31`tPTR`tnot-a-range.contoso.local."
            "7.7/32`tPTR`thost32.contoso.local."
        )
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName '16.0.10.in-addr.arpa'
        @($result.Rows | ForEach-Object { $_.Split("`t")[5] }) | Should -Be @('10.0.16.12', '', '10.0.16.1', '', '10.0.16.7')
    }

    It 'derives ADDR for a classless sub-name kept inside a normal reverse zone' {
        $path = New-ZoneFile 'rev-sub.txt' @(
            "5.0/26`tPTR`tinside.contoso.local."
            "70.0/26`tPTR`toutside.contoso.local."
            "0/26`tNS`tdc01.contoso.local."
        )
        $result = ConvertFrom-DnsZoneFile -Path $path -ZoneName '16.0.10.in-addr.arpa'
        $result.Rows[0].Split("`t")[5] | Should -BeExactly '10.0.16.5'
        $result.Rows[1].Split("`t")[5] | Should -BeExactly ''
    }

    It 'derives ADDR in an ip6.arpa zone and leaves partial nibble owners empty' {
        $result = ConvertFrom-DnsZoneFile -Path (Join-Path $FixtureRoot 'reverse-ipv6.txt') -ZoneName '8.b.d.0.1.0.0.2.ip6.arpa'
        $result.IsReverse | Should -BeTrue
        $result.RecordCount | Should -Be 5
        $result.Rows[1] | Should -BeExactly "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa`tPTR`tdc01.contoso.local`t3600`t0`t2001:db8::1"
        $result.Rows[2].Split("`t")[5] | Should -BeExactly '2001:db8:0:16::a'
        $result.Rows[3].Split("`t")[5] | Should -BeExactly '2001:db8:0:16::a'
        $result.Rows[3].Split("`t")[2] | Should -BeExactly 'ws-a-alias.contoso.local'
        $result.Rows[4].Split("`t")[5] | Should -BeExactly ''
        $result.Warnings.Count | Should -Be 1
    }

    It 'infers IsReverse from the zone name unless -ZoneInfo says otherwise' {
        $path = New-ZoneFile 'plain.txt' @("host`tA`t10.0.0.1")
        (ConvertFrom-DnsZoneFile -Path $path -ZoneName '10.in-addr.arpa').IsReverse | Should -BeTrue
        (ConvertFrom-DnsZoneFile -Path $path -ZoneName '8.b.d.0.1.0.0.2.ip6.arpa').IsReverse | Should -BeTrue
        (ConvertFrom-DnsZoneFile -Path $path -ZoneName 'arpa-like.contoso.local').IsReverse | Should -BeFalse
        (ConvertFrom-DnsZoneFile -Path $path -ZoneName '10.in-addr.arpa' -ZoneInfo @{ IsReverse = $false }).IsReverse | Should -BeFalse
    }
}

Describe 'ConvertFrom-DnsZoneFile against the synthetic generator' {
    BeforeAll {
        $script:ForwardFile = & $Generator -Path (Join-Path $TestDrive 'synthetic-forward.txt') -RecordCount 4000 -Seed 7 -IncludeDelegatedSubZone -NonAsciiRatio 0.05
        $script:Forward = ConvertFrom-DnsZoneFile -Path $ForwardFile.Path -ZoneName $ForwardFile.ZoneName
        $script:ReverseFile = & $Generator -Path (Join-Path $TestDrive 'synthetic-reverse.txt') -RecordCount 1500 -Seed 7 -Reverse -Network '10.20.0.0/16' -IncludeDelegatedSubZone
        $script:Reverse = ConvertFrom-DnsZoneFile -Path $ReverseFile.Path -ZoneName $ReverseFile.ZoneName
    }

    It 'emits exactly the generated number of rows (line count sanity)' {
        $Forward.RecordCount | Should -Be $ForwardFile.ExpectedRowCount
        $Forward.RecordCount | Should -Be 4000
        $Forward.SkippedLines | Should -Be 0
        $Reverse.RecordCount | Should -Be 1500
        $Reverse.SkippedLines | Should -Be 0
    }

    It 'emits the generated number of rows per type' {
        $counts = @{}
        foreach ($row in $Forward.Rows) {
            $counts[$row.Split("`t")[1]]++
        }
        foreach ($type in $ForwardFile.ExpectedTypeCounts.Keys) {
            [int]$counts[$type] | Should -Be $ForwardFile.ExpectedTypeCounts[$type] -Because "type $type"
        }
    }

    It 'counts the generated ignored types' {
        foreach ($type in $ForwardFile.ExpectedIgnoredTypes.Keys) {
            if ($ForwardFile.ExpectedIgnoredTypes[$type] -gt 0) {
                $Forward.IgnoredTypes[$type] | Should -Be $ForwardFile.ExpectedIgnoredTypes[$type] -Because "type $type"
            }
        }
        $Reverse.IgnoredTypes['WINSR'] | Should -Be 1
    }

    It 'derives an address for every generated PTR' {
        @($Reverse.Rows | Where-Object { $_ -match "`tPTR`t" -and $_.EndsWith("`t") }).Count | Should -Be 0
        $Reverse.Warnings.Count | Should -Be 0
    }

    It 'round-trips the generated special owners' {
        (Get-Row $Forward '*.contoso.local').Count | Should -Be 1
        (Get-Row $Forward 'print room.contoso.local').Count | Should -Be 1
        (Get-Row $Forward "kontor-$Aao.contoso.local").Count | Should -Be 1
        @($Forward.Rows | Where-Object { $_.StartsWith("dator-$Aao-") }).Count | Should -BeGreaterThan 0
    }

    It 'writes deterministic, BOM-less CRLF files' {
        $again = & $Generator -Path (Join-Path $TestDrive 'synthetic-forward-2.txt') -RecordCount 4000 -Seed 7 -IncludeDelegatedSubZone -NonAsciiRatio 0.05
        (Get-FileHash $again.Path).Hash | Should -Be (Get-FileHash $ForwardFile.Path).Hash
        $bytes = [System.IO.File]::ReadAllBytes($ForwardFile.Path)
        $bytes[0] | Should -Be ([byte][char]';')
        $lf = 0
        $crlf = 0
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 10) {
                $lf++
                if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ }
            }
        }
        $crlf | Should -Be $lf
        $lf | Should -Be $ForwardFile.Lines
    }
}
