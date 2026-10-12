#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
<#
    Tests for Set-DnsEntry (CONTRACTS.md section 13.6, with the shared rules of
    13.9, the error contract of section 5, the gate of section 10, the change log of
    section 11 and the Result object of section 12.2).

    The stubs are loaded into the module scope once. Initialize-SetTest points the
    snapshot root, the stub export root and the change log at a fresh folder per
    test, clears every cache and builds this environment on the server
    $env:COMPUTERNAME (Export-DnsZoneFile treats it as this computer, see
    Snapshot.Tests.ps1):

      contoso.local (primary)
        dc01     A 10.0.16.10                    (no PTR)
        srv01    A 10.0.16.20                    one A; PTR in the /24 and in the shadowed /16
        multi    A 10.0.16.21, A 10.0.16.22      two A; PTR 21 -> multi
        dual     A 10.0.16.23, AAAA 2001:db8::23 A + AAAA, both with a PTR
        dyn01    A 10.0.16.30 (dynamic)          PTR 30 -> dyn01 (dynamic)
        web      A 10.0.16.40                    PTR 40 -> web
        www      CNAME web.contoso.local
        taken    A 10.0.16.50                    PTR 50 -> taken (a new address with a PTR to another name)
        short    A 10.0.16.70, TTL 300           PTR 70 -> short, TTL 300
      16.0.10.in-addr.arpa (primary /24): 20, 21, 23, 30, 40, 50, 70 as above;
        90 PTR one.contoso.local and two.contoso.local (two PTR records)
      0.10.in-addr.arpa (primary /16, shadowed by the /24): 20.16 PTR srv01.contoso.local
      8.b.d.0.1.0.0.2.ip6.arpa (primary): PTR of 2001:db8::23 -> dual
      18.0.10.in-addr.arpa (secondary): 5 PTR old.contoso.local
      fabrikam.com (secondary): ro A 192.0.2.10

    A CNAME whose new target would loop is www pointed at itself; the stub raises
    WIN32 9707 for it, as the server does.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\DnsLathund.psd1" -Force
    $script:StubPath = Join-Path -Path $PSScriptRoot -ChildPath 'Stubs\DnsServerStubs.ps1'
    $script:Server = $env:COMPUTERNAME.ToLowerInvariant()
    $script:ResultProperties = @('Action', 'Name', 'Type', 'Data', 'Result', 'Error', 'Zone', 'NodeName', 'Server', 'Id', 'BatchId', 'Timestamp')
    $script:LogKeys = @('Id', 'BatchId', 'Timestamp', 'Operator', 'Server', 'Action', 'Zone', 'NodeName', 'Name', 'Type', 'Data', 'Before', 'After', 'Result', 'Error')
    $script:DynamicText = 'Dynamic record, owned by the client or the DHCP server; re-register it instead, or pass -IncludeDynamic.'
    $script:WriteCommands = @('Set-DnsServerResourceRecord', 'Remove-DnsServerResourceRecord', 'Add-DnsServerResourceRecordA', 'Add-DnsServerResourceRecordAAAA', 'Add-DnsServerResourceRecordCName', 'Add-DnsServerResourceRecordPtr')

    InModuleScope DnsLathund -Parameters @{ StubPath = $script:StubPath } {
        param ($StubPath)
        . $StubPath
    }

    function Initialize-SetTest {
        <#
        .SYNOPSIS
            Fresh stub store and folders under -Root, empty caches, and the
            environment described at the top of this file.
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
            $script:WriterServer = $null

            Add-DnsStubZone -Name 'contoso.local'
            Add-DnsStubZone -Name '16.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '0.10.in-addr.arpa'
            Add-DnsStubZone -Name '8.b.d.0.1.0.0.2.ip6.arpa'
            Add-DnsStubZone -Name '18.0.10.in-addr.arpa' -ZoneType Secondary -IsDsIntegrated $false
            Add-DnsStubZone -Name 'fabrikam.com' -ZoneType Secondary -IsDsIntegrated $false

            $zone = 'contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '@' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'dc01' -RRType A -Data '10.0.16.10'
            Add-DnsStubRecord -ZoneName $zone -Name 'srv01' -RRType A -Data '10.0.16.20'
            Add-DnsStubRecord -ZoneName $zone -Name 'multi' -RRType A -Data '10.0.16.21'
            Add-DnsStubRecord -ZoneName $zone -Name 'multi' -RRType A -Data '10.0.16.22'
            Add-DnsStubRecord -ZoneName $zone -Name 'dual' -RRType A -Data '10.0.16.23'
            Add-DnsStubRecord -ZoneName $zone -Name 'dual' -RRType AAAA -Data '2001:db8::23'
            Add-DnsStubRecord -ZoneName $zone -Name 'dyn01' -RRType A -Data '10.0.16.30' -AgeHours 3636304
            Add-DnsStubRecord -ZoneName $zone -Name 'web' -RRType A -Data '10.0.16.40'
            Add-DnsStubRecord -ZoneName $zone -Name 'www' -RRType CNAME -Data 'web.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'taken' -RRType A -Data '10.0.16.50'
            Add-DnsStubRecord -ZoneName $zone -Name 'short' -RRType A -Data '10.0.16.70' -TimeToLive 300

            $zone = '16.0.10.in-addr.arpa'
            Add-DnsStubRecord -ZoneName $zone -Name '20' -RRType PTR -Data 'srv01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '21' -RRType PTR -Data 'multi.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '23' -RRType PTR -Data 'dual.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '30' -RRType PTR -Data 'dyn01.contoso.local' -AgeHours 3636304
            Add-DnsStubRecord -ZoneName $zone -Name '40' -RRType PTR -Data 'web.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '50' -RRType PTR -Data 'taken.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '70' -RRType PTR -Data 'short.contoso.local' -TimeToLive 300
            Add-DnsStubRecord -ZoneName $zone -Name '90' -RRType PTR -Data 'one.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '90' -RRType PTR -Data 'two.contoso.local'

            # The /16 also covers 10.0.16.x, so this PTR is shadowed by the /24.
            Add-DnsStubRecord -ZoneName '0.10.in-addr.arpa' -Name '20.16' -RRType PTR -Data 'srv01.contoso.local'

            $ip6Zone = '8.b.d.0.1.0.0.2.ip6.arpa'
            $ip6Node = Get-DnsReverseNodeName -ReverseName (ConvertTo-DnsReverseName -Address '2001:db8::23')['ReverseName'] -ZoneName $ip6Zone
            Add-DnsStubRecord -ZoneName $ip6Zone -Name $ip6Node -RRType PTR -Data 'dual.contoso.local'

            Add-DnsStubRecord -ZoneName '18.0.10.in-addr.arpa' -Name '5' -RRType PTR -Data 'old.contoso.local'
            Add-DnsStubRecord -ZoneName 'fabrikam.com' -Name 'ro' -RRType A -Data '192.0.2.10'
        }
    }

    function Get-StubRecord {
        <#
        .SYNOPSIS
            The records of one node and type in the stub store, as Get-DnsLiveRecord
            hashtables (Data normalised, Ttl in seconds, Timestamp).
        #>
        param ([string]$Zone, [string]$Node, [string]$Type)

        InModuleScope DnsLathund -Parameters @{ Zone = $Zone; Node = $Node; Type = $Type } {
            param ($Zone, $Node, $Type)
            Get-DnsLiveRecord -ServerParameter @{ ComputerName = 'stub' } -ZoneName $Zone -NodeName $Node -RRType $Type
        }
    }

    function Get-StubCallCount {
        <#
        .SYNOPSIS
            Number of calls of one stub command since the store was reset.
        #>
        param ([string]$Command)

        InModuleScope DnsLathund -Parameters @{ Command = $Command } {
            param ($Command)
            [int]$script:DnsStub.Calls[$Command]
        }
    }

    function Get-WriteCallCount {
        <#
        .SYNOPSIS
            Number of calls of all writing record stubs together.
        #>
        $total = 0
        foreach ($command in $script:WriteCommands) {
            $total += Get-StubCallCount -Command $command
        }
        $total
    }

    function Get-StubCallLog {
        <#
        .SYNOPSIS
            The bound parameters of every call of one writing stub, in call order.
        #>
        param ([string]$Command)

        InModuleScope DnsLathund -Parameters @{ Command = $Command } {
            param ($Command)
            @($script:DnsStub.CallLog[$Command])
        }
    }

    function Set-StubFailure {
        <#
        .SYNOPSIS
            Makes every call of one stub fail with a Win32 code.
        #>
        param ([string]$Command, [int]$Code)

        InModuleScope DnsLathund -Parameters @{ Command = $Command; Code = $Code } {
            param ($Command, $Code)
            $script:DnsStub.Fail[$Command] = @('*')
            $script:DnsStub.FailCode[$Command] = $Code
        }
    }

    function Read-ChangeLog {
        <#
        .SYNOPSIS
            Every line of the change log as an object; empty when the file does not exist.
        #>
        param ([string]$Path)

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return @()
        }
        @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }

    function Get-Outcome {
        <#
        .SYNOPSIS
            'Action Type Name Result' per Result object, for compact assertions.
        #>
        param ($Results)

        @(foreach ($result in @($Results)) {
                '{0} {1} {2} {3}' -f $result.Action, $result.Type, $result.Name, $result.Result
            })
    }

    function Get-SetError {
        <#
        .SYNOPSIS
            The errors that Set-DnsEntry itself wrote, from an -ErrorVariable.
        #>
        param ($ErrorRecords)

        @($ErrorRecords | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -and $_.FullyQualifiedErrorId -like 'DnsLathund.Set-DnsEntry.*' })
    }

    function Invoke-Collected {
        <#
        .SYNOPSIS
            Runs a script block and keeps the objects it emitted before a terminating
            error, together with that error.
        #>
        param ([scriptblock]$ScriptBlock)

        $list = New-Object -TypeName System.Collections.ArrayList
        $caught = $null
        try {
            & $ScriptBlock | ForEach-Object { $null = $list.Add($_) }
        }
        catch {
            $caught = $_
        }
        @{ Results = @($list); Error = $caught }
    }
}

AfterAll {
    InModuleScope DnsLathund {
        $script:SnapshotRoot = $null
        $script:DnsServerExportRoot = Join-Path $env:windir 'System32\dns'
        $script:SnapshotIndexCache = @{}
        $script:ZoneTableCache = @{}
        $script:CimSessionCache = @{}
        $script:WriterServer = $null
    }
}

Describe 'Set-DnsEntry' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $script:LogPath = Join-Path -Path $script:Root -ChildPath 'log\changes.jsonl'
        Initialize-SetTest -Root $script:Root
        Mock Write-Host { } -ModuleName DnsLathund
        # Any prompt that a test does not expect fails it (Confirm.NonInteractive).
        Mock Read-Host { throw 'Read-Host was called.' } -ModuleName DnsLathund
    }

    Context 'Preconditions (terminating errors before any server round-trip)' {
        It 'throws NoChangeRequested without -TTL, -Address, -PtrTarget or -Target' {
            { Set-DnsEntry -Identity 'srv01.contoso.local' -Server $script:Server -LogPath $script:LogPath } |
                Should -Throw -ErrorId 'DnsLathund.Set-DnsEntry.NoChangeRequested,Set-DnsEntry'

            Get-StubCallCount -Command 'Get-DnsServerZone' | Should -Be 0
            Get-StubCallCount -Command 'Get-DnsServerResourceRecord' | Should -Be 0
            Test-Path -LiteralPath $script:LogPath | Should -BeFalse
        }

        It 'throws ConflictingChanges for -<First> together with -<Second>' -TestCases @(
            @{ First = 'Address'; Second = 'Target' }
            @{ First = 'Address'; Second = 'PtrTarget' }
            @{ First = 'PtrTarget'; Second = 'Target' }
        ) {
            $values = @{ Address = '10.0.16.99'; PtrTarget = 'srv01.contoso.local'; Target = 'web.contoso.local' }
            $splat = @{ Identity = 'srv01.contoso.local'; Server = $script:Server; Force = $true }
            $splat[$First] = $values[$First]
            $splat[$Second] = $values[$Second]

            { Set-DnsEntry @splat } | Should -Throw -ErrorId 'DnsLathund.Set-DnsEntry.ConflictingChanges,Set-DnsEntry'
            Get-StubCallCount -Command 'Get-DnsServerZone' | Should -Be 0
        }

        It 'throws InvalidAddress for -Address <Value>' -TestCases @(
            @{ Value = 'srv02' }
            @{ Value = '10.1' }
            @{ Value = '300.1.1.1' }
        ) {
            { Set-DnsEntry -Identity 'srv01.contoso.local' -Address $Value -Server $script:Server -Force } |
                Should -Throw -ErrorId 'DnsLathund.Set-DnsEntry.InvalidAddress,Set-DnsEntry'
            Get-StubCallCount -Command 'Get-DnsServerZone' | Should -Be 0
        }

        It 'throws InvalidName for -<Parameter> <Value>' -TestCases @(
            @{ Parameter = 'Target'; Value = 'web02' }
            @{ Parameter = 'PtrTarget'; Value = 'srv01' }
            @{ Parameter = 'Target'; Value = '*.contoso.local' }
        ) {
            $splat = @{ Identity = 'www.contoso.local'; Server = $script:Server; Force = $true }
            $splat[$Parameter] = $Value

            { Set-DnsEntry @splat } | Should -Throw -ErrorId 'DnsLathund.Set-DnsEntry.InvalidName,Set-DnsEntry'
            Get-StubCallCount -Command 'Get-DnsServerZone' | Should -Be 0
        }
    }

    Context '-TTL' {
        It 'sets the TTL of the A record and of every PTR that points at the name, shadowed /16 included, in place' {
            $results = @(Set-DnsEntry -Identity 'srv01.contoso.local' -TTL 300 -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @(
                'SetTtl A srv01.contoso.local Success'
                'SetTtl PTR 20.16.0.10.in-addr.arpa Success'
                'SetTtl PTR 20.16.0.10.in-addr.arpa Success'
            )
            @($results | ForEach-Object { $_.Zone }) | Should -Be @('contoso.local', '16.0.10.in-addr.arpa', '0.10.in-addr.arpa')
            @($results | ForEach-Object { $_.NodeName }) | Should -Be @('srv01', '20', '20.16')
            @($results | ForEach-Object { $_.Data }) | Should -Be @('10.0.16.20', 'srv01.contoso.local', 'srv01.contoso.local')

            (Get-StubRecord -Zone 'contoso.local' -Node 'srv01' -Type 'A').Ttl | Should -Be 300
            (Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '20' -Type 'PTR').Ttl | Should -Be 300
            (Get-StubRecord -Zone '0.10.in-addr.arpa' -Node '20.16' -Type 'PTR').Ttl | Should -Be 300
            Get-StubCallCount -Command 'Set-DnsServerResourceRecord' | Should -Be 3
            Get-StubCallCount -Command 'Remove-DnsServerResourceRecord' | Should -Be 0
            Get-StubCallCount -Command 'Add-DnsServerResourceRecordA' | Should -Be 0

            $lines = @(Read-ChangeLog -Path $script:LogPath)
            $lines[0].Before.Ttl | Should -Be 3600
            $lines[0].After.Ttl | Should -Be 300
        }

        It 'sets A, AAAA and both PTR records of a node with an A and an AAAA record' {
            $results = @(Set-DnsEntry -Identity 'dual.contoso.local' -TTL 120 -Server $script:Server -LogPath $script:LogPath)

            $outcome = Get-Outcome $results
            $outcome.Count | Should -Be 4
            $outcome[0] | Should -Be 'SetTtl A dual.contoso.local Success'
            $outcome[1] | Should -Be 'SetTtl AAAA dual.contoso.local Success'
            $outcome | Should -Contain 'SetTtl PTR 23.16.0.10.in-addr.arpa Success'
            @($results | Where-Object { $_.Type -eq 'PTR' -and $_.Zone -eq '8.b.d.0.1.0.0.2.ip6.arpa' }).Count | Should -Be 1
            (Get-StubRecord -Zone 'contoso.local' -Node 'dual' -Type 'AAAA').Ttl | Should -Be 120
        }

        It 'changes only the exact record of an entry piped from Get-DnsEntry, and its PTR' {
            $entry = Get-DnsEntry -Find 'multi.contoso.local' -Server $script:Server | Where-Object { $_.Data -eq '10.0.16.21' }

            $results = @($entry | Set-DnsEntry -TTL 900 -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @(
                'SetTtl A multi.contoso.local Success'
                'SetTtl PTR 21.16.0.10.in-addr.arpa Success'
            )
            $ttlByAddress = @{}
            foreach ($record in @(Get-StubRecord -Zone 'contoso.local' -Node 'multi' -Type 'A')) {
                $ttlByAddress[$record.Data] = $record.Ttl
            }
            $ttlByAddress['10.0.16.21'] | Should -Be 900
            $ttlByAddress['10.0.16.22'] | Should -Be 3600
        }

        It 'sets the TTL of an alias (CNAME); an alias has no PTR records' {
            $results = @(Set-DnsEntry -Identity 'www' -Zone 'contoso.local' -TTL 60 -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @('SetTtl CNAME www.contoso.local Success')
            (Get-StubRecord -Zone 'contoso.local' -Node 'www' -Type 'CNAME').Ttl | Should -Be 60
        }

        It 'reports AlreadyDone for records that already have the TTL, without writing or prompting' {
            $results = @(Set-DnsEntry -Identity 'short.contoso.local' -TTL 300 -Server $script:Server -LogPath $script:LogPath -Confirm)

            Get-Outcome $results | Should -Be @(
                'SetTtl A short.contoso.local AlreadyDone'
                'SetTtl PTR 70.16.0.10.in-addr.arpa AlreadyDone'
            )
            Get-WriteCallCount | Should -Be 0
            Should -Invoke Read-Host -ModuleName DnsLathund -Times 0 -Exactly
        }

        It 'sets the TTL of the PTR record of an address' {
            $results = @(Set-DnsEntry -Identity '10.0.16.40' -TTL 120 -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @('SetTtl PTR 40.16.0.10.in-addr.arpa Success')
            (Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '40' -Type 'PTR').Ttl | Should -Be 120
            (Get-StubRecord -Zone 'contoso.local' -Node 'web' -Type 'A').Ttl | Should -Be 3600
        }

        It 'fails with NotFound for <Identity>' -TestCases @(
            @{ Identity = 'nothere.contoso.local' }
            @{ Identity = '10.0.16.10' }
        ) {
            $results = @(Set-DnsEntry -Identity $Identity -TTL 120 -Server $script:Server -LogPath $script:LogPath -ErrorVariable errors -ErrorAction SilentlyContinue)

            $setErrors = Get-SetError $errors
            $setErrors.Count | Should -Be 1
            $setErrors[0].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Set-DnsEntry.NotFound,*'
            $setErrors[0].CategoryInfo.Category | Should -Be 'ObjectNotFound'
            $results.Count | Should -Be 1
            $results[0].Action | Should -Be 'SetTtl'
            $results[0].Result | Should -Be 'Failed'
            $results[0].Name | Should -Be $Identity
            Get-WriteCallCount | Should -Be 0
        }
    }

    Context '-Address' {
        It 'moves the A record in place, removes the old PTR records that point at the name and adds the new one' {
            $results = @(Set-DnsEntry -Identity 'srv01.contoso.local' -Address '10.0.16.61' -Server $script:Server -LogPath $script:LogPath -Force)

            Get-Outcome $results | Should -Be @(
                'SetAddress A srv01.contoso.local Success'
                'RemovePtr PTR 20.16.0.10.in-addr.arpa Success'
                'RemovePtr PTR 20.16.0.10.in-addr.arpa Success'
                'AddPtr PTR 61.16.0.10.in-addr.arpa Success'
            )
            $results[0].Data | Should -Be '10.0.16.61'
            $results[3].Data | Should -Be 'srv01.contoso.local'

            @(Get-StubRecord -Zone 'contoso.local' -Node 'srv01' -Type 'A').Data | Should -Be @('10.0.16.61')
            @(Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '20' -Type 'PTR').Count | Should -Be 0
            @(Get-StubRecord -Zone '0.10.in-addr.arpa' -Node '20.16' -Type 'PTR').Count | Should -Be 0
            @(Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '61' -Type 'PTR').Data | Should -Be @('srv01.contoso.local')

            # In place: one Set call for the A record, never remove-and-add.
            Get-StubCallCount -Command 'Set-DnsServerResourceRecord' | Should -Be 1
            Get-StubCallCount -Command 'Add-DnsServerResourceRecordA' | Should -Be 0
            @(Get-StubCallLog -Command 'Remove-DnsServerResourceRecord' | ForEach-Object { $_['InputObject'].RecordType }) | Should -Be @('PTR', 'PTR')
            $addCall = @(Get-StubCallLog -Command 'Add-DnsServerResourceRecordPtr')
            $addCall.Count | Should -Be 1
            $addCall[0].Keys | Should -Not -Contain 'TimeToLive'
            $addCall[0].Keys | Should -Not -Contain 'AgeRecord'
        }

        It 'with -TTL gives the moved record and the new PTR the TTL' {
            $results = @(Set-DnsEntry -Identity 'srv01.contoso.local' -Address '10.0.16.61' -TTL 600 -Server $script:Server -LogPath $script:LogPath -Force)

            Get-Outcome $results | Should -Be @(
                'SetAddress A srv01.contoso.local Success'
                'RemovePtr PTR 20.16.0.10.in-addr.arpa Success'
                'RemovePtr PTR 20.16.0.10.in-addr.arpa Success'
                'AddPtr PTR 61.16.0.10.in-addr.arpa Success'
                'SetTtl A srv01.contoso.local Success'
            )
            $record = Get-StubRecord -Zone 'contoso.local' -Node 'srv01' -Type 'A'
            $record.Data | Should -Be '10.0.16.61'
            $record.Ttl | Should -Be 600
            (Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '61' -Type 'PTR').Ttl | Should -Be 600
        }

        It 'fails with Ambiguous for a name with two A records and points at Get-DnsEntry' {
            $results = @(Set-DnsEntry -Identity 'multi.contoso.local' -Address '10.0.16.62' -Server $script:Server -LogPath $script:LogPath -Force -ErrorVariable errors -ErrorAction SilentlyContinue)

            $setErrors = Get-SetError $errors
            $setErrors.Count | Should -Be 1
            $setErrors[0].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Set-DnsEntry.Ambiguous,*'
            $setErrors[0].Exception.Message | Should -BeLike '*Get-DnsEntry*'
            Get-Outcome $results | Should -Be @('SetAddress  multi.contoso.local Failed')
            $results[0].Data | Should -Be '10.0.16.62'
            $results[0].Error | Should -Be $setErrors[0].Exception.Message
            Get-WriteCallCount | Should -Be 0
        }

        It 'moves exactly the record of a piped entry when the name has two A records' {
            $entry = Get-DnsEntry -Find 'multi.contoso.local' -Server $script:Server | Where-Object { $_.Data -eq '10.0.16.22' }

            $results = @($entry | Set-DnsEntry -Address '10.0.16.62' -Server $script:Server -LogPath $script:LogPath -Force)

            Get-Outcome $results | Should -Be @(
                'SetAddress A multi.contoso.local Success'
                'AddPtr PTR 62.16.0.10.in-addr.arpa Success'
            )
            @(Get-StubRecord -Zone 'contoso.local' -Node 'multi' -Type 'A' | ForEach-Object { $_.Data } | Sort-Object) | Should -Be @('10.0.16.21', '10.0.16.62')
            @(Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '21' -Type 'PTR').Data | Should -Be @('multi.contoso.local')
        }

        It 'skips the PTR step when the new address has a PTR to another name' {
            $results = @(Set-DnsEntry -Identity 'srv01.contoso.local' -Address '10.0.16.50' -Server $script:Server -LogPath $script:LogPath -Force)

            Get-Outcome $results | Should -Be @(
                'SetAddress A srv01.contoso.local Success'
                'RemovePtr PTR 20.16.0.10.in-addr.arpa Success'
                'RemovePtr PTR 20.16.0.10.in-addr.arpa Success'
                'AddPtr PTR 50.16.0.10.in-addr.arpa Skipped'
            )
            $results[3].Error | Should -BeLike '*taken.contoso.local*-ReplacePtr*'
            @(Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '50' -Type 'PTR').Data | Should -Be @('taken.contoso.local')
        }

        It 'with -ReplacePtr removes the PTR to the other name and adds its own' {
            $results = @(Set-DnsEntry -Identity 'srv01.contoso.local' -Address '10.0.16.50' -ReplacePtr -Server $script:Server -LogPath $script:LogPath -Force)

            Get-Outcome $results | Should -Be @(
                'SetAddress A srv01.contoso.local Success'
                'RemovePtr PTR 20.16.0.10.in-addr.arpa Success'
                'RemovePtr PTR 20.16.0.10.in-addr.arpa Success'
                'RemovePtr PTR 50.16.0.10.in-addr.arpa Success'
                'AddPtr PTR 50.16.0.10.in-addr.arpa Success'
            )
            $results[3].Data | Should -Be 'taken.contoso.local'
            @(Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '50' -Type 'PTR').Data | Should -Be @('srv01.contoso.local')
        }

        It 'skips the PTR step with a warning when no reverse zone covers the new address' {
            $results = @(Set-DnsEntry -Identity 'web.contoso.local' -Address '192.168.5.5' -Server $script:Server -LogPath $script:LogPath -Force -WarningVariable warnings -WarningAction SilentlyContinue)

            Get-Outcome $results | Should -Be @(
                'SetAddress A web.contoso.local Success'
                'RemovePtr PTR 40.16.0.10.in-addr.arpa Success'
                'AddPtr PTR 5.5.168.192.in-addr.arpa Skipped'
            )
            $results[2].Error | Should -BeLike 'No reverse zone for 192.168.5.5*'
            @($warnings | Where-Object { "$_" -like 'No reverse zone for 192.168.5.5*' }).Count | Should -Be 1
            (Get-StubRecord -Zone 'contoso.local' -Node 'web' -Type 'A').Data | Should -Be '192.168.5.5'
        }

        It 'reports AlreadyDone when the record already has the address and the PTR exists' {
            $results = @(Set-DnsEntry -Identity 'srv01.contoso.local' -Address '10.0.16.20' -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @(
                'SetAddress A srv01.contoso.local AlreadyDone'
                'AddPtr PTR 20.16.0.10.in-addr.arpa AlreadyDone'
            )
            Get-WriteCallCount | Should -Be 0
            Should -Invoke Read-Host -ModuleName DnsLathund -Times 0 -Exactly
        }

        It 'adds the missing PTR when the record already has the address (a re-run completes the sync)' {
            $results = @(Set-DnsEntry -Identity 'dc01.contoso.local' -Address '10.0.16.10' -Server $script:Server -LogPath $script:LogPath -Force)

            Get-Outcome $results | Should -Be @(
                'SetAddress A dc01.contoso.local AlreadyDone'
                'AddPtr PTR 10.16.0.10.in-addr.arpa Success'
            )
            @(Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '10' -Type 'PTR').Data | Should -Be @('dc01.contoso.local')
        }

        It 'fails with <Reason> for <Identity> -Address <Value>' -TestCases @(
            @{ Identity = 'srv01.contoso.local'; Value = '2001:db8::99'; Reason = 'AddressFamilyMismatch' }
            @{ Identity = 'www.contoso.local'; Value = '10.0.16.99'; Reason = 'NotAHost' }
            @{ Identity = '10.0.16.20'; Value = '10.0.16.99'; Reason = 'NotAHost' }
            @{ Identity = 'nothere.contoso.local'; Value = '10.0.16.99'; Reason = 'NotFound' }
        ) {
            $results = @(Set-DnsEntry -Identity $Identity -Address $Value -Server $script:Server -LogPath $script:LogPath -Force -ErrorVariable errors -ErrorAction SilentlyContinue)

            $setErrors = Get-SetError $errors
            $setErrors.Count | Should -Be 1
            $setErrors[0].FullyQualifiedErrorId | Should -BeLike "DnsLathund.Set-DnsEntry.$Reason,*"
            $results.Count | Should -Be 1
            $results[0].Action | Should -Be 'SetAddress'
            $results[0].Result | Should -Be 'Failed'
            Get-WriteCallCount | Should -Be 0
        }

        It 'skips a record in a zone that is not writable on the server' {
            $results = @(Set-DnsEntry -Identity 'ro.fabrikam.com' -Address '192.0.2.11' -Server $script:Server -LogPath $script:LogPath -Force -WarningAction SilentlyContinue)

            Get-Outcome $results | Should -Be @(
                'SetAddress A ro.fabrikam.com Skipped'
                'AddPtr PTR 11.2.0.192.in-addr.arpa Skipped'
            )
            $results[0].Error | Should -BeLike "Zone 'fabrikam.com' is not writable*"
            Get-WriteCallCount | Should -Be 0
        }
    }

    Context '-PtrTarget' {
        It 'changes the target of the PTR record of an address in place' {
            $results = @(Set-DnsEntry -Identity '10.0.16.40' -PtrTarget 'web02.contoso.local' -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @('SetPtrTarget PTR 40.16.0.10.in-addr.arpa Success')
            $results[0].Data | Should -Be 'web02.contoso.local'
            @(Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '40' -Type 'PTR').Data | Should -Be @('web02.contoso.local')
            Get-StubCallCount -Command 'Set-DnsServerResourceRecord' | Should -Be 1
            Get-StubCallCount -Command 'Remove-DnsServerResourceRecord' | Should -Be 0
            Get-StubCallCount -Command 'Add-DnsServerResourceRecordPtr' | Should -Be 0
        }

        It 'uses the address of a piped A entry, and with -TTL sets the TTL of that PTR only' {
            $entry = Get-DnsEntry -Find 'web.contoso.local' -Server $script:Server

            $results = @($entry | Set-DnsEntry -PtrTarget 'web02.contoso.local' -TTL 120 -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @(
                'SetPtrTarget PTR 40.16.0.10.in-addr.arpa Success'
                'SetTtl PTR 40.16.0.10.in-addr.arpa Success'
            )
            $ptr = Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '40' -Type 'PTR'
            $ptr.Data | Should -Be 'web02.contoso.local'
            $ptr.Ttl | Should -Be 120
            (Get-StubRecord -Zone 'contoso.local' -Node 'web' -Type 'A').Ttl | Should -Be 3600
        }

        It 'adds a PTR record when the address has none' {
            $results = @(Set-DnsEntry -Identity '10.0.16.10' -PtrTarget 'dc01.contoso.local' -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @('AddPtr PTR 10.16.0.10.in-addr.arpa Success')
            @(Get-StubRecord -Zone '16.0.10.in-addr.arpa' -Node '10' -Type 'PTR').Data | Should -Be @('dc01.contoso.local')
        }

        It 'reports AlreadyDone when the PTR already points at the target' {
            $results = @(Set-DnsEntry -Identity '10.0.16.40' -PtrTarget 'WEB.contoso.local.' -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @('SetPtrTarget PTR 40.16.0.10.in-addr.arpa AlreadyDone')
            Get-WriteCallCount | Should -Be 0
        }

        It 'fails with <Reason> for <Identity>' -TestCases @(
            @{ Identity = 'web.contoso.local'; Reason = 'NotAnAddress' }
            @{ Identity = '192.168.5.5'; Reason = 'NoReverseZone' }
            @{ Identity = '10.0.16.90'; Reason = 'Ambiguous' }
        ) {
            $results = @(Set-DnsEntry -Identity $Identity -PtrTarget 'x.contoso.local' -Server $script:Server -LogPath $script:LogPath -ErrorVariable errors -ErrorAction SilentlyContinue)

            $setErrors = Get-SetError $errors
            $setErrors.Count | Should -Be 1
            $setErrors[0].FullyQualifiedErrorId | Should -BeLike "DnsLathund.Set-DnsEntry.$Reason,*"
            $results.Count | Should -Be 1
            $results[0].Action | Should -Be 'SetPtrTarget'
            $results[0].Result | Should -Be 'Failed'
            Get-WriteCallCount | Should -Be 0
        }

        It 'skips a PTR record in a reverse zone that is not writable on the server' {
            $results = @(Set-DnsEntry -Identity '10.0.18.5' -PtrTarget 'new.contoso.local' -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @('SetPtrTarget PTR 5.18.0.10.in-addr.arpa Skipped')
            $results[0].Error | Should -BeLike "Zone '18.0.10.in-addr.arpa' is not writable*"
            Get-WriteCallCount | Should -Be 0
        }
    }

    Context '-Target' {
        It 'changes the target of an alias in place' {
            $results = @(Set-DnsEntry -Identity 'www.contoso.local' -Target 'web02.contoso.local' -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @('SetTarget CNAME www.contoso.local Success')
            $results[0].Data | Should -Be 'web02.contoso.local'
            @(Get-StubRecord -Zone 'contoso.local' -Node 'www' -Type 'CNAME').Data | Should -Be @('web02.contoso.local')
            Get-StubCallCount -Command 'Set-DnsServerResourceRecord' | Should -Be 1
            Get-StubCallCount -Command 'Add-DnsServerResourceRecordCName' | Should -Be 0
            Get-StubCallCount -Command 'Remove-DnsServerResourceRecord' | Should -Be 0
        }

        It 'with -TTL sets the target first, then the TTL of the alias' {
            $results = @(Set-DnsEntry -Identity 'www.contoso.local' -Target 'web02.contoso.local' -TTL 60 -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @(
                'SetTarget CNAME www.contoso.local Success'
                'SetTtl CNAME www.contoso.local Success'
            )
            $record = Get-StubRecord -Zone 'contoso.local' -Node 'www' -Type 'CNAME'
            $record.Data | Should -Be 'web02.contoso.local'
            $record.Ttl | Should -Be 60
        }

        It 'fails with CnameLoop when the server refuses a target that loops (WIN32 9707)' {
            $results = @(Set-DnsEntry -Identity 'www.contoso.local' -Target 'www.contoso.local' -Server $script:Server -LogPath $script:LogPath -ErrorVariable errors -ErrorAction SilentlyContinue)

            $setErrors = Get-SetError $errors
            $setErrors.Count | Should -Be 1
            $setErrors[0].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Set-DnsEntry.CnameLoop,*'
            Get-Outcome $results | Should -Be @('SetTarget CNAME www.contoso.local Failed')
            $results[0].Error | Should -Not -BeNullOrEmpty
            @(Get-StubRecord -Zone 'contoso.local' -Node 'www' -Type 'CNAME').Data | Should -Be @('web.contoso.local')
        }

        It 'reports AlreadyDone when the alias already points at the target' {
            $results = @(Set-DnsEntry -Identity 'www.contoso.local' -Target 'web.contoso.local' -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @('SetTarget CNAME www.contoso.local AlreadyDone')
            Get-WriteCallCount | Should -Be 0
        }

        It 'fails with NotACname for <Identity>' -TestCases @(
            @{ Identity = 'web.contoso.local' }
            @{ Identity = '10.0.16.40' }
        ) {
            $results = @(Set-DnsEntry -Identity $Identity -Target 'web02.contoso.local' -Server $script:Server -LogPath $script:LogPath -ErrorVariable errors -ErrorAction SilentlyContinue)

            $setErrors = Get-SetError $errors
            $setErrors.Count | Should -Be 1
            $setErrors[0].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Set-DnsEntry.NotACname,*'
            $results[0].Action | Should -Be 'SetTarget'
            $results[0].Result | Should -Be 'Failed'
            Get-WriteCallCount | Should -Be 0
        }
    }

    Context 'Dynamic records' {
        It 'skips a dynamic A record and its dynamic PTR with the contract text' {
            $results = @(Set-DnsEntry -Identity 'dyn01.contoso.local' -TTL 60 -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @(
                'SetTtl A dyn01.contoso.local Skipped'
                'SetTtl PTR 30.16.0.10.in-addr.arpa Skipped'
            )
            foreach ($result in $results) {
                $result.Error | Should -BeExactly $script:DynamicText
            }
            Get-WriteCallCount | Should -Be 0
        }

        It 'changes dynamic records with -IncludeDynamic, warns per record and logs After.Timestamp' {
            $results = @(Set-DnsEntry -Identity 'dyn01.contoso.local' -TTL 60 -IncludeDynamic -Server $script:Server -LogPath $script:LogPath -WarningVariable warnings -WarningAction SilentlyContinue)

            Get-Outcome $results | Should -Be @(
                'SetTtl A dyn01.contoso.local Success'
                'SetTtl PTR 30.16.0.10.in-addr.arpa Success'
            )
            @($warnings | Where-Object { "$_" -like '*dynamic*' }).Count | Should -Be 2
            $lines = @(Read-ChangeLog -Path $script:LogPath)
            $lines.Count | Should -Be 2
            foreach ($line in $lines) {
                $line.Before.Timestamp | Should -Not -BeNullOrEmpty
                $line.After.PSObject.Properties.Name | Should -Contain 'Timestamp'
                $line.After.Timestamp | Should -Not -BeNullOrEmpty
                $line.After.Ttl | Should -Be 60
            }
        }

        It 'skips the PTR sync when the address of a dynamic record is not changed' {
            $results = @(Set-DnsEntry -Identity 'dyn01.contoso.local' -Address '10.0.16.31' -Server $script:Server -LogPath $script:LogPath -Force)

            Get-Outcome $results | Should -Be @(
                'SetAddress A dyn01.contoso.local Skipped'
                'RemovePtr PTR 30.16.0.10.in-addr.arpa Skipped'
                'AddPtr PTR 31.16.0.10.in-addr.arpa Skipped'
            )
            $results[0].Error | Should -BeExactly $script:DynamicText
            $results[2].Error | Should -BeLike 'Not done because SetAddress*'
            Get-WriteCallCount | Should -Be 0
        }
    }

    Context 'Confirmation, -WhatIf and -Force' {
        It '-WhatIf prints one line per item, returns WhatIf per sub-operation, writes nothing to DNS but logs every Result' {
            $results = @('srv01.contoso.local', 'web.contoso.local' | Set-DnsEntry -TTL 120 -Server $script:Server -LogPath $script:LogPath -WhatIf)

            Should -Invoke Write-Host -ModuleName DnsLathund -Times 2 -Exactly -ParameterFilter { $Object -like 'What if: Performing the operation "Change DNS records" on target *' }
            Should -Invoke Write-Host -ModuleName DnsLathund -Times 1 -Exactly -ParameterFilter { $Object -like '*"srv01.contoso.local: set the TTL of A srv01.contoso.local from 3600 to 120 s;*' }
            $results.Count | Should -Be 5
            foreach ($result in $results) {
                $result.Result | Should -Be 'WhatIf'
            }
            Get-WriteCallCount | Should -Be 0
            (Get-StubRecord -Zone 'contoso.local' -Node 'srv01' -Type 'A').Ttl | Should -Be 3600
            $lines = @(Read-ChangeLog -Path $script:LogPath)
            $lines.Count | Should -Be 5
            foreach ($line in $lines) {
                $line.Result | Should -Be 'WhatIf'
            }
        }

        It '-Force never prompts, even with -Confirm and impact High' {
            $results = @(Set-DnsEntry -Identity 'srv01.contoso.local' -Address '10.0.16.61' -Server $script:Server -LogPath $script:LogPath -Force -Confirm)

            Should -Invoke Read-Host -ModuleName DnsLathund -Times 0 -Exactly
            $results[0].Result | Should -Be 'Success'
        }

        It '-Confirm:$false never prompts for impact High' {
            $results = @(Set-DnsEntry -Identity 'srv01.contoso.local' -Address '10.0.16.61' -Server $script:Server -LogPath $script:LogPath -Confirm:$false)

            Should -Invoke Read-Host -ModuleName DnsLathund -Times 0 -Exactly
            $results[0].Result | Should -Be 'Success'
        }

        It 'prompts for -Address (impact High) but not for -TTL (impact Medium) at the default ConfirmPreference' {
            Mock Read-Host { 'y' } -ModuleName DnsLathund

            $null = Set-DnsEntry -Identity 'web.contoso.local' -TTL 120 -Server $script:Server -LogPath $script:LogPath
            Should -Invoke Read-Host -ModuleName DnsLathund -Times 0 -Exactly

            $results = @(Set-DnsEntry -Identity 'srv01.contoso.local' -Address '10.0.16.61' -Server $script:Server -LogPath $script:LogPath)
            Should -Invoke Read-Host -ModuleName DnsLathund -Times 1 -Exactly -ParameterFilter { $Prompt -like "Change DNS records`n  srv01.contoso.local: change A srv01.contoso.local from 10.0.16.20 to 10.0.16.61;*" }
            $results[0].Result | Should -Be 'Success'
        }

        It 'answer N skips every sub-operation of the item' {
            Mock Read-Host { 'n' } -ModuleName DnsLathund

            $results = @(Set-DnsEntry -Identity 'srv01.contoso.local' -TTL 120 -Server $script:Server -LogPath $script:LogPath -Confirm)

            $results.Count | Should -Be 3
            foreach ($result in $results) {
                $result.Result | Should -Be 'Skipped'
                $result.Error | Should -Be 'Declined at the confirmation prompt.'
            }
            Get-WriteCallCount | Should -Be 0
        }

        It 'answer A (yes to all) confirms the remaining items at the same impact' {
            Mock Read-Host { 'a' } -ModuleName DnsLathund

            $results = @('srv01.contoso.local', 'web.contoso.local' | Set-DnsEntry -TTL 120 -Server $script:Server -LogPath $script:LogPath -Confirm)

            Should -Invoke Read-Host -ModuleName DnsLathund -Times 1 -Exactly
            $results.Count | Should -Be 5
            foreach ($result in $results) {
                $result.Result | Should -Be 'Success'
            }
        }

        It 'answer S (stop) ends the batch' {
            Mock Read-Host { 's' } -ModuleName DnsLathund

            $run = Invoke-Collected { 'srv01.contoso.local', 'web.contoso.local' | Set-DnsEntry -TTL 120 -Server $script:Server -LogPath $script:LogPath -Confirm }

            $run['Error'] | Should -Not -BeNullOrEmpty
            $run['Error'].Exception.Message | Should -Be 'Operation stopped by the operator.'
            $run['Results'].Count | Should -Be 0
            Should -Invoke Read-Host -ModuleName DnsLathund -Times 1 -Exactly
            Get-WriteCallCount | Should -Be 0
        }

        It 'ends the batch with one terminating Confirm.NonInteractive error when the session cannot prompt' {
            Mock Read-Host { throw 'PowerShell is in NonInteractive mode. Read and Prompt functionality is not available.' } -ModuleName DnsLathund

            $run = Invoke-Collected { 'srv01.contoso.local', 'web.contoso.local' | Set-DnsEntry -Address '10.0.16.61' -Server $script:Server -LogPath $script:LogPath }

            $run['Error'] | Should -Not -BeNullOrEmpty
            $run['Error'].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Confirm.NonInteractive,*'
            $run['Error'].Exception.Message | Should -Be 'This session cannot prompt. Re-run with -Force to confirm all actions, or -WhatIf to preview.'
            $run['Results'].Count | Should -Be 0
            Should -Invoke Read-Host -ModuleName DnsLathund -Times 1 -Exactly
            Get-WriteCallCount | Should -Be 0
        }
    }

    Context 'Batch behaviour, Result objects and the change log' {
        It '-Delay sleeps once per input item' {
            Mock Start-Sleep { } -ModuleName DnsLathund

            $null = 'srv01.contoso.local', 'web.contoso.local', 'nothere.contoso.local' | Set-DnsEntry -TTL 120 -Delay 3 -Server $script:Server -LogPath $script:LogPath -ErrorAction SilentlyContinue

            Should -Invoke Start-Sleep -ModuleName DnsLathund -Times 3 -Exactly -ParameterFilter { $Seconds -eq 3 }
        }

        It 'does not sleep without -Delay' {
            Mock Start-Sleep { } -ModuleName DnsLathund

            $null = 'srv01.contoso.local', 'web.contoso.local' | Set-DnsEntry -TTL 120 -Server $script:Server -LogPath $script:LogPath

            Should -Invoke Start-Sleep -ModuleName DnsLathund -Times 0 -Exactly -ParameterFilter { $Seconds -gt 0 }
        }

        It 'does not sleep under -WhatIf even with -Delay' {
            Mock Start-Sleep { } -ModuleName DnsLathund

            $null = 'srv01.contoso.local', 'web.contoso.local' | Set-DnsEntry -TTL 120 -Delay 3 -Server $script:Server -LogPath $script:LogPath -WhatIf

            Should -Invoke Start-Sleep -ModuleName DnsLathund -Times 0 -Exactly
        }

        It 'writes the Failed Result and ends the batch with ServerUnreachable when the server cannot be reached' {
            Set-StubFailure -Command 'Set-DnsServerResourceRecord' -Code 1722

            $run = Invoke-Collected { 'web.contoso.local', 'srv01.contoso.local' | Set-DnsEntry -TTL 120 -Server $script:Server -LogPath $script:LogPath -Force }

            $run['Error'] | Should -Not -BeNullOrEmpty
            $run['Error'].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Set-DnsEntry.ServerUnreachable,*'
            Get-Outcome $run['Results'] | Should -Be @('SetTtl A web.contoso.local Failed')
            Get-StubCallCount -Command 'Set-DnsServerResourceRecord' | Should -Be 1
            $lines = @(Read-ChangeLog -Path $script:LogPath)
            $lines.Count | Should -Be 1
            $lines[0].Result | Should -Be 'Failed'
        }

        It 'reports a refused write as a per-item failure and goes on with the next item' {
            Set-StubFailure -Command 'Set-DnsServerResourceRecord' -Code 5

            $results = @('web.contoso.local', 'www.contoso.local' | Set-DnsEntry -TTL 120 -Server $script:Server -LogPath $script:LogPath -ErrorVariable errors -ErrorAction SilentlyContinue)

            Get-Outcome $results | Should -Be @(
                'SetTtl A web.contoso.local Failed'
                'SetTtl PTR 40.16.0.10.in-addr.arpa Failed'
                'SetTtl CNAME www.contoso.local Failed'
            )
            $setErrors = Get-SetError $errors
            $setErrors.Count | Should -Be 3
            foreach ($setError in $setErrors) {
                $setError.FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Set-DnsEntry.WriteFailed,*'
            }
        }

        It 'skips the PTR sync when the address change itself fails' {
            Set-StubFailure -Command 'Set-DnsServerResourceRecord' -Code 5

            $results = @(Set-DnsEntry -Identity 'srv01.contoso.local' -Address '10.0.16.61' -Server $script:Server -LogPath $script:LogPath -Force -ErrorAction SilentlyContinue)

            Get-Outcome $results | Should -Be @(
                'SetAddress A srv01.contoso.local Failed'
                'RemovePtr PTR 20.16.0.10.in-addr.arpa Skipped'
                'RemovePtr PTR 20.16.0.10.in-addr.arpa Skipped'
                'AddPtr PTR 61.16.0.10.in-addr.arpa Skipped'
            )
            $results[3].Error | Should -Be "Not done because SetAddress of 'srv01.contoso.local' ended as Failed."
            Get-StubCallCount -Command 'Remove-DnsServerResourceRecord' | Should -Be 0
            Get-StubCallCount -Command 'Add-DnsServerResourceRecordPtr' | Should -Be 0
        }

        It 'reports a failed read as Failed and goes on with the next item' {
            Set-StubFailure -Command 'Get-DnsServerResourceRecord' -Code 5

            $results = @('web.contoso.local', 'www.contoso.local' | Set-DnsEntry -TTL 120 -Server $script:Server -LogPath $script:LogPath -ErrorVariable errors -ErrorAction SilentlyContinue)

            Get-Outcome $results | Should -Be @(
                'SetTtl  web.contoso.local Failed'
                'SetTtl  www.contoso.local Failed'
            )
            $results[0].Error | Should -BeLike "Could not read the records of 'web.contoso.local'*"
            @($errors | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -and $_.FullyQualifiedErrorId -like 'DnsLathund.Get-DnsLiveRecord.LookupFailed*' }).Count | Should -BeGreaterThan 0
            Get-WriteCallCount | Should -Be 0
        }

        It 'ends the batch with ServerUnreachable when a read finds the server unreachable' {
            Set-StubFailure -Command 'Get-DnsServerResourceRecord' -Code 1722

            $run = Invoke-Collected { 'web.contoso.local', 'www.contoso.local' | Set-DnsEntry -TTL 120 -Server $script:Server -LogPath $script:LogPath -ErrorAction SilentlyContinue }

            $run['Error'].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Set-DnsEntry.ServerUnreachable,*'
            Get-Outcome $run['Results'] | Should -Be @('SetTtl  web.contoso.local Failed')
            Get-WriteCallCount | Should -Be 0
        }

        It 'remembers the writer server only for real changes and reminds about Update-DnsSnapshot after changes' {
            $null = Set-DnsEntry -Identity 'web.contoso.local' -TTL 120 -Server $script:Server -LogPath $script:LogPath -WhatIf
            InModuleScope DnsLathund { $script:WriterServer } | Should -BeNullOrEmpty

            $verbose = @(Set-DnsEntry -Identity 'web.contoso.local' -TTL 120 -Server $script:Server -LogPath $script:LogPath -Verbose 4>&1 |
                    Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -and $_.Message -like '*Update-DnsSnapshot*' })

            InModuleScope DnsLathund { $script:WriterServer } | Should -BeExactly $script:Server
            $verbose.Count | Should -Be 1
        }

        It 'reports WIN32 9712 (zone not writable) from the server as Skipped' {
            Set-StubFailure -Command 'Set-DnsServerResourceRecord' -Code 9712

            $results = @(Set-DnsEntry -Identity 'www.contoso.local' -TTL 120 -Server $script:Server -LogPath $script:LogPath -ErrorVariable errors -ErrorAction SilentlyContinue)

            Get-Outcome $results | Should -Be @('SetTtl CNAME www.contoso.local Skipped')
            (Get-SetError $errors).Count | Should -Be 0
        }

        It 'reports <Reason> per item and goes on with the next one' -TestCases @(
            @{ Identity = 'srv*'; Reason = 'PatternNotAllowed' }
            @{ Identity = 'x.nowhere.example'; Reason = 'ZoneNotFound' }
            @{ Identity = 'srv01'; Reason = 'ZoneNotFound' }
            @{ Identity = ''; Reason = 'InvalidInput' }
        ) {
            $results = @($Identity, 'www.contoso.local' | Set-DnsEntry -TTL 120 -Server $script:Server -LogPath $script:LogPath -ErrorVariable errors -ErrorAction SilentlyContinue)

            $setErrors = Get-SetError $errors
            $setErrors.Count | Should -Be 1
            $setErrors[0].FullyQualifiedErrorId | Should -BeLike "DnsLathund.Set-DnsEntry.$Reason,*"
            $results.Count | Should -Be 2
            $results[0].Action | Should -Be 'SetTtl'
            $results[0].Result | Should -Be 'Failed'
            $results[0].Error | Should -Be $setErrors[0].Exception.Message
            $results[1].Result | Should -Be 'Success'
        }

        It 'with -ErrorAction Stop ends at the first per-item failure, after its Failed Result is logged' {
            $run = Invoke-Collected { 'nothere.contoso.local', 'www.contoso.local' | Set-DnsEntry -TTL 120 -Server $script:Server -LogPath $script:LogPath -ErrorAction Stop }

            $run['Error'].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Set-DnsEntry.NotFound,*'
            Get-Outcome $run['Results'] | Should -Be @('SetTtl  nothere.contoso.local Failed')
            $lines = @(Read-ChangeLog -Path $script:LogPath)
            $lines.Count | Should -Be 1
            $lines[0].Result | Should -Be 'Failed'
            Get-WriteCallCount | Should -Be 0
        }

        It 'reads a bare name in -Zone and objects with a Name property' {
            $rows = @(
                (New-Object -TypeName PSObject -Property @{ Name = 'www.contoso.local'; Comment = 'from a CSV file' })
                (New-Object -TypeName PSObject -Property @{ HostName = 'web.contoso.local' })
            )
            $fromRows = @($rows | Set-DnsEntry -TTL 120 -Server $script:Server -LogPath $script:LogPath)
            $bare = @(Set-DnsEntry -Identity 'srv01' -Zone 'contoso.local' -TTL 120 -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $fromRows | Should -Be @(
                'SetTtl CNAME www.contoso.local Success'
                'SetTtl A web.contoso.local Success'
                'SetTtl PTR 40.16.0.10.in-addr.arpa Success'
            )
            $bare[0].Name | Should -Be 'srv01.contoso.local'
            $bare[0].Result | Should -Be 'Success'
        }

        It 'emits Result objects with the properties of CONTRACTS.md 12.2 in order, one log line each, in -LogPath' {
            $results = @('srv01.contoso.local', 'nothere.contoso.local' | Set-DnsEntry -TTL 120 -Server $script:Server -LogPath $script:LogPath -ErrorAction SilentlyContinue)

            $results.Count | Should -Be 4
            foreach ($result in $results) {
                $result.PSObject.TypeNames[0] | Should -Be 'DnsLathund.Result'
                @($result.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly ($script:ResultProperties -join ',')
                $result.Server | Should -BeExactly $script:Server
                $result.BatchId | Should -Be $results[0].BatchId
                $result.Timestamp | Should -BeOfType [datetime]
            }

            Test-Path -LiteralPath $script:LogPath -PathType Leaf | Should -BeTrue
            $lines = @(Read-ChangeLog -Path $script:LogPath)
            $lines.Count | Should -Be $results.Count
            for ($index = 0; $index -lt $lines.Count; $index++) {
                @($lines[$index].PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly ($script:LogKeys -join ',')
                $lines[$index].Id | Should -Be $results[$index].Id
                $lines[$index].BatchId | Should -Be $results[$index].BatchId
                $lines[$index].Action | Should -Be $results[$index].Action
                $lines[$index].Name | Should -Be $results[$index].Name
                $lines[$index].Data | Should -Be $results[$index].Data
                $lines[$index].Result | Should -Be $results[$index].Result
                $lines[$index].Server | Should -BeExactly $script:Server
            }
            $lines[0].Before.Data | Should -Be '10.0.16.20'
            $lines[3].Result | Should -Be 'Failed'
            $lines[3].Before | Should -BeNullOrEmpty
        }
    }

    Context 'Entries from Get-DnsEntry' {
        It 'accepts snapshot entries' {
            $null = Update-DnsSnapshot -Server $script:Server
            $entry = @(Get-DnsEntry -Find '*multi*' -Server $script:Server | Where-Object { $_.Data -eq '10.0.16.22' })
            $entry.Count | Should -Be 1
            $entry[0].Source | Should -Be 'Snapshot'

            $results = @($entry | Set-DnsEntry -TTL 900 -Server $script:Server -LogPath $script:LogPath)

            Get-Outcome $results | Should -Be @('SetTtl A multi.contoso.local Success')
            $results[0].Data | Should -Be '10.0.16.22'
        }

        It 'accepts deserialized entries (Export-Clixml / Import-Clixml)' {
            $file = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N') + '.xml')
            Get-DnsEntry -Find 'srv01.contoso.local' -Server $script:Server | Export-Clixml -Path $file
            $copy = Import-Clixml -Path $file
            $copy.PSObject.TypeNames[0] | Should -Be 'Deserialized.DnsLathund.Entry'

            $results = @($copy | Set-DnsEntry -Address '10.0.16.61' -Server $script:Server -LogPath $script:LogPath -Force)

            $results[0].Action | Should -Be 'SetAddress'
            $results[0].Result | Should -Be 'Success'
            (Get-StubRecord -Zone 'contoso.local' -Node 'srv01' -Type 'A').Data | Should -Be '10.0.16.61'
        }

        It 'fails with NotFound for an entry whose record changed after it was read' {
            $entry = Get-DnsEntry -Find 'web.contoso.local' -Server $script:Server
            $null = Set-DnsEntry -Identity 'web.contoso.local' -Address '10.0.16.41' -Server $script:Server -LogPath $script:LogPath -Force

            $results = @($entry | Set-DnsEntry -TTL 120 -Server $script:Server -LogPath $script:LogPath -ErrorVariable errors -ErrorAction SilentlyContinue)

            (Get-SetError $errors)[0].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Set-DnsEntry.NotFound,*'
            Get-Outcome $results | Should -Be @('SetTtl A web.contoso.local Failed')
        }

        It 'warns when an entry was read from another server' {
            $entry = Get-DnsEntry -Find 'www.contoso.local' -Server $script:Server
            $entry.Server = 'dc99'

            $results = @($entry | Set-DnsEntry -TTL 120 -Server $script:Server -LogPath $script:LogPath -WarningVariable warnings -WarningAction SilentlyContinue)

            @($warnings | Where-Object { "$_" -like "*read from 'dc99'*" }).Count | Should -Be 1
            $results[0].Result | Should -Be 'Success'
        }
    }
}
