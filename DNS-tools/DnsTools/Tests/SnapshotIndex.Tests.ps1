#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
# Unit tests for New-DnsSnapshotIndex. Only the parser and the index builder are
# dot-sourced; the zone table is a hand-built hashtable (duck typing).

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path $PSScriptRoot '..\Private\ConvertFrom-DnsZoneFile.ps1')
    . (Join-Path $PSScriptRoot '..\Private\New-DnsSnapshotIndex.ps1')

    $script:FixtureRoot = Join-Path $PSScriptRoot 'Fixtures'
    $script:Aao = "$([char]0xE5)$([char]0xE4)$([char]0xF6)"

    # Hosted zones of the fictional server. _msdcs is hosted (so its NS record in
    # the parent is not a delegation); lab is not.
    $script:ZoneTable = @{
        ZoneLookup = @{
            'contoso.local'             = @{ IsReverse = $false }
            '_msdcs.contoso.local'      = @{ IsReverse = $false }
            '16.0.10.in-addr.arpa'      = @{ IsReverse = $true }
            '0/25.16.0.10.in-addr.arpa' = @{ IsReverse = $true }
            '8.b.d.0.1.0.0.2.ip6.arpa'  = @{ IsReverse = $true }
        }
    }

    function script:Get-ParsedFixture {
        param (
            [string]$Name,
            [string]$ZoneName,
            [datetime]$ExportedAt
        )
        $result = ConvertFrom-DnsZoneFile -Path (Join-Path $FixtureRoot $Name) -ZoneName $ZoneName
        $result['ExportedAt'] = $ExportedAt
        $result
    }

    # A parse result built by hand, the way the parser would return it.
    function script:New-ParseResult {
        param (
            [string]$ZoneName,
            [string[]]$Row,
            [bool]$IsReverse = $false
        )
        @{
            ZoneName     = $ZoneName
            IsReverse    = $IsReverse
            DefaultTtl   = 3600
            Rows         = [string[]]$Row
            RecordCount  = $Row.Count
            SkippedLines = 0
            IgnoredTypes = @{}
            Warnings     = [string[]]@()
        }
    }

    $script:ExportedForward = [datetime]'2026-10-09T08:00:00'
    $script:ExportedReverse = [datetime]'2026-10-08T22:30:00'
    $script:ExportedClassless = [datetime]'2026-10-09T09:15:00'
    $script:ExportedIpv6 = [datetime]'2026-10-09T09:20:00'

    $script:Parsed = @(
        Get-ParsedFixture 'export-sample.txt' 'contoso.local' $ExportedForward
        Get-ParsedFixture 'reverse-zone.txt' '16.0.10.in-addr.arpa' $ExportedReverse
        Get-ParsedFixture 'reverse-classless.txt' '0/25.16.0.10.in-addr.arpa' $ExportedClassless
        Get-ParsedFixture 'reverse-ipv6.txt' '8.b.d.0.1.0.0.2.ip6.arpa' $ExportedIpv6
    )
    $script:Index = New-DnsSnapshotIndex -Server 'DC01' -ParseResult $Parsed -ZoneTable $ZoneTable
}

Describe 'New-DnsSnapshotIndex result shape' {
    It 'returns a hashtable with exactly the contract keys' {
        $Index | Should -BeOfType [hashtable]
        @($Index.Keys | Sort-Object) | Should -Be @('Addr', 'Addrs', 'BuiltAt', 'Delegation', 'Dhcid', 'Name', 'Names', 'OldestExportedAt', 'Ptr', 'RefBy', 'Server', 'Zones')
    }

    It 'stores the server lower-case and the build time' {
        $Index.Server | Should -BeExactly 'dc01'
        $Index.BuiltAt | Should -BeOfType [datetime]
        ((Get-Date) - $Index.BuiltAt).TotalMinutes | Should -BeLessThan 5
    }

    It 'stores string arrays as values of Name, Addr, Ptr and RefBy' {
        foreach ($table in 'Name', 'Addr', 'Ptr', 'RefBy') {
            foreach ($key in $Index[$table].Keys) {
                , $Index[$table][$key] | Should -BeOfType [string[]] -Because "$table['$key']"
            }
        }
    }

    It 'returns Names and Addrs as string arrays' {
        , $Index.Names | Should -BeOfType [string[]]
        , $Index.Addrs | Should -BeOfType [string[]]
    }
}

Describe 'New-DnsSnapshotIndex Name' {
    It 'maps an owner to TYPE, DATA, TTL, AGE and ZONE tuples in file order' {
        $Index.Name['contoso.local'] | Should -Be @(
            "NS`tdc01.contoso.local`t3600`t0`tcontoso.local"
            "NS`tdc02.contoso.local`t3600`t0`tcontoso.local"
            "A`t10.0.16.1`t600`t3731340`tcontoso.local"
            "A`t10.0.16.2`t600`t3731333`tcontoso.local"
            "AAAA`tfd00:db8:0:16::1`t600`t3731341`tcontoso.local"
            "MX`tmail01.contoso.local`t3600`t0`tcontoso.local"
        )
    }

    It 'keeps every tuple of a round-robin node under one key in file order' {
        $Index.Name['srv02.contoso.local'] | Should -Be @(
            "A`t10.0.16.21`t3600`t0`tcontoso.local"
            "A`t10.0.16.22`t3600`t0`tcontoso.local"
            "MX`tmail01.contoso.local`t3600`t0`tcontoso.local"
        )
        $Index.Name['domaindnszones.contoso.local'] | Should -Be @(
            "A`t10.0.16.10`t600`t3731333`tcontoso.local"
            "A`t10.0.16.11`t600`t3731340`tcontoso.local"
        )
    }

    It 'includes CNAME, DHCID, SRV and NS owners' {
        $Index.Name['web.contoso.local'] | Should -Be @("CNAME`tsrv01.contoso.local`t3600`t0`tcontoso.local")
        $Index.Name['laptop-0042.contoso.local'][1] | Should -BeExactly "DHCID`tAAEBiWNjeNak5P4I34d3ZzNzbjCShtlF0ae/VtuOdlxXMHw=`t900`t3731363`tcontoso.local"
        $Index.Name['_kerberos._tcp.contoso.local'] | Should -Be @(
            "SRV`tdc01.contoso.local`t600`t3731340`tcontoso.local"
            "SRV`tdc02.contoso.local`t600`t3731339`tcontoso.local"
        )
        $Index.Name['lab.contoso.local'] | Should -Be @("NS`tdc03.lab.contoso.local`t3600`t0`tcontoso.local")
    }

    It 'includes owners of reverse zones except PTR records' {
        $Index.Name['16.0.10.in-addr.arpa'] | Should -Be @(
            "NS`tdc01.contoso.local`t3600`t0`t16.0.10.in-addr.arpa"
            "NS`tdc02.contoso.local`t3600`t0`t16.0.10.in-addr.arpa"
        )
        $Index.Name.ContainsKey('10.16.0.10.in-addr.arpa') | Should -BeFalse
    }

    It 'is case-insensitive like every PowerShell hashtable' {
        $Index.Name['SRV02.Contoso.Local'].Count | Should -Be 3
    }
}

Describe 'New-DnsSnapshotIndex Addr and Addrs' {
    It 'maps an address to the owners of its A records in file order' {
        $Index.Addr['10.0.16.10'] | Should -Be @('dc01.contoso.local', 'domaindnszones.contoso.local')
        $Index.Addr['10.0.16.77'] | Should -Be @('app server.contoso.local')
        $Index.Addr['10.0.8.17'] | Should -Be @("kontor-$Aao.contoso.local")
    }

    It 'maps an IPv6 address to the owners of its AAAA records' {
        $Index.Addr['fd00:db8:0:8::42'] | Should -Be @('laptop-0042.contoso.local')
    }

    It 'lists every address in Addr exactly once, in first-seen order' {
        $Index.Addrs | Should -Be @(
            '10.0.16.1', '10.0.16.2', 'fd00:db8:0:16::1', '10.0.16.99', '10.0.16.77', '10.0.16.10',
            'fd00:db8:0:16::10', '10.0.16.11', '10.0.8.17', '10.0.8.42', 'fd00:db8:0:8::42', '10.0.16.25',
            '10.0.64.17', '10.0.16.20', '10.0.16.21', '10.0.16.22', '10.0.16.40', '10.20.0.11',
            '10.20.0.12', '10.0.16.200'
        )
        @($Index.Addrs | Select-Object -Unique).Count | Should -Be $Index.Addrs.Count
        $Index.Addrs.Count | Should -Be $Index.Addr.Count
    }
}

Describe 'New-DnsSnapshotIndex Ptr' {
    It 'maps an address to ZONE, TARGET, TTL, AGE and OWNER tuples from every reverse zone' {
        $Index.Ptr['10.0.16.10'] | Should -Be @(
            "16.0.10.in-addr.arpa`tdc01.contoso.local`t3600`t0`t10.16.0.10.in-addr.arpa"
            "0/25.16.0.10.in-addr.arpa`tws-10.contoso.local`t1200`t3731340`t10.0/25.16.0.10.in-addr.arpa"
        )
    }

    It 'maps IPv6 addresses and keeps several PTRs of one node in file order' {
        $Index.Ptr['2001:db8:0:16::a'] | Should -Be @(
            "8.b.d.0.1.0.0.2.ip6.arpa`tws-a.contoso.local`t1200`t3731340`ta.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.6.1.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa"
            "8.b.d.0.1.0.0.2.ip6.arpa`tws-a-alias.contoso.local`t1200`t3731340`ta.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.6.1.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa"
        )
    }

    It 'leaves out PTR rows without an address' {
        foreach ($values in $Index.Ptr.Values) {
            foreach ($value in $values) {
                $value | Should -Not -BeLike "*`toutside.contoso.local`t*"
                $value | Should -Not -BeLike "*`tpartial.contoso.local`t*"
            }
        }
        $Index.Ptr.Count | Should -Be 16
    }
}

Describe 'New-DnsSnapshotIndex RefBy' {
    It 'maps a CNAME target to TYPE, OWNER and ZONE tuples' {
        $Index.RefBy['srv01.contoso.local'] | Should -Be @(
            "CNAME`talias01.contoso.local`tcontoso.local"
            "CNAME`tweb.contoso.local`tcontoso.local"
        )
    }

    It 'maps MX, SRV and NS targets' {
        $Index.RefBy['mail01.contoso.local'] | Should -Be @(
            "MX`tcontoso.local`tcontoso.local"
            "MX`tsrv02.contoso.local`tcontoso.local"
        )
        $Index.RefBy['dc02.contoso.local'] | Should -Be @(
            "NS`tcontoso.local`tcontoso.local"
            "SRV`t_ldap._tcp.default-first-site-name._sites.contoso.local`tcontoso.local"
            "SRV`t_kerberos._tcp.contoso.local`tcontoso.local"
            "NS`t16.0.10.in-addr.arpa`t16.0.10.in-addr.arpa"
        )
    }

    It 'does not list A, AAAA, DHCID or PTR data' {
        $Index.RefBy.ContainsKey('10.0.16.10') | Should -BeFalse
        $Index.RefBy.ContainsKey('ws-10.contoso.local') | Should -BeFalse
    }
}

Describe 'New-DnsSnapshotIndex Dhcid and Delegation' {
    It 'marks every owner with a DHCID record' {
        @($Index.Dhcid.Keys | Sort-Object) | Should -Be @("kontor-$Aao.contoso.local", 'laptop-0042.contoso.local', 'printer-floor03-building-a-17.contoso.local')
        $Index.Dhcid['laptop-0042.contoso.local'] | Should -BeTrue
    }

    It 'marks NS owners that are not the apex of a hosted zone as delegations' {
        @($Index.Delegation.Keys) | Should -Be @('lab.contoso.local')
        $Index.Delegation['lab.contoso.local'] | Should -BeTrue
    }

    It 'does not treat zone apexes or hosted child zones as delegations' {
        $Index.Delegation.ContainsKey('contoso.local') | Should -BeFalse
        $Index.Delegation.ContainsKey('_msdcs.contoso.local') | Should -BeFalse
        $Index.Delegation.ContainsKey('16.0.10.in-addr.arpa') | Should -BeFalse
    }

    It 'treats the apex of the zone being indexed as no delegation even when ZoneLookup lacks it' {
        $result = New-ParseResult 'unlisted.example' @("unlisted.example`tNS`tns1.unlisted.example`t3600`t0`t", "child.unlisted.example`tNS`tns1.unlisted.example`t3600`t0`t")
        $index = New-DnsSnapshotIndex -Server 'dc01' -ParseResult $result -ZoneTable @{ ZoneLookup = @{} }
        @($index.Delegation.Keys) | Should -Be @('child.unlisted.example')
    }
}

Describe 'New-DnsSnapshotIndex Names' {
    It 'lists forward owners with A, AAAA or CNAME once, in file order' {
        $Index.Names | Should -Be @(
            'contoso.local', '*.contoso.local', 'alias01.contoso.local', 'app server.contoso.local',
            'dc01.contoso.local', 'dc02.contoso.local', 'domaindnszones.contoso.local',
            "kontor-$Aao.contoso.local", 'laptop-0042.contoso.local', 'mail01.contoso.local',
            'printer-floor03-building-a-17.contoso.local', 'sip.contoso.local', 'srv01.contoso.local',
            'srv02.contoso.local', 'web.contoso.local', 'fs01.contoso.local', 'branch.contoso.local',
            'kiosk1.branch.contoso.local', 'kiosk2.branch.contoso.local', 'zz-static.contoso.local'
        )
    }

    It 'leaves out owners with only NS, SRV, MX or DHCID records and reverse-zone owners' {
        $Index.Names | Should -Not -Contain 'lab.contoso.local'
        $Index.Names | Should -Not -Contain '_kerberos._tcp.contoso.local'
        $Index.Names | Should -Not -Contain '16.0.10.in-addr.arpa'
    }

    It 'lists an owner once even when it appears in several zones and non-adjacent rows' {
        $parent = New-ParseResult 'contoso.local' @(
            "ns1.lab.contoso.local`tA`t10.0.0.53`t3600`t0`t"
            "other.contoso.local`tA`t10.0.0.1`t3600`t0`t"
            "ns1.lab.contoso.local`tAAAA`tfd00::53`t3600`t0`t"
        )
        $child = New-ParseResult 'lab.contoso.local' @(
            "lab.contoso.local`tNS`tns1.lab.contoso.local`t3600`t0`t"
            "ns1.lab.contoso.local`tA`t10.0.0.53`t3600`t0`t"
        )
        $index = New-DnsSnapshotIndex -Server 'dc01' -ParseResult $parent, $child -ZoneTable @{ ZoneLookup = @{ 'contoso.local' = @{ IsReverse = $false }; 'lab.contoso.local' = @{ IsReverse = $false } } }
        $index.Names | Should -Be @('ns1.lab.contoso.local', 'other.contoso.local')
        $index.Name['ns1.lab.contoso.local'].Count | Should -Be 3
        $index.Addr['10.0.0.53'] | Should -Be @('ns1.lab.contoso.local', 'ns1.lab.contoso.local')
    }

    It 'lists an owner whose first record is not A, AAAA or CNAME at its first A' {
        $result = New-ParseResult 'contoso.local' @(
            "first.contoso.local`tA`t10.0.0.1`t3600`t0`t"
            "mixed.contoso.local`tMX`tmail.contoso.local`t3600`t0`t"
            "mixed.contoso.local`tA`t10.0.0.2`t3600`t0`t"
            "mixed.contoso.local`tA`t10.0.0.3`t3600`t0`t"
            "last.contoso.local`tCNAME`tfirst.contoso.local`t3600`t0`t"
        )
        $index = New-DnsSnapshotIndex -Server 'dc01' -ParseResult $result -ZoneTable @{ ZoneLookup = @{} }
        $index.Names | Should -Be @('first.contoso.local', 'mixed.contoso.local', 'last.contoso.local')
    }
}

Describe 'New-DnsSnapshotIndex Zones and OldestExportedAt' {
    It 'stores ExportedAt, DefaultTtl, RecordCount and IsReverse per zone' {
        @($Index.Zones.Keys | Sort-Object) | Should -Be @('0/25.16.0.10.in-addr.arpa', '16.0.10.in-addr.arpa', '8.b.d.0.1.0.0.2.ip6.arpa', 'contoso.local')
        $zone = $Index.Zones['contoso.local']
        @($zone.Keys | Sort-Object) | Should -Be @('DefaultTtl', 'ExportedAt', 'IsReverse', 'RecordCount')
        $zone.ExportedAt | Should -Be $ExportedForward
        $zone.DefaultTtl | Should -Be 3600
        $zone.RecordCount | Should -Be 39
        $zone.IsReverse | Should -BeFalse
        $Index.Zones['0/25.16.0.10.in-addr.arpa'].DefaultTtl | Should -Be 1200
        $Index.Zones['0/25.16.0.10.in-addr.arpa'].IsReverse | Should -BeTrue
    }

    It 'reports the oldest export time' {
        $Index.OldestExportedAt | Should -Be $ExportedReverse
    }

    It 'leaves ExportedAt and OldestExportedAt empty when the caller supplies none' {
        $index = New-DnsSnapshotIndex -Server 'dc01' -ParseResult (New-ParseResult 'contoso.local' @("a.contoso.local`tA`t10.0.0.1`t3600`t0`t")) -ZoneTable @{ ZoneLookup = @{} }
        $index.Zones['contoso.local'].ExportedAt | Should -BeNullOrEmpty
        $index.OldestExportedAt | Should -BeNullOrEmpty
    }

    It 'falls back to the zone table for IsReverse when the parse result lacks it' {
        $result = New-ParseResult '20.10.in-addr.arpa' @("20.10.in-addr.arpa`tNS`tdc01.contoso.local`t3600`t0`t")
        $result.Remove('IsReverse')
        $index = New-DnsSnapshotIndex -Server 'dc01' -ParseResult $result -ZoneTable @{ ZoneLookup = @{ '20.10.in-addr.arpa' = New-Object PSObject -Property @{ IsReverse = $true } } }
        $index.Zones['20.10.in-addr.arpa'].IsReverse | Should -BeTrue
    }
}

Describe 'New-DnsSnapshotIndex input handling' {
    It 'builds an empty index from no parse results' {
        $index = New-DnsSnapshotIndex -Server 'dc01' -ParseResult @() -ZoneTable @{ ZoneLookup = @{} }
        $index.Name.Count | Should -Be 0
        $index.Names.Count | Should -Be 0
        , $index.Names | Should -BeOfType [string[]]
        , $index.Addrs | Should -BeOfType [string[]]
        $index.Zones.Count | Should -Be 0
    }

    It 'accepts the zone table as an object' {
        $zoneTable = New-Object PSObject -Property @{ ZoneLookup = $ZoneTable.ZoneLookup }
        $parsed = Get-ParsedFixture 'export-sample.txt' 'contoso.local' $ExportedForward
        $index = New-DnsSnapshotIndex -Server 'dc01' -ParseResult $parsed -ZoneTable $zoneTable
        @($index.Delegation.Keys) | Should -Be @('lab.contoso.local')
    }

    It 'accepts Rows given as a single string' {
        $result = @{ ZoneName = 'contoso.local'; IsReverse = $false; DefaultTtl = 3600; RecordCount = 1; Rows = "one.contoso.local`tA`t10.0.0.1`t3600`t0`t" }
        $index = New-DnsSnapshotIndex -Server 'dc01' -ParseResult $result -ZoneTable @{ ZoneLookup = @{} }
        $index.Addr['10.0.0.1'] | Should -Be @('one.contoso.local')
    }

    It 'sets Rows of every parse result to $null by default and keeps everything else' {
        # $Parsed was consumed by the shared build in BeforeAll.
        foreach ($result in $Parsed) {
            $result.ContainsKey('Rows') | Should -BeTrue
            $result['Rows'] | Should -BeNullOrEmpty
        }
        $Parsed[0]['RecordCount'] | Should -Be 39
        $Parsed[0]['ZoneName'] | Should -BeExactly 'contoso.local'
        $Parsed[0]['DefaultTtl'] | Should -Be 3600
        $Parsed[0]['ExportedAt'] | Should -Be $ExportedForward
        $Parsed[0]['IgnoredTypes']['TXT'] | Should -Be 2
    }

    It 'keeps Rows unchanged with -KeepRows and builds the same index' {
        $parsed = @(
            Get-ParsedFixture 'export-sample.txt' 'contoso.local' $ExportedForward
            Get-ParsedFixture 'reverse-zone.txt' '16.0.10.in-addr.arpa' $ExportedReverse
            Get-ParsedFixture 'reverse-classless.txt' '0/25.16.0.10.in-addr.arpa' $ExportedClassless
            Get-ParsedFixture 'reverse-ipv6.txt' '8.b.d.0.1.0.0.2.ip6.arpa' $ExportedIpv6
        )
        $before = @($parsed[0]['Rows'])
        # Not named $index: PowerShell variable names ignore case, so it would hide $Index.
        $kept = New-DnsSnapshotIndex -Server 'DC01' -ParseResult $parsed -ZoneTable $ZoneTable -KeepRows
        , $parsed[0]['Rows'] | Should -BeOfType [string[]]
        $parsed[0]['Rows'].Count | Should -Be 39
        $parsed[0]['Rows'] | Should -Be $before
        $parsed[3]['Rows'].Count | Should -Be 5
        $kept.Names | Should -Be $Index.Names
        $kept.Addrs | Should -Be $Index.Addrs
        $kept.Name.Count | Should -Be $Index.Name.Count
        $kept.Ptr.Count | Should -Be $Index.Ptr.Count
    }

    It 'still records zone metadata for a parse result whose rows were already consumed' {
        $parsed = Get-ParsedFixture 'reverse-ipv6.txt' '8.b.d.0.1.0.0.2.ip6.arpa' $ExportedIpv6
        $null = New-DnsSnapshotIndex -Server 'dc01' -ParseResult $parsed -ZoneTable $ZoneTable
        $again = New-DnsSnapshotIndex -Server 'dc01' -ParseResult $parsed -ZoneTable $ZoneTable
        $again.Zones['8.b.d.0.1.0.0.2.ip6.arpa'].RecordCount | Should -Be 5
        $again.Ptr.Count | Should -Be 0
    }
}

Describe 'New-DnsSnapshotIndex hot keys build in linear time' {
    It 'indexes one address shared by 5 000 names in under 2 s' {
        $rows = foreach ($i in 1..5000) { "host$i.contoso.local`tA`t10.9.9.9`t3600`t0`t" }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $index = New-DnsSnapshotIndex -Server 'dc01' -ParseResult (New-ParseResult 'contoso.local' $rows) -ZoneTable @{ ZoneLookup = @{} }
        $watch.Stop()
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 2
        $index.Addr['10.9.9.9'].Count | Should -Be 5000
        $index.Addr['10.9.9.9'][0] | Should -BeExactly 'host1.contoso.local'
        $index.Addr['10.9.9.9'][4999] | Should -BeExactly 'host5000.contoso.local'
        $index.Addrs | Should -Be @('10.9.9.9')
        $index.Names.Count | Should -Be 5000
    }

    It 'indexes one CNAME target with 5 000 aliases in under 2 s' {
        $rows = foreach ($i in 1..5000) { "alias$i.contoso.local`tCNAME`ttarget.contoso.local`t3600`t0`t" }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $index = New-DnsSnapshotIndex -Server 'dc01' -ParseResult (New-ParseResult 'contoso.local' $rows) -ZoneTable @{ ZoneLookup = @{} }
        $watch.Stop()
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 2
        $index.RefBy['target.contoso.local'].Count | Should -Be 5000
        $index.RefBy['target.contoso.local'][4999] | Should -BeExactly "CNAME`talias5000.contoso.local`tcontoso.local"
    }

    It 'indexes one owner with 5 000 records and one address with 5 000 PTRs in under 2 s' {
        $forward = foreach ($i in 1..5000) { "busy.contoso.local`tA`t10.8.$([int][math]::Floor($i / 250)).$($i % 250)`t3600`t0`t" }
        $reverse = foreach ($i in 1..5000) { "7.0.0.10.in-addr.arpa`tPTR`tname$i.contoso.local`t3600`t0`t10.0.0.7" }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $index = New-DnsSnapshotIndex -Server 'dc01' -ParseResult (New-ParseResult 'contoso.local' $forward), (New-ParseResult '10.in-addr.arpa' $reverse $true) -ZoneTable @{ ZoneLookup = @{} }
        $watch.Stop()
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 2
        $index.Name['busy.contoso.local'].Count | Should -Be 5000
        $index.Ptr['10.0.0.7'].Count | Should -Be 5000
        $index.Ptr['10.0.0.7'][0] | Should -BeExactly "10.in-addr.arpa`tname1.contoso.local`t3600`t0`t7.0.0.10.in-addr.arpa"
        $index.Names | Should -Be @('busy.contoso.local')
    }

    It 'grows linearly: four times the hot key takes far less than sixteen times as long' {
        $small = foreach ($i in 1..2500) { "s$i.contoso.local`tA`t10.7.7.7`t3600`t0`t" }
        $large = foreach ($i in 1..10000) { "l$i.contoso.local`tA`t10.7.7.7`t3600`t0`t" }
        $null = New-DnsSnapshotIndex -Server 'dc01' -ParseResult (New-ParseResult 'contoso.local' $small) -ZoneTable @{ ZoneLookup = @{} }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $null = New-DnsSnapshotIndex -Server 'dc01' -ParseResult (New-ParseResult 'contoso.local' $small) -ZoneTable @{ ZoneLookup = @{} }
        $smallSeconds = $watch.Elapsed.TotalSeconds
        $watch.Restart()
        $null = New-DnsSnapshotIndex -Server 'dc01' -ParseResult (New-ParseResult 'contoso.local' $large) -ZoneTable @{ ZoneLookup = @{} }
        $largeSeconds = $watch.Elapsed.TotalSeconds
        $largeSeconds | Should -BeLessThan ([math]::Max($smallSeconds * 10, 0.5))
    }
}
