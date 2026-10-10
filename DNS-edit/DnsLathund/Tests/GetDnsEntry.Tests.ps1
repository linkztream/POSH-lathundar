#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
<#
    Tests for Get-DnsEntry and its helpers Get-DnsLiveRecord, Resolve-DnsPtrStatus
    and ConvertTo-DnsEntry, plus the default views in DnsLathund.Format.ps1xml
    (CONTRACTS.md sections 12.1, 13.1 and 14).

    The stubs are loaded into the module scope once; Initialize-EntryTest points
    $script:SnapshotRoot, $script:DnsServerExportRoot and the stub export root at a
    fresh folder and builds the stub environment below. -Server $env:COMPUTERNAME
    makes Export-DnsZoneFile copy the export from the local stub folder (see
    Snapshot.Tests.ps1).

    Stub environment and the PtrStatus each A/AAAA record is set up to produce:

      contoso.local (primary)        16.0.10.in-addr.arpa (primary)
        dc01      10.0.16.10   Ok          10 PTR dc01
        srv01     10.0.16.20   Multiple    20 PTR srv01, srv01-old
        dyn01     10.0.16.30   WrongTarget 30 PTR wrong (dyn01 is dynamic, has a DHCID)
        web       10.0.16.40   Shadowed    (PTR only in 10.in-addr.arpa)
        web       10.0.16.41   Missing
        mail      10.0.16.50   Ok          50 PTR mail
        alias01/2 10.0.16.70   Ok          70 PTR alias02 (alias01 Ok through SharedWith)
        (none)    10.0.16.33               33 PTR ghost, 'io sense.pangkaka.com' (orphaned)
        printer80 10.0.16.80   Delegated   80 CNAME 80.64/26.16.0.10.in-addr.arpa (target in a hosted zone)
        extern90  10.0.16.90   Delegated   90 CNAME ptr90.example.net (target not hosted)
        partner07 10.0.18.7    Delegated   NS delegation 18.0 in 10.in-addr.arpa
        nore      192.168.1.10 NoReverseZone
        v6host    2001:db8::10 Ok          PTR in 8.b.d.0.1.0.0.2.ip6.arpa
        v6orphan  2001:db9::1  NoReverseZone
        gw        CNAME dc01 (target exists)      broken CNAME missing (target missing)
        _ldap._tcp SRV dc01, @ NS dc01, @ MX mail, lab NS dc01 (delegation to the hosted child)
        'print<char 26>srv' (written \032), 'Räksmörgås', 'print server' (written \040),
        '*' (wildcard owner), dhcp17 10.0.50.17 (in the DHCP range)
      lab.contoso.local (primary, delegated child)
        test01    10.0.17.5    Ok          5 PTR in the classless 0/25.17.0.10.in-addr.arpa
      10.in-addr.arpa (primary, overlaps 16.0.10): 40.16.0 PTR web, 5.17.0 CNAME
        5.0/25.17.0.10.in-addr.arpa (RFC 2317 parent CNAME), 18.0 NS ns1.partner.example
      fabrikam.com (secondary): web 192.0.2.10      partner.example (forwarder)
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\DnsLathund.psd1" -Force
    $script:StubPath = Join-Path -Path $PSScriptRoot -ChildPath 'Stubs\DnsServerStubs.ps1'
    $script:Server = $env:COMPUTERNAME.ToLowerInvariant()
    $script:ExportableZoneCount = 6
    $script:EntryProperties = @(
        'Name', 'Type', 'Data', 'TTL', 'PtrStatus', 'Zone', 'NodeName', 'Timestamp', 'IsStatic',
        'HasDhcid', 'InDhcpRange', 'ReverseZone', 'PtrTargets', 'PtrZoneFound', 'SharedWith',
        'Aliases', 'ReferencedBy', 'Target', 'TargetExists', 'DistinguishedName', 'Owner',
        'Server', 'Source', 'SnapshotAge'
    )

    InModuleScope DnsLathund -Parameters @{ StubPath = $script:StubPath } {
        param ($StubPath)

        . $StubPath

        # Same wrapper as in Snapshot.Tests.ps1: only needed while the stub
        # Export-DnsServerZone does not declare SupportsShouldProcess.
        $stubExport = Get-Command -Name 'Export-DnsServerZone' -CommandType Function
        if ($stubExport.Parameters.Keys -notcontains 'WhatIf') {
            $script:DnsStubExportCore = $stubExport.ScriptBlock
            function script:Export-DnsServerZone {
                [CmdletBinding(SupportsShouldProcess)]
                param (
                    [Parameter(Mandatory, Position = 0)][string]$Name,
                    [Parameter(Mandatory, Position = 1)][string]$FileName,
                    [string]$ComputerName,
                    [object]$CimSession
                )
                $forward = @{ Name = $Name; FileName = $FileName }
                if ($ComputerName) {
                    $forward['ComputerName'] = $ComputerName
                }
                if ($null -ne $CimSession) {
                    $forward['CimSession'] = $CimSession
                }
                & $script:DnsStubExportCore @forward
            }
        }
    }

    function Initialize-EntryTest {
        <#
        .SYNOPSIS
            Fresh stub store, snapshot root and export root under -Root, empty caches,
            and the stub environment described at the top of this file.
        #>
        param ([string]$Root)

        InModuleScope DnsLathund -Parameters @{ Root = $Root } {
            param ($Root)

            $script:SnapshotRoot = Join-Path -Path $Root -ChildPath 'snapshot'
            $script:DnsServerExportRoot = Join-Path -Path $Root -ChildPath 'server-dns'
            Reset-DnsStubStore -ExportRoot $script:DnsServerExportRoot
            $script:ZoneTableCache = @{}
            $script:CimSessionCache = @{}
            $script:SnapshotIndexCache = @{}

            Add-DnsStubZone -Name 'contoso.local' -AgingEnabled $true
            Add-DnsStubZone -Name 'lab.contoso.local'
            Add-DnsStubZone -Name '16.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '10.in-addr.arpa'
            Add-DnsStubZone -Name '0/25.17.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '8.b.d.0.1.0.0.2.ip6.arpa'
            Add-DnsStubZone -Name 'fabrikam.com' -ZoneType Secondary -IsDsIntegrated $false
            Add-DnsStubZone -Name 'partner.example' -ZoneType Forwarder

            $zone = 'contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '@' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '@' -RRType MX -Data 'mail.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'lab' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'dc01' -RRType A -Data '10.0.16.10'
            Add-DnsStubRecord -ZoneName $zone -Name 'srv01' -RRType A -Data '10.0.16.20' -TimeToLive 1200
            Add-DnsStubRecord -ZoneName $zone -Name 'dyn01' -RRType A -Data '10.0.16.30' -AgeHours 3636304
            Add-DnsStubRecord -ZoneName $zone -Name 'dyn01' -RRType DHCID -Data 'AAIBY2/AuCccgoJbsaxcQc9TUapptP69lOjxfNuVAA2kjEA='
            Add-DnsStubRecord -ZoneName $zone -Name 'web' -RRType A -Data '10.0.16.40'
            Add-DnsStubRecord -ZoneName $zone -Name 'web' -RRType A -Data '10.0.16.41'
            Add-DnsStubRecord -ZoneName $zone -Name 'mail' -RRType A -Data '10.0.16.50'
            Add-DnsStubRecord -ZoneName $zone -Name 'alias01' -RRType A -Data '10.0.16.70'
            Add-DnsStubRecord -ZoneName $zone -Name 'alias02' -RRType A -Data '10.0.16.70'
            Add-DnsStubRecord -ZoneName $zone -Name 'printer80' -RRType A -Data '10.0.16.80'
            Add-DnsStubRecord -ZoneName $zone -Name 'extern90' -RRType A -Data '10.0.16.90'
            Add-DnsStubRecord -ZoneName $zone -Name 'partner07' -RRType A -Data '10.0.18.7'
            Add-DnsStubRecord -ZoneName $zone -Name 'nore' -RRType A -Data '192.168.1.10'
            Add-DnsStubRecord -ZoneName $zone -Name 'v6host' -RRType AAAA -Data '2001:db8::10'
            Add-DnsStubRecord -ZoneName $zone -Name 'v6orphan' -RRType AAAA -Data '2001:db9::1'
            Add-DnsStubRecord -ZoneName $zone -Name 'gw' -RRType CNAME -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'broken' -RRType CNAME -Data 'missing.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '_ldap._tcp' -RRType SRV -Data 'dc01.contoso.local'
            # Windows exports this owner as print\032srv (octal \032 = character 26).
            Add-DnsStubRecord -ZoneName $zone -Name ('print' + [char]26 + 'srv') -RRType A -Data '10.0.16.60'
            Add-DnsStubRecord -ZoneName $zone -Name 'Räksmörgås' -RRType A -Data '10.0.16.61'
            Add-DnsStubRecord -ZoneName $zone -Name 'print server' -RRType A -Data '10.0.16.62'
            Add-DnsStubRecord -ZoneName $zone -Name '*' -RRType A -Data '10.0.16.99'
            Add-DnsStubRecord -ZoneName $zone -Name 'dhcp17' -RRType A -Data '10.0.50.17' -AgeHours 3636304

            Add-DnsStubRecord -ZoneName 'lab.contoso.local' -Name '@' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName 'lab.contoso.local' -Name 'test01' -RRType A -Data '10.0.17.5'

            $zone = '16.0.10.in-addr.arpa'
            Add-DnsStubRecord -ZoneName $zone -Name '@' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '10' -RRType PTR -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '20' -RRType PTR -Data 'srv01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '20' -RRType PTR -Data 'srv01-old.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '30' -RRType PTR -Data 'wrong.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '50' -RRType PTR -Data 'mail.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '70' -RRType PTR -Data 'alias02.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '80' -RRType CNAME -Data '80.64/26.16.0.10.in-addr.arpa'
            Add-DnsStubRecord -ZoneName $zone -Name '90' -RRType CNAME -Data 'ptr90.example.net'
            # Orphaned PTR records: no A record has 10.0.16.33.
            Add-DnsStubRecord -ZoneName $zone -Name '33' -RRType PTR -Data 'ghost.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '33' -RRType PTR -Data 'io sense.pangkaka.com'

            $zone = '10.in-addr.arpa'
            Add-DnsStubRecord -ZoneName $zone -Name '@' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '40.16.0' -RRType PTR -Data 'web.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '5.17.0' -RRType CNAME -Data '5.0/25.17.0.10.in-addr.arpa'
            Add-DnsStubRecord -ZoneName $zone -Name '18.0' -RRType NS -Data 'ns1.partner.example'

            Add-DnsStubRecord -ZoneName '0/25.17.0.10.in-addr.arpa' -Name '@' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName '0/25.17.0.10.in-addr.arpa' -Name '5' -RRType PTR -Data 'test01.lab.contoso.local'

            $ip6Zone = '8.b.d.0.1.0.0.2.ip6.arpa'
            $ip6Node = Get-DnsReverseNodeName -ReverseName (ConvertTo-DnsReverseName -Address '2001:db8::10')['ReverseName'] -ZoneName $ip6Zone
            Add-DnsStubRecord -ZoneName $ip6Zone -Name '@' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName $ip6Zone -Name $ip6Node -RRType PTR -Data 'v6host.contoso.local'

            Add-DnsStubRecord -ZoneName 'fabrikam.com' -Name 'web' -RRType A -Data '192.0.2.10'
        }
    }

    function New-EntrySnapshot {
        <#
        .SYNOPSIS
            Exports every exportable stub zone into the test snapshot.
        #>
        InModuleScope DnsLathund {
            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
        }
    }

    function Get-ExportCallCount {
        <#
        .SYNOPSIS
            Number of Export-DnsServerZone calls since the stub store was reset.
        #>
        InModuleScope DnsLathund {
            [int]$script:DnsStub.Calls['Export-DnsServerZone']
        }
    }

    function Get-ValueShape {
        <#
        .SYNOPSIS
            'null', 'array:<count>' or 'scalar' for one property, so that $null and
            @() can be told apart (pipeline assertions unroll both to nothing).
        #>
        param ($InputObject, [string]$Property)

        $value = $InputObject.PSObject.Properties[$Property].Value
        if ($null -eq $value) {
            return 'null'
        }
        if ($value -is [array]) {
            return 'array:' + $value.Count
        }
        'scalar'
    }
}

AfterAll {
    InModuleScope DnsLathund {
        $script:SnapshotRoot = $null
        $script:DnsServerExportRoot = Join-Path $env:windir 'System32\dns'
        $script:SnapshotIndexCache = @{}
        $script:ZoneTableCache = @{}
    }
}

Describe 'Get-DnsEntry without a snapshot (live lookups)' {
    BeforeAll {
        Initialize-EntryTest -Root (Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N')))
    }

    It 'reads an FQDN live and leaves every snapshot-derived property $null' {
        $entry = Get-DnsEntry -Find 'DC01.Contoso.Local.' -Server $script:Server

        @($entry).Count | Should -Be 1
        $entry.Name | Should -BeExactly 'dc01.contoso.local'
        $entry.Type | Should -Be 'A'
        $entry.Data | Should -Be '10.0.16.10'
        $entry.TTL | Should -Be 3600
        $entry.Zone | Should -Be 'contoso.local'
        $entry.NodeName | Should -BeExactly 'dc01'
        $entry.Source | Should -Be 'Live'
        $entry.Server | Should -BeExactly $script:Server
        $entry.DistinguishedName | Should -BeLike 'DC=dc01,*'
        $entry.PtrStatus | Should -Be 'Ok'
        $entry.IsStatic | Should -BeTrue
        $entry.InDhcpRange | Should -BeFalse
        foreach ($property in @('SnapshotAge', 'SharedWith', 'Aliases', 'ReferencedBy', 'HasDhcid', 'TargetExists', 'Owner')) {
            Get-ValueShape -InputObject $entry -Property $property | Should -Be 'null' -Because "$property is not evaluated without a snapshot"
        }
        Get-ValueShape -InputObject $entry -Property 'PtrTargets' | Should -Be 'array:1'
    }

    It 'returns one entry per record for a name with two A records' {
        $entries = @(Get-DnsEntry -Find 'web.contoso.local' -Server $script:Server)

        $entries.Count | Should -Be 2
        @($entries | ForEach-Object { $_.Data }) | Should -Be @('10.0.16.40', '10.0.16.41')
    }

    It 'reads a bare name live in -Zone, with or without -Exact' {
        $withZone = @(Get-DnsEntry -Find 'srv01' -Zone 'contoso.local' -Server $script:Server)
        $withExact = @(Get-DnsEntry -Find 'SRV01' -Zone 'contoso.local' -Exact -Server $script:Server)
        foreach ($entries in @($withZone, $withExact)) {
            $entries.Count | Should -Be 1
            $entries[0].Name | Should -Be 'srv01.contoso.local'
            $entries[0].TTL | Should -Be 1200
            $entries[0].Source | Should -Be 'Live'
        }

        $lab = @(Get-DnsEntry -Find 'test01' -Zone 'lab.contoso.local' -Server $script:Server)
        $lab.Count | Should -Be 1
        $lab[0].Zone | Should -Be 'lab.contoso.local'
    }

    It 'reads a bare name live in every hosted forward zone with -Exact' {
        $entries = @(Get-DnsEntry -Find 'test01' -Exact -Server $script:Server)
        $entries.Count | Should -Be 1
        $entries[0].Name | Should -Be 'test01.lab.contoso.local'

        @(Get-DnsEntry -Find 'web' -Exact -Server $script:Server | ForEach-Object { $_.Name }) |
            Should -Be @('web.contoso.local', 'web.contoso.local', 'web.fabrikam.com')
    }

    It 'finds the A record of an address through its PTR record and normalises the address first' {
        $entries = @(Get-DnsEntry -Find '010.000.016.020' -Server $script:Server)

        $entries.Count | Should -Be 1
        $entries[0].Name | Should -Be 'srv01.contoso.local'
        $entries[0].Source | Should -Be 'Live'

        $v6 = @(Get-DnsEntry -Find '2001:DB8:0:0::10' -Server $script:Server)
        $v6.Count | Should -Be 1
        $v6[0].Name | Should -Be 'v6host.contoso.local'
        $v6[0].Type | Should -Be 'AAAA'
    }

    It 'without a snapshot, finds only the PTR target of a shared address and cannot use SharedWith' {
        $entries = @(Get-DnsEntry -Find '10.0.16.70' -Server $script:Server)
        @($entries | ForEach-Object { $_.Name }) | Should -Be @('alias02.contoso.local')

        $alias01 = Get-DnsEntry -Find 'alias01.contoso.local' -Server $script:Server
        $alias01.PtrStatus | Should -Be 'WrongTarget'
        Get-ValueShape -InputObject $alias01 -Property 'SharedWith' | Should -Be 'null'

        # The NS delegation of 18.0.10.in-addr.arpa is only known from the snapshot.
        (Get-DnsEntry -Find 'partner07.contoso.local' -Server $script:Server).PtrStatus | Should -Be 'Missing'
    }

    It 'decodes \DDD escapes as octal and handles non-ASCII names' {
        $escaped = Get-DnsEntry -Find 'print\032srv.contoso.local' -Server $script:Server
        $escaped.Name | Should -BeExactly ('print' + [char]26 + 'srv.contoso.local')
        $escaped.Data | Should -Be '10.0.16.60'

        $spaced = Get-DnsEntry -Find 'print\040server.contoso.local' -Server $script:Server
        $spaced.Name | Should -BeExactly 'print server.contoso.local'
        $spaced.NodeName | Should -BeExactly 'print server'

        $nordic = Get-DnsEntry -Find 'RÄKSMÖRGÅS.contoso.local' -Server $script:Server
        $nordic.Name | Should -BeExactly 'räksmörgås.contoso.local'
        $nordic.NodeName | Should -BeExactly 'Räksmörgås'
    }

    It 'reads a secondary zone live and does not look into a forwarder zone' {
        $secondary = Get-DnsEntry -Find 'web.fabrikam.com' -Server $script:Server
        $secondary.Data | Should -Be '192.0.2.10'
        $secondary.PtrStatus | Should -Be 'NoReverseZone'

        $output = Get-DnsEntry -Find 'host.partner.example' -Server $script:Server -WarningVariable warnings -WarningAction SilentlyContinue
        $output | Should -BeNullOrEmpty
        "$($warnings[0])" | Should -BeExactly "No entry matched 'host.partner.example' on '$($script:Server)'."
    }

    It 'warns once per value and server when nothing matches, without an error' {
        # -ErrorVariable would also collect the "node not found" errors that the module
        # silences internally; the error stream holds only what the caller sees.
        $records = @(Get-DnsEntry -Find 'nosuch.contoso.local', '10.0.16.250', 'srv01.contoso.local' -Server $script:Server -WarningVariable warnings -WarningAction SilentlyContinue 2>&1)

        $records.Count | Should -Be 1
        $records[0].PSObject.TypeNames[0] | Should -Be 'DnsLathund.Entry'
        @($warnings | ForEach-Object { "$_" }) | Should -Be @(
            "No entry matched 'nosuch.contoso.local' on '$($script:Server)'."
            "No entry matched '10.0.16.250' on '$($script:Server)'."
        )
    }

    It 'names the orphaned PTR records when no A/AAAA record has the address' {
        $records = @(Get-DnsEntry -Find '10.0.16.33' -Server $script:Server -WarningVariable warnings -WarningAction SilentlyContinue 2>&1)

        $records.Count | Should -Be 0
        @($warnings).Count | Should -Be 1
        "$($warnings[0])" | Should -BeExactly ("No A/AAAA record has the address '10.0.16.33' on '$($script:Server)', but 2 PTR record(s) in '16.0.10.in-addr.arpa' " +
            'point at: ghost.contoso.local, io sense.pangkaka.com. These PTR records are orphaned (Test-DnsConsistency in a later phase reports them).')

        # With -Zone the A record may live in another zone, so the plain warning stays.
        $null = Get-DnsEntry -Find '10.0.16.33' -Zone 'contoso.local' -Server $script:Server -WarningVariable zoneWarnings -WarningAction SilentlyContinue
        "$($zoneWarnings[0])" | Should -BeExactly "No entry matched '10.0.16.33' on '$($script:Server)'."
    }

    It 'rejects a pattern with -Exact as a non-terminating error and continues with the next value' {
        $records = @(Get-DnsEntry -Find 'srv*', 'srv01' -Zone 'contoso.local' -Exact -Server $script:Server 2>&1)
        $errors = @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $entries = @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Get-DnsEntry.PatternWithExact*'
        $errors[0].CategoryInfo.Category | Should -Be 'InvalidArgument'
        $errors[0].TargetObject | Should -Be 'srv*'
        @($entries | ForEach-Object { $_.Name }) | Should -Be @('srv01.contoso.local')
        Get-ExportCallCount | Should -Be 0
    }

    It 'writes one non-terminating error for a -Zone that is not hosted' {
        $records = @(Get-DnsEntry -Find 'srv01', 'dc01' -Zone 'nosuch.example' -Server $script:Server -WarningVariable warnings -WarningAction SilentlyContinue 2>&1)

        $records.Count | Should -Be 1
        $records[0].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Get-DnsEntry.ZoneNotFound*'
        @($warnings).Count | Should -Be 0
    }

    It 'never exports a zone for FQDN, address, -Exact or -Zone lookups' {
        $null = Get-DnsEntry -Find 'srv01.contoso.local', '10.0.16.20', '2001:db8::10', 'contoso.local' -Server $script:Server -WarningAction SilentlyContinue
        $null = Get-DnsEntry -Find 'dc01' -Exact -Server $script:Server
        $null = Get-DnsEntry -Find 'dc01' -Zone 'contoso.local' -Server $script:Server

        Get-ExportCallCount | Should -Be 0
        InModuleScope DnsLathund {
            Test-Path -LiteralPath $script:SnapshotRoot | Should -BeFalse
            $script:SnapshotIndexCache.Count | Should -Be 0
        }
    }

    It 'reads the zone table once per server per call' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)

            $script:ZoneTableCache = @{}
            $script:DnsStub.Calls['Get-DnsServerZone'] = 0
            $null = Get-DnsEntry -Find 'srv01.contoso.local', 'dc01.contoso.local', '10.0.16.50' -Server $Server
            $script:DnsStub.Calls['Get-DnsServerZone'] | Should -Be 1
        }
    }
}

Describe 'Get-DnsEntry with a snapshot' {
    BeforeAll {
        Initialize-EntryTest -Root (Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N')))
        New-EntrySnapshot
    }

    It 'searches a pattern in the snapshot and sets Source and SnapshotAge' {
        $entries = @(Get-DnsEntry -Find 'srv*' -Server $script:Server)

        $entries.Count | Should -Be 1
        $entries[0].Name | Should -Be 'srv01.contoso.local'
        $entries[0].Source | Should -Be 'Snapshot'
        $entries[0].TTL | Should -Be 1200
        $entries[0].NodeName | Should -BeExactly 'srv01'
        $entries[0].DistinguishedName | Should -BeNullOrEmpty
        $entries[0].SnapshotAge | Should -BeOfType [timespan]
        $entries[0].SnapshotAge.TotalSeconds | Should -BeGreaterOrEqual 0
        $entries[0].SnapshotAge.TotalMinutes | Should -BeLessThan 5
    }

    It 'matches the whole FQDN with -like and restricts a pattern with -Zone' {
        @(Get-DnsEntry -Find 'srv0?' -Server $script:Server -WarningAction SilentlyContinue).Count | Should -Be 0
        @(Get-DnsEntry -Find '*' -Zone 'lab.contoso.local' -Server $script:Server | ForEach-Object { $_.Name }) |
            Should -Be @('test01.lab.contoso.local')
        @(Get-DnsEntry -Find 'dc0?.contoso.local' -Server $script:Server | ForEach-Object { $_.Name }) |
            Should -Be @('dc01.contoso.local')
    }

    It 'matches an address pattern against the addresses as well, without returning a record twice' {
        $entries = @(Get-DnsEntry -Find '10.0.16.7?' -Server $script:Server)
        @($entries | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('alias01.contoso.local', 'alias02.contoso.local')
        @($entries | Where-Object { $_.Source -ne 'Snapshot' }).Count | Should -Be 0

        # 'web*' matches by name; the address scan must not repeat those records.
        $both = @(Get-DnsEntry -Find '*0*' -Zone 'contoso.local' -Server $script:Server)
        $keys = @($both | ForEach-Object { $_.Name + '|' + $_.Type + '|' + $_.Data })
        $keys.Count | Should -Be @($keys | Sort-Object -Unique).Count
        $keys | Should -Contain 'web.contoso.local|A|10.0.16.40'
        $keys | Should -Contain 'mail.contoso.local|A|10.0.16.50'
    }

    It 'rejects an invalid wildcard pattern with a non-terminating error and continues with the next value' {
        $records = @(Get-DnsEntry -Find 'srv[*', 'dc01.contoso.local' -Server $script:Server 2>&1)
        $errors = @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })

        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Get-DnsEntry.InvalidPattern*'
        @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.Name }) |
            Should -Be @('dc01.contoso.local')
    }

    It 'restricts address lookups and FQDNs to -Zone' {
        @(Get-DnsEntry -Find '10.0.17.5' -Zone 'lab.contoso.local' -Server $script:Server | ForEach-Object { $_.Name }) |
            Should -Be @('test01.lab.contoso.local')

        $records = @(Get-DnsEntry -Find '10.0.16.70', 'srv01.contoso.local' -Zone 'lab.contoso.local' -Server $script:Server -WarningVariable warnings -WarningAction SilentlyContinue 2>&1)
        $records.Count | Should -Be 0
        @($warnings | ForEach-Object { "$_" }) | Should -Be @(
            "No entry matched '10.0.16.70' on '$($script:Server)'."
            "No entry matched 'srv01.contoso.local' on '$($script:Server)'."
        )

        # An FQDN inside -Zone is read as a node of -Zone, even below a child zone.
        @(Get-DnsEntry -Find 'test01.lab.contoso.local' -Zone 'lab.contoso.local' -Server $script:Server).Count | Should -Be 1
    }

    It 'searches a bare name as a substring of the snapshot names, with wildcard characters escaped' {
        @(Get-DnsEntry -Find 'ALIAS' -Server $script:Server | ForEach-Object { $_.Name }) |
            Should -Be @('alias01.contoso.local', 'alias02.contoso.local')
        @(Get-DnsEntry -Find 'rv01' -Server $script:Server | ForEach-Object { $_.Name }) |
            Should -Be @('srv01.contoso.local')

        $records = @(Get-DnsEntry -Find 'a[b' -Server $script:Server -WarningVariable warnings -WarningAction SilentlyContinue 2>&1)
        $records.Count | Should -Be 0
        "$($warnings[0])" | Should -BeExactly "No entry matched 'a[b' on '$($script:Server)'."
    }

    It 'finds the wildcard owner, the \032 owner and the åäö owner in the snapshot' {
        $entries = @(Get-DnsEntry -Find '*' -Zone 'contoso.local' -Server $script:Server)
        $names = @($entries | ForEach-Object { $_.Name })

        $names | Should -Contain '*.contoso.local'
        $names | Should -Contain ('print' + [char]26 + 'srv.contoso.local')
        $names | Should -Contain 'print server.contoso.local'
        $names | Should -Contain 'räksmörgås.contoso.local'

        (Get-DnsEntry -Find 'räks*' -Server $script:Server).Data | Should -Be '10.0.16.61'
    }

    It 'enriches a live entry from the snapshot' {
        $entry = Get-DnsEntry -Find 'dc01.contoso.local' -Server $script:Server

        $entry.Source | Should -Be 'Live'
        $entry.SnapshotAge | Should -BeOfType [timespan]
        $entry.DistinguishedName | Should -Not -BeNullOrEmpty
        $entry.Aliases | Should -Be @('gw.contoso.local')
        $entry.ReferencedBy | Should -Contain 'SRV:_ldap._tcp.contoso.local'
        $entry.ReferencedBy | Should -Contain 'NS:contoso.local'
        $entry.ReferencedBy | Should -Contain 'NS:lab.contoso.local'
        $entry.ReferencedBy | Should -Not -Contain 'CNAME:gw.contoso.local'
        $entry.HasDhcid | Should -BeFalse
        Get-ValueShape -InputObject $entry -Property 'HasDhcid' | Should -Be 'scalar'
        Get-ValueShape -InputObject $entry -Property 'SharedWith' | Should -Be 'array:0'

        (Get-DnsEntry -Find 'mail.contoso.local' -Server $script:Server).ReferencedBy | Should -Be @('MX:contoso.local')
    }

    It 'tells $null (not evaluated) from @() (evaluated, empty)' {
        $srv01 = Get-DnsEntry -Find 'srv01.contoso.local' -Server $script:Server
        Get-ValueShape -InputObject $srv01 -Property 'SharedWith' | Should -Be 'array:0'
        Get-ValueShape -InputObject $srv01 -Property 'Aliases' | Should -Be 'array:0'
        Get-ValueShape -InputObject $srv01 -Property 'ReferencedBy' | Should -Be 'array:0'
        Get-ValueShape -InputObject $srv01 -Property 'TargetExists' | Should -Be 'null'

        $snapshotSrv01 = Get-DnsEntry -Find 'srv01.*' -Server $script:Server
        Get-ValueShape -InputObject $snapshotSrv01 -Property 'Aliases' | Should -Be 'array:0'

        $missing = Get-DnsEntry -Find 'web.contoso.local' -Server $script:Server | Where-Object { $_.Data -eq '10.0.16.41' }
        Get-ValueShape -InputObject $missing -Property 'PtrTargets' | Should -Be 'array:0'

        $noReverse = Get-DnsEntry -Find 'nore.contoso.local' -Server $script:Server
        Get-ValueShape -InputObject $noReverse -Property 'PtrTargets' | Should -Be 'null'
        Get-ValueShape -InputObject $noReverse -Property 'ReverseZone' | Should -Be 'null'

        $cname = Get-DnsEntry -Find 'gw.contoso.local' -Server $script:Server
        foreach ($property in @('ReverseZone', 'PtrTargets', 'PtrZoneFound', 'SharedWith')) {
            Get-ValueShape -InputObject $cname -Property $property | Should -Be 'null' -Because "$property does not apply to a CNAME"
        }
        Get-ValueShape -InputObject $cname -Property 'Aliases' | Should -Be 'array:0'
    }

    It 'reports PtrStatus <Expected> for <Name> <Data> (live and snapshot)' -TestCases @(
        @{ Name = 'dc01.contoso.local'; Data = '10.0.16.10'; Expected = 'Ok'; ReverseZone = '16.0.10.in-addr.arpa'; PtrZoneFound = '16.0.10.in-addr.arpa'; PtrTargets = @('dc01.contoso.local') }
        @{ Name = 'srv01.contoso.local'; Data = '10.0.16.20'; Expected = 'Multiple'; ReverseZone = '16.0.10.in-addr.arpa'; PtrZoneFound = '16.0.10.in-addr.arpa'; PtrTargets = @('srv01.contoso.local', 'srv01-old.contoso.local') }
        @{ Name = 'dyn01.contoso.local'; Data = '10.0.16.30'; Expected = 'WrongTarget'; ReverseZone = '16.0.10.in-addr.arpa'; PtrZoneFound = '16.0.10.in-addr.arpa'; PtrTargets = @('wrong.contoso.local') }
        @{ Name = 'web.contoso.local'; Data = '10.0.16.40'; Expected = 'Shadowed'; ReverseZone = '16.0.10.in-addr.arpa'; PtrZoneFound = '10.in-addr.arpa'; PtrTargets = @('web.contoso.local') }
        @{ Name = 'web.contoso.local'; Data = '10.0.16.41'; Expected = 'Missing'; ReverseZone = '16.0.10.in-addr.arpa'; PtrZoneFound = $null; PtrTargets = @() }
        @{ Name = 'alias01.contoso.local'; Data = '10.0.16.70'; Expected = 'Ok'; ReverseZone = '16.0.10.in-addr.arpa'; PtrZoneFound = '16.0.10.in-addr.arpa'; PtrTargets = @('alias02.contoso.local') }
        @{ Name = 'printer80.contoso.local'; Data = '10.0.16.80'; Expected = 'Delegated'; ReverseZone = '16.0.10.in-addr.arpa'; PtrZoneFound = '16.0.10.in-addr.arpa'; PtrTargets = $null }
        @{ Name = 'extern90.contoso.local'; Data = '10.0.16.90'; Expected = 'Delegated'; ReverseZone = '16.0.10.in-addr.arpa'; PtrZoneFound = $null; PtrTargets = $null }
        @{ Name = 'partner07.contoso.local'; Data = '10.0.18.7'; Expected = 'Delegated'; ReverseZone = '10.in-addr.arpa'; PtrZoneFound = $null; PtrTargets = $null }
        @{ Name = 'test01.lab.contoso.local'; Data = '10.0.17.5'; Expected = 'Ok'; ReverseZone = '0/25.17.0.10.in-addr.arpa'; PtrZoneFound = '0/25.17.0.10.in-addr.arpa'; PtrTargets = @('test01.lab.contoso.local') }
        @{ Name = 'v6host.contoso.local'; Data = '2001:db8::10'; Expected = 'Ok'; ReverseZone = '8.b.d.0.1.0.0.2.ip6.arpa'; PtrZoneFound = '8.b.d.0.1.0.0.2.ip6.arpa'; PtrTargets = @('v6host.contoso.local') }
        @{ Name = 'nore.contoso.local'; Data = '192.168.1.10'; Expected = 'NoReverseZone'; ReverseZone = $null; PtrZoneFound = $null; PtrTargets = $null }
        @{ Name = 'v6orphan.contoso.local'; Data = '2001:db9::1'; Expected = 'NoReverseZone'; ReverseZone = $null; PtrZoneFound = $null; PtrTargets = $null }
        @{ Name = 'gw.contoso.local'; Data = 'dc01.contoso.local'; Expected = 'NotApplicable'; ReverseZone = $null; PtrZoneFound = $null; PtrTargets = $null }
    ) {
        $live = @(Get-DnsEntry -Find $Name -Server $script:Server | Where-Object { $_.Data -eq $Data })
        $snapshot = @(Get-DnsEntry -Find ($Name + '*') -Server $script:Server | Where-Object { $_.Name -eq $Name -and $_.Data -eq $Data })

        foreach ($entry in @($live[0], $snapshot[0])) {
            $live.Count | Should -Be 1
            $snapshot.Count | Should -Be 1
            $entry.PtrStatus | Should -BeExactly $Expected -Because "$($entry.Source) entry"
            $entry.ReverseZone | Should -Be $ReverseZone
            $entry.PtrZoneFound | Should -Be $PtrZoneFound
            if ($null -eq $PtrTargets) {
                Get-ValueShape -InputObject $entry -Property 'PtrTargets' | Should -Be 'null'
            }
            else {
                Get-ValueShape -InputObject $entry -Property 'PtrTargets' | Should -Be ('array:' + $PtrTargets.Count)
                if ($PtrTargets.Count -gt 0) {
                    @($entry.PtrTargets) | Should -Be $PtrTargets
                }
            }
        }
        $live[0].Source | Should -Be 'Live'
        $snapshot[0].Source | Should -Be 'Snapshot'
    }

    It 'fills SharedWith with the other owners of the address' {
        $alias01 = Get-DnsEntry -Find 'alias01.contoso.local' -Server $script:Server
        $alias01.SharedWith | Should -Be @('alias02.contoso.local')
        $alias02 = Get-DnsEntry -Find 'alias02.*' -Server $script:Server
        $alias02.SharedWith | Should -Be @('alias01.contoso.local')
    }

    It 'names orphaned PTR records also when a snapshot exists, and keeps the plain warning without PTR records' {
        $null = Get-DnsEntry -Find '10.0.16.33', '10.0.16.250' -Server $script:Server -WarningVariable warnings -WarningAction SilentlyContinue

        @($warnings).Count | Should -Be 2
        "$($warnings[0])" | Should -BeLike "No A/AAAA record has the address '10.0.16.33'*2 PTR record(s) in '16.0.10.in-addr.arpa' point at: ghost.contoso.local, io sense.pangkaka.com. These PTR records are orphaned*"
        "$($warnings[1])" | Should -BeExactly "No entry matched '10.0.16.250' on '$($script:Server)'."
    }

    It 'lists every A record of an address from the snapshot and confirms each live' {
        $entries = @(Get-DnsEntry -Find '10.0.16.70' -Server $script:Server)

        @($entries | ForEach-Object { $_.Name }) | Should -Be @('alias02.contoso.local', 'alias01.contoso.local')
        @($entries | Where-Object { $_.Source -ne 'Live' }).Count | Should -Be 0
        @($entries | Where-Object { $_.PtrStatus -ne 'Ok' }).Count | Should -Be 0
    }

    It 'sets HasDhcid, Timestamp and IsStatic' {
        foreach ($entry in @((Get-DnsEntry -Find 'dyn01.contoso.local' -Server $script:Server), (Get-DnsEntry -Find 'dyn01*' -Server $script:Server))) {
            $entry.HasDhcid | Should -BeTrue -Because "$($entry.Source) entry"
            $entry.IsStatic | Should -BeFalse
            $entry.Timestamp | Should -BeOfType [datetime]
            $entry.Timestamp | Should -Be ([datetime]::FromFileTimeUtc(0).AddHours(3636304).ToLocalTime())
        }
        (Get-DnsEntry -Find 'srv01*' -Server $script:Server).HasDhcid | Should -BeFalse
    }

    It 'sets TargetExists for a CNAME both ways' {
        $gw = Get-DnsEntry -Find 'gw.contoso.local' -Server $script:Server
        $gw.Type | Should -Be 'CNAME'
        $gw.Target | Should -Be 'dc01.contoso.local'
        $gw.TargetExists | Should -BeTrue

        $broken = Get-DnsEntry -Find 'broken*' -Server $script:Server
        $broken.Target | Should -Be 'missing.contoso.local'
        $broken.TargetExists | Should -BeFalse
        Get-ValueShape -InputObject $broken -Property 'TargetExists' | Should -Be 'scalar'

        (Get-DnsEntry -Find 'srv01.contoso.local' -Server $script:Server).Target | Should -BeNullOrEmpty
    }

    It 'marks InDhcpRange with -ExcludeNetwork and ignores an invalid network with one warning' {
        $entries = @(Get-DnsEntry -Find 'dhcp17.contoso.local', 'srv01*', '10.0.50.17' -ExcludeNetwork '10.0.50.0/24', 'not-a-network' -Server $script:Server -WarningVariable warnings -WarningAction SilentlyContinue)

        $entries.Count | Should -Be 3
        $entries[0].InDhcpRange | Should -BeTrue
        $entries[1].InDhcpRange | Should -BeFalse
        $entries[2].InDhcpRange | Should -BeTrue
        @($warnings).Count | Should -Be 1
        "$($warnings[0])" | Should -BeLike "*'not-a-network'*"
    }

    It 'stops after -First entries in total' {
        @(Get-DnsEntry -Find '*' -First 3 -Server $script:Server).Count | Should -Be 3
        @(Get-DnsEntry -Find 'web.contoso.local', 'dc01.contoso.local' -First 1 -Server $script:Server).Count | Should -Be 1
        @('web.contoso.local', 'dc01.contoso.local', 'srv01.contoso.local' | Get-DnsEntry -First 2 -Server $script:Server | ForEach-Object { $_.Data }) |
            Should -Be @('10.0.16.40', '10.0.16.41')
    }

    It 'repeats the search for every server and marks each entry with its server' {
        $entries = @(Get-DnsEntry -Find 'srv01.contoso.local' -Server $env:COMPUTERNAME, 'LOCALHOST' -WarningAction SilentlyContinue)

        $entries.Count | Should -Be 2
        @($entries | ForEach-Object { $_.Server }) | Should -Be @($script:Server, 'localhost')
        # Only the first server has a snapshot; a live lookup never creates one.
        $entries[0].SnapshotAge | Should -Not -BeNullOrEmpty
        $entries[1].SnapshotAge | Should -BeNullOrEmpty
        Get-ExportCallCount | Should -Be $script:ExportableZoneCount
    }

    It 'emits DnsLathund.Entry objects with the properties in contract order' {
        foreach ($entry in @(
                (Get-DnsEntry -Find 'srv01.contoso.local' -Server $script:Server),
                (Get-DnsEntry -Find 'srv01*' -Server $script:Server),
                (Get-DnsEntry -Find 'gw.contoso.local' -Server $script:Server)
            )) {
            $entry.PSObject.TypeNames[0] | Should -Be 'DnsLathund.Entry'
            @($entry.PSObject.Properties | ForEach-Object { $_.Name }) | Should -Be $script:EntryProperties
        }
    }

    It 'binds strings by value and objects by property name from the pipeline' {
        @('srv01.contoso.local', 'dc01.contoso.local' | Get-DnsEntry -Server $script:Server | ForEach-Object { $_.Name }) |
            Should -Be @('srv01.contoso.local', 'dc01.contoso.local')

        $inputObjects = @(
            New-Object -TypeName PSObject -Property @{ Name = 'mail.contoso.local' }
            New-Object -TypeName PSObject -Property @{ IPAddress = '10.0.16.10' }
            New-Object -TypeName PSObject -Property @{ HostName = 'test01.lab.contoso.local' }
        )
        @($inputObjects | Get-DnsEntry -Server $script:Server | ForEach-Object { $_.Name }) |
            Should -Be @('mail.contoso.local', 'dc01.contoso.local', 'test01.lab.contoso.local')

        # An entry piped back in is looked up again by its Name.
        @(Get-DnsEntry -Find 'srv01*' -Server $script:Server | Get-DnsEntry -Server $script:Server | ForEach-Object { $_.Source }) |
            Should -Be @('Live')
    }

    It 'skips empty values, such as blank lines from Get-Content' {
        $path = Join-Path -Path $TestDrive -ChildPath 'names.txt'
        Set-Content -LiteralPath $path -Value @('srv01.contoso.local', '', '   ', '10.0.16.10') -Encoding UTF8

        $records = @(Get-Content -LiteralPath $path | Get-DnsEntry -Server $script:Server -WarningVariable warnings 2>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0
        @($records | ForEach-Object { $_.Name }) | Should -Be @('srv01.contoso.local', 'dc01.contoso.local')
        @($warnings).Count | Should -Be 0
    }
}

Describe 'Get-DnsEntry snapshot handling' {
    BeforeEach {
        Initialize-EntryTest -Root (Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N')))
    }

    It 'exports a snapshot first, with a warning, when a pattern needs one' {
        $entries = @(Get-DnsEntry -Find 'srv*' -Server $script:Server -WarningVariable warnings -WarningAction SilentlyContinue)

        $entries.Count | Should -Be 1
        $entries[0].Source | Should -Be 'Snapshot'
        Get-ExportCallCount | Should -Be $script:ExportableZoneCount
        "$($warnings[0])" | Should -BeLike "No snapshot exists for '$($script:Server)'*"
    }

    It 'uses an existing snapshot on disk for live lookups without exporting again' {
        New-EntrySnapshot
        InModuleScope DnsLathund { $script:SnapshotIndexCache = @{} }
        $exportCalls = Get-ExportCallCount

        $entry = Get-DnsEntry -Find 'dc01.contoso.local' -Server $script:Server -WarningVariable warnings

        $entry.Source | Should -Be 'Live'
        $entry.Aliases | Should -Be @('gw.contoso.local')
        $entry.SnapshotAge | Should -BeOfType [timespan]
        @($warnings).Count | Should -Be 0
        Get-ExportCallCount | Should -Be $exportCalls
    }

    It 'never exports for a live lookup when only a meta.json without zone files exists' {
        New-EntrySnapshot
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $script:SnapshotIndexCache = @{}
            Get-ChildItem -LiteralPath (Join-Path -Path $script:SnapshotRoot -ChildPath $Server) -Filter '*.txt' | Remove-Item
        }
        $exportCalls = Get-ExportCallCount

        $entry = Get-DnsEntry -Find 'dc01.contoso.local' -Server $script:Server
        $entry.Source | Should -Be 'Live'
        Get-ValueShape -InputObject $entry -Property 'Aliases' | Should -Be 'null'
        Get-ExportCallCount | Should -Be $exportCalls
    }

    It 'warns once about a stale snapshot and still uses it, for snapshot and live entries' {
        New-EntrySnapshot
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $meta = Get-DnsSnapshotMeta -Server $Server
            $meta['Zones']['lab.contoso.local']['ExportedAt'] = (Get-Date).AddDays(-3).AddMinutes(-5)
            Save-DnsSnapshotMeta -Server $Server -Meta $meta
            $script:SnapshotIndexCache = @{}
        }
        $exportCalls = Get-ExportCallCount

        $entries = @(Get-DnsEntry -Find 'srv*', 'dc01.contoso.local' -MaxSnapshotAge (New-TimeSpan -Days 1) -Server $script:Server -WarningVariable warnings -WarningAction SilentlyContinue)

        $entries.Count | Should -Be 2
        @($warnings).Count | Should -Be 1
        "$($warnings[0])" | Should -BeLike "*'$($script:Server)' is 3d 0h 5m old*Update-DnsSnapshot*"
        foreach ($entry in $entries) {
            $entry.SnapshotAge.TotalDays | Should -BeGreaterThan 3
        }
        $entries[1].Aliases | Should -Be @('gw.contoso.local')
        Get-ExportCallCount | Should -Be $exportCalls

        $null = Get-DnsEntry -Find 'srv*' -Server $script:Server -WarningVariable defaultWarnings -WarningAction SilentlyContinue
        "$($defaultWarnings[0])" | Should -BeLike '*older than the accepted 1d 0h 0m*'
    }

    It 'warns when -Exact has to look in more than 10 forward zones' {
        InModuleScope DnsLathund {
            foreach ($number in 1..10) {
                Add-DnsStubZone -Name "extra$number.example"
            }
            $script:ZoneTableCache = @{}
        }

        $entries = @(Get-DnsEntry -Find 'srv01', 'dc01' -Exact -Server $script:Server -WarningVariable warnings -WarningAction SilentlyContinue)

        $entries.Count | Should -Be 2
        @($warnings).Count | Should -Be 1
        "$($warnings[0])" | Should -BeLike "*13 forward zones*-Zone*"
        Get-ExportCallCount | Should -Be 0
    }
}

Describe 'Resolve-DnsPtrStatus' {
    BeforeAll {
        Initialize-EntryTest -Root (Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N')))
        New-EntrySnapshot
    }

    It 'finds the covering reverse zones with classless zones before their parents' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $zoneTable = Get-DnsZoneTable -Server $Server
            @(Find-DnsZoneForName -Name '5.17.0.10.in-addr.arpa' -ZoneTable $zoneTable -Reverse) |
                Should -Be @('0/25.17.0.10.in-addr.arpa', '10.in-addr.arpa')
            @(Find-DnsZoneForName -Name '200.17.0.10.in-addr.arpa' -ZoneTable $zoneTable -Reverse) |
                Should -Be @('10.in-addr.arpa')
        }
    }

    It 'gives the same answer live and from the index, and reports SharedWith only with an index' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $zoneTable = Get-DnsZoneTable -Server $Server
            $index = Get-DnsSnapshotIndex -Server $Server
            $serverParameters = Get-DnsServerParameter -Server $Server

            foreach ($case in @(
                    @('10.0.16.70', 'alias01.contoso.local'), @('10.0.16.40', 'web.contoso.local'),
                    @('10.0.17.5', 'test01.lab.contoso.local'), @('10.0.16.80', 'printer80.contoso.local')
                )) {
                $fromIndex = Resolve-DnsPtrStatus -Address $case[0] -Name $case[1] -ZoneTable $zoneTable -Index $index
                $fromServer = Resolve-DnsPtrStatus -Address $case[0] -Name $case[1] -ZoneTable $zoneTable -Index $index -ServerParameter $serverParameters
                $fromServer['PtrStatus'] | Should -Be $fromIndex['PtrStatus'] -Because $case[0]
                $fromServer['PtrZoneFound'] | Should -Be $fromIndex['PtrZoneFound']
                @($fromServer['PtrTargets']) | Should -Be @($fromIndex['PtrTargets'])
            }

            $withoutIndex = Resolve-DnsPtrStatus -Address '10.0.16.70' -Name 'alias01.contoso.local' -ZoneTable $zoneTable -ServerParameter $serverParameters
            $withoutIndex['PtrStatus'] | Should -Be 'WrongTarget'
            $null -eq $withoutIndex['SharedWith'] | Should -BeTrue
            $withIndex = Resolve-DnsPtrStatus -Address '10.0.16.70' -Name 'ALIAS01.contoso.local.' -ZoneTable $zoneTable -Index $index
            $withIndex['PtrStatus'] | Should -Be 'Ok'
            @($withIndex['SharedWith']) | Should -Be @('alias02.contoso.local')
        }
    }
}

Describe 'Get-DnsLiveRecord' {
    BeforeAll {
        Initialize-EntryTest -Root (Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N')))
    }

    It 'returns normalised hashtables, one per record and type, always with -Node' {
        InModuleScope DnsLathund {
            Mock Get-DnsServerResourceRecord -ParameterFilter { -not $Node } { throw 'Get-DnsServerResourceRecord must be called with -Node.' }

            $records = @(Get-DnsLiveRecord -ServerParameter @{ ComputerName = 'dc01' } -ZoneName 'Contoso.Local.' -NodeName 'dyn01' -RRType 'A', 'DHCID', 'AAAA')

            $records.Count | Should -Be 2
            foreach ($record in $records) {
                $record | Should -BeOfType [hashtable]
                $record['Owner'] | Should -BeExactly 'dyn01.contoso.local'
                $record['Zone'] | Should -BeExactly 'contoso.local'
                $record['NodeName'] | Should -BeExactly 'dyn01'
                $record['Ttl'] | Should -Be 3600
                $record['DistinguishedName'] | Should -BeLike 'DC=dyn01,*'
            }
            $records[0]['Type'] | Should -Be 'A'
            $records[0]['Data'] | Should -Be '10.0.16.30'
            $records[0]['Timestamp'] | Should -BeOfType [datetime]
            $records[1]['Timestamp'] | Should -BeNullOrEmpty
            $records[1]['Type'] | Should -Be 'DHCID'
            $records[1]['Data'] | Should -BeExactly 'AAIBY2/AuCccgoJbsaxcQc9TUapptP69lOjxfNuVAA2kjEA='

            $srv = Get-DnsLiveRecord -ServerParameter @{ ComputerName = 'dc01' } -ZoneName 'contoso.local' -NodeName '_ldap._tcp' -RRType 'SRV'
            $srv['Data'] | Should -BeExactly 'dc01.contoso.local'
            $apex = @(Get-DnsLiveRecord -ServerParameter @{ ComputerName = 'dc01' } -ZoneName 'contoso.local' -NodeName '@' -RRType 'MX', 'NS')
            @($apex | ForEach-Object { $_['Data'] }) | Should -Be @('mail.contoso.local', 'dc01.contoso.local')
            $apex[0]['Owner'] | Should -BeExactly 'contoso.local'
        }
    }

    It 'returns nothing, without an error or warning, for a node or zone that does not exist' {
        InModuleScope DnsLathund {
            # The stub answers like the real cmdlet: WIN32 9714 / ObjectNotFound for a
            # missing node, WIN32 9601 / ObjectNotFound for a missing zone.
            foreach ($lookup in @(@('contoso.local', 'nosuch'), @('nosuch.example', 'srv01'))) {
                $records = @(Get-DnsLiveRecord -ServerParameter @{ ComputerName = 'dc01' } -ZoneName $lookup[0] -NodeName $lookup[1] -RRType 'A', 'CNAME' -WarningVariable warnings -Verbose 4>&1 2>&1)
                @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0 -Because "$($lookup[1]) in $($lookup[0])"
                @($records | Where-Object { $_ -is [hashtable] }).Count | Should -Be 0
                @($records | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -and "$_" -like '*does not exist*' }).Count | Should -Be 2
                @($warnings).Count | Should -Be 0
            }
        }
    }

    It 'treats <Case> as "no records"' -TestCases @(
        @{ Case = 'a WIN32 9714 error of another category'; Category = 'NotSpecified'; ErrorId = 'WIN32 9714,Get-DnsServerResourceRecord' }
        @{ Case = 'any ObjectNotFound error'; Category = 'ObjectNotFound'; ErrorId = 'WIN32 9601,Get-DnsServerResourceRecord' }
    ) {
        InModuleScope DnsLathund -Parameters @{ Category = $Category; ErrorId = $ErrorId } {
            param ($Category, $ErrorId)
            $mockError = @{ Category = $Category; ErrorId = $ErrorId }
            Mock Get-DnsServerResourceRecord { Write-Error -Message 'The record was not found.' -Category $mockError['Category'] -ErrorId $mockError['ErrorId'] }

            $records = @(Get-DnsLiveRecord -ServerParameter @{ ComputerName = 'dc01' } -ZoneName 'contoso.local' -NodeName 'srv01' -RRType 'A' 2>&1)
            $records.Count | Should -Be 0
            Should -Invoke Get-DnsServerResourceRecord -Times 1 -Exactly
        }
    }

    It 'reports any other failure as a non-terminating LookupFailed error with the original category' -TestCases @(
        @{ Category = 'ConnectionError'; UseMock = $false }
        @{ Category = 'PermissionDenied'; UseMock = $true }
    ) {
        InModuleScope DnsLathund -Parameters @{ UseMock = $UseMock } {
            param ($UseMock)
            if ($UseMock) {
                Mock Get-DnsServerResourceRecord { Write-Error -Message 'Access is denied.' -Category PermissionDenied -ErrorId 'WIN32 5,Get-DnsServerResourceRecord' }
            }
            else {
                # The stub fails with WIN32 1722 (RPC server unavailable), ConnectionError.
                $script:DnsStub.Fail['Get-DnsServerResourceRecord'] = @('contoso.local')
            }
            try {
                $records = @(Get-DnsLiveRecord -ServerParameter @{ ComputerName = 'dc01' } -ZoneName 'contoso.local' -NodeName 'srv01' -RRType 'A', 'AAAA' -WarningVariable warnings 2>&1)
            }
            finally {
                $script:DnsStub.Fail.Remove('Get-DnsServerResourceRecord')
            }

            $records.Count | Should -Be 2
            foreach ($record in $records) {
                $record | Should -BeOfType [System.Management.Automation.ErrorRecord]
                $record.FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Get-DnsLiveRecord.LookupFailed*'
                $record.TargetObject | Should -Be 'srv01'
            }
            "$($records[0])" | Should -BeLike "Lookup of 'srv01' (A) in zone 'contoso.local' on 'dc01' failed: *"
            "$($records[1])" | Should -BeLike "Lookup of 'srv01' (AAAA) in zone 'contoso.local' on 'dc01' failed: *"
            @($warnings).Count | Should -Be 0
        }
    }
}

Describe 'Get-DnsEntry when a live lookup fails' {
    BeforeAll {
        Initialize-EntryTest -Root (Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N')))
    }

    It 'passes LookupFailed errors on as non-terminating errors and continues with the other values' {
        InModuleScope DnsLathund { $script:DnsStub.Fail['Get-DnsServerResourceRecord'] = @('contoso.local') }
        try {
            $records = @(Get-DnsEntry -Find 'srv01.contoso.local', 'test01.lab.contoso.local' -Server $script:Server -WarningVariable warnings -WarningAction SilentlyContinue 2>&1)
        }
        finally {
            InModuleScope DnsLathund { $script:DnsStub.Fail.Remove('Get-DnsServerResourceRecord') }
        }
        $errors = @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $entries = @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

        $errors.Count | Should -Be 3 -Because 'A, AAAA and CNAME of srv01 each fail'
        @($errors | Where-Object { $_.FullyQualifiedErrorId -notlike 'DnsLathund.Get-DnsLiveRecord.LookupFailed*' }).Count | Should -Be 0
        $errors[0].CategoryInfo.Category | Should -Be 'ConnectionError'
        @($entries | ForEach-Object { $_.Name }) | Should -Be @('test01.lab.contoso.local')
        "$($warnings[0])" | Should -BeExactly "No entry matched 'srv01.contoso.local' on '$($script:Server)'."
    }

    It 'stops at the first failed lookup with -ErrorAction Stop' {
        InModuleScope DnsLathund { $script:DnsStub.Fail['Get-DnsServerResourceRecord'] = @('contoso.local') }
        try {
            { Get-DnsEntry -Find 'srv01.contoso.local' -Server $script:Server -ErrorAction Stop } |
                Should -Throw "Lookup of 'srv01' (A) in zone 'contoso.local'*"
        }
        finally {
            InModuleScope DnsLathund { $script:DnsStub.Fail.Remove('Get-DnsServerResourceRecord') }
        }
    }
}

Describe 'DnsLathund.Format.ps1xml' {
    It 'defines the default table views of CONTRACTS.md section 14' -TestCases @(
        @{ TypeName = 'DnsLathund.Entry'; Columns = @('Name', 'Type', 'Data', 'TTL', 'PtrStatus', 'Zone', 'Source') }
        @{ TypeName = 'DnsLathund.Snapshot'; Columns = @('Server', 'Zone', 'ExportedAt', 'Age', 'ZoneType', 'IsReverse') }
        @{ TypeName = 'DnsLathund.Result'; Columns = @('Action', 'Name', 'Data', 'Result', 'Error') }
        @{ TypeName = 'DnsLathund.ZoneInfo'; Columns = @('ZoneName', 'ZoneType', 'IsReverse', 'ReplicationScope', 'DynamicUpdate', 'AgingEnabled') }
    ) {
        $formatData = @(Get-FormatData -TypeName $TypeName)
        $formatData.Count | Should -Be 1
        $tableView = @($formatData[0].FormatViewDefinition | Where-Object { $_.Control -is [System.Management.Automation.TableControl] })[0]
        $tableView | Should -Not -BeNullOrEmpty
        @($tableView.Control.Headers | ForEach-Object { $_.Label }) | Should -Be $Columns
    }

    It 'shows Age and SnapshotAge as d.hh:mm:ss or hh:mm:ss' {
        $snapshot = InModuleScope DnsLathund {
            New-DnsObject -TypeName 'Snapshot' -Property ([ordered]@{
                    Server = 'dc01'; Zone = 'contoso.local'; ExportedAt = (Get-Date); Age = (New-TimeSpan -Days 2 -Hours 3 -Minutes 4 -Seconds 5).Add([timespan]::FromMilliseconds(600))
                    IsReverse = $false; ZoneType = 'Primary'; ReplicationScope = 'Domain'; DirectoryPartitionName = $null
                    DynamicUpdate = 'Secure'; AgingEnabled = $true; FileSizeBytes = 1; Path = 'C:\x'
                })
        }
        ($snapshot | Format-Table | Out-String -Width 200) | Should -Match '\b2\.03:04:05\b'
        $snapshot.Age = New-TimeSpan -Hours 3 -Minutes 4 -Seconds 5
        ($snapshot | Format-Table | Out-String -Width 200) | Should -Match '\s03:04:05\b'

        Initialize-EntryTest -Root (Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N')))
        New-EntrySnapshot
        $entry = Get-DnsEntry -Find 'srv01.contoso.local' -Server $script:Server
        $entry.SnapshotAge = New-TimeSpan -Days 1 -Hours 2
        $list = $entry | Format-List | Out-String -Width 200
        $list | Should -Match 'SnapshotAge\s+:\s+1\.02:00:00'
        $list | Should -Match 'PtrStatus\s+:\s+Multiple'
        ($entry | Format-Table | Out-String -Width 200) | Should -Match 'srv01\.contoso\.local\s+A\s+10\.0\.16\.20\s+1200\s+Multiple\s+contoso\.local\s+Live'
    }
}
