#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
<#
    Tests for Backup-DnsZone (CONTRACTS.md sections 13.8, 13.9, 10, 11 and 12.2).

    The stubs are loaded into the module scope once. Initialize-BackupTest points the
    snapshot root, the stub export root and the change log at a fresh folder, clears
    every cache and builds this environment on the server $env:COMPUTERNAME, which
    Export-DnsZoneFile treats as this computer (see Snapshot.Tests.ps1):

      contoso.local               primary, exportable
      16.0.10.in-addr.arpa        primary, exportable
      0/25.16.0.10.in-addr.arpa   primary, exportable (classless: '/' is not valid in a file name)
      fabrikam.com                secondary, not exportable
      0.in-addr.arpa              auto-created, not exportable
      TrustAnchors                primary, not exportable

    Backup-DnsZone has no -Delay (CONTRACTS.md section 6 limits it to Remove-, New- and
    Set-DnsEntry), so the Start-Sleep test of the other change commands has no
    counterpart here; one test asserts that the parameter does not exist.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\DnsTools.psd1" -Force
    $script:StubPath = Join-Path -Path $PSScriptRoot -ChildPath 'Stubs\DnsServerStubs.ps1'
    $script:Server = $env:COMPUTERNAME.ToLowerInvariant()
    $script:ExportableZones = @('0/25.16.0.10.in-addr.arpa', '16.0.10.in-addr.arpa', 'contoso.local') | Sort-Object
    $script:ResultProperties = @('Action', 'Name', 'Type', 'Data', 'Result', 'Error', 'Zone', 'NodeName', 'Server', 'Id', 'BatchId', 'Timestamp')
    $script:LogKeys = @('Id', 'BatchId', 'Timestamp', 'Operator', 'Server', 'Action', 'Zone', 'NodeName', 'Name', 'Type', 'Data', 'Before', 'After', 'Result', 'Error')

    InModuleScope DnsTools -Parameters @{ StubPath = $script:StubPath } {
        param ($StubPath)
        . $StubPath
    }

    function Initialize-BackupTest {
        <#
        .SYNOPSIS
            Fresh stub store and folders under -Root, empty caches, and the
            environment described at the top of this file.
        #>
        param ([string]$Root)

        InModuleScope DnsTools -Parameters @{ Root = $Root } {
            param ($Root)

            $script:SnapshotRoot = Join-Path -Path $Root -ChildPath 'snapshot'
            $script:DnsServerExportRoot = Join-Path -Path $Root -ChildPath 'server-dns'
            Reset-DnsStubStore -ExportRoot $script:DnsServerExportRoot
            $script:ZoneTableCache = @{}
            $script:CimSessionCache = @{}
            $script:SnapshotIndexCache = @{}
            $script:WriterServer = $null

            Add-DnsStubZone -Name 'contoso.local' -AgingEnabled $true
            Add-DnsStubZone -Name '16.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '0/25.16.0.10.in-addr.arpa'
            Add-DnsStubZone -Name 'fabrikam.com' -ZoneType Secondary -IsDsIntegrated $false
            Add-DnsStubZone -Name '0.in-addr.arpa' -IsAutoCreated -IsDsIntegrated $false
            Add-DnsStubZone -Name 'TrustAnchors' -ReplicationScope 'Forest'

            Add-DnsStubRecord -ZoneName 'contoso.local' -Name '@' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'srv01' -RRType A -Data '10.0.16.20'
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'gw' -RRType CNAME -Data 'srv01.contoso.local'
            Add-DnsStubRecord -ZoneName '16.0.10.in-addr.arpa' -Name '20' -RRType PTR -Data 'srv01.contoso.local'
            Add-DnsStubRecord -ZoneName '0/25.16.0.10.in-addr.arpa' -Name '5' -RRType PTR -Data 'srv05.contoso.local'
        }
    }
}

AfterAll {
    InModuleScope DnsTools {
        $script:SnapshotRoot = $null
        $script:DnsServerExportRoot = Join-Path $env:windir 'System32\dns'
        $script:SnapshotIndexCache = @{}
        $script:ZoneTableCache = @{}
    }
}

Describe 'Backup-DnsZone' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $script:BackupPath = Join-Path -Path $script:Root -ChildPath 'backup'
        $script:LogPath = Join-Path -Path $script:Root -ChildPath 'log\backup.jsonl'
        $script:Base = @{ Server = $env:COMPUTERNAME; Path = $script:BackupPath; LogPath = $script:LogPath }

        # A run that forgets -LogPath must not write to the real default log either.
        $script:SavedLogEnvironment = $env:DNSTOOLS_LOGPATH
        $script:DefaultLogPath = Join-Path -Path $script:Root -ChildPath 'default-log\default.jsonl'
        $env:DNSTOOLS_LOGPATH = $script:DefaultLogPath

        Initialize-BackupTest -Root $script:Root
    }

    AfterEach {
        $env:DNSTOOLS_LOGPATH = $script:SavedLogEnvironment
    }

    Context 'Parameters' {
        It 'declares the parameters, aliases and impact of CONTRACTS.md 13.8 and 6' {
            $command = Get-Command -Name 'Backup-DnsZone'
            $command.Parameters['Path'].Aliases | Should -Contain 'BackupPath'
            $command.Parameters['Server'].Aliases | Should -Contain 'ComputerName'
            $command.Parameters['Zone'].Aliases | Should -Contain 'ZoneName'
            $command.Parameters['Zone'].ParameterType | Should -Be ([string[]])
            $command.Parameters['Server'].ParameterType | Should -Be ([string])
            $command.Parameters['TimeoutSec'].ParameterType | Should -Be ([int])
            foreach ($name in @('Zone', 'Path', 'Server', 'Credential', 'TimeoutSec', 'LogPath', 'Force', 'WhatIf', 'Confirm')) {
                $command.Parameters.Keys | Should -Contain $name
            }
            $command.OutputType.Name | Should -Contain 'DnsTools.Result'
        }

        It 'has no -Delay (CONTRACTS.md 6 limits it to Remove-, New- and Set-DnsEntry) and takes no pipeline input' {
            $command = Get-Command -Name 'Backup-DnsZone'
            $command.Parameters.Keys | Should -Not -Contain 'Delay'
            foreach ($parameter in $command.Parameters.Values) {
                foreach ($attribute in $parameter.Attributes) {
                    if ($attribute -is [System.Management.Automation.ParameterAttribute]) {
                        $attribute.ValueFromPipeline | Should -BeFalse -Because "-$($parameter.Name) must not take pipeline input"
                        $attribute.ValueFromPipelineByPropertyName | Should -BeFalse -Because "-$($parameter.Name) must not take pipeline input"
                    }
                }
            }
        }
    }

    Context 'Backing up every exportable zone' {
        It 'exports every exportable zone once and only those, and leaves nothing in the server export folder' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Expected = $script:ExportableZones } {
                param ($Base, $Expected)

                $results = @(Backup-DnsZone @Base)

                $results.Count | Should -Be 3
                @($results | ForEach-Object { $_.Zone } | Sort-Object) | Should -Be $Expected
                $script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 3
                @(Get-ChildItem -LiteralPath $script:DnsServerExportRoot -Force).Count | Should -Be 0
                foreach ($result in $results) {
                    $result.Result | Should -BeExactly 'Success'
                }
            }
        }

        It 'creates a server-and-time-stamped folder with one backup file per zone and one RESTORE.md' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Server = $script:Server } {
                param ($Base, $Server)

                $null = Backup-DnsZone @Base

                $folders = @(Get-ChildItem -LiteralPath $Base['Path'] -Directory)
                $folders.Count | Should -Be 1
                $folders[0].Name | Should -Match ('^' + [regex]::Escape($Server) + '-\d{8}-\d{6}$')
                $stamp = $folders[0].Name.Substring($Server.Length + 1)

                $expected = @(
                    'RESTORE.md'
                    "backup_0_25.16.0.10.in-addr.arpa_$stamp.txt"
                    "backup_16.0.10.in-addr.arpa_$stamp.txt"
                    "backup_contoso.local_$stamp.txt"
                ) | Sort-Object
                @(Get-ChildItem -LiteralPath $folders[0].FullName -File | ForEach-Object { $_.Name } | Sort-Object) | Should -Be $expected
                @(Get-ChildItem -LiteralPath $Base['Path'] -Recurse -Filter 'RESTORE.md').Count | Should -Be 1
            }
        }

        It 'saves the zone as exported by the server' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                $results = @(Backup-DnsZone @Base)

                $contoso = Get-Content -LiteralPath ($results | Where-Object { $_.Zone -eq 'contoso.local' }).Data -Raw
                $contoso | Should -Match 'srv01'
                $contoso | Should -Match '10\.0\.16\.20'
                $classless = Get-Content -LiteralPath ($results | Where-Object { $_.Zone -eq '0/25.16.0.10.in-addr.arpa' }).Data -Raw
                $classless | Should -Match 'srv05\.contoso\.local'
            }
        }

        It 'returns one DnsTools.Result per zone with the properties of CONTRACTS.md 12.2 in order' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Server = $script:Server; Properties = $script:ResultProperties } {
                param ($Base, $Server, $Properties)

                $results = @(Backup-DnsZone @Base)

                $folder = @(Get-ChildItem -LiteralPath $Base['Path'] -Directory)[0].FullName
                $batchIds = @($results | ForEach-Object { $_.BatchId } | Select-Object -Unique)
                $batchIds.Count | Should -Be 1
                foreach ($result in $results) {
                    $result.PSObject.TypeNames[0] | Should -BeExactly 'DnsTools.Result'
                    @($result.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly ($Properties -join ',')
                    $result.Action | Should -BeExactly 'Backup'
                    $result.Name | Should -BeExactly $result.Zone
                    $result.Type | Should -BeExactly 'Zone'
                    $result.Result | Should -BeExactly 'Success'
                    $null -eq $result.Error | Should -BeTrue
                    $result.NodeName | Should -BeExactly '@'
                    $result.Server | Should -BeExactly $Server
                    { [guid]$result.Id } | Should -Not -Throw
                    { [guid]$result.BatchId } | Should -Not -Throw
                    $result.Timestamp | Should -BeOfType [datetime]
                    Test-Path -LiteralPath $result.Data -PathType Leaf | Should -BeTrue
                    (Split-Path -Path $result.Data -Parent) | Should -Be (Convert-Path -LiteralPath $folder)
                    (Split-Path -Path $result.Data -Leaf) | Should -BeLike 'backup_*.txt'
                }
            }
        }

        It 'writes RESTORE.md in English with the files, the server, the time, the single-record command and the zone restore steps' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Server = $script:Server } {
                param ($Base, $Server)

                $null = Backup-DnsZone @Base

                $folder = @(Get-ChildItem -LiteralPath $Base['Path'] -Directory)[0]
                $stamp = $folder.Name.Substring($Server.Length + 1)
                $text = Get-Content -LiteralPath (Join-Path -Path $folder.FullName -ChildPath 'RESTORE.md') -Raw -Encoding UTF8

                $text | Should -Match ('(?m)^# Restore DNS zones \(backup taken \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} from ' + [regex]::Escape($Server) + '\)')
                $text | Should -Match ('(?m)^- Server: ' + [regex]::Escape($Server) + '\s*$')
                $text | Should -Match ('(?m)^- Folder: ' + [regex]::Escape($folder.FullName) + '\s*$')
                foreach ($row in @(
                        "| contoso.local | backup_contoso.local_$stamp.txt |"
                        "| 16.0.10.in-addr.arpa | backup_16.0.10.in-addr.arpa_$stamp.txt |"
                        "| 0/25.16.0.10.in-addr.arpa | backup_0_25.16.0.10.in-addr.arpa_$stamp.txt |"
                    )) {
                    $text | Should -BeLike "*$row*"
                }
                $text | Should -Not -BeLike '*fabrikam*'

                # A single record: New-DnsEntry.
                $text | Should -Match 'New-DnsEntry -Name \S+ -Address \S+ -Server '
                $text | Should -Match 'New-DnsEntry -Name \S+ -Target \S+ -Server '

                # A whole AD-integrated zone, in order.
                $text | Should -Match 'Remove-DnsServerZone -Name <zone>'
                $text | Should -Match 'dnscmd \S+ /zoneadd <zone> /primary /file <backup file> /load'
                $text | Should -Match 'ConvertTo-DnsServerPrimaryZone -Name <zone> -ReplicationScope Domain'
                $text | Should -Match 'repadmin /syncall /AdeP'
                $text.IndexOf('Remove-DnsServerZone') | Should -BeLessThan $text.IndexOf('/zoneadd')
                $text.IndexOf('/zoneadd') | Should -BeLessThan $text.IndexOf('ConvertTo-DnsServerPrimaryZone')
                $text.IndexOf('ConvertTo-DnsServerPrimaryZone') | Should -BeLessThan $text.IndexOf('repadmin')
                $text | Should -Match 'SOA serial number and the aging timestamps are not restored'

                # Readable with and without a BOM, on both editions.
                $text -cmatch '[^\x00-\x7F]' | Should -BeFalse
            }
        }

        It 'does not leave anything behind or write to the snapshot' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                $null = Backup-DnsZone @Base

                Test-Path -LiteralPath $script:SnapshotRoot | Should -BeFalse
                $script:SnapshotIndexCache.Count | Should -Be 0
                Test-Path -LiteralPath $Base['LogPath'] -PathType Leaf | Should -BeTrue
            }
        }
    }

    Context 'Requested zones' {
        It 'backs up only the zones named with -Zone, ignoring case, a trailing dot and duplicates' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                $results = @(Backup-DnsZone @Base -Zone 'CONTOSO.LOCAL.', 'contoso.local', '16.0.10.in-addr.arpa', ' ')

                @($results | ForEach-Object { $_.Zone }) | Should -Be @('contoso.local', '16.0.10.in-addr.arpa')
                $script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 2
                @(Get-ChildItem -LiteralPath $Base['Path'] -Recurse -File -Filter 'backup_*.txt').Count | Should -Be 2
            }
        }

        It 'accepts the zone as -ZoneName and the server as -ComputerName' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                $results = @(Backup-DnsZone -ComputerName $Base['Server'] -Path $Base['Path'] -LogPath $Base['LogPath'] -ZoneName 'contoso.local')

                $results.Count | Should -Be 1
                $results[0].Zone | Should -BeExactly 'contoso.local'
            }
        }

        It 'writes a non-terminating error and a Failed result for <Case> and backs up the rest' -TestCases @(
            @{ Case = 'a zone that is not hosted'; Requested = 'missing.example'; Name = 'missing.example'; ErrorId = 'DnsTools.Backup-DnsZone.ZoneNotFound'; Category = 'ObjectNotFound'
                Message = "Zone 'missing.example' is not hosted on '{0}'. Check the name, or list the zones with Get-DnsServerZone -ComputerName {0}." }
            @{ Case = 'a secondary zone'; Requested = 'fabrikam.com'; Name = 'fabrikam.com'; ErrorId = 'DnsTools.Backup-DnsZone.ZoneNotExportable'; Category = 'InvalidOperation'
                Message = "Zone 'fabrikam.com' on '{0}' cannot be exported because it is a Secondary zone. Only primary zones are exported; export it on the server that hosts the primary copy." }
            @{ Case = 'an auto-created zone'; Requested = '0.in-addr.arpa'; Name = '0.in-addr.arpa'; ErrorId = 'DnsTools.Backup-DnsZone.ZoneNotExportable'; Category = 'InvalidOperation'
                Message = "Zone '0.in-addr.arpa' on '{0}' cannot be exported because it was created automatically by the DNS server. Only primary zones are exported; export it on the server that hosts the primary copy." }
            @{ Case = 'the trust anchors zone'; Requested = 'TrustAnchors'; Name = 'trustanchors'; ErrorId = 'DnsTools.Backup-DnsZone.ZoneNotExportable'; Category = 'InvalidOperation'
                Message = "Zone 'trustanchors' on '{0}' cannot be exported because it holds DNSSEC trust anchors. Only primary zones are exported; export it on the server that hosts the primary copy." }
        ) {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Server = $script:Server; Requested = $Requested; Name = $Name; ErrorId = $ErrorId; Category = $Category; Message = $Message } {
                param ($Base, $Server, $Requested, $Name, $ErrorId, $Category, $Message)

                $records = @(Backup-DnsZone @Base -Zone $Requested, 'contoso.local' 2>&1)
                $errors = @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                $results = @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

                $errors.Count | Should -Be 1
                $errors[0].FullyQualifiedErrorId | Should -BeLike "$ErrorId*"
                $errors[0].CategoryInfo.Category | Should -Be $Category
                $errors[0].TargetObject | Should -Be $Requested
                $errors[0].Exception.Message | Should -BeExactly ($Message -f $Server)

                $results.Count | Should -Be 2
                $failed = $results[0]
                $failed.Result | Should -BeExactly 'Failed'
                $failed.Action | Should -BeExactly 'Backup'
                $failed.Name | Should -BeExactly $Name
                $failed.Zone | Should -BeExactly $Name
                $failed.Type | Should -BeExactly 'Zone'
                $failed.NodeName | Should -BeExactly '@'
                $null -eq $failed.Data | Should -BeTrue
                $failed.Error | Should -BeExactly ($Message -f $Server)
                $results[1].Zone | Should -BeExactly 'contoso.local'
                $results[1].Result | Should -BeExactly 'Success'

                $script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 1
                @(Get-ChildItem -LiteralPath $Base['Path'] -Recurse -File -Filter 'backup_*.txt').Count | Should -Be 1
            }
        }

        It 'uses the same texts as Update-DnsSnapshot for zones that are not hosted or not exportable' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                $backupErrors = @(Backup-DnsZone @Base -Zone 'missing.example', 'fabrikam.com', '0.in-addr.arpa', 'TrustAnchors' 2>&1 |
                        Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                $snapshotErrors = @(Update-DnsSnapshot -Server $Base['Server'] -Zone 'missing.example', 'fabrikam.com', '0.in-addr.arpa', 'TrustAnchors' 2>&1 |
                        Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })

                $backupErrors.Count | Should -Be 4
                $snapshotErrors.Count | Should -Be 4
                for ($index = 0; $index -lt 4; $index++) {
                    $backupErrors[$index].Exception.Message | Should -BeExactly $snapshotErrors[$index].Exception.Message
                    $backupErrors[$index].FullyQualifiedErrorId.Replace('Backup-DnsZone', 'Update-DnsSnapshot') | Should -BeExactly $snapshotErrors[$index].FullyQualifiedErrorId
                }
            }
        }

        It 'creates no folder and asks nothing when no requested zone can be backed up' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                Mock Read-Host { throw 'Read-Host must not be called.' }
                Mock Write-Host { }

                $records = @(Backup-DnsZone @Base -Zone 'missing.example', 'fabrikam.com' -Confirm 2>&1)
                $errors = @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                $results = @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

                $errors.Count | Should -Be 2
                @($results | ForEach-Object { $_.Result }) | Should -Be @('Failed', 'Failed')
                Should -Invoke Read-Host -Times 0 -Exactly
                Should -Invoke Write-Host -Times 0 -Exactly
                Test-Path -LiteralPath $Base['Path'] | Should -BeFalse
                [int]$script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 0
                (Get-Content -LiteralPath $Base['LogPath'] -Encoding UTF8).Count | Should -Be 2
            }
        }

        It 'warns and does nothing when the server hosts no exportable zone' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Server = $script:Server } {
                param ($Base, $Server)

                Reset-DnsStubStore -ExportRoot $script:DnsServerExportRoot
                $script:ZoneTableCache = @{}
                Add-DnsStubZone -Name 'fabrikam.com' -ZoneType Secondary -IsDsIntegrated $false
                Add-DnsStubZone -Name '0.in-addr.arpa' -IsAutoCreated -IsDsIntegrated $false

                $records = @(Backup-DnsZone @Base 3>&1)

                $records.Count | Should -Be 1
                $records[0] | Should -BeOfType [System.Management.Automation.WarningRecord]
                $records[0].Message | Should -Be "'$Server' hosts no exportable zones (only secondary, stub, forwarder or automatically created zones). Nothing was backed up."
                Test-Path -LiteralPath $Base['Path'] | Should -BeFalse
                [int]$script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 0
            }
        }

        It 'reads a fresh zone list, so that a zone created after the module cached the table is backed up' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                $null = Get-DnsZoneTable -Server $Base['Server']
                Add-DnsStubZone -Name 'new.contoso.local'

                $results = @(Backup-DnsZone @Base)

                @($results | ForEach-Object { $_.Zone }) | Should -Contain 'new.contoso.local'
                $results.Count | Should -Be 4
            }
        }
    }

    Context 'Export failures' {
        It 'reports a zone whose export fails as Failed with the export error and backs up the others' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Server = $script:Server } {
                param ($Base, $Server)

                $script:DnsStub.Fail['Export-DnsServerZone'] = @('16.0.10.in-addr.arpa')

                $records = @(Backup-DnsZone @Base 2>&1)
                $errors = @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                $results = @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

                $results.Count | Should -Be 3
                $failed = @($results | Where-Object { $_.Result -eq 'Failed' })
                $failed.Count | Should -Be 1
                $failed[0].Zone | Should -BeExactly '16.0.10.in-addr.arpa'
                $failed[0].Action | Should -BeExactly 'Backup'
                $failed[0].Error | Should -BeLike "Zone '16.0.10.in-addr.arpa' on '$Server' could not be backed up: Could not export zone '16.0.10.in-addr.arpa' on '$Server':*Stub failure*"
                # The file that was meant to be written is named, and it does not exist.
                $failed[0].Data | Should -BeLike "$($Base['Path'])\$Server-*\backup_16.0.10.in-addr.arpa_*.txt"
                Test-Path -LiteralPath $failed[0].Data | Should -BeFalse
                @($results | Where-Object { $_.Result -eq 'Success' } | ForEach-Object { $_.Zone } | Sort-Object) | Should -Be @('0/25.16.0.10.in-addr.arpa', 'contoso.local')

                $errors.Count | Should -Be 1
                $errors[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.Backup-DnsZone.ExportFailed*'
                $errors[0].CategoryInfo.Category | Should -Be 'InvalidOperation'
                $errors[0].TargetObject | Should -BeExactly '16.0.10.in-addr.arpa'
                $errors[0].Exception.Message | Should -BeExactly $failed[0].Error

                $script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 3
                @(Get-ChildItem -LiteralPath $script:DnsServerExportRoot -Force).Count | Should -Be 0

                # RESTORE.md lists the files that exist, not the one that failed.
                $folder = @(Get-ChildItem -LiteralPath $Base['Path'] -Directory)[0].FullName
                @(Get-ChildItem -LiteralPath $folder -File -Filter 'backup_*.txt').Count | Should -Be 2
                $text = Get-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'RESTORE.md') -Raw
                $text | Should -BeLike '*| contoso.local |*'
                $text | Should -BeLike '*| 0/25.16.0.10.in-addr.arpa |*'
                $text | Should -Not -BeLike '*| 16.0.10.in-addr.arpa |*'
            }
        }

        It 'stops at the first failed zone with -ErrorAction Stop, after logging it, and still writes RESTORE.md for the zones saved so far' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                $script:DnsStub.Fail['Export-DnsServerZone'] = @('16.0.10.in-addr.arpa')
                $seen = @{ Results = @(); Thrown = $null }

                try {
                    Backup-DnsZone @Base -Zone 'contoso.local', '16.0.10.in-addr.arpa', '0/25.16.0.10.in-addr.arpa' -ErrorAction Stop |
                        ForEach-Object { $seen['Results'] = @($seen['Results']) + @($_) }
                }
                catch {
                    $seen['Thrown'] = $_
                }

                $seen['Thrown'] | Should -Not -BeNullOrEmpty
                $seen['Thrown'].FullyQualifiedErrorId | Should -BeLike 'DnsTools.Backup-DnsZone.ExportFailed*'
                @($seen['Results'] | ForEach-Object { $_.Result }) | Should -Be @('Success', 'Failed')
                $script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 2

                $logged = @(Get-Content -LiteralPath $Base['LogPath'] -Encoding UTF8 | ConvertFrom-Json)
                @($logged | ForEach-Object { $_.Result }) | Should -Be @('Success', 'Failed')

                $folder = @(Get-ChildItem -LiteralPath $Base['Path'] -Directory)[0].FullName
                $text = Get-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'RESTORE.md') -Raw
                $text | Should -BeLike '*| contoso.local |*'
                $text | Should -Not -BeLike '*| 16.0.10.in-addr.arpa |*'
            }
        }

        It 'removes the empty backup folder and writes no RESTORE.md when no zone could be saved' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                $script:DnsStub.Fail['Export-DnsServerZone'] = @('*')

                $records = @(Backup-DnsZone @Base 2>&1)
                $results = @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

                @($results | ForEach-Object { $_.Result }) | Should -Be @('Failed', 'Failed', 'Failed')
                @(Get-ChildItem -LiteralPath $Base['Path'] -Recurse -Force).Count | Should -Be 0
                @(Get-ChildItem -LiteralPath $script:DnsServerExportRoot -Force).Count | Should -Be 0
            }
        }

        It 'warns when RESTORE.md cannot be written but keeps the zone files and results' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                Mock Set-Content { throw 'disk full' } -ParameterFilter { $LiteralPath -like '*RESTORE.md' }

                $records = @(Backup-DnsZone @Base 3>&1)
                $warnings = @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
                $results = @($records | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })

                $warnings.Count | Should -Be 1
                $warnings[0].Message | Should -BeLike 'The zone files were saved, but RESTORE.md could not be written to*disk full*'
                @($results | ForEach-Object { $_.Result }) | Should -Be @('Success', 'Success', 'Success')
                @(Get-ChildItem -LiteralPath $Base['Path'] -Recurse -File -Filter 'backup_*.txt').Count | Should -Be 3
            }
        }

        It 'stops with a terminating error before anything is created when the zone list cannot be read' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                $script:DnsStub.Fail['Get-DnsServerZone'] = @('*')

                { Backup-DnsZone @Base } | Should -Throw "Could not read the zone list from*"
                Test-Path -LiteralPath $Base['Path'] | Should -BeFalse
                [int]$script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 0
            }
        }
    }

    Context 'WhatIf, Confirm and Force' {
        It '-WhatIf prints one gate line, returns one WhatIf result per zone and creates nothing' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Server = $script:Server; Expected = $script:ExportableZones } {
                param ($Base, $Server, $Expected)

                Mock Write-Host { }
                Mock Read-Host { throw 'Read-Host must not be called.' }

                $results = @(Backup-DnsZone @Base -WhatIf)

                Should -Invoke Write-Host -Times 1 -Exactly
                Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq "What if: Performing the operation ""Back up DNS zones"" on target ""3 zone(s) on $Server""." }
                Should -Invoke Read-Host -Times 0 -Exactly

                $results.Count | Should -Be 3
                @($results | ForEach-Object { $_.Zone } | Sort-Object) | Should -Be $Expected
                foreach ($result in $results) {
                    $result.Result | Should -BeExactly 'WhatIf'
                    $result.Action | Should -BeExactly 'Backup'
                    $result.Type | Should -BeExactly 'Zone'
                    $result.NodeName | Should -BeExactly '@'
                    $null -eq $result.Error | Should -BeTrue
                    # The file that would be written.
                    $result.Data | Should -BeLike "$($Base['Path'])\$Server-*\backup_*.txt"
                    Test-Path -LiteralPath $result.Data | Should -BeFalse
                }

                Test-Path -LiteralPath $Base['Path'] | Should -BeFalse
                [int]$script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 0
                @(Get-ChildItem -LiteralPath $script:DnsServerExportRoot -Force -ErrorAction SilentlyContinue).Count | Should -Be 0

                # Logged like any other result.
                $logged = @(Get-Content -LiteralPath $Base['LogPath'] -Encoding UTF8 | ConvertFrom-Json)
                $logged.Count | Should -Be 3
                foreach ($line in $logged) {
                    $line.Result | Should -BeExactly 'WhatIf'
                    $line.Action | Should -BeExactly 'Backup'
                }
            }
        }

        It '-WhatIf with a requested zone that cannot be backed up reports it as Failed and the others as WhatIf' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                Mock Write-Host { }

                $records = @(Backup-DnsZone @Base -Zone 'contoso.local', 'missing.example' -WhatIf 2>&1)
                $errors = @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                $results = @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

                $errors.Count | Should -Be 1
                $errors[0].FullyQualifiedErrorId | Should -BeLike 'DnsTools.Backup-DnsZone.ZoneNotFound*'
                @($results | ForEach-Object { '{0}:{1}' -f $_.Zone, $_.Result }) | Should -Be @('missing.example:Failed', 'contoso.local:WhatIf')
                Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*"1 zone(s) on *' }
                Test-Path -LiteralPath $Base['Path'] | Should -BeFalse
            }
        }

        It '-WhatIf does not need a reachable folder and names a server with colons safely' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                Mock Write-Host { }

                $results = @(Backup-DnsZone -Server 'FE80::1' -Path $Base['Path'] -LogPath $Base['LogPath'] -Zone 'contoso.local' -WhatIf)

                $results.Count | Should -Be 1
                $results[0].Server | Should -BeExactly 'fe80::1'
                $results[0].Data | Should -BeLike "$($Base['Path'])\fe80__1-*\backup_contoso.local_*.txt"
                Test-Path -LiteralPath $Base['Path'] | Should -BeFalse
            }
        }

        It 'never prompts with <Case>' -TestCases @(
            @{ Case = '-Force -Confirm'; Splat = @{ Force = $true; Confirm = $true } }
            @{ Case = '-Confirm:$false'; Splat = @{ Confirm = $false } }
            @{ Case = '-Force'; Splat = @{ Force = $true } }
            @{ Case = 'the default $ConfirmPreference (impact Low)'; Splat = @{} }
        ) {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Splat = $Splat } {
                param ($Base, $Splat)

                Mock Read-Host { throw 'Read-Host must not be called.' }
                Mock Write-Host { }

                $results = @(Backup-DnsZone @Base @Splat)

                Should -Invoke Read-Host -Times 0 -Exactly
                Should -Invoke Write-Host -Times 0 -Exactly
                @($results | ForEach-Object { $_.Result }) | Should -Be @('Success', 'Success', 'Success')
            }
        }

        It '-Confirm asks once for the whole run, not once per zone' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Server = $script:Server } {
                param ($Base, $Server)

                Mock Read-Host { 'y' }

                $results = @(Backup-DnsZone @Base -Confirm)

                Should -Invoke Read-Host -Times 1 -Exactly
                $expectedPrompt = "Back up DNS zones*3 zone(s) on $Server*"
                Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $Prompt -like $expectedPrompt }
                $results.Count | Should -Be 3
            }
        }

        It 'does nothing and returns nothing when the operator answers N' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                Mock Read-Host { 'n' }

                $results = @(Backup-DnsZone @Base -Confirm)

                Should -Invoke Read-Host -Times 1 -Exactly
                $results.Count | Should -Be 0
                Test-Path -LiteralPath $Base['Path'] | Should -BeFalse
                [int]$script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 0
                Test-Path -LiteralPath $Base['LogPath'] | Should -BeFalse
            }
        }

        It '[A] Yes to all is accepted like Yes' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                Mock Read-Host { 'a' }

                $results = @(Backup-DnsZone @Base -Confirm)

                Should -Invoke Read-Host -Times 1 -Exactly
                $results.Count | Should -Be 3
            }
        }

        It '[S] Stop ends the run with a terminating error and creates nothing' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                Mock Read-Host { 's' }

                { Backup-DnsZone @Base -Confirm } | Should -Throw 'Operation stopped by the operator.'

                Test-Path -LiteralPath $Base['Path'] | Should -BeFalse
                [int]$script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 0
            }
        }

        It 'ends with one terminating Confirm.NonInteractive error when the session cannot prompt, and creates nothing' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                Mock Read-Host { throw 'There is no console.' }
                $seen = @{ Results = @(); Thrown = $null }

                try {
                    Backup-DnsZone @Base -Confirm | ForEach-Object { $seen['Results'] = @($seen['Results']) + @($_) }
                }
                catch {
                    $seen['Thrown'] = $_
                }

                Should -Invoke Read-Host -Times 1 -Exactly
                $seen['Thrown'] | Should -Not -BeNullOrEmpty
                $seen['Thrown'].FullyQualifiedErrorId | Should -BeLike 'DnsTools.Confirm.NonInteractive*'
                $seen['Thrown'].Exception.Message | Should -BeLike 'This session cannot prompt. Re-run with -Force*'
                $seen['Results'].Count | Should -Be 0
                Test-Path -LiteralPath $Base['Path'] | Should -BeFalse
                [int]$script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 0
            }
        }
    }

    Context 'Change log' {
        It 'writes exactly one line per result with every CONTRACTS.md 11 key, in order, to -LogPath' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Server = $script:Server; LogKeys = $script:LogKeys; DefaultLogPath = $script:DefaultLogPath } {
                param ($Base, $Server, $LogKeys, $DefaultLogPath)

                $script:DnsStub.Fail['Export-DnsServerZone'] = @('16.0.10.in-addr.arpa')
                $records = @(Backup-DnsZone @Base -Zone 'missing.example', 'contoso.local', '16.0.10.in-addr.arpa' 2>&1)
                $results = @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

                $lines = @(Get-Content -LiteralPath $Base['LogPath'] -Encoding UTF8)
                $lines.Count | Should -Be $results.Count
                $lines.Count | Should -Be 3
                Test-Path -LiteralPath $DefaultLogPath | Should -BeFalse

                for ($index = 0; $index -lt $lines.Count; $index++) {
                    $entry = $lines[$index] | ConvertFrom-Json
                    $result = $results[$index]
                    @($entry.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly ($LogKeys -join ',')
                    $entry.Id | Should -BeExactly $result.Id
                    $entry.BatchId | Should -BeExactly $result.BatchId
                    $entry.Server | Should -BeExactly $Server
                    $entry.Operator | Should -Not -BeNullOrEmpty
                    ([datetime]$entry.Timestamp).ToString('yyyy-MM-ddTHH:mm:ss') | Should -BeExactly $result.Timestamp.ToString('yyyy-MM-ddTHH:mm:ss')
                    $entry.Action | Should -BeExactly 'Backup'
                    $entry.Zone | Should -BeExactly $result.Zone
                    $entry.NodeName | Should -BeExactly '@'
                    $entry.Name | Should -BeExactly $result.Zone
                    $entry.Type | Should -BeExactly 'Zone'
                    $entry.Data | Should -BeExactly $result.Data
                    $entry.Result | Should -BeExactly $result.Result
                    $entry.Error | Should -BeExactly $result.Error
                    $lines[$index] | Should -Match '"Before":null'
                    $lines[$index] | Should -Match '"After":null'
                }

                @($results | ForEach-Object { $_.Result }) | Should -Be @('Failed', 'Success', 'Failed')
                @($lines | ForEach-Object { ($_ | ConvertFrom-Json).BatchId } | Select-Object -Unique).Count | Should -Be 1
            }
        }

        It 'uses DNSTOOLS_LOGPATH when -LogPath is not given' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; DefaultLogPath = $script:DefaultLogPath } {
                param ($Base, $DefaultLogPath)

                $null = Backup-DnsZone -Server $Base['Server'] -Path $Base['Path']

                @(Get-Content -LiteralPath $DefaultLogPath -Encoding UTF8).Count | Should -Be 3
            }
        }
    }

    Context 'Paths and names' {
        It 'defaults -Path to %LOCALAPPDATA%\DnsTools\backup' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Root = $script:Root } {
                param ($Base, $Root)

                $local = Join-Path -Path $Root -ChildPath 'localappdata'
                $saved = $env:LOCALAPPDATA
                try {
                    $env:LOCALAPPDATA = $local
                    $results = @(Backup-DnsZone -Server $Base['Server'] -LogPath $Base['LogPath'])
                }
                finally {
                    $env:LOCALAPPDATA = $saved
                }

                $results.Count | Should -Be 3
                @(Get-ChildItem -LiteralPath (Join-Path -Path $local -ChildPath 'DnsTools\backup') -Directory).Count | Should -Be 1
                $results[0].Data | Should -BeLike "$local\DnsTools\backup\*\backup_*.txt"
            }
        }

        It 'throws when there is no -Path and no LOCALAPPDATA' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                $withoutPath = @{ Server = $Base['Server']; LogPath = $Base['LogPath'] }
                $saved = $env:LOCALAPPDATA
                try {
                    $env:LOCALAPPDATA = $null
                    { Backup-DnsZone @withoutPath } | Should -Throw 'No -Path given and LOCALAPPDATA is not set*Specify -Path.'
                }
                finally {
                    $env:LOCALAPPDATA = $saved
                }
                [int]$script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 0
            }
        }

        It 'accepts -BackupPath and resolves a relative path against the current location' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Root = $script:Root } {
                param ($Base, $Root)

                $null = New-Item -Path $Root -ItemType Directory -Force
                Push-Location -LiteralPath $Root
                try {
                    $results = @(Backup-DnsZone -Server $Base['Server'] -BackupPath 'relative\backups' -LogPath $Base['LogPath'] -Zone 'contoso.local')
                }
                finally {
                    Pop-Location
                }

                $results.Count | Should -Be 1
                $results[0].Data | Should -BeLike '*\relative\backups\*\backup_contoso.local_*.txt'
                @(Get-ChildItem -LiteralPath (Join-Path -Path $Root -ChildPath 'relative\backups') -Directory).Count | Should -Be 1
            }
        }

        It 'throws a terminating error with a hint when the backup folder cannot be created' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Root = $script:Root } {
                param ($Base, $Root)

                # A file where the folder should go.
                $null = New-Item -Path $Root -ItemType Directory -Force
                $blocker = Join-Path -Path $Root -ChildPath 'blocker'
                Set-Content -LiteralPath $blocker -Value 'x' -WhatIf:$false -Confirm:$false

                $blocked = @{ Server = $Base['Server']; Path = $blocker; LogPath = $Base['LogPath'] }
                { Backup-DnsZone @blocked } | Should -Throw "Could not create the backup folder*Specify another -Path."
                [int]$script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 0
            }
        }

        It 'names the folder and files from the time after the gate, with the same stamp, and never reuses a folder' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Server = $script:Server } {
                param ($Base, $Server)

                # Only the calls without -Format are fixed: Export-DnsZoneFile needs the real format for its own file name.
                Mock Get-Date { [datetime]'2026-10-11T12:30:45' } -ParameterFilter { -not $Format }

                $results = @(Backup-DnsZone @Base -Zone 'contoso.local', '0/25.16.0.10.in-addr.arpa')

                $folder = Join-Path -Path $Base['Path'] -ChildPath "$Server-20261011-123045"
                Test-Path -LiteralPath $folder -PathType Container | Should -BeTrue
                @($results | ForEach-Object { Split-Path -Path $_.Data -Leaf }) | Should -Be @(
                    'backup_contoso.local_20261011-123045.txt'
                    'backup_0_25.16.0.10.in-addr.arpa_20261011-123045.txt'
                )
                (Get-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'RESTORE.md') -Raw) | Should -BeLike '*backup taken 2026-10-11 12:30:45 from*- Taken: 2026-10-11 12:30:45*'

                # Same second again: the first backup must stay as it is.
                $script:DnsStub.Calls['Export-DnsServerZone'] = 0
                $restoreBefore = Get-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'RESTORE.md') -Raw
                { Backup-DnsZone @Base -Zone 'contoso.local' } | Should -Throw "The backup folder '$folder' already exists*"
                [int]$script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 0
                (Get-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'RESTORE.md') -Raw) | Should -BeExactly $restoreBefore
            }
        }

        It 'replaces characters that are not valid in a file name in the zone part of the name' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                Add-DnsStubZone -Name '_msdcs.contoso.local'

                $results = @(Backup-DnsZone @Base -Zone '_msdcs.contoso.local', '0/25.16.0.10.in-addr.arpa')

                $results.Count | Should -Be 2
                (Split-Path -Path $results[0].Data -Leaf) | Should -BeLike 'backup__msdcs.contoso.local_*.txt'
                (Split-Path -Path $results[1].Data -Leaf) | Should -BeLike 'backup_0_25.16.0.10.in-addr.arpa_*.txt'
                $results[1].Name | Should -BeExactly '0/25.16.0.10.in-addr.arpa'
            }
        }
    }

    Context 'Server, credential and timeout' {
        It 'passes -Server, -Credential and -TimeoutSec on to Export-DnsZoneFile' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base; Server = $script:Server } {
                param ($Base, $Server)

                $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList 'CONTOSO\dnsbackup', (New-Object -TypeName System.Security.SecureString)
                Mock Export-DnsZoneFile {
                    Set-Content -LiteralPath $DestinationPath -Value '; zone' -WhatIf:$false -Confirm:$false
                    $DestinationPath
                }

                $results = @(Backup-DnsZone @Base -Zone 'contoso.local', '16.0.10.in-addr.arpa' -Credential $credential -TimeoutSec 42)

                $results.Count | Should -Be 2
                Should -Invoke Export-DnsZoneFile -Times 2 -Exactly -ParameterFilter {
                    $Server -eq $Base['Server'].ToLowerInvariant() -and $TimeoutSec -eq 42 -and $null -ne $Credential -and $Credential.UserName -eq 'CONTOSO\dnsbackup'
                }
                $results[0].Data | Should -BeLike "$($Base['Path'])\$Server-*\backup_contoso.local_*.txt"
            }
        }

        It 'warns nothing about the writer server, because a backup changes nothing in DNS' {
            InModuleScope DnsTools -Parameters @{ Base = $script:Base } {
                param ($Base)

                $script:WriterServer = 'dc99'

                $records = @(Backup-DnsZone @Base 3>&1)

                @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0
                $script:WriterServer | Should -BeExactly 'dc99'
            }
        }
    }
}
