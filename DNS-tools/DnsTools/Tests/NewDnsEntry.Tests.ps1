#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
<#
    Tests for New-DnsEntry (CONTRACTS.md section 13.5, with sections 5, 10, 11, 12.2
    and 13.9): parameter sets and pipeline binding, preflight (NodeIsCname,
    CnameCollision, Delegated, NoReverseZone, RFC 2317 placement), AlreadyDone,
    -ReplacePtr, -CreateReverseZone through New-DnsLiveReverseZone in the run's own
    batch (one BatchId, "Yes to all" per impact level), -WhatIf and the writer
    server, the confirmation gate, batch abort, -Delay, the Result shape and the
    change log.

    The stubs are loaded into the module scope once. Initialize-NewEntryTest gives
    every test a fresh stub store, empty caches, its own change log and this
    environment on the server dc01:

      contoso.local (primary, Custom partition CorpDnsZones.contoso.local, Secure,
                     aging on: no-refresh 3 days, refresh 5 days, scavenger 10.0.16.10)
        @          NS dc01.contoso.local
        dc01       A 10.0.16.10
        srv01      A 10.0.16.20 (TTL 3600)
        web        A 10.0.16.40
        www        CNAME web.contoso.local
        txtnode    TXT
        branch     NS ns1.branch.contoso.local (delegated subtree)
      file.local (primary, file-backed), legacy.local (primary, Legacy scope)
      fabrikam.com (secondary, read-only)
      16.0.10.in-addr.arpa (/24): 10 PTR dc01, 20 PTR srv01, 30 PTR old.contoso.local
      20.172.in-addr.arpa (/16)
      32.0.10.in-addr.arpa: 5 CNAME 5.0/26.32.0.10.in-addr.arpa
      0/26.32.0.10.in-addr.arpa (classless, hosted)
      33.0.10.in-addr.arpa: 7 CNAME 7.0/26.33.0.10.in-addr.arpa (classless zone not hosted)
      34.0.10.in-addr.arpa: 9 CNAME 9.sub.34.0.10.in-addr.arpa
      sub.34.0.10.in-addr.arpa (hosted)
      8.b.d.0.1.0.0.2.ip6.arpa (2001:db8::/32)
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\DnsTools.psd1" -Force
    $script:StubPath = Join-Path -Path $PSScriptRoot -ChildPath 'Stubs\DnsServerStubs.ps1'
    $script:Server = 'dc01'
    $script:ResultProperties = @('Action', 'Name', 'Type', 'Data', 'Result', 'Error', 'Zone', 'NodeName', 'Server', 'Id', 'BatchId', 'Timestamp')
    $script:LogKeys = @('Id', 'BatchId', 'Timestamp', 'Operator', 'Server', 'Action', 'Zone', 'NodeName', 'Name', 'Type', 'Data', 'Before', 'After', 'Result', 'Error')

    InModuleScope DnsTools -Parameters @{ StubPath = $script:StubPath } {
        param ($StubPath)
        . $StubPath
    }

    function Initialize-NewEntryTest {
        <#
        .SYNOPSIS
            Fresh stub store, empty caches and the environment described at the top
            of this file.
        #>
        InModuleScope DnsTools {
            Reset-DnsStubStore
            $script:ZoneTableCache = @{}
            $script:CimSessionCache = @{}
            $script:SnapshotIndexCache = @{}
            $script:WriterServer = $null

            Add-DnsStubZone -Name 'contoso.local' -ReplicationScope 'Custom' -DirectoryPartitionName 'CorpDnsZones.contoso.local' -DynamicUpdate 'Secure' -AgingEnabled $true -NoRefreshInterval (New-TimeSpan -Days 3) -RefreshInterval (New-TimeSpan -Days 5) -ScavengeServers @('10.0.16.10')
            Add-DnsStubZone -Name 'file.local' -IsDsIntegrated $false -DynamicUpdate 'None'
            Add-DnsStubZone -Name 'legacy.local' -ReplicationScope 'Legacy' -DirectoryPartitionName 'contoso.local'
            Add-DnsStubZone -Name 'fabrikam.com' -ZoneType Secondary -IsDsIntegrated $false
            Add-DnsStubZone -Name '16.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '20.172.in-addr.arpa'
            Add-DnsStubZone -Name '32.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '0/26.32.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '33.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '34.0.10.in-addr.arpa'
            Add-DnsStubZone -Name 'sub.34.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '8.b.d.0.1.0.0.2.ip6.arpa'

            $zone = 'contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '@' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'dc01' -RRType A -Data '10.0.16.10'
            Add-DnsStubRecord -ZoneName $zone -Name 'srv01' -RRType A -Data '10.0.16.20' -TimeToLive 3600
            Add-DnsStubRecord -ZoneName $zone -Name 'web' -RRType A -Data '10.0.16.40'
            Add-DnsStubRecord -ZoneName $zone -Name 'www' -RRType CNAME -Data 'web.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'txtnode' -RRType TXT -Data 'v=spf1 -all'
            Add-DnsStubRecord -ZoneName $zone -Name 'branch' -RRType NS -Data 'ns1.branch.contoso.local'

            Add-DnsStubRecord -ZoneName '16.0.10.in-addr.arpa' -Name '10' -RRType PTR -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName '16.0.10.in-addr.arpa' -Name '20' -RRType PTR -Data 'srv01.contoso.local'
            Add-DnsStubRecord -ZoneName '16.0.10.in-addr.arpa' -Name '30' -RRType PTR -Data 'old.contoso.local'
            Add-DnsStubRecord -ZoneName '32.0.10.in-addr.arpa' -Name '5' -RRType CNAME -Data '5.0/26.32.0.10.in-addr.arpa'
            Add-DnsStubRecord -ZoneName '33.0.10.in-addr.arpa' -Name '7' -RRType CNAME -Data '7.0/26.33.0.10.in-addr.arpa'
            Add-DnsStubRecord -ZoneName '34.0.10.in-addr.arpa' -Name '9' -RRType CNAME -Data '9.sub.34.0.10.in-addr.arpa'
        }
    }

    function Get-StubRecord {
        <#
        .SYNOPSIS
            The stored records of one type at one node, as @{ Data; Ttl; Timestamp }.
        #>
        param ([string]$Zone, [string]$Node, [string]$Type)

        InModuleScope DnsTools -Parameters @{ Zone = $Zone; Node = $Node; Type = $Type } {
            param ($Zone, $Node, $Type)
            foreach ($record in @($script:DnsStub.Records[$Zone.ToLowerInvariant()])) {
                if ($null -ne $record -and $record.HostName -eq $Node -and $record.RecordType -eq $Type) {
                    @{ Data = (Get-DnsStubRecordValue -Record $record); Ttl = [int]$record.TimeToLive.TotalSeconds; Timestamp = $record.Timestamp }
                }
            }
        }
    }

    function Get-StubCall {
        <#
        .SYNOPSIS
            The logged bound parameters of every call of a writing stub.
        #>
        param ([string]$Command)

        InModuleScope DnsTools -Parameters @{ Command = $Command } {
            param ($Command)
            foreach ($call in @($script:DnsStub.CallLog[$Command])) {
                if ($null -ne $call) {
                    $call
                }
            }
        }
    }

    function Get-StubCallCount {
        <#
        .SYNOPSIS
            How often a stub was called.
        #>
        param ([string]$Command)

        InModuleScope DnsTools -Parameters @{ Command = $Command } {
            param ($Command)
            [int]$script:DnsStub.Calls[$Command]
        }
    }

    function Get-AddCallCount {
        <#
        .SYNOPSIS
            Calls of every record- and zone-writing stub together.
        #>
        $total = 0
        foreach ($command in @('Add-DnsServerResourceRecordA', 'Add-DnsServerResourceRecordAAAA', 'Add-DnsServerResourceRecordCName', 'Add-DnsServerResourceRecordPtr', 'Remove-DnsServerResourceRecord', 'Add-DnsServerPrimaryZone', 'Set-DnsServerZoneAging')) {
            $total += Get-StubCallCount -Command $command
        }
        $total
    }

    function Test-StubZone {
        <#
        .SYNOPSIS
            Whether the stub store hosts a zone.
        #>
        param ([string]$Zone)

        InModuleScope DnsTools -Parameters @{ Zone = $Zone } {
            param ($Zone)
            $null -ne $script:DnsStub.Zones[$Zone.ToLowerInvariant()]
        }
    }

    function Get-LogLine {
        <#
        .SYNOPSIS
            The change-log lines of a file as objects.
        #>
        param ([string]$Path)

        if (-not (Test-Path -LiteralPath $Path)) {
            return
        }
        foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
            if ($line) {
                $line | ConvertFrom-Json
            }
        }
    }

    function Get-OwnError {
        <#
        .SYNOPSIS
            The errors of a -ErrorVariable that New-DnsEntry wrote itself (the
            silenced "not found" answers of the DnsServer cmdlets are left out).
        #>
        param ([object[]]$ErrorRecord, [string]$Prefix = 'DnsTools.New-DnsEntry.')

        foreach ($record in @($ErrorRecord)) {
            if ($null -ne $record -and [string]$record.FullyQualifiedErrorId -like "$Prefix*") {
                $record
            }
        }
    }
}

AfterAll {
    InModuleScope DnsTools {
        $script:ZoneTableCache = @{}
        $script:CimSessionCache = @{}
        $script:SnapshotIndexCache = @{}
        $script:WriterServer = $null
    }
}

Describe 'New-DnsEntry' {
    BeforeEach {
        Initialize-NewEntryTest
        $script:LogPath = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N') + '\changes.jsonl')
        $script:Common = @{ Server = $script:Server; LogPath = $script:LogPath }
    }

    Context 'Host records' {
        It 'creates a static A record and its PTR record with the zone default TTL' {
            $results = @(New-DnsEntry -Name 'app01.contoso.local' -Address '10.0.16.101' @script:Common)

            ($results | ForEach-Object { '{0}:{1}:{2}:{3}' -f $_.Action, $_.Name, $_.Data, $_.Result }) -join '|' | Should -BeExactly 'AddA:app01.contoso.local:10.0.16.101:Success|AddPtr:101.16.0.10.in-addr.arpa:app01.contoso.local:Success'
            $results[0].Type | Should -BeExactly 'A'
            $results[0].Zone | Should -BeExactly 'contoso.local'
            $results[0].NodeName | Should -BeExactly 'app01'
            $results[1].Type | Should -BeExactly 'PTR'
            $results[1].Zone | Should -BeExactly '16.0.10.in-addr.arpa'
            $results[1].NodeName | Should -BeExactly '101'

            $a = @(Get-StubRecord -Zone 'contoso.local' -Node 'app01' -Type A)
            $a.Count | Should -Be 1
            $a[0]['Data'] | Should -BeExactly '10.0.16.101'
            $a[0]['Ttl'] | Should -Be 3600
            $a[0]['Timestamp'] | Should -BeNullOrEmpty
            @(Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '101' -Type PTR)[0]['Data'] | Should -BeExactly 'app01.contoso.local'

            $call = @(Get-StubCall -Command 'Add-DnsServerResourceRecordA')[0]
            $call.Keys | Should -Not -Contain 'TimeToLive'
            $call.Keys | Should -Not -Contain 'AgeRecord'
            $call.Keys | Should -Not -Contain 'CreatePtr'
            $call['WhatIf'] | Should -BeFalse
            $call['Confirm'] | Should -BeFalse
        }

        It 'passes -TTL (alias TimeToLive) to the A and the PTR record' {
            $null = New-DnsEntry -Name 'app02' -Zone 'contoso.local' -Address '10.0.16.102' -TimeToLive 1200 @script:Common

            @(Get-StubCall -Command 'Add-DnsServerResourceRecordA')[0]['TimeToLive'] | Should -Be (New-TimeSpan -Seconds 1200)
            @(Get-StubCall -Command 'Add-DnsServerResourceRecordPtr')[0]['TimeToLive'] | Should -Be (New-TimeSpan -Seconds 1200)
            @(Get-StubRecord -Zone 'contoso.local' -Node 'app02' -Type A)[0]['Ttl'] | Should -Be 1200
        }

        It 'creates one record per address, forward records first, IPv6 included' {
            $results = @(New-DnsEntry -Name 'multi.contoso.local' -Address '10.0.16.61', '2001:db8::61', '10.0.16.61' @script:Common)

            ($results | ForEach-Object { $_.Action + ':' + $_.Data }) -join '|' | Should -BeExactly 'AddA:10.0.16.61|AddAAAA:2001:db8::61|AddPtr:multi.contoso.local|AddPtr:multi.contoso.local'
            ($results | ForEach-Object { $_.Result } | Sort-Object -Unique) -join ',' | Should -BeExactly 'Success'
            $results[3].Zone | Should -BeExactly '8.b.d.0.1.0.0.2.ip6.arpa'
            $results[3].Name | Should -BeExactly '1.6.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa'
            @(Get-StubRecord -Zone 'contoso.local' -Node 'multi' -Type AAAA)[0]['Data'] | Should -BeExactly '2001:db8::61'
        }

        It 'puts the PTR record into a /16 zone at the two-label node' {
            $results = @(New-DnsEntry -Name 'app05.contoso.local' -Address '172.20.5.9' @script:Common)

            $results[1].Zone | Should -BeExactly '20.172.in-addr.arpa'
            $results[1].NodeName | Should -BeExactly '9.5'
            @(Get-StubRecord -Zone '20.172.in-addr.arpa' -Node '9.5' -Type PTR)[0]['Data'] | Should -BeExactly 'app05.contoso.local'
        }

        It 'creates only the A record with -NoPtr' {
            $results = @(New-DnsEntry -Name 'lab99.contoso.local' -Address '10.0.99.5' -NoPtr @script:Common)

            $results.Count | Should -Be 1
            $results[0].Action | Should -BeExactly 'AddA'
            $results[0].Result | Should -BeExactly 'Success'
            Get-StubCallCount -Command 'Add-DnsServerResourceRecordPtr' | Should -Be 0
        }

        It 'reports AlreadyDone for an identical A and PTR record without writing or asking' {
            Mock -ModuleName DnsTools Read-Host { throw 'Read-Host must not be called.' }

            $results = @(New-DnsEntry -Name 'srv01.contoso.local' -Address '10.0.16.20' -Confirm @script:Common)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'AddA:AlreadyDone|AddPtr:AlreadyDone'
            Get-AddCallCount | Should -Be 0
            Should -Invoke Read-Host -ModuleName DnsTools -Times 0 -Exactly
        }

        It 'reports AlreadyDone with a warning when the existing record has another TTL' {
            $results = @(New-DnsEntry -Name 'srv01.contoso.local' -Address '10.0.16.20' -TTL 1200 @script:Common -WarningVariable warnings -WarningAction SilentlyContinue)

            $results[0].Result | Should -BeExactly 'AlreadyDone'
            @($warnings).Count | Should -Be 1
            [string]$warnings[0] | Should -BeLike '*3600*1200*Set-DnsEntry -TTL 1200*'
            @(Get-StubRecord -Zone 'contoso.local' -Node 'srv01' -Type A)[0]['Ttl'] | Should -Be 3600
        }

        It 'leaves a PTR record that points at another name alone without -ReplacePtr' {
            $results = @(New-DnsEntry -Name 'new30.contoso.local' -Address '10.0.16.30' @script:Common)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'AddA:Success|AddPtr:Skipped'
            $results[1].Error | Should -BeLike "*old.contoso.local*-ReplacePtr*"
            @(Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '30' -Type PTR | ForEach-Object { $_['Data'] }) -join ',' | Should -BeExactly 'old.contoso.local'
        }

        It 'replaces that PTR record with -ReplacePtr (RemovePtr, then AddPtr)' {
            $results = @(New-DnsEntry -Name 'new30.contoso.local' -Address '10.0.16.30' -ReplacePtr @script:Common)

            ($results | ForEach-Object { '{0}:{1}:{2}' -f $_.Action, $_.Data, $_.Result }) -join '|' | Should -BeExactly 'AddA:10.0.16.30:Success|RemovePtr:old.contoso.local:Success|AddPtr:new30.contoso.local:Success'
            $results[1].Name | Should -BeExactly '30.16.0.10.in-addr.arpa'
            @(Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '30' -Type PTR | ForEach-Object { $_['Data'] }) -join ',' | Should -BeExactly 'new30.contoso.local'
        }
    }

    Context 'Preflight' {
        It 'fails with NodeIsCname for a name that is an alias and writes nothing' {
            $results = @(New-DnsEntry -Name 'www.contoso.local' -Address '10.0.16.41' @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            $results.Count | Should -Be 1
            $results[0].Action | Should -BeExactly 'AddA'
            $results[0].Result | Should -BeExactly 'Failed'
            $results[0].Error | Should -BeLike '*alias*web.contoso.local*'
            $own = @(Get-OwnError -ErrorRecord $failures)
            $own.Count | Should -Be 1
            $own[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsEntry.NodeIsCname*'
            Get-AddCallCount | Should -Be 0
        }

        It 'fails with Delegated for a name below an NS delegation' {
            $results = @(New-DnsEntry -Name 'host.branch.contoso.local' -Address '10.0.16.42' @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            $results[0].Result | Should -BeExactly 'Failed'
            $results[0].Error | Should -BeLike "*'branch.contoso.local'*ns1.branch.contoso.local*"
            @(Get-OwnError -ErrorRecord $failures)[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsEntry.Delegated*'
            Get-AddCallCount | Should -Be 0
        }

        It 'fails with NoReverseZone and does not create the A record' {
            $results = @(New-DnsEntry -Name 'lab99.contoso.local' -Address '10.0.99.5' @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            $results.Count | Should -Be 1
            $results[0].Action | Should -BeExactly 'AddA'
            $results[0].Result | Should -BeExactly 'Failed'
            $own = @(Get-OwnError -ErrorRecord $failures)
            $own[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsEntry.NoReverseZone*'
            $own[0].Exception.Message | Should -BeLike '*-NoPtr*-CreateReverseZone*'
            @(Get-StubRecord -Zone 'contoso.local' -Node 'lab99' -Type A).Count | Should -Be 0
            Get-AddCallCount | Should -Be 0
        }

        It 'fails with NoReverseZone for an IPv6 address outside every ip6.arpa zone' {
            $results = @(New-DnsEntry -Name 'lab6.contoso.local' -Address '2001:db9::5' @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            $results[0].Action | Should -BeExactly 'AddAAAA'
            $results[0].Result | Should -BeExactly 'Failed'
            $results[0].Error | Should -BeLike '*0.0.0.0.0.0.0.0.9.b.d.0.1.0.0.2.ip6.arpa (2001:db9::/64)*'
            @(Get-OwnError -ErrorRecord $failures)[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsEntry.NoReverseZone*'
            Get-AddCallCount | Should -Be 0
        }

        It 'says that the A record exists when only its PTR record lacks a reverse zone' {
            InModuleScope DnsTools {
                Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'lab93' -RRType A -Data '10.0.93.5'
            }

            $results = @(New-DnsEntry -Name 'lab93.contoso.local' -Address '10.0.93.5' @script:Common -ErrorAction SilentlyContinue)

            $results[0].Result | Should -BeExactly 'Failed'
            $results[0].Error | Should -BeLike "*although 'lab93.contoso.local' already has its A record*"
        }

        It 'fails the whole item when only one of its addresses has no reverse zone' {
            $results = @(New-DnsEntry -Name 'two.contoso.local' -Address '10.0.16.43', '10.0.99.43' @script:Common -ErrorAction SilentlyContinue)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'AddA:Failed|AddA:Failed'
            Get-AddCallCount | Should -Be 0
        }

        It 'puts the PTR record into a hosted RFC 2317 classless zone' {
            $results = @(New-DnsEntry -Name 'cl05.contoso.local' -Address '10.0.32.5' @script:Common)

            $results[1].Result | Should -BeExactly 'Success'
            $results[1].Zone | Should -BeExactly '0/26.32.0.10.in-addr.arpa'
            $results[1].NodeName | Should -BeExactly '5'
            @(Get-StubRecord -Zone '0/26.32.0.10.in-addr.arpa' -Node '5' -Type PTR)[0]['Data'] | Should -BeExactly 'cl05.contoso.local'
        }

        It 'follows the RFC 2317 CNAME of the parent zone into the hosted zone it points to' {
            $results = @(New-DnsEntry -Name 'cl09.contoso.local' -Address '10.0.34.9' @script:Common)

            $results[1].Zone | Should -BeExactly 'sub.34.0.10.in-addr.arpa'
            $results[1].NodeName | Should -BeExactly '9'
            @(Get-StubRecord -Zone 'sub.34.0.10.in-addr.arpa' -Node '9' -Type PTR)[0]['Data'] | Should -BeExactly 'cl09.contoso.local'
            @(Get-StubRecord -Zone '34.0.10.in-addr.arpa' -Node '9' -Type PTR).Count | Should -Be 0
        }

        It 'fails with Delegated when the RFC 2317 CNAME points into a zone that is not hosted' {
            $results = @(New-DnsEntry -Name 'cl07.contoso.local' -Address '10.0.33.7' @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            $results[0].Result | Should -BeExactly 'Failed'
            $results[0].Error | Should -BeLike '*7.0/26.33.0.10.in-addr.arpa*-NoPtr*'
            @(Get-OwnError -ErrorRecord $failures)[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsEntry.Delegated*'
            Get-AddCallCount | Should -Be 0
        }

        It 'reports <Reason> for <Case>' -ForEach @(
            @{ Case = 'a pattern'; Reason = 'PatternNotAllowed'; Parameters = @{ Name = '*.contoso.local'; Address = '10.0.16.44' } }
            @{ Case = 'a name outside every hosted zone'; Reason = 'ZoneNotFound'; Parameters = @{ Name = 'host.unknown.test'; Address = '10.0.16.44' } }
            @{ Case = 'a bare name without -Zone'; Reason = 'ZoneNotFound'; Parameters = @{ Name = 'host44'; Address = '10.0.16.44' } }
            @{ Case = 'an address as the name'; Reason = 'InvalidInput'; Parameters = @{ Name = '10.0.16.44'; Address = '10.0.16.44' } }
            @{ Case = 'an invalid address'; Reason = 'InvalidInput'; Parameters = @{ Name = 'host44.contoso.local'; Address = '10.0.16' } }
            @{ Case = 'an alias target that is an address'; Reason = 'InvalidInput'; Parameters = @{ Name = 'alias44.contoso.local'; Target = '10.0.16.44' } }
            @{ Case = 'an alias target that is not fully qualified'; Reason = 'InvalidInput'; Parameters = @{ Name = 'alias44.contoso.local'; Target = 'web' } }
        ) {
            $results = @(New-DnsEntry @Parameters @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            $results.Count | Should -Be 1
            $results[0].Result | Should -BeExactly 'Failed'
            $results[0].Error | Should -Not -BeNullOrEmpty
            $own = @(Get-OwnError -ErrorRecord $failures)
            $own.Count | Should -Be 1
            $own[0].FullyQualifiedErrorId | Should -BeLike "DnsTools.New-DnsEntry.$Reason,*"
            Get-AddCallCount | Should -Be 0
        }

        It 'rejects -NoPtr together with -CreateReverseZone' {
            { New-DnsEntry -Name 'x.contoso.local' -Address '10.0.16.45' -NoPtr -CreateReverseZone @script:Common } | Should -Throw '*-NoPtr cannot be combined*'
        }
    }

    Context 'Aliases' {
        It 'creates a CNAME record with -TTL' {
            $results = @(New-DnsEntry -Name 'portal' -Zone 'contoso.local' -Target 'web.contoso.local' -TTL 300 @script:Common)

            $results.Count | Should -Be 1
            $results[0].Action | Should -BeExactly 'AddCName'
            $results[0].Type | Should -BeExactly 'CNAME'
            $results[0].Data | Should -BeExactly 'web.contoso.local'
            $results[0].Result | Should -BeExactly 'Success'
            $record = @(Get-StubRecord -Zone 'contoso.local' -Node 'portal' -Type CNAME)[0]
            $record['Data'] | Should -BeExactly 'web.contoso.local'
            $record['Ttl'] | Should -Be 300
        }

        It 'reports AlreadyDone for the same alias' {
            $results = @(New-DnsEntry -Name 'www.contoso.local' -Target 'WEB.contoso.local.' @script:Common)

            $results[0].Result | Should -BeExactly 'AlreadyDone'
            Get-AddCallCount | Should -Be 0
        }

        It 'fails with NodeIsCname for an alias that points elsewhere' {
            $results = @(New-DnsEntry -Name 'www.contoso.local' -Target 'srv01.contoso.local' @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            $results[0].Result | Should -BeExactly 'Failed'
            $results[0].Error | Should -BeLike '*Set-DnsEntry -Target*'
            @(Get-OwnError -ErrorRecord $failures)[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsEntry.NodeIsCname*'
        }

        It 'fails with CnameCollision for a name with <Existing> records' -ForEach @(
            @{ Existing = 'TXT'; Name = 'txtnode.contoso.local' }
            @{ Existing = 'A'; Name = 'srv01.contoso.local' }
            @{ Existing = 'NS (zone apex)'; Name = 'contoso.local' }
        ) {
            $results = @(New-DnsEntry -Name $Name -Target 'web.contoso.local' @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            $results[0].Action | Should -BeExactly 'AddCName'
            $results[0].Result | Should -BeExactly 'Failed'
            @(Get-OwnError -ErrorRecord $failures)[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsEntry.CnameCollision*'
            Get-AddCallCount | Should -Be 0
        }

        It 'reports CnameCollision when the server refuses the CNAME (9709)' {
            InModuleScope DnsTools {
                $script:DnsStub.BeforeCall['Add-DnsServerResourceRecordCName'] = { Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'race01' -RRType TXT -Data 'late' }
            }

            $results = @(New-DnsEntry -Name 'race01.contoso.local' -Target 'web.contoso.local' @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            $results[0].Result | Should -BeExactly 'Failed'
            @(Get-OwnError -ErrorRecord $failures)[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsEntry.CnameCollision*'
        }
    }

    Context 'Write outcomes' {
        It 'reports Skipped for a read-only (secondary) zone and skips the PTR record' {
            $results = @(New-DnsEntry -Name 'host.fabrikam.com' -Address '10.0.16.150' @script:Common)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'AddA:Skipped|AddPtr:Skipped'
            $results[0].Error | Should -BeLike '*read-only*'
            Get-StubCallCount -Command 'Add-DnsServerResourceRecordPtr' | Should -Be 0
        }

        It 'reports access denied as Failed, never AlreadyDone, and goes on with the next item' {
            InModuleScope DnsTools {
                $script:DnsStub.Fail['Add-DnsServerResourceRecordA'] = @('contoso.local')
                $script:DnsStub.FailCode['Add-DnsServerResourceRecordA'] = 5
            }
            $items = @(
                New-Object PSObject -Property @{ Name = 'deny01.contoso.local'; Address = '10.0.16.151' }
                New-Object PSObject -Property @{ Name = 'deny02.contoso.local'; Address = '2001:db8::152' }
            )

            $results = @($items | New-DnsEntry @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'AddA:Failed|AddPtr:Skipped|AddAAAA:Success|AddPtr:Success'
            $own = @(Get-OwnError -ErrorRecord $failures)
            $own.Count | Should -Be 1
            $own[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsEntry.AddFailed*'
        }

        It 'writes the Failed result and stops the batch when the server is unreachable during a write' {
            InModuleScope DnsTools {
                $script:DnsStub.Fail['Add-DnsServerResourceRecordA'] = @('contoso.local')
                $script:DnsStub.FailCode['Add-DnsServerResourceRecordA'] = 1722
            }
            $items = @(
                New-Object PSObject -Property @{ Name = 'down01.contoso.local'; Address = '10.0.16.153' }
                New-Object PSObject -Property @{ Name = 'down02.contoso.local'; Address = '10.0.16.154' }
            )

            $caught = $null
            try {
                $items | New-DnsEntry @script:Common -OutVariable streamed -ErrorAction SilentlyContinue
            }
            catch {
                $caught = $_
            }

            $caught | Should -Not -BeNullOrEmpty
            $caught.FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsEntry.ServerUnreachable*'
            @($streamed).Count | Should -Be 1
            $streamed[0].Action | Should -BeExactly 'AddA'
            $streamed[0].Result | Should -BeExactly 'Failed'
            Get-StubCallCount -Command 'Add-DnsServerResourceRecordA' | Should -Be 1
            @(Get-LogLine -Path $script:LogPath).Count | Should -Be 1
        }

        It 'stops the batch when the preflight cannot reach the server' {
            InModuleScope DnsTools {
                # The zone table is read first, so only the record reads fail.
                $null = Get-DnsZoneTable -Server 'dc01'
                $script:DnsStub.Fail['Get-DnsServerResourceRecord'] = @('contoso.local')
            }
            $items = @(
                New-Object PSObject -Property @{ Name = 'down03.contoso.local'; Address = '10.0.16.155' }
                New-Object PSObject -Property @{ Name = 'down04.contoso.local'; Address = '10.0.16.156' }
            )

            $caught = $null
            try {
                $items | New-DnsEntry @script:Common -OutVariable streamed -ErrorAction SilentlyContinue
            }
            catch {
                $caught = $_
            }

            $caught.FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsEntry.ServerUnreachable*'
            @($streamed).Count | Should -Be 1
            $streamed[0].Result | Should -BeExactly 'Failed'
            Get-AddCallCount | Should -Be 0
        }
    }

    Context '-CreateReverseZone' {
        It 'creates the /24 zone with the forward zone settings before the PTR record' {
            $results = @(New-DnsEntry -Name 'lab99.contoso.local' -Address '10.0.99.5' -CreateReverseZone -Force @script:Common -WarningVariable warnings -WarningAction SilentlyContinue)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:Success|SetZoneAging:Success|AddA:Success|AddPtr:Success'
            $results[0].Name | Should -BeExactly '99.0.10.in-addr.arpa'
            $results[0].Data | Should -BeExactly '10.0.99.0/24'
            $results[3].Zone | Should -BeExactly '99.0.10.in-addr.arpa'
            $results[3].NodeName | Should -BeExactly '5'

            $zoneCall = @(Get-StubCall -Command 'Add-DnsServerPrimaryZone')[0]
            $zoneCall['NetworkId'] | Should -BeExactly '10.0.99.0/24'
            $zoneCall['ReplicationScope'] | Should -BeExactly 'Custom'
            $zoneCall['DirectoryPartitionName'] | Should -BeExactly 'CorpDnsZones.contoso.local'
            $zoneCall['DynamicUpdate'] | Should -BeExactly 'Secure'
            @(Get-StubRecord -Zone '99.0.10.in-addr.arpa' -Node '5' -Type PTR)[0]['Data'] | Should -BeExactly 'lab99.contoso.local'
            ($warnings | ForEach-Object { [string]$_ }) -join ' ' | Should -BeLike '*DsPollingInterval*'
        }

        It 'creates one zone for two addresses in the same network, and none when the zone already exists' {
            $results = @(New-DnsEntry -Name 'lab98.contoso.local' -Address '10.0.98.5', '10.0.98.6' -CreateReverseZone -Force @script:Common -WarningAction SilentlyContinue)
            $again = @(New-DnsEntry -Name 'lab98b.contoso.local' -Address '10.0.98.7' -CreateReverseZone -Force @script:Common -WarningAction SilentlyContinue)

            @($results | Where-Object { $_.Action -eq 'CreateZone' }).Count | Should -Be 1
            ($results | ForEach-Object { $_.Result } | Sort-Object -Unique) -join ',' | Should -BeExactly 'Success'
            ($again | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'AddA:Success|AddPtr:Success'
            Get-StubCallCount -Command 'Add-DnsServerPrimaryZone' | Should -Be 1
        }

        It 'creates the /64 zone for an IPv6 address' {
            $results = @(New-DnsEntry -Name 'lab6.contoso.local' -Address '2001:db9::5' -CreateReverseZone -Force @script:Common -WarningAction SilentlyContinue)

            $results[0].Name | Should -BeExactly '0.0.0.0.0.0.0.0.9.b.d.0.1.0.0.2.ip6.arpa'
            $results[0].Data | Should -BeExactly '2001:db9::/64'
            $results[3].Result | Should -BeExactly 'Success'
            $results[3].NodeName | Should -BeExactly '5.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0'
            Test-StubZone -Zone '0.0.0.0.0.0.0.0.9.b.d.0.1.0.0.2.ip6.arpa' | Should -BeTrue
        }

        It 'treats the WhatIf zone as present under -WhatIf and writes nothing' {
            Mock -ModuleName DnsTools Write-Host { }

            $results = @(New-DnsEntry -Name 'lab99.contoso.local' -Address '10.0.99.5' -CreateReverseZone -WhatIf @script:Common)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:WhatIf|SetZoneAging:WhatIf|AddA:WhatIf|AddPtr:WhatIf'
            $results[3].Zone | Should -BeExactly '99.0.10.in-addr.arpa'
            $results[3].NodeName | Should -BeExactly '5'
            Test-StubZone -Zone '99.0.10.in-addr.arpa' | Should -BeFalse
            Get-AddCallCount | Should -Be 0
            Should -Invoke Write-Host -ModuleName DnsTools -Times 2 -Exactly -ParameterFilter { [string]$Object -like 'What if:*' }
        }

        It 'skips the records when the forward zone is file-backed and the zone cannot copy its partition' {
            $results = @(New-DnsEntry -Name 'host.file.local' -Address '10.0.91.5' -CreateReverseZone -Force @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:Failed|AddA:Skipped|AddPtr:Skipped'
            $results[0].Error | Should -BeLike '*specify -ReplicationScope*'
            $own = @(Get-OwnError -ErrorRecord $failures)
            $own.Count | Should -Be 1
            $own[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsEntry.ReplicationScopeRequired,*'
            $own[0].Exception.Message | Should -BeLike '*specify -ReplicationScope*'
            Get-AddCallCount | Should -Be 0
            @(Get-StubRecord -Zone 'file.local' -Node 'host' -Type A).Count | Should -Be 0
        }

        It 'skips the records when the zone creation is declined' {
            Mock -ModuleName DnsTools Read-Host { 'n' }

            $results = @(New-DnsEntry -Name 'lab99.contoso.local' -Address '10.0.99.5' -CreateReverseZone @script:Common)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:Skipped|AddA:Skipped|AddPtr:Skipped'
            $results[1].Error | Should -BeLike "*'99.0.10.in-addr.arpa' was not created*"
            Get-AddCallCount | Should -Be 0
            Should -Invoke Read-Host -ModuleName DnsTools -Times 1 -Exactly -ParameterFilter { $Prompt -like 'Create reverse zone*' }
        }

        It 'does not let "Yes to all" at the Medium record prompt approve the High zone creation' {
            Mock -ModuleName DnsTools Read-Host {
                if ($Prompt -like 'Create reverse zone*') {
                    'n'
                }
                else {
                    'a'
                }
            }
            $items = @(
                New-Object PSObject -Property @{ Name = 'yes01.contoso.local'; Address = '10.0.97.1' }
                New-Object PSObject -Property @{ Name = 'yes02.contoso.local'; Address = '10.0.97.2' }
                New-Object PSObject -Property @{ Name = 'yes03.contoso.local'; Address = '10.0.16.160' }
            )

            $results = @($items | New-DnsEntry -CreateReverseZone -Confirm @script:Common)

            Should -Invoke Read-Host -ModuleName DnsTools -Times 1 -Exactly -ParameterFilter { $Prompt -like 'Add DNS records*' }
            Should -Invoke Read-Host -ModuleName DnsTools -Times 2 -Exactly -ParameterFilter { $Prompt -like 'Create reverse zone*' }
            Test-StubZone -Zone '97.0.10.in-addr.arpa' | Should -BeFalse
            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:Skipped|AddA:Skipped|AddPtr:Skipped|CreateZone:Skipped|AddA:Skipped|AddPtr:Skipped|AddA:Success|AddPtr:Success'
        }

        It 'still asks for every zone after [A]ll at the Medium record prompt' {
            Mock -ModuleName DnsTools Read-Host {
                if ($Prompt -like 'Create reverse zone*') {
                    'y'
                }
                else {
                    'a'
                }
            }
            $items = @(
                New-Object PSObject -Property @{ Name = 'med01.contoso.local'; Address = '10.0.97.1' }
                New-Object PSObject -Property @{ Name = 'med02.contoso.local'; Address = '10.0.96.1' }
            )

            $results = @($items | New-DnsEntry -CreateReverseZone -Confirm @script:Common -WarningAction SilentlyContinue)

            Should -Invoke Read-Host -ModuleName DnsTools -Times 1 -Exactly -ParameterFilter { $Prompt -like 'Add DNS records*' }
            Should -Invoke Read-Host -ModuleName DnsTools -Times 1 -Exactly -ParameterFilter { $Prompt -like 'Create reverse zone*97.0.10.in-addr.arpa*' }
            Should -Invoke Read-Host -ModuleName DnsTools -Times 1 -Exactly -ParameterFilter { $Prompt -like 'Create reverse zone*96.0.10.in-addr.arpa*' }
            ($results | ForEach-Object { $_.Result } | Sort-Object -Unique) -join ',' | Should -BeExactly 'Success'
        }

        It 'lets [A]ll at the High zone prompt approve the zone of the next item' {
            Mock -ModuleName DnsTools Read-Host {
                if ($Prompt -like 'Create reverse zone*') {
                    'a'
                }
                else {
                    'y'
                }
            }
            $items = @(
                New-Object PSObject -Property @{ Name = 'all01.contoso.local'; Address = '10.0.97.1' }
                New-Object PSObject -Property @{ Name = 'all02.contoso.local'; Address = '10.0.96.1' }
            )

            $results = @($items | New-DnsEntry -CreateReverseZone -Confirm @script:Common -WarningAction SilentlyContinue)

            Should -Invoke Read-Host -ModuleName DnsTools -Times 1 -Exactly -ParameterFilter { $Prompt -like 'Create reverse zone*' }
            Should -Invoke Read-Host -ModuleName DnsTools -Times 2 -Exactly -ParameterFilter { $Prompt -like 'Add DNS records*' }
            Test-StubZone -Zone '97.0.10.in-addr.arpa' | Should -BeTrue
            Test-StubZone -Zone '96.0.10.in-addr.arpa' | Should -BeTrue
            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:Success|SetZoneAging:Success|AddA:Success|AddPtr:Success|CreateZone:Success|SetZoneAging:Success|AddA:Success|AddPtr:Success'
        }

        It 'gives every Result of a -CreateReverseZone run one BatchId, in the output and in the log' {
            $items = @(
                New-Object PSObject -Property @{ Name = 'batch01.contoso.local'; Address = '10.0.97.1' }
                New-Object PSObject -Property @{ Name = 'batch02.contoso.local'; Address = '10.0.96.1' }
                New-Object PSObject -Property @{ Name = 'batch03.contoso.local'; Address = '10.0.97.3' }
            )

            $results = @($items | New-DnsEntry -CreateReverseZone -Force @script:Common -WarningAction SilentlyContinue)

            @($results | Where-Object { $_.Action -eq 'CreateZone' }).Count | Should -Be 2
            @($results | Where-Object { $_.Action -eq 'SetZoneAging' }).Count | Should -Be 2
            $batchIds = @($results | ForEach-Object { $_.BatchId } | Sort-Object -Unique)
            $batchIds.Count | Should -Be 1
            $lines = @(Get-LogLine -Path $script:LogPath)
            $lines.Count | Should -Be $results.Count
            ($lines | ForEach-Object { $_.BatchId } | Sort-Object -Unique) -join ',' | Should -BeExactly $batchIds[0]
        }

        It 'stops the batch with DnsTools.New-DnsEntry.ServerUnreachable when the zone creation cannot reach the server' {
            InModuleScope DnsTools {
                $script:DnsStub.Fail['Add-DnsServerPrimaryZone'] = @('*')
                $script:DnsStub.FailCode['Add-DnsServerPrimaryZone'] = 1722
            }
            $items = @(
                New-Object PSObject -Property @{ Name = 'down01.contoso.local'; Address = '10.0.97.1' }
                New-Object PSObject -Property @{ Name = 'down02.contoso.local'; Address = '10.0.16.171' }
            )

            $caught = $null
            try {
                $items | New-DnsEntry -CreateReverseZone -Force @script:Common -OutVariable streamed -ErrorAction SilentlyContinue
            }
            catch {
                $caught = $_
            }

            $caught.FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsEntry.ServerUnreachable,*'
            $caught.Exception.Message | Should -BeLike "The DNS server 'dc01' cannot be reached:*The run was stopped*"
            ($streamed | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:Failed'
            @(Get-StubRecord -Zone 'contoso.local' -Node 'down02' -Type A).Count | Should -Be 0
        }

        It 'reports a failed zone creation per item and goes on with the next item' {
            InModuleScope DnsTools {
                $script:DnsStub.Fail['Add-DnsServerPrimaryZone'] = @('*')
                $script:DnsStub.FailCode['Add-DnsServerPrimaryZone'] = 5
            }
            $items = @(
                New-Object PSObject -Property @{ Name = 'deny01.contoso.local'; Address = '10.0.97.1' }
                New-Object PSObject -Property @{ Name = 'deny02.contoso.local'; Address = '10.0.16.172' }
            )

            $results = @($items | New-DnsEntry -CreateReverseZone -Force @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:Failed|AddA:Skipped|AddPtr:Skipped|AddA:Success|AddPtr:Success'
            $own = @(Get-OwnError -ErrorRecord $failures)
            $own.Count | Should -Be 1
            $own[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsEntry.CreateFailed,*'
        }
    }

    Context 'Pipeline and input file' {
        It 'binds Import-Csv rows by property name; an empty TTL cell means "not given"' {
            $csvPath = Join-Path -Path $TestDrive -ChildPath 'pipeline.csv'
            Set-Content -LiteralPath $csvPath -Encoding UTF8 -Value @(
                'Name,Address,TTL,Zone'
                'ppl01,10.0.16.111,1200,contoso.local'
                'ppl02.contoso.local,10.0.16.112,,'
            )

            $results = @(Import-Csv -LiteralPath $csvPath | New-DnsEntry @script:Common)

            ($results | ForEach-Object { $_.Action + ':' + $_.Name + ':' + $_.Result }) -join '|' | Should -BeExactly 'AddA:ppl01.contoso.local:Success|AddPtr:111.16.0.10.in-addr.arpa:Success|AddA:ppl02.contoso.local:Success|AddPtr:112.16.0.10.in-addr.arpa:Success'
            $calls = @(Get-StubCall -Command 'Add-DnsServerResourceRecordA')
            $calls[0]['TimeToLive'] | Should -Be (New-TimeSpan -Seconds 1200)
            $calls[1].Keys | Should -Not -Contain 'TimeToLive'
        }

        It 'binds host and alias objects in one pipeline to their own parameter sets' {
            $items = @(
                New-Object PSObject -Property @{ Name = 'mix01.contoso.local'; Address = '10.0.16.113'; TimeToLive = 900 }
                New-Object PSObject -Property @{ Name = 'mix02.contoso.local'; Target = 'mix01.contoso.local' }
            )

            $results = @($items | New-DnsEntry @script:Common)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'AddA:Success|AddPtr:Success|AddCName:Success'
            @(Get-StubCall -Command 'Add-DnsServerResourceRecordA')[0]['TimeToLive'] | Should -Be (New-TimeSpan -Seconds 900)
            @(Get-StubCall -Command 'Add-DnsServerResourceRecordCName')[0].Keys | Should -Not -Contain 'TimeToLive'
        }

        It 'creates every row of a 10-row CSV file with -InputFile, a non-ASCII name included' {
            $csvPath = Join-Path -Path $TestDrive -ChildPath 'entries.csv'
            Set-Content -LiteralPath $csvPath -Encoding UTF8 -Value @(
                'Name,Address,Target,TTL,Zone'
                'kåken,10.0.16.201,,,contoso.local'
                'file01.contoso.local,10.0.16.202,,600,'
                'file02,10.0.16.203,,,contoso.local'
                'file03.contoso.local,2001:db8::203,,,'
                'falias01.contoso.local,,file01.contoso.local,,'
                'falias02,,web.contoso.local,300,contoso.local'
                'file04.contoso.local,10.0.16.204,,,'
                'file05.contoso.local,172.20.5.205,,,'
                'file06.contoso.local,10.0.32.6,,,'
                'file07.contoso.local,10.0.16.207,,,'
            )

            $results = @(New-DnsEntry -InputFile $csvPath @script:Common)

            $results.Count | Should -Be 18
            ($results | ForEach-Object { $_.Result } | Sort-Object -Unique) -join ',' | Should -BeExactly 'Success'
            @($results | Where-Object { $_.Action -eq 'AddCName' }).Count | Should -Be 2
            $results[0].Name | Should -BeExactly 'kåken.contoso.local'
            @(Get-StubRecord -Zone 'contoso.local' -Node 'kåken' -Type A)[0]['Data'] | Should -BeExactly '10.0.16.201'
            @(Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '201' -Type PTR)[0]['Data'] | Should -BeExactly 'kåken.contoso.local'
            @(Get-StubRecord -Zone 'contoso.local' -Node 'file01' -Type A)[0]['Ttl'] | Should -Be 600
            @(Get-StubRecord -Zone 'contoso.local' -Node 'falias02' -Type CNAME)[0]['Ttl'] | Should -Be 300
        }

        It 'reports a bad row as Failed and goes on with the rest of the file' {
            $csvPath = Join-Path -Path $TestDrive -ChildPath 'bad.csv'
            Set-Content -LiteralPath $csvPath -Encoding UTF8 -Value @(
                'Name;Address;Target;TTL'
                'bad01.contoso.local;10.0.16.300;;'
                'bad02.contoso.local;10.0.16.211;;ten'
                'bad03.contoso.local;10.0.16.212;bad.contoso.local;'
                ';10.0.16.213;;'
                'bad04.contoso.local;;;'
                'good01.contoso.local;10.0.16.214;;'
            )

            $results = @(New-DnsEntry -InputFile $csvPath @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'AddA:Failed|AddA:Failed|AddCName:Failed|AddA:Failed|AddA:Failed|AddA:Failed|AddA:Success|AddPtr:Success'
            $own = @(Get-OwnError -ErrorRecord $failures)
            $own.Count | Should -Be 5
            ($own | ForEach-Object { ([string]$_.FullyQualifiedErrorId).Split(',')[0] } | Sort-Object -Unique) -join ',' | Should -BeExactly 'DnsTools.New-DnsEntry.InvalidInput'
        }
    }

    Context 'Confirmation, -WhatIf, -Force and -Delay' {
        BeforeEach {
            $script:Items = @(
                New-Object PSObject -Property @{ Name = 'gate01.contoso.local'; Address = '10.0.16.221' }
                New-Object PSObject -Property @{ Name = 'gate02.contoso.local'; Address = '10.0.16.222' }
            )
        }

        It 'shows one gate line per item under -WhatIf, returns WhatIf per sub-operation, logs it and writes nothing' {
            Mock -ModuleName DnsTools Write-Host { }

            $results = @($script:Items | New-DnsEntry -WhatIf @script:Common)

            Should -Invoke Write-Host -ModuleName DnsTools -Times 2 -Exactly -ParameterFilter { [string]$Object -like 'What if: Performing the operation "Add DNS records" on target "gate0?.contoso.local: add 1 A, 1 PTR".' }
            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'AddA:WhatIf|AddPtr:WhatIf|AddA:WhatIf|AddPtr:WhatIf'
            Get-AddCallCount | Should -Be 0
            @(Get-StubRecord -Zone 'contoso.local' -Node 'gate01' -Type A).Count | Should -Be 0
            $lines = @(Get-LogLine -Path $script:LogPath)
            $lines.Count | Should -Be 4
            ($lines | ForEach-Object { $_.Result } | Sort-Object -Unique) -join ',' | Should -BeExactly 'WhatIf'
        }

        It 'leaves the session''s writer server empty under -WhatIf, also with -CreateReverseZone' {
            Mock -ModuleName DnsTools Write-Host { }

            $null = $script:Items | New-DnsEntry -WhatIf @script:Common
            $null = New-DnsEntry -Name 'lab99.contoso.local' -Address '10.0.99.5' -CreateReverseZone -WhatIf @script:Common
            InModuleScope DnsTools { $script:WriterServer } | Should -BeNullOrEmpty

            $null = New-DnsEntry -Name 'lab99.contoso.local' -Address '10.0.99.5' -CreateReverseZone -Force @script:Common -WarningAction SilentlyContinue
            InModuleScope DnsTools { $script:WriterServer } | Should -BeExactly 'dc01'
        }

        It 'never prompts with -Force or -Confirm:$false, also for a High zone creation' {
            Mock -ModuleName DnsTools Read-Host { throw 'Read-Host must not be called.' }

            $null = New-DnsEntry -Name 'force01.contoso.local' -Address '10.0.16.223' -Confirm -Force @script:Common
            $null = New-DnsEntry -Name 'force02.contoso.local' -Address '10.0.16.224' -Confirm:$false @script:Common
            $null = New-DnsEntry -Name 'force03.contoso.local' -Address '10.0.96.1' -CreateReverseZone -Confirm -Force @script:Common -WarningAction SilentlyContinue
            $null = New-DnsEntry -Name 'force04.contoso.local' -Address '10.0.95.1' -CreateReverseZone -Confirm:$false @script:Common -WarningAction SilentlyContinue

            Should -Invoke Read-Host -ModuleName DnsTools -Times 0 -Exactly
            Test-StubZone -Zone '96.0.10.in-addr.arpa' | Should -BeTrue
            Test-StubZone -Zone '95.0.10.in-addr.arpa' | Should -BeTrue
            @(Get-StubRecord -Zone 'contoso.local' -Node 'force02' -Type A).Count | Should -Be 1
        }

        It 'asks once per item with -Confirm and skips the item when declined' {
            Mock -ModuleName DnsTools Read-Host { 'n' }

            $results = @($script:Items | New-DnsEntry -Confirm @script:Common)

            Should -Invoke Read-Host -ModuleName DnsTools -Times 2 -Exactly -ParameterFilter { $Prompt -like "Add DNS records*gate0?.contoso.local: add 1 A, 1 PTR*" }
            ($results | ForEach-Object { $_.Result } | Sort-Object -Unique) -join ',' | Should -BeExactly 'Skipped'
            $results[0].Error | Should -BeExactly 'Declined at the confirmation prompt.'
            Get-AddCallCount | Should -Be 0
        }

        It 'ends the batch on [S]top' {
            Mock -ModuleName DnsTools Read-Host { 's' }

            { $script:Items | New-DnsEntry -Confirm @script:Common } | Should -Throw '*stopped by the operator*'

            Should -Invoke Read-Host -ModuleName DnsTools -Times 1 -Exactly
            Get-AddCallCount | Should -Be 0
        }

        It 'ends the batch with one terminating error when the session cannot prompt' {
            Mock -ModuleName DnsTools Read-Host { throw 'Windows PowerShell is in NonInteractive mode.' }

            $caught = $null
            try {
                $script:Items | New-DnsEntry -Confirm @script:Common -OutVariable streamed -ErrorAction SilentlyContinue -ErrorVariable failures
            }
            catch {
                $caught = $_
            }

            $caught.FullyQualifiedErrorId | Should -BeLike 'DnsTools.Confirm.NonInteractive*'
            $caught.Exception.Message | Should -BeLike '*-Force*'
            Should -Invoke Read-Host -ModuleName DnsTools -Times 1 -Exactly
            @($streamed).Count | Should -Be 0
            # PowerShell appends one terminating error to the -ErrorVariable once per
            # nesting level; what matters is that no item reports an error of its own.
            @(Get-OwnError -ErrorRecord $failures).Count | Should -Be 0
            Get-AddCallCount | Should -Be 0
        }

        It 'calls Start-Sleep once per item with -Delay, and not under -WhatIf' {
            Mock -ModuleName DnsTools Start-Sleep { }
            Mock -ModuleName DnsTools Write-Host { }
            $items = @($script:Items) + @(New-Object PSObject -Property @{ Name = 'gate03.contoso.local'; Address = '10.0.99.3' })

            $null = $items | New-DnsEntry -Delay 2 -Force @script:Common -ErrorAction SilentlyContinue
            Should -Invoke Start-Sleep -ModuleName DnsTools -Times 3 -Exactly -ParameterFilter { $Seconds -eq 2 }

            $null = $items | New-DnsEntry -Delay 2 -WhatIf @script:Common -ErrorAction SilentlyContinue
            Should -Invoke Start-Sleep -ModuleName DnsTools -Times 3 -Exactly -ParameterFilter { $Seconds -eq 2 }
        }
    }

    Context 'Result objects and the change log' {
        It 'gives every Result the properties of CONTRACTS.md 12.2 in order and writes one log line per Result to -LogPath' {
            $items = @(
                New-Object PSObject -Property @{ Name = 'log01.contoso.local'; Address = '10.0.16.231' }
                New-Object PSObject -Property @{ Name = 'srv01.contoso.local'; Address = '10.0.16.20' }
                New-Object PSObject -Property @{ Name = 'log02.contoso.local'; Target = 'web.contoso.local' }
                New-Object PSObject -Property @{ Name = 'www.contoso.local'; Address = '10.0.16.232' }
            )

            $results = @($items | New-DnsEntry @script:Common -ErrorAction SilentlyContinue)
            $results += @(New-DnsEntry -Name 'log03.contoso.local' -Address '10.0.94.1' -CreateReverseZone -Force @script:Common -WarningAction SilentlyContinue)

            $results.Count | Should -Be 10
            foreach ($result in $results) {
                $result.PSObject.TypeNames[0] | Should -BeExactly 'DnsTools.Result'
                @($result.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly ($script:ResultProperties -join ',')
                $result.Server | Should -BeExactly 'dc01'
                { [guid]$result.Id } | Should -Not -Throw
                { [guid]$result.BatchId } | Should -Not -Throw
                $result.Timestamp | Should -BeOfType [datetime]
            }
            @($results[0..5] | ForEach-Object { $_.BatchId } | Sort-Object -Unique).Count | Should -Be 1
            # The zone created by -CreateReverseZone belongs to the run that created it.
            @($results[6..9] | ForEach-Object { $_.BatchId } | Sort-Object -Unique).Count | Should -Be 1
            $results[6].BatchId | Should -Not -Be $results[0].BatchId

            $lines = @(Get-LogLine -Path $script:LogPath)
            $lines.Count | Should -Be $results.Count
            foreach ($line in $lines) {
                @($line.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly ($script:LogKeys -join ',')
                $line.Name | Should -Not -BeNullOrEmpty
                $line.Operator | Should -Not -BeNullOrEmpty
            }
            ($lines | ForEach-Object { $_.Id }) -join ',' | Should -BeExactly (($results | ForEach-Object { $_.Id }) -join ',')
            $lines[0].After.Data | Should -BeExactly '10.0.16.231'
            $lines[0].After.IsStatic | Should -BeTrue
            $lines[2].Result | Should -BeExactly 'AlreadyDone'
            $lines[2].Before.Data | Should -BeExactly '10.0.16.20'
        }
    }
}
