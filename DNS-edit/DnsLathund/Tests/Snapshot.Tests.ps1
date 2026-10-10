#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
<#
    Tests for the snapshot store: Get-DnsSnapshotRoot, Get-/Save-DnsSnapshotMeta,
    Update-DnsSnapshot, Get-DnsSnapshot and Get-DnsSnapshotIndex
    (CONTRACTS.md sections 9.4, 12.3, 13.2 and 13.3).

    Pattern for other test files that need a snapshot: load the stubs into the module
    scope once, then per test point $script:SnapshotRoot, $script:DnsServerExportRoot
    and the stub export root at a fresh folder (Initialize-SnapshotTest below) and use
    -Server $env:COMPUTERNAME, which Export-DnsZoneFile treats as this computer, so
    the export is copied from the local stub export folder.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\DnsLathund.psd1" -Force
    $script:StubPath = Join-Path -Path $PSScriptRoot -ChildPath 'Stubs\DnsServerStubs.ps1'
    $script:Server = $env:COMPUTERNAME.ToLowerInvariant()
    $script:ExportableZones = @('0/25.16.0.10.in-addr.arpa', '16.0.10.in-addr.arpa', 'contoso.local', 'lab.contoso.local')
    $script:SnapshotProperties = @(
        'Server', 'Zone', 'ExportedAt', 'Age', 'IsReverse', 'ZoneType', 'ReplicationScope',
        'DirectoryPartitionName', 'DynamicUpdate', 'AgingEnabled', 'FileSizeBytes', 'Path'
    )

    InModuleScope DnsLathund -Parameters @{ StubPath = $script:StubPath } {
        param ($StubPath)

        . $StubPath

        # The real Export-DnsServerZone supports -WhatIf/-Confirm and the module must
        # pass -WhatIf:$false -Confirm:$false (CONTRACTS.md section 3). The stub does
        # not declare SupportsShouldProcess, so it is wrapped until it does; the
        # wrapper disappears by itself once the stub accepts the switches.
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

        $script:RealCmdlet = @{}
        foreach ($cmdletName in @('Copy-Item', 'Remove-Item', 'New-Item', 'Move-Item', 'Set-Content', 'Add-Content')) {
            $script:RealCmdlet[$cmdletName] = Get-Command -Name $cmdletName -CommandType Cmdlet
        }
    }

    function Initialize-SnapshotTest {
        <#
        .SYNOPSIS
            Fresh stub store, snapshot root and export root under -Root, empty caches,
            and the standard zone set.
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

            # Exportable: four primary zones. Everything else must be left alone.
            Add-DnsStubZone -Name 'contoso.local' -AgingEnabled $true
            Add-DnsStubZone -Name 'lab.contoso.local' -ReplicationScope 'Forest' -DirectoryPartitionName 'ForestDnsZones.contoso.local'
            Add-DnsStubZone -Name '16.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '0/25.16.0.10.in-addr.arpa'
            Add-DnsStubZone -Name 'fabrikam.com' -ZoneType Secondary -IsDsIntegrated $false
            Add-DnsStubZone -Name 'stub.example' -ZoneType Stub -IsDsIntegrated $false
            Add-DnsStubZone -Name 'partner.example' -ZoneType Forwarder -ReplicationScope 'Forest'
            Add-DnsStubZone -Name '0.in-addr.arpa' -IsAutoCreated -IsDsIntegrated $false
            Add-DnsStubZone -Name 'TrustAnchors' -ReplicationScope 'Forest'

            Add-DnsStubRecord -ZoneName 'contoso.local' -Name '@' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'dc01' -RRType A -Data '10.0.16.10'
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'srv01' -RRType A -Data '10.0.16.20'
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'srv02' -RRType A -Data '10.0.16.21' -AgeHours 3636304
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'gw' -RRType CNAME -Data 'srv01.contoso.local'
            Add-DnsStubRecord -ZoneName 'lab.contoso.local' -Name 'test01' -RRType A -Data '10.0.17.5'
            Add-DnsStubRecord -ZoneName '16.0.10.in-addr.arpa' -Name '20' -RRType PTR -Data 'srv01.contoso.local'
            Add-DnsStubRecord -ZoneName '0/25.16.0.10.in-addr.arpa' -Name '5' -RRType PTR -Data 'srv05.contoso.local'
        }
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

Describe 'Get-DnsSnapshotRoot' {
    BeforeEach {
        $script:SavedSnapshotPath = $env:DNSLATHUND_SNAPSHOTPATH
    }

    AfterEach {
        $env:DNSLATHUND_SNAPSHOTPATH = $script:SavedSnapshotPath
        InModuleScope DnsLathund { $script:SnapshotRoot = $null }
    }

    It 'prefers $script:SnapshotRoot, then DNSLATHUND_SNAPSHOTPATH, then LOCALAPPDATA' {
        InModuleScope DnsLathund {
            $env:DNSLATHUND_SNAPSHOTPATH = 'C:\FromEnvironment'
            $script:SnapshotRoot = 'C:\FromModule'
            Get-DnsSnapshotRoot | Should -BeExactly 'C:\FromModule'

            $script:SnapshotRoot = $null
            Get-DnsSnapshotRoot | Should -BeExactly 'C:\FromEnvironment'

            $env:DNSLATHUND_SNAPSHOTPATH = $null
            Get-DnsSnapshotRoot | Should -BeExactly (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'DnsLathund\snapshot')
        }
    }

    It 'returns the lower-case server folder and replaces characters that are not valid in a folder name' {
        InModuleScope DnsLathund {
            $script:SnapshotRoot = 'C:\Snap'
            Get-DnsSnapshotRoot -Server 'DC01.Contoso.LOCAL' | Should -BeExactly 'C:\Snap\dc01.contoso.local'
            Get-DnsSnapshotRoot -Server 'FE80::1' | Should -BeExactly 'C:\Snap\fe80__1'
        }
    }
}

Describe 'Get-DnsSnapshotMeta and Save-DnsSnapshotMeta' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-SnapshotTest -Root $script:Root
    }

    It 'round-trips the metadata, with ExportedAt as an ISO 8601 string with offset on disk' {
        InModuleScope DnsLathund {
            $exportedAt = (Get-Date).AddMinutes(-90)
            $meta = @{
                Zones = @{
                    'contoso.local' = @{
                        File = 'contoso.local.txt'; ExportedAt = $exportedAt; IsReverse = $false; ZoneType = 'Primary'
                        ReplicationScope = 'Domain'; DirectoryPartitionName = 'DomainDnsZones.contoso.local'
                        DynamicUpdate = 'Secure'; AgingEnabled = $true; FileSizeBytes = 1234
                    }
                }
            }
            Save-DnsSnapshotMeta -Server 'DC01' -Meta $meta

            $metaPath = Join-Path -Path $script:SnapshotRoot -ChildPath 'dc01\meta.json'
            $raw = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8
            $raw | Should -Match '"Server":\s*"dc01"'
            $raw | Should -Match '"SchemaVersion":\s*1'
            $raw | Should -Match ('"ExportedAt":\s*"' + [regex]::Escape($exportedAt.ToString('o')) + '"')
            $exportedAt.ToString('o') | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}[+-]\d{2}:\d{2}$'

            $read = Get-DnsSnapshotMeta -Server 'dc01'
            $read | Should -BeOfType [hashtable]
            $read['Server'] | Should -BeExactly 'dc01'
            $read['SchemaVersion'] | Should -Be 1
            $read['Zones'] | Should -BeOfType [hashtable]
            $entry = $read['Zones']['contoso.local']
            $entry | Should -BeOfType [hashtable]
            $entry['ExportedAt'] | Should -BeOfType [datetime]
            $entry['ExportedAt'] | Should -Be $exportedAt
            $entry['ExportedAt'].Kind | Should -Be 'Local'
            $entry['File'] | Should -BeExactly 'contoso.local.txt'
            $entry['IsReverse'] | Should -BeFalse
            $entry['ZoneType'] | Should -Be 'Primary'
            $entry['ReplicationScope'] | Should -Be 'Domain'
            $entry['DirectoryPartitionName'] | Should -Be 'DomainDnsZones.contoso.local'
            $entry['DynamicUpdate'] | Should -Be 'Secure'
            $entry['AgingEnabled'] | Should -BeTrue
            $entry['FileSizeBytes'] | Should -Be 1234
        }
    }

    It 'returns $null with a warning when meta.json is <Case>' -TestCases @(
        @{ Case = 'missing'; Content = $null }
        @{ Case = 'not JSON'; Content = 'this is not json {' }
        @{ Case = 'empty'; Content = '' }
        @{ Case = 'of an unknown schema version'; Content = '{ "Server": "dc01", "SchemaVersion": 2, "Zones": {} }' }
    ) {
        InModuleScope DnsLathund -Parameters @{ Content = $Content } {
            param ($Content)

            $folder = Join-Path -Path $script:SnapshotRoot -ChildPath 'dc01'
            $null = New-Item -Path $folder -ItemType Directory -Force
            if ($null -ne $Content) {
                Set-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'meta.json') -Value $Content -Encoding UTF8
            }

            $result = Get-DnsSnapshotMeta -Server 'dc01' -WarningVariable warnings -WarningAction SilentlyContinue
            $result | Should -BeNullOrEmpty
            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike '*Update-DnsSnapshot*'
        }
    }

    It 'skips a zone entry without a file name or a valid ExportedAt and keeps the others' {
        InModuleScope DnsLathund {
            $folder = Join-Path -Path $script:SnapshotRoot -ChildPath 'dc01'
            $null = New-Item -Path $folder -ItemType Directory -Force
            $json = '{ "Server": "dc01", "SchemaVersion": 1, "Zones": {' +
                ' "good.local": { "File": "good.local.txt", "ExportedAt": "2026-10-09T15:00:00.0000000+02:00" },' +
                ' "nofile.local": { "ExportedAt": "2026-10-09T15:00:00.0000000+02:00" },' +
                ' "baddate.local": { "File": "baddate.local.txt", "ExportedAt": "yesterday-ish" } } }'
            Set-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'meta.json') -Value $json -Encoding UTF8

            $result = Get-DnsSnapshotMeta -Server 'dc01' -WarningVariable warnings -WarningAction SilentlyContinue
            @($result['Zones'].Keys) | Should -Be @('good.local')
            $result['Zones']['good.local']['ExportedAt'] | Should -Be ([datetime]::Parse('2026-10-09T15:00:00.0000000+02:00'))
            $result['Zones']['good.local']['IsReverse'] | Should -BeNullOrEmpty
            @($warnings).Count | Should -Be 2
        }
    }
}

Describe 'Update-DnsSnapshot' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-SnapshotTest -Root $script:Root
    }

    It 'exports every exportable zone and only those, with files, meta.json and a cached index' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server; Expected = $script:ExportableZones } {
            param ($Server, $Expected)

            $snapshots = @(Update-DnsSnapshot -Server $env:COMPUTERNAME)

            @($snapshots | ForEach-Object { $_.Zone }) | Should -Be $Expected
            $script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 4

            $folder = Join-Path -Path $script:SnapshotRoot -ChildPath $Server
            @(Get-ChildItem -LiteralPath $folder -File | ForEach-Object { $_.Name } | Sort-Object) |
                Should -Be @('0_25.16.0.10.in-addr.arpa.txt', '16.0.10.in-addr.arpa.txt', 'contoso.local.txt', 'lab.contoso.local.txt', 'meta.json')
            @(Get-ChildItem -LiteralPath $script:DnsServerExportRoot -Force).Count | Should -Be 0

            $meta = Get-DnsSnapshotMeta -Server $Server
            @($meta['Zones'].Keys | Sort-Object) | Should -Be $Expected
            $meta['Zones']['0/25.16.0.10.in-addr.arpa']['File'] | Should -BeExactly '0_25.16.0.10.in-addr.arpa.txt'

            $script:SnapshotIndexCache.ContainsKey($Server) | Should -BeTrue
            $index = $script:SnapshotIndexCache[$Server]
            @($index['Zones'].Keys | Sort-Object) | Should -Be $Expected
            $index['Names'] | Should -Contain 'srv01.contoso.local'
            $index['Names'] | Should -Contain 'test01.lab.contoso.local'
            $index['Ptr'].ContainsKey('10.0.16.20') | Should -BeTrue
            $index['Ptr'].ContainsKey('10.0.16.5') | Should -BeTrue
            $index['Zones']['contoso.local']['ExportedAt'] | Should -Be $meta['Zones']['contoso.local']['ExportedAt']
        }
    }

    It 'records the zone settings in meta.json' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            $meta = Get-DnsSnapshotMeta -Server $Server
            $folder = Join-Path -Path $script:SnapshotRoot -ChildPath $Server

            $contoso = $meta['Zones']['contoso.local']
            $contoso['IsReverse'] | Should -BeFalse
            $contoso['ZoneType'] | Should -Be 'Primary'
            $contoso['ReplicationScope'] | Should -Be 'Domain'
            $contoso['DirectoryPartitionName'] | Should -Be 'DomainDnsZones.contoso.local'
            $contoso['DynamicUpdate'] | Should -Be 'Secure'
            $contoso['AgingEnabled'] | Should -BeTrue
            $contoso['FileSizeBytes'] | Should -Be (Get-Item -LiteralPath (Join-Path -Path $folder -ChildPath 'contoso.local.txt')).Length
            ((Get-Date) - $contoso['ExportedAt']).TotalMinutes | Should -BeLessThan 5

            $meta['Zones']['lab.contoso.local']['ReplicationScope'] | Should -Be 'Forest'
            $meta['Zones']['16.0.10.in-addr.arpa']['IsReverse'] | Should -BeTrue
        }
    }

    It 'emits DnsLathund.Snapshot objects with every contract property in order and a correct Age' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server; Properties = $script:SnapshotProperties } {
            param ($Server, $Properties)

            $snapshots = @(Update-DnsSnapshot -Server $env:COMPUTERNAME)
            $snapshots.Count | Should -Be 4
            foreach ($snapshot in $snapshots) {
                $snapshot.PSObject.TypeNames[0] | Should -Be 'DnsLathund.Snapshot'
                @($snapshot.PSObject.Properties | ForEach-Object { $_.Name }) | Should -Be $Properties
                $snapshot.Server | Should -BeExactly $Server
                $snapshot.ExportedAt | Should -BeOfType [datetime]
                $snapshot.Age | Should -BeOfType [timespan]
                $snapshot.Age.TotalSeconds | Should -BeGreaterOrEqual 0
                $expectedAge = (Get-Date) - $snapshot.ExportedAt
                [Math]::Abs(($expectedAge - $snapshot.Age).TotalSeconds) | Should -BeLessThan 30
                $snapshot.ZoneType | Should -Be 'Primary'
                Test-Path -LiteralPath $snapshot.Path -PathType Leaf | Should -BeTrue
                $snapshot.FileSizeBytes | Should -Be (Get-Item -LiteralPath $snapshot.Path).Length
            }
            ($snapshots | Where-Object { $_.Zone -eq '16.0.10.in-addr.arpa' }).IsReverse | Should -BeTrue
            ($snapshots | Where-Object { $_.Zone -eq 'contoso.local' }).IsReverse | Should -BeFalse
            ($snapshots | Where-Object { $_.Zone -eq 'contoso.local' }).AgingEnabled | Should -BeTrue
        }
    }

    It 'exports only the zones given with -Zone and keeps the other zones of the snapshot' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server; Expected = $script:ExportableZones } {
            param ($Server, $Expected)

            # Without a previous snapshot only the named zone is in it.
            $first = @(Update-DnsSnapshot -Server $env:COMPUTERNAME -Zone 'CONTOSO.LOCAL.')
            @($first | ForEach-Object { $_.Zone }) | Should -Be @('contoso.local')

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            $before = Get-DnsSnapshotMeta -Server $Server
            $script:DnsStub.Calls['Export-DnsServerZone'] = 0
            Start-Sleep -Milliseconds 20

            $snapshots = @(Update-DnsSnapshot -Server $env:COMPUTERNAME -Zone 'contoso.local')
            $after = Get-DnsSnapshotMeta -Server $Server

            $script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 1
            @($snapshots | ForEach-Object { $_.Zone }) | Should -Be $Expected
            $after['Zones']['contoso.local']['ExportedAt'] | Should -BeGreaterThan $before['Zones']['contoso.local']['ExportedAt']
            foreach ($zoneName in @('lab.contoso.local', '16.0.10.in-addr.arpa', '0/25.16.0.10.in-addr.arpa')) {
                $after['Zones'][$zoneName]['ExportedAt'] | Should -Be $before['Zones'][$zoneName]['ExportedAt']
            }

            # The index still covers the zones that were not exported this time.
            $index = $script:SnapshotIndexCache[$Server]
            @($index['Zones'].Keys | Sort-Object) | Should -Be $Expected
            $index['Names'] | Should -Contain 'test01.lab.contoso.local'
        }
    }

    It 'writes a non-terminating error for a zone that is not hosted or not exportable and exports the rest' {
        InModuleScope DnsLathund {
            $records = @(Update-DnsSnapshot -Server $env:COMPUTERNAME -Zone 'missing.example', 'contoso.local', 'fabrikam.com' 2>&1)
            $errors = @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
            $snapshots = @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

            @($snapshots | ForEach-Object { $_.Zone }) | Should -Be @('contoso.local')
            $errors.Count | Should -Be 2
            $errors[0].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Update-DnsSnapshot.ZoneNotFound*'
            $errors[0].TargetObject | Should -Be 'missing.example'
            $errors[0].CategoryInfo.Category | Should -Be 'ObjectNotFound'
            $errors[1].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Update-DnsSnapshot.ZoneNotExportable*'
            "$($errors[1])" | Should -BeLike '*Secondary*'
        }
    }

    It 'keeps the previous file and meta entry of a zone whose export fails and updates the others' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server; Expected = $script:ExportableZones } {
            param ($Server, $Expected)

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            $folder = Join-Path -Path $script:SnapshotRoot -ChildPath $Server
            $labPath = Join-Path -Path $folder -ChildPath 'lab.contoso.local.txt'
            $labBefore = Get-Content -LiteralPath $labPath -Raw
            $before = Get-DnsSnapshotMeta -Server $Server
            Start-Sleep -Milliseconds 20

            Add-DnsStubRecord -ZoneName 'lab.contoso.local' -Name 'test02' -RRType A -Data '10.0.17.6'
            $script:DnsStub.Fail['Export-DnsServerZone'] = @('lab.contoso.local')
            # -ErrorVariable would also collect the errors handled inside the module;
            # the error stream holds only what the caller sees.
            $records = @(Update-DnsSnapshot -Server $env:COMPUTERNAME 2>&1)
            $errors = @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
            $snapshots = @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

            $errors.Count | Should -Be 1
            $errors[0].FullyQualifiedErrorId | Should -BeLike 'DnsLathund.Update-DnsSnapshot.ExportFailed*'
            $errors[0].TargetObject | Should -Be 'lab.contoso.local'
            "$($errors[0])" | Should -BeLike '*previous snapshot of this zone is kept*'

            Get-Content -LiteralPath $labPath -Raw | Should -Be $labBefore
            @(Get-ChildItem -LiteralPath $folder -Filter '*.tmp').Count | Should -Be 0
            $after = Get-DnsSnapshotMeta -Server $Server
            $after['Zones']['lab.contoso.local']['ExportedAt'] | Should -Be $before['Zones']['lab.contoso.local']['ExportedAt']
            $after['Zones']['contoso.local']['ExportedAt'] | Should -BeGreaterThan $before['Zones']['contoso.local']['ExportedAt']
            @($snapshots | ForEach-Object { $_.Zone }) | Should -Be $Expected

            $index = $script:SnapshotIndexCache[$Server]
            $index['Names'] | Should -Contain 'test01.lab.contoso.local'
            $index['Names'] | Should -Not -Contain 'test02.lab.contoso.local'
        }
    }

    It 'removes zones that are no longer exportable on a full update, but not on a -Zone update' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            $folder = Join-Path -Path $script:SnapshotRoot -ChildPath $Server
            $script:DnsStub.Zones.Remove('lab.contoso.local')

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME -Zone 'contoso.local'
            Test-Path -LiteralPath (Join-Path -Path $folder -ChildPath 'lab.contoso.local.txt') | Should -BeTrue

            $snapshots = @(Update-DnsSnapshot -Server $env:COMPUTERNAME)
            @($snapshots | ForEach-Object { $_.Zone }) | Should -Not -Contain 'lab.contoso.local'
            $snapshots.Count | Should -Be 3
            Test-Path -LiteralPath (Join-Path -Path $folder -ChildPath 'lab.contoso.local.txt') | Should -BeFalse
            @((Get-DnsSnapshotMeta -Server $Server)['Zones'].Keys) | Should -Not -Contain 'lab.contoso.local'
            @($script:SnapshotIndexCache[$Server]['Zones'].Keys) | Should -Not -Contain 'lab.contoso.local'
        }
    }

    It 'exports nothing and writes nothing with -WhatIf, and lists the zones in Verbose' {
        InModuleScope DnsLathund -Parameters @{ Expected = $script:ExportableZones } {
            param ($Expected)

            $records = @(Update-DnsSnapshot -Server $env:COMPUTERNAME -WhatIf -Verbose 4>&1 6>$null)

            @($records | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }).Count | Should -Be 0
            $verboseText = @($records | ForEach-Object { "$_" }) -join "`n"
            foreach ($zoneName in $Expected) {
                $verboseText | Should -BeLike "*Zone to export: '$zoneName'*"
            }
            Test-Path -LiteralPath $script:SnapshotRoot | Should -BeFalse
            $script:DnsStub.Calls['Export-DnsServerZone'] | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $script:DnsStub.ExportRoot -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
            $script:SnapshotIndexCache.Count | Should -Be 0
        }
    }

    It 'leaves an existing snapshot untouched with -WhatIf' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            $metaPath = Join-Path -Path $script:SnapshotRoot -ChildPath "$Server\meta.json"
            $metaBefore = Get-Content -LiteralPath $metaPath -Raw
            $indexBefore = $script:SnapshotIndexCache[$Server]

            $output = Update-DnsSnapshot -Server $env:COMPUTERNAME -WhatIf 6>$null

            $output | Should -BeNullOrEmpty
            Get-Content -LiteralPath $metaPath -Raw | Should -Be $metaBefore
            $script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 4
            [object]::ReferenceEquals($script:SnapshotIndexCache[$Server], $indexBefore) | Should -BeTrue
        }
    }

    It 'never prompts with -Force or -Confirm:$false, or with the default confirmation preference' {
        InModuleScope DnsLathund {
            Mock Read-Host { throw 'Read-Host must not be called.' }

            @(Update-DnsSnapshot -Server $env:COMPUTERNAME -Force).Count | Should -Be 4
            @(Update-DnsSnapshot -Server $env:COMPUTERNAME -Confirm:$false).Count | Should -Be 4
            @(Update-DnsSnapshot -Server $env:COMPUTERNAME -Confirm -Force).Count | Should -Be 4
            @(Update-DnsSnapshot -Server $env:COMPUTERNAME).Count | Should -Be 4

            Should -Invoke Read-Host -Times 0 -Exactly
        }
    }

    It 'asks once for the whole export with -Confirm and exports nothing when declined' {
        InModuleScope DnsLathund {
            Mock Read-Host { 'n' }

            $output = Update-DnsSnapshot -Server $env:COMPUTERNAME -Confirm

            $output | Should -BeNullOrEmpty
            Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $Prompt -like '*Export DNS zones to local snapshot*4 zone(s) on*' }
            $script:DnsStub.Calls['Export-DnsServerZone'] | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:SnapshotRoot | Should -BeFalse
        }
    }

    It 'calls every file write with -WhatIf:$false and -Confirm:$false' {
        InModuleScope DnsLathund {
            Mock Copy-Item { & $script:RealCmdlet['Copy-Item'] @PesterBoundParameters }
            Mock Remove-Item { & $script:RealCmdlet['Remove-Item'] @PesterBoundParameters }
            Mock New-Item { & $script:RealCmdlet['New-Item'] @PesterBoundParameters }
            Mock Move-Item { & $script:RealCmdlet['Move-Item'] @PesterBoundParameters }
            Mock Set-Content { & $script:RealCmdlet['Set-Content'] @PesterBoundParameters }
            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            $script:DnsStub.Zones.Remove('lab.contoso.local')
            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME

            $safeCall = {
                $PesterBoundParameters.ContainsKey('WhatIf') -and -not $PesterBoundParameters['WhatIf'] -and
                $PesterBoundParameters.ContainsKey('Confirm') -and -not $PesterBoundParameters['Confirm']
            }
            $unsafeCall = { -not (& $safeCall) }
            foreach ($cmdletName in @('Copy-Item', 'Remove-Item', 'New-Item', 'Move-Item', 'Set-Content')) {
                Should -Invoke $cmdletName -ParameterFilter $safeCall -Because "$cmdletName is used by Update-DnsSnapshot"
                Should -Invoke $cmdletName -ParameterFilter $unsafeCall -Times 0 -Exactly -Because "$cmdletName must carry -WhatIf:`$false -Confirm:`$false"
            }
        }
    }
}

Describe 'Get-DnsSnapshot' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-SnapshotTest -Root $script:Root
    }

    It 'lists the zones of the snapshot from meta.json without calling the DNS server' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server; Expected = $script:ExportableZones; Properties = $script:SnapshotProperties } {
            param ($Server, $Expected, $Properties)

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            $script:DnsStub.Calls = @{}
            $script:ZoneTableCache = @{}
            Mock Get-DnsZoneTable { throw 'Get-DnsSnapshot must not read the zone table.' }

            $snapshots = @(Get-DnsSnapshot -Server $env:COMPUTERNAME)

            @($snapshots | ForEach-Object { $_.Zone }) | Should -Be $Expected
            $script:DnsStub.Calls.Count | Should -Be 0
            Should -Invoke Get-DnsZoneTable -Times 0 -Exactly
            foreach ($snapshot in $snapshots) {
                $snapshot.PSObject.TypeNames[0] | Should -Be 'DnsLathund.Snapshot'
                @($snapshot.PSObject.Properties | ForEach-Object { $_.Name }) | Should -Be $Properties
                $snapshot.Server | Should -BeExactly $Server
                Test-Path -LiteralPath $snapshot.Path | Should -BeTrue
            }
        }
    }

    It 'warns and returns nothing, without an error, when no snapshot folder exists' {
        InModuleScope DnsLathund {
            $output = Get-DnsSnapshot -Server 'NoSnapshot01' -WarningVariable warnings -WarningAction SilentlyContinue -ErrorVariable errors

            $output | Should -BeNullOrEmpty
            @($errors).Count | Should -Be 0
            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike "*No snapshot exists for 'nosnapshot01'*Update-DnsSnapshot*"
        }
    }

    It 'filters with -Zone, exact or with wildcards, and warns about a zone that is not in the snapshot' {
        InModuleScope DnsLathund {
            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME

            @(Get-DnsSnapshot -Server $env:COMPUTERNAME -Zone 'contoso.local' | ForEach-Object { $_.Zone }) | Should -Be @('contoso.local')
            @(Get-DnsSnapshot -Server $env:COMPUTERNAME -Zone 'CONTOSO.LOCAL.' | ForEach-Object { $_.Zone }) | Should -Be @('contoso.local')
            @(Get-DnsSnapshot -Server $env:COMPUTERNAME -Zone '*.in-addr.arpa' | ForEach-Object { $_.Zone }) | Should -Be @('0/25.16.0.10.in-addr.arpa', '16.0.10.in-addr.arpa')
            @(Get-DnsSnapshot -Server $env:COMPUTERNAME -Zone 'lab.*', 'contoso.local' | ForEach-Object { $_.Zone }) | Should -Be @('contoso.local', 'lab.contoso.local')

            $output = Get-DnsSnapshot -Server $env:COMPUTERNAME -Zone 'missing.example' -WarningVariable warnings -WarningAction SilentlyContinue
            $output | Should -BeNullOrEmpty
            "$($warnings[0])" | Should -BeLike "*'missing.example' is not in the snapshot*"
        }
    }

    It 'lists several servers, from -Server and from the pipeline' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            $null = Update-DnsSnapshot -Server 'localhost' -Zone 'contoso.local'

            $snapshots = @(Get-DnsSnapshot -Server $env:COMPUTERNAME, 'localhost')
            $snapshots.Count | Should -Be 5
            @($snapshots | Where-Object { $_.Server -eq $Server }).Count | Should -Be 4
            @($snapshots | Where-Object { $_.Server -eq 'localhost' } | ForEach-Object { $_.Zone }) | Should -Be @('contoso.local')

            @($env:COMPUTERNAME, 'localhost' | Get-DnsSnapshot).Count | Should -Be 5
        }
    }

    It 'uses the logon server when -Server is not given' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            $savedLogonServer = $env:LOGONSERVER
            try {
                $env:LOGONSERVER = '\\' + $env:COMPUTERNAME
                $snapshots = @(Get-DnsSnapshot)
            }
            finally {
                $env:LOGONSERVER = $savedLogonServer
            }
            $snapshots.Count | Should -Be 4
            $snapshots[0].Server | Should -BeExactly $Server
        }
    }

    It 'computes Age from ExportedAt in meta.json' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            $meta = Get-DnsSnapshotMeta -Server $Server
            $twoDaysAgo = (Get-Date).AddDays(-2)
            $meta['Zones']['contoso.local']['ExportedAt'] = $twoDaysAgo
            Save-DnsSnapshotMeta -Server $Server -Meta $meta

            $snapshot = Get-DnsSnapshot -Server $env:COMPUTERNAME -Zone 'contoso.local'
            $snapshot.ExportedAt | Should -Be $twoDaysAgo
            $snapshot.Age.TotalHours | Should -BeGreaterOrEqual 48
            $snapshot.Age.TotalHours | Should -BeLessThan 48.1
        }
    }

    It 'warns and returns nothing when meta.json is corrupt' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            Set-Content -LiteralPath (Join-Path -Path $script:SnapshotRoot -ChildPath "$Server\meta.json") -Value '{ broken' -Encoding UTF8

            $records = @(Get-DnsSnapshot -Server $env:COMPUTERNAME -WarningVariable warnings -WarningAction SilentlyContinue 2>&1)
            $records.Count | Should -Be 0 -Because 'neither output nor an error may reach the caller'
            @($warnings).Count | Should -Be 1
        }
    }
}

Describe 'Get-DnsSnapshotIndex' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-SnapshotTest -Root $script:Root
    }

    It 'loads the snapshot from disk once and returns the cached index on the second call' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server; Expected = $script:ExportableZones } {
            param ($Server, $Expected)

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            $meta = Get-DnsSnapshotMeta -Server $Server
            $script:SnapshotIndexCache = @{}
            $exportCalls = $script:DnsStub.Calls['Export-DnsServerZone']

            $first = Get-DnsSnapshotIndex -Server $env:COMPUTERNAME -WarningVariable warnings
            $second = Get-DnsSnapshotIndex -Server $env:COMPUTERNAME

            @($warnings).Count | Should -Be 0
            $first | Should -BeOfType [hashtable]
            [object]::ReferenceEquals($first, $second) | Should -BeTrue
            [object]::ReferenceEquals($script:SnapshotIndexCache[$Server], $first) | Should -BeTrue
            @($first['Zones'].Keys | Sort-Object) | Should -Be $Expected
            $first['Zones']['lab.contoso.local']['ExportedAt'] | Should -Be $meta['Zones']['lab.contoso.local']['ExportedAt']
            $first['Names'] | Should -Contain 'gw.contoso.local'
            $first['Ptr'].ContainsKey('10.0.16.5') | Should -BeTrue
            $script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be $exportCalls
        }
    }

    It 'returns the rebuilt index after Update-DnsSnapshot' {
        InModuleScope DnsLathund {
            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            $before = Get-DnsSnapshotIndex -Server $env:COMPUTERNAME

            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'new01' -RRType A -Data '10.0.16.30'
            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME -Zone 'contoso.local'
            $after = Get-DnsSnapshotIndex -Server $env:COMPUTERNAME

            [object]::ReferenceEquals($before, $after) | Should -BeFalse
            $before['Names'] | Should -Not -Contain 'new01.contoso.local'
            $after['Names'] | Should -Contain 'new01.contoso.local'
            $after['Names'] | Should -Contain 'test01.lab.contoso.local'
        }
    }

    It 'warns, but uses the snapshot, when it is older than -MaxSnapshotAge' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            $meta = Get-DnsSnapshotMeta -Server $Server
            $meta['Zones']['lab.contoso.local']['ExportedAt'] = (Get-Date).AddDays(-3).AddMinutes(-5)
            Save-DnsSnapshotMeta -Server $Server -Meta $meta
            $script:SnapshotIndexCache = @{}
            $exportCalls = $script:DnsStub.Calls['Export-DnsServerZone']

            $index = Get-DnsSnapshotIndex -Server $env:COMPUTERNAME -MaxSnapshotAge (New-TimeSpan -Days 1) -WarningVariable warnings -WarningAction SilentlyContinue
            $index | Should -Not -BeNullOrEmpty
            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike "*'$Server' is 3d 0h 5m old*Update-DnsSnapshot -Server $Server*"
            $index['OldestExportedAt'] | Should -Be $meta['Zones']['lab.contoso.local']['ExportedAt']

            # The cached index warns as well; a fresh enough limit does not.
            $null = Get-DnsSnapshotIndex -Server $env:COMPUTERNAME -MaxSnapshotAge (New-TimeSpan -Days 1) -WarningVariable cachedWarnings -WarningAction SilentlyContinue
            @($cachedWarnings).Count | Should -Be 1
            $null = Get-DnsSnapshotIndex -Server $env:COMPUTERNAME -MaxSnapshotAge (New-TimeSpan -Days 7) -WarningVariable noWarnings
            @($noWarnings).Count | Should -Be 0

            # Stale is not refreshed automatically.
            $script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be $exportCalls
        }
    }

    It 'exports automatically, after a warning, when no snapshot exists' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server; Expected = $script:ExportableZones } {
            param ($Server, $Expected)

            # Also under a caller's -WhatIf: a search must still get its data.
            $WhatIfPreference = $true
            $index = Get-DnsSnapshotIndex -Server $env:COMPUTERNAME -WarningVariable warnings -WarningAction SilentlyContinue
            $WhatIfPreference = $false

            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeExactly "No snapshot exists for '$Server'. Exporting 4 zone(s) now; this can take several minutes on large zones."
            $index | Should -Not -BeNullOrEmpty
            @($index['Zones'].Keys | Sort-Object) | Should -Be $Expected
            $script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 4
            Test-Path -LiteralPath (Join-Path -Path $script:SnapshotRoot -ChildPath "$Server\meta.json") | Should -BeTrue
            [object]::ReferenceEquals($script:SnapshotIndexCache[$Server], $index) | Should -BeTrue
        }
    }

    It 'throws when no snapshot exists and no zone can be exported' {
        InModuleScope DnsLathund {
            $script:DnsStub.Fail['Export-DnsServerZone'] = @('*')

            { Get-DnsSnapshotIndex -Server $env:COMPUTERNAME -WarningAction SilentlyContinue 2>$null } |
                Should -Throw '*Could not create a snapshot*Update-DnsSnapshot*'
        }
    }

    It 'reads an existing snapshot when the zone table cannot be read' {
        InModuleScope DnsLathund -Parameters @{ Expected = $script:ExportableZones } {
            param ($Expected)

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            $script:SnapshotIndexCache = @{}
            $script:ZoneTableCache = @{}
            $exportCalls = $script:DnsStub.Calls['Export-DnsServerZone']
            Mock Get-DnsServerZone { throw 'The RPC server is unavailable (test).' }

            $index = Get-DnsSnapshotIndex -Server $env:COMPUTERNAME -WarningVariable warnings -WarningAction SilentlyContinue

            Should -Invoke Get-DnsServerZone -Times 1 -Exactly
            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike '*The RPC server is unavailable (test).*'
            @($index['Zones'].Keys | Sort-Object) | Should -Be $Expected
            $index['Names'] | Should -Contain 'srv01.contoso.local'
            # The classless zone is understood from its name alone.
            $index['Ptr'].ContainsKey('10.0.16.5') | Should -BeTrue
            $script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be $exportCalls
        }
    }

    It 'leaves out a zone whose file is missing, with a warning' {
        InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)

            $null = Update-DnsSnapshot -Server $env:COMPUTERNAME
            Remove-Item -LiteralPath (Join-Path -Path $script:SnapshotRoot -ChildPath "$Server\lab.contoso.local.txt")
            $script:SnapshotIndexCache = @{}

            $index = Get-DnsSnapshotIndex -Server $env:COMPUTERNAME -WarningVariable warnings -WarningAction SilentlyContinue

            @($index['Zones'].Keys) | Should -Not -Contain 'lab.contoso.local'
            @($index['Zones'].Keys).Count | Should -Be 3
            "$($warnings[0])" | Should -BeLike "*lab.contoso.local*missing*"
        }
    }
}
