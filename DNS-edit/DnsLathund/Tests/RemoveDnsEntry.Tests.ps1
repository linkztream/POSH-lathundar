#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
<#
    Tests for Remove-DnsEntry (CONTRACTS.md section 13.4, with 5.8, 10, 11, 12.2 and
    13.9).

    The stubs are loaded into the module scope once. Initialize-RemoveTest points the
    snapshot root, the stub export root and the default change log at a fresh folder,
    clears every cache (zone table, CIM session, snapshot index, writer server) and
    builds this environment on the server $env:COMPUTERNAME, which Export-DnsZoneFile
    treats as this computer (see Snapshot.Tests.ps1), so a test can take a snapshot:

      contoso.local (primary)
        @            NS dc01.contoso.local, MX mail.contoso.local
        dc01         A 10.0.16.10                 SRV _ldap._tcp and NS @ point at it
        _ldap._tcp   SRV dc01.contoso.local
        mail         A 10.0.16.50                 MX @ points at it
        srv01        A 10.0.16.20, A 10.0.16.21   (node with two A records)
        gw           CNAME srv01.contoso.local    (alias of srv01)
        web          A 10.0.16.40
        www          CNAME web.contoso.local      (alias of web)
        smtp         CNAME web.contoso.local      (alias of web; MX in lab points at it)
        dhcp01       A 10.0.16.30 (dynamic), DHCID
        *            A 10.0.16.99                 (wildcard owner)
        kåken        A 10.0.16.77                 (non-ASCII name)
        shadow01     A 10.0.16.60                 (PTR only in the /16 zone)
        shared01     A 10.0.16.45                 (PTR 45 points at it)
        shared02     A 10.0.16.45                 (no PTR; found only through a snapshot)
        cls05        A 10.0.17.5                  (PTR in the RFC 2317 classless zone)
        ro01         A 10.0.18.5                  (PTR in a secondary reverse zone)
        v6host       AAAA 2001:db8::10
        f01 .. f08   A 10.0.20.1 .. 10.0.20.8     (no PTR)
      lab.contoso.local (primary, child zone)
        @            MX smtp.contoso.local
        test01       A 10.0.17.50
        alias01      CNAME srv01.contoso.local    (alias in another zone)
      16.0.10.in-addr.arpa (primary, /24)
        10 dc01, 20 srv01, 21 srv01, 30 dhcp01 (dynamic), 40 web, 45 shared01, 50 mail,
        77 kåken, 88 gone01.contoso.local (orphan: no A record)
      0.10.in-addr.arpa (primary, /16)            60.16 shadow01 (shadowed by the /24)
      17.0.10.in-addr.arpa (primary)              5 CNAME 5.0/26.17.0.10.in-addr.arpa
      0/26.17.0.10.in-addr.arpa (primary)         5 PTR cls05
      18.0.10.in-addr.arpa (secondary)            5 PTR ro01
      8.b.d.0.1.0.0.2.ip6.arpa (primary)          PTR of 2001:db8::10 -> v6host
      fabrikam.com (secondary)                    web A 10.0.30.5
      partner.example (stub)
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\DnsLathund.psd1" -Force
    $script:StubPath = Join-Path -Path $PSScriptRoot -ChildPath 'Stubs\DnsServerStubs.ps1'
    $script:Server = $env:COMPUTERNAME.ToLowerInvariant()
    $script:ResultProperties = @('Action', 'Name', 'Type', 'Data', 'Result', 'Error', 'Zone', 'NodeName', 'Server', 'Id', 'BatchId', 'Timestamp')
    $script:LogKeys = @('Id', 'BatchId', 'Timestamp', 'Operator', 'Server', 'Action', 'Zone', 'NodeName', 'Name', 'Type', 'Data', 'Before', 'After', 'Result', 'Error')
    $script:SavedLogPath = $env:DNSLATHUND_LOGPATH
    $script:Dhcid = 'AAIBY2/AuCccgoJbsaxcQc9TUapptP69lOjxfNuVAA2kjEA='

    InModuleScope DnsLathund -Parameters @{ StubPath = $script:StubPath } {
        param ($StubPath)
        . $StubPath
    }

    function Initialize-RemoveTest {
        <#
        .SYNOPSIS
            Fresh stub store, folders and default log under -Root, empty caches, and
            the environment described at the top of this file.
        #>
        param ([string]$Root)

        $null = New-Item -Path $Root -ItemType Directory -Force
        $env:DNSLATHUND_LOGPATH = Join-Path -Path $Root -ChildPath 'log\default.jsonl'

        InModuleScope DnsLathund -Parameters @{ Root = $Root } {
            param ($Root)

            $script:SnapshotRoot = Join-Path -Path $Root -ChildPath 'snapshot'
            $script:DnsServerExportRoot = Join-Path -Path $Root -ChildPath 'server-dns'
            Reset-DnsStubStore -ExportRoot $script:DnsServerExportRoot
            $script:ZoneTableCache = @{}
            $script:CimSessionCache = @{}
            $script:SnapshotIndexCache = @{}
            $script:WriterServer = $null

            Add-DnsStubZone -Name 'contoso.local'
            Add-DnsStubZone -Name 'lab.contoso.local'
            Add-DnsStubZone -Name '16.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '0.10.in-addr.arpa'
            Add-DnsStubZone -Name '17.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '0/26.17.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '18.0.10.in-addr.arpa' -ZoneType Secondary -IsDsIntegrated $false
            Add-DnsStubZone -Name '8.b.d.0.1.0.0.2.ip6.arpa'
            Add-DnsStubZone -Name 'fabrikam.com' -ZoneType Secondary -IsDsIntegrated $false
            Add-DnsStubZone -Name 'partner.example' -ZoneType Stub -IsDsIntegrated $false

            $zone = 'contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '@' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '@' -RRType MX -Data 'mail.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'dc01' -RRType A -Data '10.0.16.10'
            Add-DnsStubRecord -ZoneName $zone -Name '_ldap._tcp' -RRType SRV -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'mail' -RRType A -Data '10.0.16.50'
            Add-DnsStubRecord -ZoneName $zone -Name 'srv01' -RRType A -Data '10.0.16.20'
            Add-DnsStubRecord -ZoneName $zone -Name 'srv01' -RRType A -Data '10.0.16.21'
            Add-DnsStubRecord -ZoneName $zone -Name 'gw' -RRType CNAME -Data 'srv01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'web' -RRType A -Data '10.0.16.40'
            Add-DnsStubRecord -ZoneName $zone -Name 'www' -RRType CNAME -Data 'web.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'smtp' -RRType CNAME -Data 'web.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'dhcp01' -RRType A -Data '10.0.16.30' -AgeHours 3636304
            Add-DnsStubRecord -ZoneName $zone -Name 'dhcp01' -RRType DHCID -Data 'AAIBY2/AuCccgoJbsaxcQc9TUapptP69lOjxfNuVAA2kjEA='
            Add-DnsStubRecord -ZoneName $zone -Name '*' -RRType A -Data '10.0.16.99'
            Add-DnsStubRecord -ZoneName $zone -Name 'kåken' -RRType A -Data '10.0.16.77'
            Add-DnsStubRecord -ZoneName $zone -Name 'shadow01' -RRType A -Data '10.0.16.60'
            Add-DnsStubRecord -ZoneName $zone -Name 'shared01' -RRType A -Data '10.0.16.45'
            Add-DnsStubRecord -ZoneName $zone -Name 'shared02' -RRType A -Data '10.0.16.45'
            Add-DnsStubRecord -ZoneName $zone -Name 'cls05' -RRType A -Data '10.0.17.5'
            Add-DnsStubRecord -ZoneName $zone -Name 'ro01' -RRType A -Data '10.0.18.5'
            Add-DnsStubRecord -ZoneName $zone -Name 'v6host' -RRType AAAA -Data '2001:db8::10'
            foreach ($number in 1..8) {
                Add-DnsStubRecord -ZoneName $zone -Name ('f0{0}' -f $number) -RRType A -Data ('10.0.20.{0}' -f $number)
            }

            $zone = 'lab.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '@' -RRType MX -Data 'smtp.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'test01' -RRType A -Data '10.0.17.50'
            Add-DnsStubRecord -ZoneName $zone -Name 'alias01' -RRType CNAME -Data 'srv01.contoso.local'

            $zone = '16.0.10.in-addr.arpa'
            Add-DnsStubRecord -ZoneName $zone -Name '10' -RRType PTR -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '20' -RRType PTR -Data 'srv01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '21' -RRType PTR -Data 'srv01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '30' -RRType PTR -Data 'dhcp01.contoso.local' -AgeHours 3636304
            Add-DnsStubRecord -ZoneName $zone -Name '40' -RRType PTR -Data 'web.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '45' -RRType PTR -Data 'shared01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '50' -RRType PTR -Data 'mail.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '77' -RRType PTR -Data 'kåken.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '88' -RRType PTR -Data 'gone01.contoso.local'

            Add-DnsStubRecord -ZoneName '0.10.in-addr.arpa' -Name '60.16' -RRType PTR -Data 'shadow01.contoso.local'
            Add-DnsStubRecord -ZoneName '17.0.10.in-addr.arpa' -Name '5' -RRType CNAME -Data '5.0/26.17.0.10.in-addr.arpa'
            Add-DnsStubRecord -ZoneName '0/26.17.0.10.in-addr.arpa' -Name '5' -RRType PTR -Data 'cls05.contoso.local'
            Add-DnsStubRecord -ZoneName '18.0.10.in-addr.arpa' -Name '5' -RRType PTR -Data 'ro01.contoso.local'

            $ip6Zone = '8.b.d.0.1.0.0.2.ip6.arpa'
            $ip6Node = Get-DnsReverseNodeName -ReverseName (ConvertTo-DnsReverseName -Address '2001:db8::10')['ReverseName'] -ZoneName $ip6Zone
            Add-DnsStubRecord -ZoneName $ip6Zone -Name $ip6Node -RRType PTR -Data 'v6host.contoso.local'

            Add-DnsStubRecord -ZoneName 'fabrikam.com' -Name 'web' -RRType A -Data '10.0.30.5'
        }
    }

    function Get-StubNode {
        <#
        .SYNOPSIS
            Returns the records at one node of the stub store as 'TYPE data' strings.
        #>
        param (
            [string]$Zone,
            [string]$Node
        )

        InModuleScope DnsLathund -Parameters @{ Zone = $Zone; Node = $Node } {
            param ($Zone, $Node)
            @(
                foreach ($record in @($script:DnsStub.Records[$Zone.ToLowerInvariant()])) {
                    if ($null -ne $record -and $record.HostName -eq $Node) {
                        '{0} {1}' -f $record.RecordType, (Get-DnsStubRecordValue -Record $record)
                    }
                }
            )
        }
    }

    function Get-StubCallCount {
        <#
        .SYNOPSIS
            Returns how often a stub command was called since the store was reset.
        #>
        param ([string]$Command)

        InModuleScope DnsLathund -Parameters @{ Command = $Command } {
            param ($Command)
            [int]$script:DnsStub.Calls[$Command]
        }
    }

    function New-TestEntry {
        <#
        .SYNOPSIS
            Builds a DnsLathund.Entry with the identity properties Remove-DnsEntry reads.
        #>
        param (
            [string]$Name,
            [string]$Type,
            [string]$Data,
            [string]$Zone,
            [string]$NodeName,
            [string]$Server
        )

        InModuleScope DnsLathund -Parameters @{ Name = $Name; Type = $Type; Data = $Data; Zone = $Zone; NodeName = $NodeName; Server = $Server } {
            param ($Name, $Type, $Data, $Zone, $NodeName, $Server)
            New-DnsObject -TypeName 'Entry' -Property ([ordered]@{ Name = $Name; Type = $Type; Data = $Data; TTL = 3600; Zone = $Zone; NodeName = $NodeName; Server = $Server })
        }
    }

    function Get-LogLine {
        <#
        .SYNOPSIS
            Reads a change-log file as JSON objects; nothing when it does not exist.
        #>
        param ([string]$Path)

        if (Test-Path -LiteralPath $Path) {
            @(Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
        }
    }

    function Get-RemoveError {
        <#
        .SYNOPSIS
            Keeps the errors Remove-DnsEntry itself reported (the silenced "not found"
            answers of the stubs also reach a caller's -ErrorVariable, CONTRACTS.md 5.2b).
        #>
        param ([object[]]$ErrorRecord)

        @($ErrorRecord | Where-Object { $null -ne $_ -and [string]$_.FullyQualifiedErrorId -like 'DnsLathund.Remove-DnsEntry.*' })
    }
}

AfterAll {
    $env:DNSLATHUND_LOGPATH = $script:SavedLogPath
    InModuleScope DnsLathund {
        $script:SnapshotRoot = $null
        $script:DnsServerExportRoot = Join-Path $env:windir 'System32\dns'
        $script:SnapshotIndexCache = @{}
        $script:ZoneTableCache = @{}
        $script:CimSessionCache = @{}
        $script:WriterServer = $null
    }
}

Describe 'Remove-DnsEntry: names' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-RemoveTest -Root $script:Root
    }

    It 'removes the PTR records, the A records and then the aliases of a name' {
        $results = @(Remove-DnsEntry -Identity 'srv01.contoso.local' -Server $script:Server -Force)

        @($results | ForEach-Object { $_.Action }) -join ',' | Should -BeExactly 'RemovePtr,RemovePtr,RemoveA,RemoveA,RemoveCName,RemoveCName'
        @($results | Where-Object { $_.Result -ne 'Success' }).Count | Should -Be 0
        @($results[0..1] | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly '20.16.0.10.in-addr.arpa,21.16.0.10.in-addr.arpa'
        $results[0].Data | Should -BeExactly 'srv01.contoso.local'
        $results[0].Zone | Should -BeExactly '16.0.10.in-addr.arpa'
        $results[0].NodeName | Should -BeExactly '20'
        @($results[2..3] | ForEach-Object { $_.Data }) -join ',' | Should -BeExactly '10.0.16.20,10.0.16.21'
        $results[2].Name | Should -BeExactly 'srv01.contoso.local'
        (@($results[4..5] | ForEach-Object { $_.Name }) | Sort-Object) -join ',' | Should -BeExactly 'alias01.lab.contoso.local,gw.contoso.local'
        $results[4].Data | Should -BeExactly 'srv01.contoso.local'

        @(Get-StubNode -Zone 'contoso.local' -Node 'srv01').Count | Should -Be 0
        @(Get-StubNode -Zone 'contoso.local' -Node 'gw').Count | Should -Be 0
        @(Get-StubNode -Zone 'lab.contoso.local' -Node 'alias01').Count | Should -Be 0
        @(Get-StubNode -Zone '16.0.10.in-addr.arpa' -Node '20').Count | Should -Be 0
        @(Get-StubNode -Zone '16.0.10.in-addr.arpa' -Node '10') | Should -Be @('PTR dc01.contoso.local')
    }

    It 'is idempotent: a second run reports AlreadyDone with the identity as Data' {
        $null = Remove-DnsEntry -Identity 'srv01.contoso.local' -Server $script:Server -Force
        $results = @(Remove-DnsEntry -Identity 'srv01.contoso.local' -Server $script:Server -Force)

        $results.Count | Should -Be 1
        $results[0].Action | Should -BeExactly 'RemoveA'
        $results[0].Result | Should -BeExactly 'AlreadyDone'
        $results[0].Name | Should -BeExactly 'srv01.contoso.local'
        $results[0].Data | Should -BeExactly 'srv01.contoso.local'
        $results[0].Zone | Should -BeExactly 'contoso.local'
        $results[0].NodeName | Should -BeExactly 'srv01'
        $results[0].Error | Should -BeNullOrEmpty
    }

    It 'takes a bare name with -Zone and skips an alias that an MX record points at' {
        $results = @(Remove-DnsEntry -Identity 'web' -Zone 'contoso.local' -Server $script:Server -Force)

        @($results | ForEach-Object { '{0} {1} {2}' -f $_.Action, $_.Name, $_.Result }) | Should -Be @(
            'RemovePtr 40.16.0.10.in-addr.arpa Success'
            'RemoveA web.contoso.local Success'
            'RemoveCName www.contoso.local Success'
            'RemoveCName smtp.contoso.local Skipped'
        )
        $results[3].Error | Should -BeExactly 'Referenced by 1 MX record (lab.contoso.local). Add -AllowReferenced to remove it anyway.'
        @(Get-StubNode -Zone 'contoso.local' -Node 'smtp') | Should -Be @('CNAME web.contoso.local')
        @(Get-StubNode -Zone 'contoso.local' -Node 'www').Count | Should -Be 0
    }

    It 'skips every record of a name that SRV and NS records point at, with the contract message' {
        $results = @(Remove-DnsEntry -Identity 'dc01.contoso.local' -Server $script:Server -Force)

        @($results | ForEach-Object { '{0} {1}' -f $_.Action, $_.Result }) | Should -Be @('RemovePtr Skipped', 'RemoveA Skipped')
        foreach ($result in $results) {
            $result.Error | Should -BeExactly 'Referenced by 1 SRV and 1 NS records (_ldap._tcp.contoso.local, contoso.local). Add -AllowReferenced to remove it anyway.'
        }
        @(Get-StubNode -Zone 'contoso.local' -Node 'dc01') | Should -Be @('A 10.0.16.10')
        @(Get-StubNode -Zone '16.0.10.in-addr.arpa' -Node '10') | Should -Be @('PTR dc01.contoso.local')
    }

    It 'counts every referencing owner and lists the first three' {
        InModuleScope DnsLathund {
            foreach ($service in @('_kerberos._tcp', '_kpasswd._tcp', '_gc._tcp')) {
                Add-DnsStubRecord -ZoneName 'contoso.local' -Name $service -RRType SRV -Data 'dc01.contoso.local'
            }
        }

        $results = @(Remove-DnsEntry -Identity 'dc01.contoso.local' -Server $script:Server -Force)

        $results[0].Error | Should -BeExactly 'Referenced by 4 SRV and 1 NS records (_ldap._tcp.contoso.local, _kerberos._tcp.contoso.local, _kpasswd._tcp.contoso.local, ...). Add -AllowReferenced to remove it anyway.'
    }

    It 'skips a name that an MX record points at' {
        $results = @(Remove-DnsEntry -Identity 'mail.contoso.local' -Server $script:Server -Force)

        @($results | ForEach-Object { $_.Result }) | Should -Be @('Skipped', 'Skipped')
        $results[1].Error | Should -BeExactly 'Referenced by 1 MX record (contoso.local). Add -AllowReferenced to remove it anyway.'
    }

    It 'removes a referenced name with -AllowReferenced and warns, leaving the SRV and NS records alone' {
        $results = @(Remove-DnsEntry -Identity 'dc01.contoso.local' -Server $script:Server -AllowReferenced -Force -WarningVariable warnings -WarningAction SilentlyContinue)

        @($results | ForEach-Object { '{0} {1}' -f $_.Action, $_.Result }) | Should -Be @('RemovePtr Success', 'RemoveA Success')
        @($warnings | Where-Object { [string]$_ -like "'dc01.contoso.local': Referenced by 1 SRV and 1 NS records*-AllowReferenced*" }).Count | Should -Be 1
        @(Get-StubNode -Zone 'contoso.local' -Node '_ldap._tcp') | Should -Be @('SRV dc01.contoso.local')
    }

    It 'skips the item when the reference check cannot run; -SkipReferenceCheck removes it and leaves the aliases' {
        InModuleScope DnsLathund { $script:DnsStub.CimUnavailable = $true }

        $skipped = @(Remove-DnsEntry -Identity 'srv01.contoso.local' -Server $script:Server -Force)

        @($skipped | ForEach-Object { '{0} {1}' -f $_.Action, $_.Result }) | Should -Be @('RemovePtr Skipped', 'RemovePtr Skipped', 'RemoveA Skipped', 'RemoveA Skipped')
        foreach ($result in $skipped) {
            $result.Error | Should -BeExactly "The reference check could not run (root\MicrosoftDNS on '$($script:Server)' is not reachable). Run Update-DnsSnapshot first, or pass -SkipReferenceCheck."
        }
        @(Get-StubNode -Zone 'contoso.local' -Node 'srv01').Count | Should -Be 2

        $removed = @(Remove-DnsEntry -Identity 'srv01.contoso.local' -Server $script:Server -SkipReferenceCheck -Force -WarningVariable warnings -WarningAction SilentlyContinue)

        @($removed | ForEach-Object { $_.Action }) -join ',' | Should -BeExactly 'RemovePtr,RemovePtr,RemoveA,RemoveA'
        @($removed | Where-Object { $_.Result -ne 'Success' }).Count | Should -Be 0
        @($warnings | Where-Object { [string]$_ -like '*-SkipReferenceCheck*' }).Count | Should -Be 1
        @(Get-StubNode -Zone 'contoso.local' -Node 'gw') | Should -Be @('CNAME srv01.contoso.local')
    }

    It 'reads references and aliases from a fresh snapshot and leaves an alias alone that no longer points at the name' {
        $null = Update-DnsSnapshot -Server $script:Server -Force
        InModuleScope DnsLathund {
            $script:DnsStub.CimUnavailable = $true
            # alias01 changes after the snapshot: the snapshot still lists it.
            $script:DnsStub.Records['lab.contoso.local'] = @(foreach ($record in $script:DnsStub.Records['lab.contoso.local']) { if ($record.HostName -ne 'alias01') { $record } })
            Add-DnsStubRecord -ZoneName 'lab.contoso.local' -Name 'alias01' -RRType CNAME -Data 'web.contoso.local'
        }

        $results = @(Remove-DnsEntry -Identity 'srv01.contoso.local' -Server $script:Server -Force)

        @($results | ForEach-Object { '{0} {1} {2}' -f $_.Action, $_.Name, $_.Result }) | Should -Contain 'RemoveCName gw.contoso.local Success'
        @($results | Where-Object { $_.Name -eq 'alias01.lab.contoso.local' }).Count | Should -Be 0
        @(Get-StubNode -Zone 'lab.contoso.local' -Node 'alias01') | Should -Be @('CNAME web.contoso.local')
        (Get-StubCallCount -Command 'New-CimSession') | Should -Be 0
    }

    It 'keeps the aliases with -KeepAlias and the PTR records with -KeepPtr (no Result for them)' {
        $results = @(Remove-DnsEntry -Identity 'srv01.contoso.local' -Server $script:Server -KeepAlias -KeepPtr -Force)

        @($results | ForEach-Object { '{0} {1}' -f $_.Action, $_.Result }) | Should -Be @('RemoveA Success', 'RemoveA Success')
        @(Get-StubNode -Zone 'contoso.local' -Node 'gw') | Should -Be @('CNAME srv01.contoso.local')
        @(Get-StubNode -Zone 'lab.contoso.local' -Node 'alias01') | Should -Be @('CNAME srv01.contoso.local')
        @(Get-StubNode -Zone '16.0.10.in-addr.arpa' -Node '20') | Should -Be @('PTR srv01.contoso.local')
    }

    It 'removes the DHCID record after the last A record, warns per dynamic record and counts them in the summary' {
        $output = @(Remove-DnsEntry -Identity 'dhcp01.contoso.local' -Server $script:Server -Force -Verbose -WarningVariable warnings -WarningAction SilentlyContinue 4>&1)
        $results = @($output | Where-Object { $_.PSObject.TypeNames[0] -eq 'DnsLathund.Result' })
        $verbose = @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message })

        @($results | ForEach-Object { '{0} {1} {2}' -f $_.Action, $_.Data, $_.Result }) | Should -Be @(
            'RemovePtr dhcp01.contoso.local Success'
            'RemoveA 10.0.16.30 Success'
            "RemoveDhcid $($script:Dhcid) Success"
        )
        $results[2].Type | Should -BeExactly 'DHCID'
        @($warnings | Where-Object { [string]$_ -like '*is a dynamic record*' }).Count | Should -Be 2
        @($verbose | Where-Object { $_ -like "Remove-DnsEntry on '*'*3 Success*; 2 dynamic record(s)." }).Count | Should -Be 1
        @($verbose | Where-Object { $_ -like '*run Update-DnsSnapshot*' }).Count | Should -Be 1
        @(Get-StubNode -Zone 'contoso.local' -Node 'dhcp01').Count | Should -Be 0
    }

    It 'removes exactly the record of an entry and keeps the other A record, the DHCID record and the aliases' {
        InModuleScope DnsLathund { Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'srv01' -RRType DHCID -Data 'AAIBY2/AuCccgoJbsaxcQc9TUapptP69lOjxfNuVAA2kjEA=' }

        $results = @(Get-DnsEntry -Find 'srv01.contoso.local' -Server $script:Server | Where-Object { $_.Data -eq '10.0.16.21' } | Remove-DnsEntry -Server $script:Server -Force)

        @($results | ForEach-Object { '{0} {1} {2}' -f $_.Action, $_.Data, $_.Result }) | Should -Be @('RemovePtr srv01.contoso.local Success', 'RemoveA 10.0.16.21 Success')
        @(Get-StubNode -Zone 'contoso.local' -Node 'srv01') | Should -Be @('A 10.0.16.20', "DHCID $($script:Dhcid)")
        @(Get-StubNode -Zone 'contoso.local' -Node 'gw') | Should -Be @('CNAME srv01.contoso.local')
    }

    It 'removes only the CNAME record of <Case>' -TestCases @(
        @{ Case = 'a CNAME entry'; UseEntry = $true }
        @{ Case = 'a CNAME node named as a string'; UseEntry = $false }
    ) {
        if ($UseEntry) {
            $results = @(Get-DnsEntry -Find 'gw.contoso.local' -Server $script:Server | Remove-DnsEntry -Server $script:Server -Force)
        }
        else {
            $results = @(Remove-DnsEntry -Identity 'gw.contoso.local' -Server $script:Server -Force)
        }

        @($results | ForEach-Object { '{0} {1} {2} {3}' -f $_.Action, $_.Name, $_.Data, $_.Result }) | Should -Be @('RemoveCName gw.contoso.local srv01.contoso.local Success')
        @(Get-StubNode -Zone 'contoso.local' -Node 'srv01').Count | Should -Be 2
        @(Get-StubNode -Zone 'contoso.local' -Node 'gw').Count | Should -Be 0
    }

    It 'rejects a pattern with PatternNotAllowed and removes a wildcard owner given as an entry' {
        $rejected = @(Remove-DnsEntry -Identity '*.contoso.local' -Server $script:Server -Force -ErrorVariable runErrors -ErrorAction SilentlyContinue)

        $rejected.Count | Should -Be 1
        $rejected[0].Result | Should -BeExactly 'Failed'
        $rejected[0].Action | Should -BeExactly 'RemoveA'
        $rejected[0].Name | Should -BeExactly '*.contoso.local'
        $rejected[0].Error | Should -BeLike '*is a pattern*Get-DnsEntry*'
        $errors = Get-RemoveError -ErrorRecord $runErrors
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeExactly 'DnsLathund.Remove-DnsEntry.PatternNotAllowed,Remove-DnsEntry'
        [string]$errors[0].CategoryInfo.Category | Should -BeExactly 'InvalidArgument'
        @(Get-StubNode -Zone 'contoso.local' -Node '*') | Should -Be @('A 10.0.16.99')

        $entry = New-TestEntry -Name '*.contoso.local' -Type 'A' -Data '10.0.16.99' -Zone 'contoso.local' -NodeName '*' -Server $script:Server
        $removed = @($entry | Remove-DnsEntry -Server $script:Server -Force)

        @($removed | ForEach-Object { '{0} {1} {2}' -f $_.Action, $_.Name, $_.Result }) | Should -Be @('RemoveA *.contoso.local Success')
        @(Get-StubNode -Zone 'contoso.local' -Node '*').Count | Should -Be 0
    }

    It 'reports ZoneNotFound for a name outside every hosted zone' {
        $results = @(Remove-DnsEntry -Identity 'host.example.org' -Server $script:Server -Force -ErrorVariable runErrors -ErrorAction SilentlyContinue)

        $results.Count | Should -Be 1
        $results[0].Result | Should -BeExactly 'Failed'
        $results[0].Data | Should -BeExactly 'host.example.org'
        (Get-RemoveError -ErrorRecord $runErrors)[0].FullyQualifiedErrorId | Should -BeExactly 'DnsLathund.Remove-DnsEntry.ZoneNotFound,Remove-DnsEntry'
    }

    It 'removes a name with a non-ASCII character and its PTR record' {
        $results = @(Remove-DnsEntry -Identity 'KÅKEN.contoso.local' -Server $script:Server -Force)

        @($results | ForEach-Object { '{0} {1} {2}' -f $_.Action, $_.Data, $_.Result }) | Should -Be @('RemovePtr kåken.contoso.local Success', 'RemoveA 10.0.16.77 Success')
        $results[1].Name | Should -BeExactly 'kåken.contoso.local'
        @(Get-StubNode -Zone 'contoso.local' -Node 'kåken').Count | Should -Be 0
        @(Get-StubNode -Zone '16.0.10.in-addr.arpa' -Node '77').Count | Should -Be 0
    }

    It 'removes a shadowed PTR record from the shorter reverse zone' {
        $results = @(Remove-DnsEntry -Identity 'shadow01.contoso.local' -Server $script:Server -Force)

        @($results | ForEach-Object { '{0} {1} {2} {3}' -f $_.Action, $_.Zone, $_.NodeName, $_.Result }) | Should -Be @(
            'RemovePtr 0.10.in-addr.arpa 60.16 Success'
            'RemoveA contoso.local shadow01 Success'
        )
        $results[0].Name | Should -BeExactly '60.16.0.10.in-addr.arpa'
        @(Get-StubNode -Zone '0.10.in-addr.arpa' -Node '60.16').Count | Should -Be 0
    }

    It 'removes the PTR record in an RFC 2317 classless zone and keeps the CNAME in the parent zone' {
        $results = @(Remove-DnsEntry -Identity 'cls05.contoso.local' -Server $script:Server -Force)

        @($results | ForEach-Object { '{0} {1} {2} {3}' -f $_.Action, $_.Zone, $_.NodeName, $_.Result }) | Should -Be @(
            'RemovePtr 0/26.17.0.10.in-addr.arpa 5 Success'
            'RemoveA contoso.local cls05 Success'
        )
        @(Get-StubNode -Zone '0/26.17.0.10.in-addr.arpa' -Node '5').Count | Should -Be 0
        @(Get-StubNode -Zone '17.0.10.in-addr.arpa' -Node '5') | Should -Be @('CNAME 5.0/26.17.0.10.in-addr.arpa')
    }

    It 'skips a PTR record in a read-only reverse zone and still removes the A record' {
        $results = @(Remove-DnsEntry -Identity 'ro01.contoso.local' -Server $script:Server -Force)

        @($results | ForEach-Object { '{0} {1}' -f $_.Action, $_.Result }) | Should -Be @('RemovePtr Skipped', 'RemoveA Success')
        $results[0].Zone | Should -BeExactly '18.0.10.in-addr.arpa'
        $results[0].Error | Should -BeLike "*'18.0.10.in-addr.arpa' is not writable on this server*Secondary*"
        @(Get-StubNode -Zone '18.0.10.in-addr.arpa' -Node '5') | Should -Be @('PTR ro01.contoso.local')
        @(Get-StubNode -Zone 'contoso.local' -Node 'ro01').Count | Should -Be 0
        (Get-StubCallCount -Command 'Remove-DnsServerResourceRecord') | Should -Be 1
    }

    It 'skips <Case>' -TestCases @(
        @{ Case = 'a name in a read-only forward zone'; Identity = 'web.fabrikam.com'; Expected = "*'fabrikam.com' is not writable on this server*Secondary*" }
        @{ Case = 'a name in a stub zone'; Identity = 'host.partner.example'; Expected = "*'partner.example' is a Stub zone*" }
    ) {
        $results = @(Remove-DnsEntry -Identity $Identity -Server $script:Server -Force)

        $results.Count | Should -BeGreaterThan 0
        foreach ($result in $results) {
            $result.Result | Should -BeExactly 'Skipped'
            $result.Error | Should -BeLike $Expected
        }
        (Get-StubCallCount -Command 'Remove-DnsServerResourceRecord') | Should -Be 0
    }

    It 'keeps the A record and the aliases when a PTR record in a writable zone cannot be removed' {
        InModuleScope DnsLathund { $script:DnsStub.Fail['Remove-DnsServerResourceRecord'] = @('16.0.10.in-addr.arpa') }

        $results = @(Remove-DnsEntry -Identity 'web.contoso.local' -Server $script:Server -Force -ErrorVariable runErrors -ErrorAction SilentlyContinue)

        @($results | ForEach-Object { '{0} {1} {2}' -f $_.Action, $_.Name, $_.Result }) | Should -Be @(
            'RemovePtr 40.16.0.10.in-addr.arpa Failed'
            'RemoveA web.contoso.local Skipped'
            'RemoveCName www.contoso.local Skipped'
            'RemoveCName smtp.contoso.local Skipped'
        )
        $results[0].Error | Should -BeLike 'Could not remove the PTR record*'
        $results[1].Error | Should -BeLike '*kept to avoid an orphaned PTR*'
        $results[2].Error | Should -BeExactly "Kept because 'web.contoso.local' was not removed."
        $errors = Get-RemoveError -ErrorRecord $runErrors
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeExactly 'DnsLathund.Remove-DnsEntry.RemoveFailed,Remove-DnsEntry'
        [string]$errors[0].CategoryInfo.Category | Should -BeExactly 'PermissionDenied'
        @(Get-StubNode -Zone 'contoso.local' -Node 'web') | Should -Be @('A 10.0.16.40')
    }

    It 'lets a failed alias block nothing' {
        InModuleScope DnsLathund { $script:DnsStub.Fail['Remove-DnsServerResourceRecord'] = @('lab.contoso.local') }

        $results = @(Remove-DnsEntry -Identity 'srv01.contoso.local' -Server $script:Server -Force -ErrorVariable runErrors -ErrorAction SilentlyContinue)

        @($results | Where-Object { $_.Result -eq 'Failed' } | ForEach-Object { $_.Name }) | Should -Be @('alias01.lab.contoso.local')
        @($results | Where-Object { $_.Result -eq 'Success' }).Count | Should -Be 5
        (Get-RemoveError -ErrorRecord $runErrors).Count | Should -Be 1
        @(Get-StubNode -Zone 'contoso.local' -Node 'srv01').Count | Should -Be 0
    }

    It 'reports AlreadyDone when a record disappears between the read and the removal' {
        InModuleScope DnsLathund {
            $script:DnsStub.BeforeCall['Remove-DnsServerResourceRecord'] = {
                $script:DnsStub.Records['contoso.local'] = @(foreach ($record in $script:DnsStub.Records['contoso.local']) { if ($record.HostName -ne 'f01') { $record } })
            }
        }

        $results = @(Remove-DnsEntry -Identity 'f01.contoso.local' -Server $script:Server -Force -ErrorVariable runErrors -ErrorAction SilentlyContinue)

        @($results | ForEach-Object { '{0} {1}' -f $_.Action, $_.Result }) | Should -Be @('RemoveA AlreadyDone')
        (Get-RemoveError -ErrorRecord $runErrors).Count | Should -Be 0
    }

    It 'removes an AAAA record and its ip6.arpa PTR record' {
        $results = @(Remove-DnsEntry -Identity 'v6host.contoso.local' -Server $script:Server -Force)

        @($results | ForEach-Object { '{0} {1} {2}' -f $_.Action, $_.Zone, $_.Result }) | Should -Be @(
            'RemovePtr 8.b.d.0.1.0.0.2.ip6.arpa Success'
            'RemoveAAAA contoso.local Success'
        )
        $results[1].Data | Should -BeExactly '2001:db8::10'
        $results[1].Type | Should -BeExactly 'AAAA'
    }
}

Describe 'Remove-DnsEntry: addresses' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-RemoveTest -Root $script:Root
    }

    It 'removes an orphaned PTR record of an address instead of reporting AlreadyDone' {
        $results = @(Remove-DnsEntry -Identity '10.0.16.88' -Server $script:Server -Force -WarningAction SilentlyContinue)

        @($results | ForEach-Object { '{0} {1} {2} {3}' -f $_.Action, $_.Name, $_.Data, $_.Result }) | Should -Be @('RemovePtr 88.16.0.10.in-addr.arpa gone01.contoso.local Success')
        @(Get-StubNode -Zone '16.0.10.in-addr.arpa' -Node '88').Count | Should -Be 0
    }

    It 'removes the A record that holds the address and keeps the other A record and the aliases of the name' {
        $results = @(Remove-DnsEntry -Identity '10.0.16.20' -Server $script:Server -Force -WarningAction SilentlyContinue)

        @($results | ForEach-Object { '{0} {1} {2}' -f $_.Action, $_.Data, $_.Result }) | Should -Be @('RemovePtr srv01.contoso.local Success', 'RemoveA 10.0.16.20 Success')
        @(Get-StubNode -Zone 'contoso.local' -Node 'srv01') | Should -Be @('A 10.0.16.21')
        @(Get-StubNode -Zone 'contoso.local' -Node 'gw') | Should -Be @('CNAME srv01.contoso.local')
    }

    It 'warns once per batch without a snapshot and finds only the names that PTR records point at' {
        $results = @(Remove-DnsEntry -Identity '10.0.16.45', '10.0.16.88' -Server $script:Server -Force -WarningVariable warnings -WarningAction SilentlyContinue)

        @($warnings | Where-Object { [string]$_ -like 'A records without a PTR cannot be found by address without a snapshot*' }).Count | Should -Be 1
        @($results | ForEach-Object { '{0} {1} {2}' -f $_.Action, $_.Name, $_.Result }) | Should -Be @(
            'RemovePtr 45.16.0.10.in-addr.arpa Success'
            'RemoveA shared01.contoso.local Success'
            'RemovePtr 88.16.0.10.in-addr.arpa Success'
        )
        @(Get-StubNode -Zone 'contoso.local' -Node 'shared02') | Should -Be @('A 10.0.16.45')
    }

    It 'finds an A record without a PTR record through the snapshot address index' {
        $null = Update-DnsSnapshot -Server $script:Server -Force

        $results = @(Remove-DnsEntry -Identity '10.0.16.45' -Server $script:Server -Force -WarningVariable warnings -WarningAction SilentlyContinue)

        @($results | ForEach-Object { '{0} {1} {2}' -f $_.Action, $_.Name, $_.Result }) | Should -Be @(
            'RemovePtr 45.16.0.10.in-addr.arpa Success'
            'RemoveA shared01.contoso.local Success'
            'RemoveA shared02.contoso.local Success'
        )
        @($warnings | Where-Object { [string]$_ -like '*without a snapshot*' }).Count | Should -Be 0
        @(Get-StubNode -Zone 'contoso.local' -Node 'shared02').Count | Should -Be 0
    }

    It 'reports AlreadyDone for an address that nothing uses' {
        $results = @(Remove-DnsEntry -Identity '10.0.16.111' -Server $script:Server -Force -WarningAction SilentlyContinue)

        $results.Count | Should -Be 1
        $results[0].Action | Should -BeExactly 'RemoveA'
        $results[0].Result | Should -BeExactly 'AlreadyDone'
        $results[0].Name | Should -BeExactly '10.0.16.111'
        $results[0].Type | Should -BeExactly 'A'
        $results[0].Data | Should -BeExactly '10.0.16.111'
        $results[0].Zone | Should -BeNullOrEmpty
    }

    It 'with -Zone removes only the A records of that zone and never treats a PTR to a name elsewhere as an orphan' {
        $results = @(Remove-DnsEntry -Identity '10.0.16.20' -Zone 'lab.contoso.local' -Server $script:Server -Force -WarningAction SilentlyContinue)

        @($results | ForEach-Object { '{0} {1}' -f $_.Action, $_.Result }) | Should -Be @('RemoveA AlreadyDone')
        @(Get-StubNode -Zone '16.0.10.in-addr.arpa' -Node '20') | Should -Be @('PTR srv01.contoso.local')
    }
}

Describe 'Remove-DnsEntry: pipeline and input file' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-RemoveTest -Root $script:Root
    }

    It 'removes entries piped from Get-DnsEntry one by one; the aliases go with the last A record' {
        $results = @(Get-DnsEntry -Find 'srv01.contoso.local' -Server $script:Server | Remove-DnsEntry -Server $script:Server -Force)

        @($results | ForEach-Object { '{0} {1}' -f $_.Action, $_.Data }) | Should -Be @(
            'RemovePtr srv01.contoso.local'
            'RemoveA 10.0.16.20'
            'RemovePtr srv01.contoso.local'
            'RemoveA 10.0.16.21'
            'RemoveCName srv01.contoso.local'
            'RemoveCName srv01.contoso.local'
        )
        @($results | Where-Object { $_.Result -ne 'Success' }).Count | Should -Be 0
        @($results | ForEach-Object { $_.BatchId } | Select-Object -Unique).Count | Should -Be 1
    }

    It 'accepts a Deserialized.DnsLathund.Entry from Export-Clixml / Import-Clixml' {
        $entry = @(Get-DnsEntry -Find 'srv01.contoso.local' -Server $script:Server | Where-Object { $_.Data -eq '10.0.16.21' })[0]
        $path = Join-Path -Path $script:Root -ChildPath 'entry.xml'
        $entry | Export-Clixml -LiteralPath $path
        $deserialized = Import-Clixml -LiteralPath $path
        $deserialized.PSObject.TypeNames[0] | Should -BeExactly 'Deserialized.DnsLathund.Entry'

        $results = @($deserialized | Remove-DnsEntry -Server $script:Server -Force)

        @($results | ForEach-Object { '{0} {1} {2}' -f $_.Action, $_.Data, $_.Result }) | Should -Be @('RemovePtr srv01.contoso.local Success', 'RemoveA 10.0.16.21 Success')
        @(Get-StubNode -Zone 'contoso.local' -Node 'srv01') | Should -Be @('A 10.0.16.20')
    }

    It 'warns once per entry that was read from another server' {
        $entries = @(
            New-TestEntry -Name 'f01.contoso.local' -Type 'A' -Data '10.0.20.1' -Zone 'contoso.local' -NodeName 'f01' -Server 'dc99'
            New-TestEntry -Name 'f02.contoso.local' -Type 'A' -Data '10.0.20.2' -Zone 'contoso.local' -NodeName 'f02' -Server 'dc99'
            New-TestEntry -Name 'f03.contoso.local' -Type 'A' -Data '10.0.20.3' -Zone 'contoso.local' -NodeName 'f03' -Server $script:Server
        )

        $results = @($entries | Remove-DnsEntry -Server $script:Server -Force -WarningVariable warnings -WarningAction SilentlyContinue)

        @($results | Where-Object { $_.Result -eq 'Success' }).Count | Should -Be 3
        @($warnings | Where-Object { [string]$_ -like "*was read from 'dc99', but this command changes '$($script:Server)'*" }).Count | Should -Be 2
    }

    It 'reads the Name, HostName or IPAddress property of other objects and skips blank strings' {
        $objects = @(
            [pscustomobject]@{ HostName = 'web.contoso.local'; Description = 'old web server' }
            [pscustomobject]@{ IPAddress = '10.0.16.88' }
            [pscustomobject]@{ Name = 'f01.contoso.local' }
            ''
            '   '
        )

        $results = @($objects | Remove-DnsEntry -Server $script:Server -Force -WarningAction SilentlyContinue -ErrorVariable runErrors -ErrorAction SilentlyContinue)

        @($results | ForEach-Object { '{0} {1} {2}' -f $_.Action, $_.Name, $_.Result }) | Should -Be @(
            'RemovePtr 40.16.0.10.in-addr.arpa Success'
            'RemoveA web.contoso.local Success'
            'RemoveCName www.contoso.local Success'
            'RemoveCName smtp.contoso.local Skipped'
            'RemovePtr 88.16.0.10.in-addr.arpa Success'
            'RemoveA f01.contoso.local Success'
        )
        (Get-RemoveError -ErrorRecord $runErrors).Count | Should -Be 0
    }

    It 'processes an -InputFile of 25 lines: names, FQDNs, addresses, comments and a duplicate' {
        $path = Join-Path -Path $script:Root -ChildPath 'decommissioned.txt'
        $lines = @(
            '# Decommissioned hosts, October 2026'
            ''
            'srv01.contoso.local'
            'web.contoso.local'
            '# addresses'
            '10.0.16.88'
            '10.0.16.45'
            'kåken.contoso.local'
            'shadow01.contoso.local'
            'cls05.contoso.local'
            'f01'
            'f02.contoso.local'
            'F02.contoso.local'
            'f03'
            '10.0.20.4'
            'f05.contoso.local'
            'f06'
            '# not there, outside the zone, or a pattern'
            'nothere.contoso.local'
            'host.example.org'
            '*.contoso.local'
            'f07'
            'f08'
            'mail.contoso.local'
            'dc01.contoso.local'
        )
        $lines.Count | Should -Be 25
        Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
        Mock Write-Progress -ModuleName DnsLathund { }

        $results = @(Remove-DnsEntry -InputFile $path -Zone 'contoso.local' -Server $script:Server -Force -WarningVariable warnings -WarningAction SilentlyContinue -ErrorVariable runErrors -ErrorAction SilentlyContinue)

        Should -Invoke Write-Progress -ModuleName DnsLathund -ParameterFilter { $Activity -like 'Removing the DNS entries listed in*' -and $Status -eq 'Item 1 of 20' }
        Should -Invoke Write-Progress -ModuleName DnsLathund -Times 1 -Exactly -ParameterFilter { $Activity -like 'Removing the DNS entries listed in*' -and $Completed }

        @($results | Where-Object { $_.Result -eq 'Success' }).Count | Should -Be 25
        @($results | Where-Object { $_.Result -eq 'Skipped' }).Count | Should -Be 5
        @($results | Where-Object { $_.Result -eq 'AlreadyDone' } | ForEach-Object { $_.Name }) | Should -Be @('10.0.20.4', 'nothere.contoso.local')
        @($results | Where-Object { $_.Result -eq 'Failed' } | ForEach-Object { $_.Name }) | Should -Be @('host.example.org', '*.contoso.local')
        $results.Count | Should -Be 34
        @(Get-RemoveError -ErrorRecord $runErrors | ForEach-Object { ([string]$_.FullyQualifiedErrorId).Split(',')[0] }) | Should -Be @('DnsLathund.Remove-DnsEntry.ZoneNotFound', 'DnsLathund.Remove-DnsEntry.PatternNotAllowed')
        @($warnings | Where-Object { [string]$_ -like '*without a snapshot*' }).Count | Should -Be 1
        @(Get-StubNode -Zone 'contoso.local' -Node 'kåken').Count | Should -Be 0
        @(Get-StubNode -Zone 'contoso.local' -Node 'f02').Count | Should -Be 0
        @(Get-StubNode -Zone 'contoso.local' -Node 'f04') | Should -Be @('A 10.0.20.4')
    }

    It 'processes a CSV -InputFile with a Name column (semicolon separated, Address, Target and Zone columns)' {
        $path = Join-Path -Path $script:Root -ChildPath 'remove.csv'
        Set-Content -LiteralPath $path -Encoding UTF8 -Value @(
            'Name;Address;Target;Zone'
            'srv01.contoso.local;10.0.16.21;;'
            'web;;;contoso.local'
            '10.0.16.88;;;'
            'alias01.lab.contoso.local;;srv01.contoso.local;'
        )

        $results = @(Remove-DnsEntry -FilePath $path -Server $script:Server -Force -WarningAction SilentlyContinue)

        @($results | ForEach-Object { '{0} {1} {2} {3}' -f $_.Action, $_.Name, $_.Data, $_.Result }) | Should -Be @(
            'RemovePtr 21.16.0.10.in-addr.arpa srv01.contoso.local Success'
            'RemoveA srv01.contoso.local 10.0.16.21 Success'
            'RemovePtr 40.16.0.10.in-addr.arpa web.contoso.local Success'
            'RemoveA web.contoso.local 10.0.16.40 Success'
            'RemoveCName www.contoso.local web.contoso.local Success'
            'RemoveCName smtp.contoso.local web.contoso.local Skipped'
            'RemovePtr 88.16.0.10.in-addr.arpa gone01.contoso.local Success'
            'RemoveCName alias01.lab.contoso.local srv01.contoso.local Success'
        )
        @(Get-StubNode -Zone 'contoso.local' -Node 'srv01') | Should -Be @('A 10.0.16.20')
        @(Get-StubNode -Zone 'contoso.local' -Node 'gw') | Should -Be @('CNAME srv01.contoso.local')
    }
}

Describe 'Remove-DnsEntry: confirmation, -WhatIf and batch control' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-RemoveTest -Root $script:Root
    }

    It '-WhatIf prints one gate line per item, returns WhatIf per record, removes nothing and logs every Result' {
        Mock Write-Host -ModuleName DnsLathund { }

        $results = @(Remove-DnsEntry -Identity 'srv01.contoso.local', 'web.contoso.local' -Server $script:Server -WhatIf)

        Should -Invoke Write-Host -ModuleName DnsLathund -Times 2 -Exactly
        Should -Invoke Write-Host -ModuleName DnsLathund -Times 1 -Exactly -ParameterFilter { $Object -eq 'What if: Performing the operation "Remove DNS records" on target "srv01.contoso.local: remove 2 PTR, 2 A, 2 CNAME aliases".' }
        Should -Invoke Write-Host -ModuleName DnsLathund -Times 1 -Exactly -ParameterFilter { $Object -eq 'What if: Performing the operation "Remove DNS records" on target "web.contoso.local: remove 1 PTR, 1 A, 1 CNAME alias".' }
        @($results | ForEach-Object { $_.Result }) -join ',' | Should -BeExactly 'WhatIf,WhatIf,WhatIf,WhatIf,WhatIf,WhatIf,WhatIf,WhatIf,WhatIf,Skipped'
        (Get-StubCallCount -Command 'Remove-DnsServerResourceRecord') | Should -Be 0
        @(Get-StubNode -Zone 'contoso.local' -Node 'srv01').Count | Should -Be 2
        @(Get-StubNode -Zone 'contoso.local' -Node 'www').Count | Should -Be 1

        $log = @(Get-LogLine -Path $env:DNSLATHUND_LOGPATH)
        $log.Count | Should -Be 10
        @($log | ForEach-Object { $_.Result }) -join ',' | Should -BeExactly 'WhatIf,WhatIf,WhatIf,WhatIf,WhatIf,WhatIf,WhatIf,WhatIf,WhatIf,Skipped'
        $log[0].Name | Should -BeExactly '20.16.0.10.in-addr.arpa'
        $log[0].Data | Should -BeExactly 'srv01.contoso.local'
    }

    It '<Case> never prompts' -TestCases @(
        @{ Case = '-Force'; Splat = @{ Force = $true } }
        @{ Case = '-Confirm:$false'; Splat = @{ Confirm = $false } }
    ) {
        Mock Read-Host -ModuleName DnsLathund { throw 'Read-Host must not be called.' }

        $results = @(Remove-DnsEntry -Identity 'f01.contoso.local', 'f02.contoso.local' -Server $script:Server @Splat)

        Should -Invoke Read-Host -ModuleName DnsLathund -Times 0 -Exactly
        @($results | ForEach-Object { $_.Result }) -join ',' | Should -BeExactly 'Success,Success'
    }

    It 'prompts once per item with the gate text; Y removes, N skips every record of the item' {
        Mock Read-Host -ModuleName DnsLathund {
            if ($Prompt -like '*web.contoso.local*') {
                'n'
            }
            else {
                'y'
            }
        }

        $results = @(Remove-DnsEntry -Identity 'srv01.contoso.local', 'web.contoso.local' -Server $script:Server)

        Should -Invoke Read-Host -ModuleName DnsLathund -Times 2 -Exactly
        Should -Invoke Read-Host -ModuleName DnsLathund -Times 1 -Exactly -ParameterFilter { $Prompt -like "Remove DNS records*srv01.contoso.local: remove 2 PTR, 2 A, 2 CNAME aliases*" }
        @($results | Where-Object { $_.Result -eq 'Success' }).Count | Should -Be 6
        $declined = @($results | Where-Object { $_.Error -like 'Declined at the confirmation prompt*' })
        @($declined | ForEach-Object { '{0} {1}' -f $_.Name, $_.Result }) | Should -Be @(
            '40.16.0.10.in-addr.arpa Skipped'
            'web.contoso.local Skipped'
            'www.contoso.local Skipped'
        )
        @($results | Where-Object { $_.Name -eq 'smtp.contoso.local' } | ForEach-Object { $_.Error }) | Should -BeLike 'Referenced by 1 MX record*'
        @(Get-StubNode -Zone 'contoso.local' -Node 'web') | Should -Be @('A 10.0.16.40')
    }

    It 'remembers [A] Yes to all for the rest of the batch' {
        Mock Read-Host -ModuleName DnsLathund { 'a' }

        $results = @(Remove-DnsEntry -Identity 'f01.contoso.local', 'f02.contoso.local', 'f03.contoso.local' -Server $script:Server)

        Should -Invoke Read-Host -ModuleName DnsLathund -Times 1 -Exactly
        @($results | ForEach-Object { $_.Result }) -join ',' | Should -BeExactly 'Success,Success,Success'
    }

    It '[S]top ends the batch' {
        Mock Read-Host -ModuleName DnsLathund { 's' }
        $collected = [System.Collections.Generic.List[object]]::new()

        { Remove-DnsEntry -Identity 'f01.contoso.local', 'f02.contoso.local' -Server $script:Server | ForEach-Object { $collected.Add($_) } } | Should -Throw '*stopped by the operator*'

        Should -Invoke Read-Host -ModuleName DnsLathund -Times 1 -Exactly
        $collected.Count | Should -Be 0
        @(Get-StubNode -Zone 'contoso.local' -Node 'f01').Count | Should -Be 1
        @(Get-StubNode -Zone 'contoso.local' -Node 'f02').Count | Should -Be 1
    }

    It 'ends the batch with one terminating error when the session cannot prompt; the second item is not attempted' {
        Mock Read-Host -ModuleName DnsLathund { throw 'The host cannot prompt.' }
        Mock Write-Host -ModuleName DnsLathund { }

        # The reads of the first item alone (-WhatIf reads exactly what a real run reads before its gate).
        $before = Get-StubCallCount -Command 'Get-DnsServerResourceRecord'
        $null = Remove-DnsEntry -Identity 'web.contoso.local' -Server $script:Server -WhatIf
        $firstItemReads = (Get-StubCallCount -Command 'Get-DnsServerResourceRecord') - $before

        $collected = [System.Collections.Generic.List[object]]::new()
        $before = Get-StubCallCount -Command 'Get-DnsServerResourceRecord'
        { Remove-DnsEntry -Identity 'web.contoso.local', 'test01.lab.contoso.local' -Server $script:Server | ForEach-Object { $collected.Add($_) } } | Should -Throw -ErrorId 'DnsLathund.Confirm.NonInteractive,Remove-DnsEntry'

        ((Get-StubCallCount -Command 'Get-DnsServerResourceRecord') - $before) | Should -Be $firstItemReads
        Should -Invoke Read-Host -ModuleName DnsLathund -Times 1 -Exactly
        $collected.Count | Should -Be 0
        @(Get-StubNode -Zone 'contoso.local' -Node 'web') | Should -Be @('A 10.0.16.40')
        @(Get-StubNode -Zone 'lab.contoso.local' -Node 'test01') | Should -Be @('A 10.0.17.50')
    }

    It 'ends the batch after the Failed Result when the server becomes unreachable during a removal' {
        InModuleScope DnsLathund {
            $script:DnsStub.Fail['Remove-DnsServerResourceRecord'] = @('*')
            $script:DnsStub.FailCode['Remove-DnsServerResourceRecord'] = 1722
        }
        $collected = [System.Collections.Generic.List[object]]::new()

        { Remove-DnsEntry -Identity 'web.contoso.local', 'test01.lab.contoso.local' -Server $script:Server -Force | ForEach-Object { $collected.Add($_) } } | Should -Throw -ErrorId 'DnsLathund.Remove-DnsEntry.ServerUnreachable,Remove-DnsEntry'

        $collected.Count | Should -Be 1
        $collected[0].Action | Should -BeExactly 'RemovePtr'
        $collected[0].Result | Should -BeExactly 'Failed'
        $collected[0].Error | Should -BeLike 'Could not remove the PTR record*'
        (Get-StubCallCount -Command 'Remove-DnsServerResourceRecord') | Should -Be 1
        @(Get-LogLine -Path $env:DNSLATHUND_LOGPATH).Count | Should -Be 1
        @(Get-StubNode -Zone 'lab.contoso.local' -Node 'test01') | Should -Be @('A 10.0.17.50')
    }

    It 'ends the batch after the Failed Result when the server becomes unreachable during a lookup' {
        InModuleScope DnsLathund { $script:DnsStub.Fail['Get-DnsServerResourceRecord'] = @('contoso.local') }
        $collected = [System.Collections.Generic.List[object]]::new()

        { Remove-DnsEntry -Identity 'web.contoso.local', 'test01.lab.contoso.local' -Server $script:Server -Force | ForEach-Object { $collected.Add($_) } } | Should -Throw -ErrorId 'DnsLathund.Remove-DnsEntry.ServerUnreachable,Remove-DnsEntry'

        $collected.Count | Should -Be 1
        $collected[0].Result | Should -BeExactly 'Failed'
        $collected[0].Name | Should -BeExactly 'web.contoso.local'
        (Get-StubCallCount -Command 'Remove-DnsServerResourceRecord') | Should -Be 0
        @(Get-StubNode -Zone 'lab.contoso.local' -Node 'test01') | Should -Be @('A 10.0.17.50')
    }

    It 'reports access denied on a lookup as a Failed item, never AlreadyDone, and goes on' {
        InModuleScope DnsLathund {
            $script:DnsStub.Fail['Get-DnsServerResourceRecord'] = @('contoso.local')
            $script:DnsStub.FailCode['Get-DnsServerResourceRecord'] = 5
        }

        $results = @(Remove-DnsEntry -Identity 'web.contoso.local', 'test01.lab.contoso.local' -Server $script:Server -Force -ErrorVariable runErrors -ErrorAction SilentlyContinue)

        @($results | ForEach-Object { '{0} {1}' -f $_.Name, $_.Result }) | Should -Be @('web.contoso.local Failed', 'test01.lab.contoso.local Success')
        $errors = Get-RemoveError -ErrorRecord $runErrors
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeExactly 'DnsLathund.Remove-DnsEntry.LookupFailed,Remove-DnsEntry'
        [string]$errors[0].CategoryInfo.Category | Should -BeExactly 'PermissionDenied'
    }

    It '-Delay sleeps once per item, and not under -WhatIf' {
        Mock Start-Sleep -ModuleName DnsLathund { }
        Mock Write-Host -ModuleName DnsLathund { }

        $null = Remove-DnsEntry -Identity 'f01', 'f02', 'nothere' -Zone 'contoso.local' -Server $script:Server -Delay 2 -Force

        Should -Invoke Start-Sleep -ModuleName DnsLathund -Times 3 -Exactly -ParameterFilter { $Seconds -eq 2 }

        $null = Remove-DnsEntry -Identity 'f03', 'f04' -Zone 'contoso.local' -Server $script:Server -Delay 2 -WhatIf

        Should -Invoke Start-Sleep -ModuleName DnsLathund -Times 3 -Exactly -ParameterFilter { $Seconds -eq 2 }
    }

    It 'warns once per zone that has zone scopes besides the default' {
        InModuleScope DnsLathund { $script:DnsStub.ZoneScopes['contoso.local'] = @('branch') }

        $null = Remove-DnsEntry -Identity 'f01.contoso.local', 'f02.contoso.local' -Server $script:Server -Force -WarningVariable warnings -WarningAction SilentlyContinue

        @($warnings | Where-Object { [string]$_ -like "Zone 'contoso.local'*zone scopes besides the default (branch)*" }).Count | Should -Be 1
        (Get-StubCallCount -Command 'Get-DnsServerZoneScope') | Should -Be 1
    }

    It 'warns when this session already changed DNS on another server' {
        InModuleScope DnsLathund { $script:WriterServer = 'dc99' }

        $null = Remove-DnsEntry -Identity 'f01.contoso.local' -Server $script:Server -Force -WarningVariable warnings -WarningAction SilentlyContinue

        @($warnings | Where-Object { [string]$_ -like "This session already changed DNS on 'dc99'*" }).Count | Should -Be 1
    }

    It 'does not remember the writer server for a -WhatIf run' {
        InModuleScope DnsLathund { $script:WriterServer = $null }

        $null = Remove-DnsEntry -Identity 'f01.contoso.local' -Server $script:Server -WhatIf

        InModuleScope DnsLathund { $script:WriterServer } | Should -BeNullOrEmpty
    }
}

Describe 'Remove-DnsEntry: Result objects and change log' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-RemoveTest -Root $script:Root
    }

    It 'returns Results with the properties of CONTRACTS.md 12.2 in order and writes one CONTRACTS.md 11 line each to -LogPath' {
        $logPath = Join-Path -Path $script:Root -ChildPath 'explicit\changes.jsonl'

        $results = @(Remove-DnsEntry -Identity 'srv01.contoso.local', 'dc01.contoso.local', 'nothere.contoso.local' -Server $script:Server -LogPath $logPath -Force)

        $results.Count | Should -Be 9
        foreach ($result in $results) {
            $result.PSObject.TypeNames[0] | Should -BeExactly 'DnsLathund.Result'
            @($result.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly ($script:ResultProperties -join ',')
            $result.Server | Should -BeExactly $script:Server
            $result.Timestamp | Should -BeOfType [datetime]
        }
        @($results | ForEach-Object { $_.BatchId } | Select-Object -Unique).Count | Should -Be 1

        $log = @(Get-LogLine -Path $logPath)
        $log.Count | Should -Be $results.Count
        for ($number = 0; $number -lt $log.Count; $number++) {
            @($log[$number].PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly ($script:LogKeys -join ',')
            $log[$number].Id | Should -BeExactly $results[$number].Id
            $log[$number].BatchId | Should -BeExactly $results[$number].BatchId
            $log[$number].Action | Should -BeExactly $results[$number].Action
            $log[$number].Name | Should -BeExactly $results[$number].Name
            $log[$number].Data | Should -BeExactly $results[$number].Data
            $log[$number].Result | Should -BeExactly $results[$number].Result
        }
        $log[2].Before.Data | Should -BeExactly '10.0.16.20'
        $log[2].Before.Ttl | Should -Be 3600
        $log[2].Before.IsStatic | Should -BeTrue
        $log[6].Result | Should -BeExactly 'Skipped'
        $log[6].Before | Should -BeNullOrEmpty
        Test-Path -LiteralPath $env:DNSLATHUND_LOGPATH | Should -BeFalse
    }
}
