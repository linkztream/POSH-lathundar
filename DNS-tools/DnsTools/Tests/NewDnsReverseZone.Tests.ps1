#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
<#
    Tests for New-DnsReverseZone (CONTRACTS.md section 13.7, with sections 5, 10, 11,
    12.2 and 13.9): the zone name from Get-DnsReverseZoneName, AlreadyDone, the
    replication rule (Custom with the partition of the -CopySettingsFrom zone,
    -ReplicationScope for file-backed and Legacy zones), dynamic update, the aging
    copy with [ipaddress[]] scavenge servers, the zone table refresh, the
    replication warning, -WhatIf, the confirmation gate, batch abort, the Result
    shape and the change log.

    New-DnsReverseZone is a thin wrapper around the private New-DnsLiveReverseZone
    (CONTRACTS.md section 7.5), which New-DnsEntry -CreateReverseZone calls with its
    own batch. The second Describe block calls that helper directly: the given
    BatchId, its terminating errors DnsTools.New-DnsLiveReverseZone.<Reason>,
    AlreadyDone, when SetZoneAging is written, and the shared confirmation state.

    Initialize-ReverseZoneTest gives every test a fresh stub store, empty caches,
    its own change log and these zones on the server dc01:

      contoso.local  primary, Custom partition CorpDnsZones.contoso.local, Secure,
                     aging on: no-refresh 3 days, refresh 5 days,
                     scavengers 10.0.16.10 and 10.0.16.11
      domain.local   primary, Domain scope (DomainDnsZones.contoso.local),
                     NonsecureAndSecure, aging off, no scavengers
      file.local     primary, file-backed, dynamic update None
      legacy.local   primary, Legacy scope
      16.0.10.in-addr.arpa (already hosted)
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

    function Initialize-ReverseZoneTest {
        <#
        .SYNOPSIS
            Fresh stub store, empty caches and the zones described at the top of
            this file.
        #>
        InModuleScope DnsTools {
            Reset-DnsStubStore
            $script:ZoneTableCache = @{}
            $script:CimSessionCache = @{}
            $script:SnapshotIndexCache = @{}
            $script:WriterServer = $null

            Add-DnsStubZone -Name 'contoso.local' -ReplicationScope 'Custom' -DirectoryPartitionName 'CorpDnsZones.contoso.local' -DynamicUpdate 'Secure' -AgingEnabled $true -NoRefreshInterval (New-TimeSpan -Days 3) -RefreshInterval (New-TimeSpan -Days 5) -ScavengeServers @('10.0.16.10', '10.0.16.11')
            Add-DnsStubZone -Name 'domain.local' -ReplicationScope 'Domain' -DirectoryPartitionName 'DomainDnsZones.contoso.local' -DynamicUpdate 'NonsecureAndSecure' -AgingEnabled $false
            Add-DnsStubZone -Name 'file.local' -IsDsIntegrated $false -DynamicUpdate 'None'
            Add-DnsStubZone -Name 'legacy.local' -ReplicationScope 'Legacy' -DirectoryPartitionName 'contoso.local'
            Add-DnsStubZone -Name '16.0.10.in-addr.arpa'
        }
    }

    function Get-StubZone {
        <#
        .SYNOPSIS
            A stub zone and its aging settings as one hashtable, or $null.
        #>
        param ([string]$Zone)

        InModuleScope DnsTools -Parameters @{ Zone = $Zone } {
            param ($Zone)
            $key = $Zone.ToLowerInvariant()
            $stubZone = $script:DnsStub.Zones[$key]
            if ($null -ne $stubZone) {
                $aging = $script:DnsStub.Aging[$key]
                @{
                    ReplicationScope       = $stubZone.ReplicationScope
                    DirectoryPartitionName = $stubZone.DirectoryPartitionName
                    DynamicUpdate          = $stubZone.DynamicUpdate
                    IsDsIntegrated         = $stubZone.IsDsIntegrated
                    AgingEnabled           = $aging.AgingEnabled
                    NoRefreshInterval      = $aging.NoRefreshInterval
                    RefreshInterval        = $aging.RefreshInterval
                    ScavengeServers        = @($aging.ScavengeServers)
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

    function Test-CachedZone {
        <#
        .SYNOPSIS
            Whether the module's cached zone table of dc01 knows a zone.
        #>
        param ([string]$Zone)

        InModuleScope DnsTools -Parameters @{ Zone = $Zone } {
            param ($Zone)
            $table = $script:ZoneTableCache['dc01']
            $null -ne $table -and $null -ne $table.ZoneLookup[$Zone]
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
            The errors of a -ErrorVariable that New-DnsReverseZone wrote itself.
        #>
        param ([object[]]$ErrorRecord)

        foreach ($record in @($ErrorRecord)) {
            if ($null -ne $record -and [string]$record.FullyQualifiedErrorId -like 'DnsTools.New-DnsReverseZone.*') {
                $record
            }
        }
    }

    function Invoke-LiveReverseZone {
        <#
        .SYNOPSIS
            Calls New-DnsLiveReverseZone in the module scope, once per network and
            with one batch for all of them, the way a change command does.

        .DESCRIPTION
            Returns @{ BatchId; Results; Error }: the id of the batch, every Result
            the helper emitted, and the terminating error that ended the calls
            ($null when none did).
        #>
        param (
            [string[]]$NetworkId,
            [string]$CopySettingsFrom = 'contoso.local',
            [string]$LogPath,
            [switch]$Preview,
            [switch]$NoForce
        )

        InModuleScope DnsTools -Parameters @{ NetworkId = $NetworkId; CopySettingsFrom = $CopySettingsFrom; LogPath = $LogPath; Preview = [bool]$Preview; Force = -not $NoForce } {
            param ($NetworkId, $CopySettingsFrom, $LogPath, $Preview, $Force)

            $batch = New-DnsBatch -Server 'dc01' -LogPath $LogPath -Force:$Force
            $zoneTable = Get-DnsZoneTable -Server 'dc01'
            $serverParameter = Get-DnsServerParameter -Server 'dc01'
            # The public commands hand -WhatIf down by dynamic scoping; so does this.
            $WhatIfPreference = $Preview

            $collected = @()
            $caught = $null
            foreach ($network in $NetworkId) {
                $results = $null
                try {
                    $null = New-DnsLiveReverseZone -Batch $batch -NetworkId $network -CopySettingsFrom $CopySettingsFrom -ZoneTable $zoneTable -ServerParameter $serverParameter -OutVariable results -WarningAction SilentlyContinue
                }
                catch {
                    $caught = $_
                }
                $collected += @(foreach ($result in @($results)) { if ($null -ne $result) { $result } })
                if ($null -ne $caught) {
                    break
                }
            }
            $WhatIfPreference = $false

            @{ BatchId = $batch['BatchId']; Results = $collected; Error = $caught }
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

Describe 'New-DnsReverseZone' {
    BeforeEach {
        Initialize-ReverseZoneTest
        $script:LogPath = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N') + '\changes.jsonl')
        $script:Common = @{ Server = $script:Server; LogPath = $script:LogPath }
    }

    Context 'Creating the zone' {
        It 'creates the zone in the partition of the -CopySettingsFrom zone and copies its dynamic update and aging settings' {
            $results = @(New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'Contoso.Local' -Force @script:Common -WarningVariable warnings -WarningAction SilentlyContinue)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:Success|SetZoneAging:Success'
            $results[0].Name | Should -BeExactly '17.0.10.in-addr.arpa'
            $results[0].Data | Should -BeExactly '10.0.17.0/24'
            $results[0].Zone | Should -BeExactly '17.0.10.in-addr.arpa'
            $results[0].Type | Should -BeNullOrEmpty
            $results[0].NodeName | Should -BeNullOrEmpty
            $results[1].Data | Should -BeExactly 'Aging=True, NoRefreshInterval=3.00:00:00, RefreshInterval=5.00:00:00, ScavengeServers=10.0.16.10 10.0.16.11'

            $createCall = @(Get-StubCall -Command 'Add-DnsServerPrimaryZone')[0]
            $createCall['NetworkId'] | Should -BeExactly '10.0.17.0/24'
            $createCall['ReplicationScope'] | Should -BeExactly 'Custom'
            $createCall['DirectoryPartitionName'] | Should -BeExactly 'CorpDnsZones.contoso.local'
            $createCall['DynamicUpdate'] | Should -BeExactly 'Secure'
            $createCall['WhatIf'] | Should -BeFalse
            $createCall['Confirm'] | Should -BeFalse

            $agingCall = @(Get-StubCall -Command 'Set-DnsServerZoneAging')[0]
            $agingCall['Name'] | Should -BeExactly '17.0.10.in-addr.arpa'
            $agingCall['Aging'] | Should -BeTrue
            $agingCall['NoRefreshInterval'] | Should -Be (New-TimeSpan -Days 3)
            $agingCall['RefreshInterval'] | Should -Be (New-TimeSpan -Days 5)
            @($agingCall['ScavengeServers']).Count | Should -Be 2
            foreach ($scavengeServer in @($agingCall['ScavengeServers'])) {
                $scavengeServer | Should -BeOfType [ipaddress]
            }
            $agingCall['WhatIf'] | Should -BeFalse
            $agingCall['Confirm'] | Should -BeFalse

            $zone = Get-StubZone -Zone '17.0.10.in-addr.arpa'
            $zone['ReplicationScope'] | Should -BeExactly 'Custom'
            $zone['DirectoryPartitionName'] | Should -BeExactly 'CorpDnsZones.contoso.local'
            $zone['AgingEnabled'] | Should -BeTrue
            $zone['ScavengeServers'] -join ',' | Should -BeExactly '10.0.16.10,10.0.16.11'

            Test-CachedZone -Zone '17.0.10.in-addr.arpa' | Should -BeTrue
            ($warnings | ForEach-Object { [string]$_ }) -join ' ' | Should -BeLike '*replication*DsPollingInterval*'
        }

        It 'derives the zone <Zone> from <NetworkId>' -ForEach @(
            @{ NetworkId = '10.0.17.5/24'; Zone = '17.0.10.in-addr.arpa'; Network = '10.0.17.0/24' }
            @{ NetworkId = '172.20.0.0/16'; Zone = '20.172.in-addr.arpa'; Network = '172.20.0.0/16' }
            @{ NetworkId = '2001:db8:0:1::/64'; Zone = '1.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa'; Network = '2001:db8:0:1::/64' }
        ) {
            $results = @(New-DnsReverseZone -NetworkId $NetworkId -CopySettingsFrom 'contoso.local' -Force @script:Common -WarningAction SilentlyContinue)

            $results[0].Name | Should -BeExactly $Zone
            $results[0].Data | Should -BeExactly $Network
            $results[0].Result | Should -BeExactly 'Success'
            Get-StubZone -Zone $Zone | Should -Not -BeNullOrEmpty
        }

        It 'copies a Domain-scoped zone as Custom with its partition, and aging off without scavengers' {
            $results = @(New-DnsReverseZone -NetworkId '10.0.18.0/24' -CopySettingsFrom 'domain.local' -Force @script:Common -WarningAction SilentlyContinue)

            $results[1].Data | Should -BeExactly 'Aging=False, NoRefreshInterval=7.00:00:00, RefreshInterval=7.00:00:00, ScavengeServers=any'
            $createCall = @(Get-StubCall -Command 'Add-DnsServerPrimaryZone')[0]
            $createCall['ReplicationScope'] | Should -BeExactly 'Custom'
            $createCall['DirectoryPartitionName'] | Should -BeExactly 'DomainDnsZones.contoso.local'
            $createCall['DynamicUpdate'] | Should -BeExactly 'NonsecureAndSecure'
            $agingCall = @(Get-StubCall -Command 'Set-DnsServerZoneAging')[0]
            $agingCall['Aging'] | Should -BeFalse
            $agingCall.Keys | Should -Not -Contain 'ScavengeServers'
        }

        It 'uses -DynamicUpdate instead of the setting of the -CopySettingsFrom zone' {
            $null = New-DnsReverseZone -NetworkId '10.0.18.0/24' -CopySettingsFrom 'domain.local' -DynamicUpdate 'Secure' -Force @script:Common -WarningAction SilentlyContinue

            @(Get-StubCall -Command 'Add-DnsServerPrimaryZone')[0]['DynamicUpdate'] | Should -BeExactly 'Secure'
            (Get-StubZone -Zone '18.0.10.in-addr.arpa')['DynamicUpdate'] | Should -BeExactly 'Secure'
        }

        It 'skips the aging step with a warning when the aging settings could not be read' {
            InModuleScope DnsTools {
                $script:DnsStub.Fail['Get-DnsServerZoneAging'] = @('contoso.local')
            }

            $results = @(New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'contoso.local' -Force @script:Common -WarningVariable warnings -WarningAction SilentlyContinue)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:Success|SetZoneAging:Skipped'
            $results[1].Error | Should -BeLike "*aging settings of zone 'contoso.local' could not be read*"
            Get-StubCallCount -Command 'Set-DnsServerZoneAging' | Should -Be 0
            ($warnings | ForEach-Object { [string]$_ }) -join ' ' | Should -BeLike '*Set-DnsServerZoneAging*'
            Get-StubZone -Zone '17.0.10.in-addr.arpa' | Should -Not -BeNullOrEmpty
        }
    }

    Context 'AlreadyDone and the replication rule' {
        It 'reports AlreadyDone for a hosted zone without asking or changing it' {
            Mock -ModuleName DnsTools Read-Host { throw 'Read-Host must not be called.' }

            $results = @(New-DnsReverseZone -NetworkId '10.0.16.0/24' -CopySettingsFrom 'contoso.local' -Confirm @script:Common)

            $results.Count | Should -Be 1
            $results[0].Action | Should -BeExactly 'CreateZone'
            $results[0].Result | Should -BeExactly 'AlreadyDone'
            Get-StubCallCount -Command 'Add-DnsServerPrimaryZone' | Should -Be 0
            Get-StubCallCount -Command 'Set-DnsServerZoneAging' | Should -Be 0
            Should -Invoke Read-Host -ModuleName DnsTools -Times 0 -Exactly
        }

        It 'reports AlreadyDone when the zone appears between the zone list and the creation (9609)' {
            InModuleScope DnsTools {
                $script:DnsStub.BeforeCall['Add-DnsServerPrimaryZone'] = { Add-DnsStubZone -Name '17.0.10.in-addr.arpa' }
            }

            $results = @(New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'contoso.local' -Force @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            $results.Count | Should -Be 1
            $results[0].Result | Should -BeExactly 'AlreadyDone'
            @(Get-OwnError -ErrorRecord $failures).Count | Should -Be 0
            Get-StubCallCount -Command 'Set-DnsServerZoneAging' | Should -Be 0
            Test-CachedZone -Zone '17.0.10.in-addr.arpa' | Should -BeTrue
        }

        It 'fails with "specify -ReplicationScope" for a <Kind> zone' -ForEach @(
            @{ Kind = 'file-backed'; Source = 'file.local' }
            @{ Kind = 'Legacy'; Source = 'legacy.local' }
        ) {
            $results = @(New-DnsReverseZone -NetworkId '10.0.19.0/24' -CopySettingsFrom $Source -Force @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            $results.Count | Should -Be 1
            $results[0].Result | Should -BeExactly 'Failed'
            $results[0].Error | Should -BeLike '*specify -ReplicationScope*'
            $own = @(Get-OwnError -ErrorRecord $failures)
            $own.Count | Should -Be 1
            $own[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsReverseZone.ReplicationScopeRequired,*'
            Get-StubCallCount -Command 'Add-DnsServerPrimaryZone' | Should -Be 0
        }

        It 'uses -ReplicationScope <Scope> as given for a <Kind> zone' -ForEach @(
            @{ Kind = 'file-backed'; Source = 'file.local'; Scope = 'Domain' }
            @{ Kind = 'Legacy'; Source = 'legacy.local'; Scope = 'Forest' }
            @{ Kind = 'Legacy'; Source = 'legacy.local'; Scope = 'Legacy' }
        ) {
            $results = @(New-DnsReverseZone -NetworkId '10.0.19.0/24' -CopySettingsFrom $Source -ReplicationScope $Scope -Force @script:Common -WarningAction SilentlyContinue)

            $results[0].Result | Should -BeExactly 'Success'
            $createCall = @(Get-StubCall -Command 'Add-DnsServerPrimaryZone')[0]
            $createCall['ReplicationScope'] | Should -BeExactly $Scope
            $createCall.Keys | Should -Not -Contain 'DirectoryPartitionName'
        }

        It 'fails for -ReplicationScope Custom when the zone has no partition to copy' {
            $results = @(New-DnsReverseZone -NetworkId '10.0.19.0/24' -CopySettingsFrom 'file.local' -ReplicationScope Custom -Force @script:Common -ErrorAction SilentlyContinue)

            $results[0].Result | Should -BeExactly 'Failed'
            $results[0].Error | Should -BeLike '*Domain, Forest or Legacy*'
            Get-StubCallCount -Command 'Add-DnsServerPrimaryZone' | Should -Be 0
        }

        It 'uses the partition of the zone for -ReplicationScope Custom' {
            $null = New-DnsReverseZone -NetworkId '10.0.19.0/24' -CopySettingsFrom 'domain.local' -ReplicationScope Custom -Force @script:Common -WarningAction SilentlyContinue

            $createCall = @(Get-StubCall -Command 'Add-DnsServerPrimaryZone')[0]
            $createCall['ReplicationScope'] | Should -BeExactly 'Custom'
            $createCall['DirectoryPartitionName'] | Should -BeExactly 'DomainDnsZones.contoso.local'
        }
    }

    Context 'Errors' {
        It 'stops before contacting the server for a network without a zone of its own' {
            $caught = $null
            try {
                $null = New-DnsReverseZone -NetworkId '10.0.16.0/23' -CopySettingsFrom 'contoso.local' -Force @script:Common
            }
            catch {
                $caught = $_
            }

            $caught.FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsReverseZone.InvalidNetworkId*'
            $caught.Exception.Message | Should -BeLike '*/24*'
            Get-StubCallCount -Command 'Get-DnsServerZone' | Should -Be 0
            Test-Path -LiteralPath $script:LogPath | Should -BeFalse
        }

        It 'fails with ZoneNotFound when -CopySettingsFrom is not hosted' {
            $results = @(New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'nowhere.test' -Force @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            $results.Count | Should -Be 1
            $results[0].Result | Should -BeExactly 'Failed'
            @(Get-OwnError -ErrorRecord $failures)[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsReverseZone.ZoneNotFound,*'
            Get-StubCallCount -Command 'Add-DnsServerPrimaryZone' | Should -Be 0
        }

        It 'reports access denied as Failed with a non-terminating error and no aging step' {
            InModuleScope DnsTools {
                $script:DnsStub.Fail['Add-DnsServerPrimaryZone'] = @('*')
                $script:DnsStub.FailCode['Add-DnsServerPrimaryZone'] = 5
            }

            $results = @(New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'contoso.local' -Force @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures)

            $results.Count | Should -Be 1
            $results[0].Result | Should -BeExactly 'Failed'
            @(Get-OwnError -ErrorRecord $failures)[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsReverseZone.CreateFailed,*'
            Get-StubCallCount -Command 'Set-DnsServerZoneAging' | Should -Be 0
            Get-StubCallCount -Command 'Get-DnsServerZone' | Should -Be 1
        }

        It 'writes the Failed result and stops with ServerUnreachable when the server cannot be reached' {
            InModuleScope DnsTools {
                $script:DnsStub.Fail['Add-DnsServerPrimaryZone'] = @('*')
                $script:DnsStub.FailCode['Add-DnsServerPrimaryZone'] = 1722
            }

            $caught = $null
            try {
                New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'contoso.local' -Force @script:Common -OutVariable streamed -ErrorAction SilentlyContinue
            }
            catch {
                $caught = $_
            }

            $caught.FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsReverseZone.ServerUnreachable*'
            @($streamed).Count | Should -Be 1
            $streamed[0].Result | Should -BeExactly 'Failed'
            @(Get-LogLine -Path $script:LogPath).Count | Should -Be 1
        }

        It 'reports a failed aging step as Failed after a successful creation' {
            InModuleScope DnsTools {
                $script:DnsStub.Fail['Set-DnsServerZoneAging'] = @('*')
            }

            $results = @(New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'contoso.local' -Force @script:Common -ErrorAction SilentlyContinue -ErrorVariable failures -WarningAction SilentlyContinue)

            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:Success|SetZoneAging:Failed'
            @(Get-OwnError -ErrorRecord $failures)[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsReverseZone.AgingFailed,*'
            Test-CachedZone -Zone '17.0.10.in-addr.arpa' | Should -BeTrue
        }
    }

    Context 'Confirmation and -WhatIf' {
        It 'shows one gate line under -WhatIf, returns and logs WhatIf results, and changes nothing' {
            Mock -ModuleName DnsTools Write-Host { }

            $results = @(New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'contoso.local' -WhatIf @script:Common)

            Should -Invoke Write-Host -ModuleName DnsTools -Times 1 -Exactly -ParameterFilter { [string]$Object -like 'What if: Performing the operation "Create reverse zone" on target "17.0.10.in-addr.arpa (10.0.17.0/24) on dc01, settings from contoso.local: replication scope Custom (CorpDnsZones.contoso.local), dynamic update Secure".' }
            ($results | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:WhatIf|SetZoneAging:WhatIf'
            Get-StubZone -Zone '17.0.10.in-addr.arpa' | Should -BeNullOrEmpty
            Get-StubCallCount -Command 'Add-DnsServerPrimaryZone' | Should -Be 0
            Get-StubCallCount -Command 'Set-DnsServerZoneAging' | Should -Be 0
            Get-StubCallCount -Command 'Get-DnsServerZone' | Should -Be 1
            $lines = @(Get-LogLine -Path $script:LogPath)
            ($lines | ForEach-Object { $_.Result }) -join ',' | Should -BeExactly 'WhatIf,WhatIf'
        }

        It 'never prompts with -Force or -Confirm:$false' {
            Mock -ModuleName DnsTools Read-Host { throw 'Read-Host must not be called.' }

            $first = @(New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'contoso.local' -Confirm -Force @script:Common -WarningAction SilentlyContinue)
            $second = @(New-DnsReverseZone -NetworkId '10.0.18.0/24' -CopySettingsFrom 'contoso.local' -Confirm:$false @script:Common -WarningAction SilentlyContinue)

            Should -Invoke Read-Host -ModuleName DnsTools -Times 0 -Exactly
            $first[0].Result | Should -BeExactly 'Success'
            $second[0].Result | Should -BeExactly 'Success'
        }

        It 'asks with the default confirmation preference (impact High) and creates nothing when declined' {
            Mock -ModuleName DnsTools Read-Host { 'n' }

            $results = @(New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'contoso.local' @script:Common)

            Should -Invoke Read-Host -ModuleName DnsTools -Times 1 -Exactly -ParameterFilter { $Prompt -like 'Create reverse zone*17.0.10.in-addr.arpa*' }
            $results.Count | Should -Be 1
            $results[0].Result | Should -BeExactly 'Skipped'
            $results[0].Error | Should -BeExactly 'Declined at the confirmation prompt.'
            Get-StubCallCount -Command 'Add-DnsServerPrimaryZone' | Should -Be 0
        }

        It 'creates the zone when the operator answers yes' {
            Mock -ModuleName DnsTools Read-Host { 'y' }

            $results = @(New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'contoso.local' @script:Common -WarningAction SilentlyContinue)

            $results[0].Result | Should -BeExactly 'Success'
            Get-StubZone -Zone '17.0.10.in-addr.arpa' | Should -Not -BeNullOrEmpty
        }

        It 'ends on [S]top' {
            Mock -ModuleName DnsTools Read-Host { 's' }

            { New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'contoso.local' -Confirm @script:Common } | Should -Throw '*stopped by the operator*'

            Get-StubCallCount -Command 'Add-DnsServerPrimaryZone' | Should -Be 0
        }

        It 'ends with one terminating error when the session cannot prompt' {
            Mock -ModuleName DnsTools Read-Host { throw 'Windows PowerShell is in NonInteractive mode.' }

            $caught = $null
            try {
                New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'contoso.local' @script:Common -OutVariable streamed -ErrorAction SilentlyContinue
            }
            catch {
                $caught = $_
            }

            $caught.FullyQualifiedErrorId | Should -BeLike 'DnsTools.Confirm.NonInteractive*'
            @($streamed).Count | Should -Be 0
            Get-StubCallCount -Command 'Add-DnsServerPrimaryZone' | Should -Be 0
        }

        It 'does not make the server the session''s writer server under -WhatIf, but does when it creates the zone' {
            Mock -ModuleName DnsTools Write-Host { }

            $null = New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'contoso.local' -WhatIf @script:Common
            InModuleScope DnsTools { $script:WriterServer } | Should -BeNullOrEmpty

            $null = New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'contoso.local' -Force @script:Common -WarningAction SilentlyContinue
            InModuleScope DnsTools { $script:WriterServer } | Should -BeExactly 'dc01'
        }
    }

    Context 'Result objects and the change log' {
        It 'gives every Result the properties of CONTRACTS.md 12.2 in order and writes one log line per Result to -LogPath' {
            $results = @(New-DnsReverseZone -NetworkId '10.0.17.0/24' -CopySettingsFrom 'contoso.local' -Force @script:Common -WarningAction SilentlyContinue)
            $results += @(New-DnsReverseZone -NetworkId '10.0.16.0/24' -CopySettingsFrom 'contoso.local' -Force @script:Common)

            $results.Count | Should -Be 3
            foreach ($result in $results) {
                $result.PSObject.TypeNames[0] | Should -BeExactly 'DnsTools.Result'
                @($result.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly ($script:ResultProperties -join ',')
                $result.Server | Should -BeExactly 'dc01'
                { [guid]$result.Id } | Should -Not -Throw
                $result.Timestamp | Should -BeOfType [datetime]
            }
            $results[0].BatchId | Should -BeExactly $results[1].BatchId
            $results[2].BatchId | Should -Not -Be $results[0].BatchId

            $lines = @(Get-LogLine -Path $script:LogPath)
            $lines.Count | Should -Be 3
            foreach ($line in $lines) {
                @($line.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly ($script:LogKeys -join ',')
                $line.Name | Should -Not -BeNullOrEmpty
            }
            ($lines | ForEach-Object { $_.Id }) -join ',' | Should -BeExactly (($results | ForEach-Object { $_.Id }) -join ',')
            $lines[0].Data | Should -BeExactly '10.0.17.0/24'
        }
    }
}

Describe 'New-DnsLiveReverseZone' {
    BeforeEach {
        Initialize-ReverseZoneTest
        $script:LogPath = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N') + '\changes.jsonl')
    }

    Context 'The batch of the caller' {
        It 'writes CreateZone and SetZoneAging with the BatchId of the given batch, also in the log' {
            $run = Invoke-LiveReverseZone -NetworkId '10.0.17.0/24' -LogPath $script:LogPath

            $run['Error'] | Should -BeNullOrEmpty
            ($run['Results'] | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:Success|SetZoneAging:Success'
            foreach ($result in $run['Results']) {
                $result.BatchId | Should -BeExactly $run['BatchId']
            }
            $lines = @(Get-LogLine -Path $script:LogPath)
            $lines.Count | Should -Be 2
            ($lines | ForEach-Object { $_.BatchId } | Sort-Object -Unique) -join ',' | Should -BeExactly $run['BatchId']
            Test-CachedZone -Zone '17.0.10.in-addr.arpa' | Should -BeTrue
        }

        It 'asks once when [A]ll is answered at the first zone of a batch, and creates the second zone without asking' {
            Mock -ModuleName DnsTools Read-Host { 'a' }

            $run = Invoke-LiveReverseZone -NetworkId '10.0.17.0/24', '10.0.18.0/24' -LogPath $script:LogPath -NoForce

            Should -Invoke Read-Host -ModuleName DnsTools -Times 1 -Exactly -ParameterFilter { $Prompt -like 'Create reverse zone*17.0.10.in-addr.arpa*' }
            ($run['Results'] | ForEach-Object { $_.Name + ':' + $_.Result }) -join '|' | Should -BeExactly '17.0.10.in-addr.arpa:Success|17.0.10.in-addr.arpa:Success|18.0.10.in-addr.arpa:Success|18.0.10.in-addr.arpa:Success'
        }

        It 'writes Skipped CreateZone and no SetZoneAging when the zone is declined' {
            Mock -ModuleName DnsTools Read-Host { 'n' }

            $run = Invoke-LiveReverseZone -NetworkId '10.0.17.0/24' -LogPath $script:LogPath -NoForce

            ($run['Results'] | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:Skipped'
            $run['Results'][0].Error | Should -BeExactly 'Declined at the confirmation prompt.'
            Get-StubCallCount -Command 'Add-DnsServerPrimaryZone' | Should -Be 0
        }
    }

    Context 'AlreadyDone and SetZoneAging' {
        It 'reports AlreadyDone for a hosted zone, without SetZoneAging' {
            $run = Invoke-LiveReverseZone -NetworkId '10.0.16.0/24' -LogPath $script:LogPath

            ($run['Results'] | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:AlreadyDone'
            Get-StubCallCount -Command 'Add-DnsServerPrimaryZone' | Should -Be 0
            Get-StubCallCount -Command 'Set-DnsServerZoneAging' | Should -Be 0
        }

        It 'reports AlreadyDone on 9609, without SetZoneAging, and refreshes the zone table' {
            InModuleScope DnsTools {
                $script:DnsStub.BeforeCall['Add-DnsServerPrimaryZone'] = { Add-DnsStubZone -Name '17.0.10.in-addr.arpa' }
            }

            $run = Invoke-LiveReverseZone -NetworkId '10.0.17.0/24' -LogPath $script:LogPath

            $run['Error'] | Should -BeNullOrEmpty
            ($run['Results'] | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:AlreadyDone'
            Get-StubCallCount -Command 'Add-DnsServerPrimaryZone' | Should -Be 1
            Get-StubCallCount -Command 'Set-DnsServerZoneAging' | Should -Be 0
            Test-CachedZone -Zone '17.0.10.in-addr.arpa' | Should -BeTrue
        }

        It 'writes SetZoneAging as WhatIf under -WhatIf, changes nothing and leaves the zone table as it is' {
            Mock -ModuleName DnsTools Write-Host { }

            $run = Invoke-LiveReverseZone -NetworkId '10.0.17.0/24' -LogPath $script:LogPath -Preview

            ($run['Results'] | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:WhatIf|SetZoneAging:WhatIf'
            Get-StubCallCount -Command 'Add-DnsServerPrimaryZone' | Should -Be 0
            Get-StubCallCount -Command 'Set-DnsServerZoneAging' | Should -Be 0
            Get-StubCallCount -Command 'Get-DnsServerZone' | Should -Be 1
            Test-CachedZone -Zone '17.0.10.in-addr.arpa' | Should -BeFalse
        }

        It 'raises AgingFailed only after the zone table refresh when the aging step fails' {
            InModuleScope DnsTools {
                $script:DnsStub.Fail['Set-DnsServerZoneAging'] = @('*')
            }

            $run = Invoke-LiveReverseZone -NetworkId '10.0.17.0/24' -LogPath $script:LogPath

            ($run['Results'] | ForEach-Object { $_.Action + ':' + $_.Result }) -join '|' | Should -BeExactly 'CreateZone:Success|SetZoneAging:Failed'
            $run['Error'].FullyQualifiedErrorId | Should -BeLike 'DnsTools.New-DnsLiveReverseZone.AgingFailed,*'
            Test-CachedZone -Zone '17.0.10.in-addr.arpa' | Should -BeTrue
        }
    }

    Context 'Terminating errors' {
        It 'writes a Failed CreateZone and raises <Reason> for <Case>' -ForEach @(
            @{ Case = 'a network without a zone of its own'; Reason = 'InvalidNetworkId'; NetworkId = '10.0.16.0/23'; Source = 'contoso.local'; Name = '10.0.16.0/23'; FailCode = $null }
            @{ Case = 'a -CopySettingsFrom zone that is not hosted'; Reason = 'ZoneNotFound'; NetworkId = '10.0.17.0/24'; Source = 'nowhere.test'; Name = '17.0.10.in-addr.arpa'; FailCode = $null }
            @{ Case = 'an unreachable server'; Reason = 'ServerUnreachable'; NetworkId = '10.0.17.0/24'; Source = 'contoso.local'; Name = '17.0.10.in-addr.arpa'; FailCode = 1722 }
            @{ Case = 'access denied'; Reason = 'CreateFailed'; NetworkId = '10.0.17.0/24'; Source = 'contoso.local'; Name = '17.0.10.in-addr.arpa'; FailCode = 5 }
            @{ Case = 'a file-backed -CopySettingsFrom zone'; Reason = 'ReplicationScopeRequired'; NetworkId = '10.0.17.0/24'; Source = 'file.local'; Name = '17.0.10.in-addr.arpa'; FailCode = $null }
        ) {
            if ($null -ne $FailCode) {
                InModuleScope DnsTools -Parameters @{ FailCode = $FailCode } {
                    param ($FailCode)
                    $script:DnsStub.Fail['Add-DnsServerPrimaryZone'] = @('*')
                    $script:DnsStub.FailCode['Add-DnsServerPrimaryZone'] = $FailCode
                }
            }

            $run = Invoke-LiveReverseZone -NetworkId $NetworkId -CopySettingsFrom $Source -LogPath $script:LogPath

            $run['Error'].FullyQualifiedErrorId | Should -BeLike "DnsTools.New-DnsLiveReverseZone.$Reason,*"
            @($run['Results']).Count | Should -Be 1
            $run['Results'][0].Action | Should -BeExactly 'CreateZone'
            $run['Results'][0].Result | Should -BeExactly 'Failed'
            $run['Results'][0].Name | Should -BeExactly $Name
            $run['Results'][0].BatchId | Should -BeExactly $run['BatchId']
            $run['Results'][0].Error | Should -Not -BeNullOrEmpty
            @(Get-LogLine -Path $script:LogPath).Count | Should -Be 1
            Get-StubCallCount -Command 'Set-DnsServerZoneAging' | Should -Be 0
        }

        It 'gives ServerUnreachable the batch-abort text' {
            InModuleScope DnsTools {
                $script:DnsStub.Fail['Add-DnsServerPrimaryZone'] = @('*')
                $script:DnsStub.FailCode['Add-DnsServerPrimaryZone'] = 1722
            }

            $run = Invoke-LiveReverseZone -NetworkId '10.0.17.0/24' -LogPath $script:LogPath

            $run['Error'].CategoryInfo.Category | Should -Be 'ConnectionError'
            $run['Error'].Exception.Message | Should -BeLike "The DNS server 'dc01' cannot be reached: * The run was stopped; the remaining input was not processed. Check the server and run the command again."
        }

        It 'lets the non-interactive refusal of the gate pass unchanged' {
            Mock -ModuleName DnsTools Read-Host { throw 'Windows PowerShell is in NonInteractive mode.' }

            $run = Invoke-LiveReverseZone -NetworkId '10.0.17.0/24' -LogPath $script:LogPath -NoForce

            $run['Error'].FullyQualifiedErrorId | Should -BeLike 'DnsTools.Confirm.NonInteractive*'
            @($run['Results']).Count | Should -Be 0
        }
    }
}
