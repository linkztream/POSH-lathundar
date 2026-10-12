#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
<#
    Tests for the phase-2 write foundation (CONTRACTS.md sections 7.5, 10, 11 and
    12.2): New-DnsBatch, Write-DnsResult, Read-DnsInputFile, Get-DnsReferenceTable,
    Get-DnsReference, Remove-/Add-/Set-DnsLiveRecord with the winerror.h codes of
    section 13.9, Test-DnsConnectionError, Resolve-DnsChangeTarget,
    Get-DnsReverseZoneName, Test-DnsWriterServer, "Yes to all" per impact in
    Confirm-DnsAction, and the phase-2 stubs they run against.

    The stubs are loaded into the module scope once. Initialize-WriteTest points the
    snapshot root, the stub export root and the change log at a fresh folder, clears
    every cache (zone table, CIM session, snapshot index, writer server) and builds
    this environment on the server $env:COMPUTERNAME, which Export-DnsZoneFile
    treats as this computer (see Snapshot.Tests.ps1):

      contoso.local (primary)
        @          NS dc01.contoso.local, MX mail.contoso.local
        dc01       A 10.0.16.10
        srv01      A 10.0.16.20, A 10.0.16.21 (two A records at one node)
        dyn01      A 10.0.16.30 (dynamic, has a timestamp)
        mail       A 10.0.16.50
        web        A 10.0.16.40
        gw         CNAME srv01.contoso.local
        www        CNAME web.contoso.local
        _ldap._tcp SRV dc01.contoso.local
        *          A 10.0.16.99 (wildcard owner)
      lab.contoso.local (primary)
        test01           A 10.0.17.5
        alias01          CNAME srv01.contoso.local     (points into another zone)
        _kerberos._tcp   SRV srv01.contoso.local       (points into another zone)
      16.0.10.in-addr.arpa (primary): 10 PTR dc01, 20 PTR srv01
      8.b.d.0.1.0.0.2.ip6.arpa (primary)
      fabrikam.com (secondary)
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\DnsLathund.psd1" -Force
    $script:StubPath = Join-Path -Path $PSScriptRoot -ChildPath 'Stubs\DnsServerStubs.ps1'
    $script:Server = $env:COMPUTERNAME.ToLowerInvariant()
    $script:ResultProperties = @('Action', 'Name', 'Type', 'Data', 'Result', 'Error', 'Zone', 'NodeName', 'Server', 'Id', 'BatchId', 'Timestamp')
    $script:LogKeys = @('Id', 'BatchId', 'Timestamp', 'Operator', 'Server', 'Action', 'Zone', 'NodeName', 'Name', 'Type', 'Data', 'Before', 'After', 'Result', 'Error')

    InModuleScope DnsLathund -Parameters @{ StubPath = $script:StubPath } {
        param ($StubPath)
        . $StubPath
    }

    function Initialize-WriteTest {
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
            Add-DnsStubZone -Name 'lab.contoso.local'
            Add-DnsStubZone -Name '16.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '8.b.d.0.1.0.0.2.ip6.arpa'
            Add-DnsStubZone -Name 'fabrikam.com' -ZoneType Secondary -IsDsIntegrated $false

            $zone = 'contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '@' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '@' -RRType MX -Data 'mail.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'dc01' -RRType A -Data '10.0.16.10'
            Add-DnsStubRecord -ZoneName $zone -Name 'srv01' -RRType A -Data '10.0.16.20'
            Add-DnsStubRecord -ZoneName $zone -Name 'srv01' -RRType A -Data '10.0.16.21'
            Add-DnsStubRecord -ZoneName $zone -Name 'dyn01' -RRType A -Data '10.0.16.30' -AgeHours 3636304
            Add-DnsStubRecord -ZoneName $zone -Name 'mail' -RRType A -Data '10.0.16.50'
            Add-DnsStubRecord -ZoneName $zone -Name 'web' -RRType A -Data '10.0.16.40'
            Add-DnsStubRecord -ZoneName $zone -Name 'gw' -RRType CNAME -Data 'srv01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'www' -RRType CNAME -Data 'web.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '_ldap._tcp' -RRType SRV -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '*' -RRType A -Data '10.0.16.99'

            $zone = 'lab.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name 'test01' -RRType A -Data '10.0.17.5'
            Add-DnsStubRecord -ZoneName $zone -Name 'alias01' -RRType CNAME -Data 'srv01.contoso.local'
            Add-DnsStubRecord -ZoneName $zone -Name '_kerberos._tcp' -RRType SRV -Data 'srv01.contoso.local' -Port 88

            Add-DnsStubRecord -ZoneName '16.0.10.in-addr.arpa' -Name '10' -RRType PTR -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName '16.0.10.in-addr.arpa' -Name '20' -RRType PTR -Data 'srv01.contoso.local'
        }
    }

    function Invoke-ResolveProbe {
        <#
        .SYNOPSIS
            Runs Resolve-DnsChangeTarget in the module scope and returns either the
            target or the caught error as one hashtable.
        #>
        param (
            [object]$Item,
            [string]$Zone,
            [string]$Server
        )

        InModuleScope DnsLathund -Parameters @{ Item = $Item; Zone = $Zone; Server = $Server } {
            param ($Item, $Zone, $Server)

            $zoneTable = Get-DnsZoneTable -Server $Server
            try {
                $target = Resolve-DnsChangeTarget -InputObject $Item -ZoneTable $zoneTable -Zone $Zone
                @{ Target = $target; ErrorId = $null; Category = $null; Message = $null }
            }
            catch {
                @{ Target = $null; ErrorId = [string]$_.FullyQualifiedErrorId; Category = [string]$_.CategoryInfo.Category; Message = $_.Exception.Message }
            }
        }
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

Describe 'New-DnsBatch' {
    It 'returns the batch hashtable of CONTRACTS.md 7.5' {
        $batch = InModuleScope DnsLathund {
            New-DnsBatch -Server ' DC01 ' -LogPath 'C:\Logs\dns.jsonl' -Delay 2 -Force
        }

        $batch | Should -BeOfType [hashtable]
        (@($batch.Keys) | Sort-Object) -join ',' | Should -BeExactly 'BatchId,CimSession,Confirm,Counts,Delay,Force,LogPath,References,Server,StartedAt'
        { [guid]$batch['BatchId'] } | Should -Not -Throw
        $batch['BatchId'] | Should -BeOfType [string]
        $batch['Server'] | Should -BeExactly 'dc01'
        $batch['LogPath'] | Should -BeExactly 'C:\Logs\dns.jsonl'
        $batch['Delay'] | Should -Be 2
        $batch['Force'] | Should -BeOfType [bool]
        $batch['Force'] | Should -BeTrue
        $batch['Confirm'] | Should -BeOfType [hashtable]
        $batch['Confirm']['All'] | Should -BeOfType [hashtable]
        $batch['Confirm']['All'].Count | Should -Be 0
        $batch['StartedAt'] | Should -BeOfType [datetime]
        $batch['References'] | Should -BeOfType [hashtable]
        $batch['CimSession'] | Should -BeNullOrEmpty
        $batch['Counts'] | Should -BeOfType [hashtable]
    }

    It 'defaults to no log path, no delay and Force $false, and gives every batch its own id' {
        $batches = InModuleScope DnsLathund {
            @{ First = (New-DnsBatch -Server 'dc01' -LogPath ''); Second = (New-DnsBatch -Server 'dc01') }
        }

        $batches['First']['LogPath'] | Should -BeNullOrEmpty
        $batches['First']['Delay'] | Should -Be 0
        $batches['First']['Force'] | Should -BeFalse
        $batches['First']['BatchId'] | Should -Not -Be $batches['Second']['BatchId']
    }
}

Describe 'Write-DnsResult' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $script:LogPath = Join-Path -Path $script:Root -ChildPath 'log\changes.jsonl'
    }

    It 'returns a DnsLathund.Result with the properties of CONTRACTS.md 12.2 in order' {
        $result = InModuleScope DnsLathund -Parameters @{ LogPath = $script:LogPath } {
            param ($LogPath)
            $batch = New-DnsBatch -Server 'DC01' -LogPath $LogPath
            $result = Write-DnsResult -Batch $batch -Action 'RemoveA' -Name 'srv01.contoso.local' -Type 'A' -Data '10.0.16.20' -Zone 'contoso.local' -NodeName 'srv01' -Result 'Success'
            @{ Result = $result; Batch = $batch }
        }

        $object = $result['Result']
        $object.PSObject.TypeNames[0] | Should -BeExactly 'DnsLathund.Result'
        @($object.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly ($script:ResultProperties -join ',')
        $object.Action | Should -BeExactly 'RemoveA'
        $object.Name | Should -BeExactly 'srv01.contoso.local'
        $object.Type | Should -BeExactly 'A'
        $object.Data | Should -BeExactly '10.0.16.20'
        $object.Result | Should -BeExactly 'Success'
        $object.Error | Should -BeNullOrEmpty
        $object.Zone | Should -BeExactly 'contoso.local'
        $object.NodeName | Should -BeExactly 'srv01'
        $object.Server | Should -BeExactly 'dc01'
        { [guid]$object.Id } | Should -Not -Throw
        $object.BatchId | Should -BeExactly $result['Batch']['BatchId']
        $object.Timestamp | Should -BeOfType [datetime]
        $result['Batch']['Counts']['Success'] | Should -Be 1
    }

    It 'writes exactly one change-log line per call with every CONTRACTS.md 11 key, in order' {
        $results = InModuleScope DnsLathund -Parameters @{ LogPath = $script:LogPath } {
            param ($LogPath)
            $batch = New-DnsBatch -Server 'dc01' -LogPath $LogPath
            # A record as Get-DnsLiveRecord returns it: the extra keys must not reach the log.
            $before = @{ Owner = 'srv01.contoso.local'; Zone = 'contoso.local'; NodeName = 'srv01'; Type = 'A'; Data = '10.0.16.20'; Ttl = 3600; Timestamp = $null; DistinguishedName = 'DC=srv01' }
            $first = Write-DnsResult -Batch $batch -Action 'RemoveA' -Name 'srv01.contoso.local' -Type 'A' -Data '10.0.16.20' -Zone 'contoso.local' -NodeName 'srv01' -Result 'Success' -Before $before
            $second = Write-DnsResult -Batch $batch -Action 'AddPtr' -Name 'srv01.contoso.local' -Type 'PTR' -Data 'srv01.contoso.local' -Zone '16.0.10.in-addr.arpa' -NodeName '20' -Result 'Failed' -Error 'Access denied.'
            @{ First = $first; Second = $second }
        }

        $lines = @(Get-Content -LiteralPath $script:LogPath -Encoding UTF8)
        $lines.Count | Should -Be 2

        $entry = $lines[0] | ConvertFrom-Json
        @($entry.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly ($script:LogKeys -join ',')
        $entry.Id | Should -BeExactly $results['First'].Id
        $entry.BatchId | Should -BeExactly $results['First'].BatchId
        $entry.Server | Should -BeExactly 'dc01'
        $entry.Operator | Should -Not -BeNullOrEmpty
        ([datetime]$entry.Timestamp).ToString('yyyy-MM-ddTHH:mm:ss') | Should -BeExactly $results['First'].Timestamp.ToString('yyyy-MM-ddTHH:mm:ss')
        $entry.Action | Should -BeExactly 'RemoveA'
        $entry.Zone | Should -BeExactly 'contoso.local'
        $entry.NodeName | Should -BeExactly 'srv01'
        $entry.Name | Should -BeExactly 'srv01.contoso.local'
        $entry.Type | Should -BeExactly 'A'
        $entry.Data | Should -BeExactly '10.0.16.20'
        @($entry.Before.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly 'Data,Ttl,Timestamp,IsStatic'
        $entry.Before.Data | Should -BeExactly '10.0.16.20'
        $entry.Before.Ttl | Should -Be 3600
        $entry.Before.Timestamp | Should -BeNullOrEmpty
        $entry.Before.IsStatic | Should -BeTrue
        $entry.After | Should -BeNullOrEmpty
        $entry.Result | Should -BeExactly 'Success'
        $entry.Error | Should -BeNullOrEmpty

        $failed = $lines[1] | ConvertFrom-Json
        $failed.Result | Should -BeExactly 'Failed'
        $failed.Error | Should -BeExactly 'Access denied.'
        $failed.Id | Should -BeExactly $results['Second'].Id
        $results['Second'].Error | Should -BeExactly 'Access denied.'
    }

    It 'logs WhatIf results even when the caller runs under -WhatIf' {
        $null = InModuleScope DnsLathund -Parameters @{ LogPath = $script:LogPath } {
            param ($LogPath)
            $WhatIfPreference = $true
            $batch = New-DnsBatch -Server 'dc01' -LogPath $LogPath
            Write-DnsResult -Batch $batch -Action 'AddA' -Name 'new01.contoso.local' -Type 'A' -Data '10.0.16.60' -Zone 'contoso.local' -NodeName 'new01' -Result 'WhatIf'
        }

        $lines = @(Get-Content -LiteralPath $script:LogPath -Encoding UTF8)
        $lines.Count | Should -Be 1
        ($lines[0] | ConvertFrom-Json).Result | Should -BeExactly 'WhatIf'
    }

    It 'logs Name and Data on a WhatIf line that has no Before or After' {
        $null = InModuleScope DnsLathund -Parameters @{ LogPath = $script:LogPath } {
            param ($LogPath)
            $batch = New-DnsBatch -Server 'dc01' -LogPath $LogPath
            Write-DnsResult -Batch $batch -Action 'AddA' -Name 'new01.contoso.local' -Type 'A' -Data '10.0.16.60' -Zone 'contoso.local' -NodeName 'new01' -Result 'WhatIf'
        }

        $line = @(Get-Content -LiteralPath $script:LogPath -Encoding UTF8)[0]
        $entry = $line | ConvertFrom-Json
        @($entry.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly ($script:LogKeys -join ',')
        $entry.Result | Should -BeExactly 'WhatIf'
        $entry.Name | Should -BeExactly 'new01.contoso.local'
        $entry.Data | Should -BeExactly '10.0.16.60'
        $line | Should -Match '"Before":null'
        $line | Should -Match '"After":null'
    }

    It 'turns empty strings into $null and derives IsStatic from a timestamp' {
        $result = InModuleScope DnsLathund -Parameters @{ LogPath = $script:LogPath } {
            param ($LogPath)
            $batch = New-DnsBatch -Server 'dc01' -LogPath $LogPath
            $after = @{ Data = '10.0.16.30'; Ttl = 1200; Timestamp = (Get-Date).Date }
            Write-DnsResult -Batch $batch -Action 'SetTtl' -Name 'dyn01.contoso.local' -Type 'A' -Data '' -Zone 'contoso.local' -NodeName 'dyn01' -Result 'AlreadyDone' -Error '' -After $after
        }

        $result.Data | Should -BeNullOrEmpty
        $null -eq $result.Data | Should -BeTrue
        $null -eq $result.Error | Should -BeTrue
        $entry = Get-Content -LiteralPath $script:LogPath -Encoding UTF8 | ConvertFrom-Json
        $entry.After.IsStatic | Should -BeFalse
        $entry.After.Timestamp | Should -Not -BeNullOrEmpty
        $null -eq $entry.Error | Should -BeTrue
        $null -eq $entry.Data | Should -BeTrue
    }
}

Describe 'Read-DnsInputFile' {
    BeforeAll {
        $script:Root = Join-Path -Path $TestDrive -ChildPath 'input'
        $null = New-Item -Path $script:Root -ItemType Directory -Force
        $script:Utf8Bom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
        $script:Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

        function Invoke-ReadProbe {
            <#
            .SYNOPSIS
                Reads a file with Read-DnsInputFile in the module scope; returns the
                items and the warnings.
            #>
            param ([string]$Path, [switch]$Csv)

            InModuleScope DnsLathund -Parameters @{ Path = $Path; Csv = [bool]$Csv } {
                param ($Path, $Csv)
                $items = @(Read-DnsInputFile -Path $Path -Csv:$Csv -WarningVariable readWarnings -WarningAction SilentlyContinue)
                @{ Items = $items; Warnings = @($readWarnings) }
            }
        }
    }

    It 'returns trimmed lines without comments, blank lines and case-insensitive duplicates' {
        $path = Join-Path -Path $script:Root -ChildPath 'list.txt'
        [System.IO.File]::WriteAllText($path, "  srv01.contoso.local  `r`n# a comment`r`n`r`nSRV01.Contoso.Local`r`n10.0.16.5`r`n   `r`n  # indented comment`r`nsrv02`r`n", $script:Utf8Bom)

        $read = Invoke-ReadProbe -Path $path

        $read['Items'] -join '|' | Should -BeExactly 'srv01.contoso.local|10.0.16.5|srv02'
        $read['Items'][0] | Should -BeOfType [string]
        $read['Warnings'].Count | Should -Be 0
    }

    It 'reads BOM and BOM-less UTF-8 alike (<Case>)' -TestCases @(
        @{ Case = 'with BOM'; WithBom = $true }
        @{ Case = 'without BOM'; WithBom = $false }
    ) {
        $name = 'k' + [char]0x00E5 + 'ken.contoso.local'
        $other = 'r' + [char]0x00E4 + 'ksm' + [char]0x00F6 + 'rg' + [char]0x00E5 + 's.contoso.local'
        $path = Join-Path -Path $script:Root -ChildPath ("utf8-{0}.txt" -f $WithBom)
        $encoding = $script:Utf8NoBom
        if ($WithBom) {
            $encoding = $script:Utf8Bom
        }
        [System.IO.File]::WriteAllText($path, "$name`r`n$other`r`n", $encoding)

        $read = Invoke-ReadProbe -Path $path

        $read['Items'].Count | Should -Be 2
        $read['Items'][0] | Should -BeExactly $name
        $read['Items'][1] | Should -BeExactly $other
    }

    It 'recognises a CSV file by a header with a Name column and returns hashtables with the five keys' {
        $path = Join-Path -Path $script:Root -ChildPath 'new.csv'
        [System.IO.File]::WriteAllText($path, "Name,Address,TTL`r`nsrv05.contoso.local, 10.0.16.55 ,600`r`nsrv06.contoso.local,10.0.16.56,`r`n", $script:Utf8NoBom)

        $read = Invoke-ReadProbe -Path $path

        $read['Items'].Count | Should -Be 2
        $read['Warnings'].Count | Should -Be 0
        foreach ($row in $read['Items']) {
            $row | Should -BeOfType [hashtable]
            (@($row.Keys) | Sort-Object) -join ',' | Should -BeExactly 'Address,Name,Target,TTL,Zone'
        }
        $read['Items'][0]['Name'] | Should -BeExactly 'srv05.contoso.local'
        $read['Items'][0]['Address'] | Should -BeExactly '10.0.16.55'
        $read['Items'][0]['TTL'] | Should -BeExactly '600'
        $read['Items'][0]['Target'] | Should -BeNullOrEmpty
        $read['Items'][0]['Zone'] | Should -BeNullOrEmpty
        $null -eq $read['Items'][1]['TTL'] | Should -BeTrue
    }

    It 'reads CSV with -Csv even without a Name column' {
        $path = Join-Path -Path $script:Root -ChildPath 'addresses.csv'
        [System.IO.File]::WriteAllText($path, "Address,Zone`r`n10.0.16.5,contoso.local`r`n", $script:Utf8NoBom)

        $asLines = Invoke-ReadProbe -Path $path
        $asCsv = Invoke-ReadProbe -Path $path -Csv

        $asLines['Items'] -join '|' | Should -BeExactly 'Address,Zone|10.0.16.5,contoso.local'
        $asCsv['Items'].Count | Should -Be 1
        $asCsv['Items'][0]['Address'] | Should -BeExactly '10.0.16.5'
        $asCsv['Items'][0]['Zone'] | Should -BeExactly 'contoso.local'
        $null -eq $asCsv['Items'][0]['Name'] | Should -BeTrue
    }

    It 'reads Export-Csv output (quoted header, #TYPE line) and warns once about unknown columns' {
        $path = Join-Path -Path $script:Root -ChildPath 'export.csv'
        [System.IO.File]::WriteAllText($path, "#TYPE DnsLathund.Entry`r`n""Name"",""Type"",""Data"",""Zone""`r`n""srv01.contoso.local"",""A"",""10.0.16.20"",""contoso.local""`r`n""gw.contoso.local"",""CNAME"",""srv01.contoso.local"",""contoso.local""`r`n", $script:Utf8Bom)

        $read = Invoke-ReadProbe -Path $path

        $read['Items'].Count | Should -Be 2
        $read['Items'][1]['Name'] | Should -BeExactly 'gw.contoso.local'
        $read['Items'][1]['Zone'] | Should -BeExactly 'contoso.local'
        $read['Warnings'].Count | Should -Be 1
        [string]$read['Warnings'][0] | Should -BeLike '*Type, Data*'
    }

    It 'reads a semicolon-separated CSV file (Excel with a European locale)' {
        $path = Join-Path -Path $script:Root -ChildPath 'excel.csv'
        [System.IO.File]::WriteAllText($path, "name;target`r`nwww2.contoso.local;web.contoso.local`r`n", $script:Utf8Bom)

        $read = Invoke-ReadProbe -Path $path

        $read['Items'].Count | Should -Be 1
        $read['Items'][0]['Name'] | Should -BeExactly 'www2.contoso.local'
        $read['Items'][0]['Target'] | Should -BeExactly 'web.contoso.local'
    }

    It 'throws when the file <Case>' -TestCases @(
        @{ Case = 'does not exist'; Content = $null; Expected = '*does not exist*' }
        @{ Case = 'is empty'; Content = ''; Expected = '*is empty*' }
        @{ Case = 'has only comments and blank lines'; Content = "# nothing`r`n`r`n   `r`n"; Expected = '*is empty*' }
        @{ Case = 'has a CSV header but no rows'; Content = "Name,Address`r`n"; Expected = '*no rows*' }
    ) {
        $path = Join-Path -Path $script:Root -ChildPath ('throws-{0}.txt' -f [guid]::NewGuid().ToString('N'))
        if ($null -ne $Content) {
            [System.IO.File]::WriteAllText($path, $Content, $script:Utf8NoBom)
        }

        { InModuleScope DnsLathund -Parameters @{ Path = $path } { param ($Path) Read-DnsInputFile -Path $Path } } | Should -Throw $Expected
    }
}

Describe 'Get-DnsReferenceTable' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-WriteTest -Root $script:Root
    }

    It 'runs the four WQL queries of CONTRACTS.md 7.5 and normalises the trailing dots' {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $session = Get-DnsCimSession -Server $Server
            $callsBefore = [int]$script:DnsStub.Calls['Get-CimInstance']
            $table = Get-DnsReferenceTable -Zone 'Contoso.Local.' -CimSession $session -TimeoutSec 30
            $log = @($script:DnsStub.CallLog['Get-CimInstance'])
            @{ Table = $table; Calls = [int]$script:DnsStub.Calls['Get-CimInstance'] - $callsBefore; Log = $log[($log.Count - 4)..($log.Count - 1)] }
        }

        $probe['Calls'] | Should -Be 4
        $expectedQueries = @(
            "SELECT OwnerName, PrimaryName FROM MicrosoftDNS_CNAMEType WHERE ContainerName='contoso.local'"
            "SELECT OwnerName, SRVDomainName FROM MicrosoftDNS_SRVType WHERE ContainerName='contoso.local'"
            "SELECT OwnerName, NSHost FROM MicrosoftDNS_NSType WHERE ContainerName='contoso.local'"
            "SELECT OwnerName, MailExchange FROM MicrosoftDNS_MXType WHERE ContainerName='contoso.local'"
        )
        @($probe['Log'] | ForEach-Object { $_['Query'] }) -join "`n" | Should -BeExactly ($expectedQueries -join "`n")
        foreach ($call in $probe['Log']) {
            $call['Namespace'] | Should -BeExactly 'root\MicrosoftDNS'
            $call['OperationTimeoutSec'] | Should -Be 30
            $call['CimSession'] | Should -Not -BeNullOrEmpty
        }

        $table = $probe['Table']
        (@($table.Keys) | Sort-Object) -join ',' | Should -BeExactly 'Cname,Mx,Ns,Srv'
        @($table['Cname']['srv01.contoso.local']) | Should -Be @('gw.contoso.local')
        @($table['Cname']['web.contoso.local']) | Should -Be @('www.contoso.local')
        @($table['Srv']['dc01.contoso.local']) | Should -Be @('_ldap._tcp.contoso.local')
        @($table['Ns']['dc01.contoso.local']) | Should -Be @('contoso.local')
        @($table['Mx']['mail.contoso.local']) | Should -Be @('contoso.local')
        foreach ($listName in @('Cname', 'Srv', 'Ns', 'Mx')) {
            foreach ($target in @($table[$listName].Keys)) {
                $target | Should -Not -BeLike '*.'
            }
        }
    }

    It 'collects every owner that points at the same target' {
        $table = InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'gw2' -RRType CNAME -Data 'srv01.contoso.local'
            Get-DnsReferenceTable -Zone 'contoso.local' -CimSession (Get-DnsCimSession -Server $Server)
        }

        (@($table['Cname']['srv01.contoso.local']) | Sort-Object) -join ',' | Should -BeExactly 'gw.contoso.local,gw2.contoso.local'
    }

    It 'returns $null when <Case>' -TestCases @(
        @{ Case = 'a query fails'; NoSession = $false }
        @{ Case = 'there is no CIM session'; NoSession = $true }
    ) {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server; NoSession = $NoSession } {
            param ($Server, $NoSession)
            $session = $null
            if (-not $NoSession) {
                $session = Get-DnsCimSession -Server $Server
                $script:DnsStub.Fail['Get-CimInstance'] = @('contoso.local')
            }
            $table = Get-DnsReferenceTable -Zone 'contoso.local' -CimSession $session -ErrorAction SilentlyContinue
            $verbose = @(Get-DnsReferenceTable -Zone 'contoso.local' -CimSession $session -Verbose -ErrorAction SilentlyContinue 4>&1 | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -and $_.Message -like 'No reference table*' })
            @{ IsNull = $null -eq $table; Verbose = $verbose.Count }
        }

        $probe['IsNull'] | Should -BeTrue
        $probe['Verbose'] | Should -Be 1
    }
}

Describe 'Get-DnsReference' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-WriteTest -Root $script:Root
    }

    It 'answers from a fresh cached snapshot through RefBy, without CIM' {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $null = Update-DnsSnapshot -Server $Server -Force
            $zoneTable = Get-DnsZoneTable -Server $Server
            $batch = New-DnsBatch -Server $Server
            @{
                Dc01      = Get-DnsReference -Name 'dc01.contoso.local' -ZoneTable $zoneTable -Batch $batch
                Srv01     = Get-DnsReference -Name 'SRV01.contoso.local.' -ZoneTable $zoneTable -Batch $batch
                Mail      = Get-DnsReference -Name 'mail.contoso.local' -ZoneTable $zoneTable -Batch $batch
                CimCalls  = [int]$script:DnsStub.Calls['New-CimSession'] + [int]$script:DnsStub.Calls['Get-CimInstance']
                BatchCim  = $batch['CimSession']
            }
        }

        $probe['Dc01']['Source'] | Should -BeExactly 'Snapshot'
        $probe['Dc01']['Age'] | Should -BeOfType [timespan]
        @($probe['Dc01']['Srv']) | Should -Be @('_ldap._tcp.contoso.local')
        @($probe['Dc01']['Ns']) | Should -Be @('contoso.local')
        @($probe['Dc01']['Mx']).Count | Should -Be 0
        @($probe['Dc01']['Cname']).Count | Should -Be 0
        (@($probe['Srv01']['Cname']) | Sort-Object) -join ',' | Should -BeExactly 'alias01.lab.contoso.local,gw.contoso.local'
        @($probe['Srv01']['Srv']) | Should -Be @('_kerberos._tcp.lab.contoso.local')
        @($probe['Mail']['Mx']) | Should -Be @('contoso.local')
        $probe['CimCalls'] | Should -Be 0
        $probe['BatchCim'] | Should -BeNullOrEmpty
    }

    It 'loads a fresh snapshot from disk when nothing is cached' {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $null = Update-DnsSnapshot -Server $Server -Force
            $script:SnapshotIndexCache = @{}
            $zoneTable = Get-DnsZoneTable -Server $Server
            $references = Get-DnsReference -Name 'dc01.contoso.local' -ZoneTable $zoneTable -Batch (New-DnsBatch -Server $Server)
            @{ References = $references; Cached = $script:SnapshotIndexCache.ContainsKey($Server); CimCalls = [int]$script:DnsStub.Calls['Get-CimInstance'] }
        }

        $probe['References']['Source'] | Should -BeExactly 'Snapshot'
        @($probe['References']['Srv']) | Should -Be @('_ldap._tcp.contoso.local')
        $probe['Cached'] | Should -BeTrue
        $probe['CimCalls'] | Should -Be 0
    }

    It 'uses WQL when the snapshot <Case>' -TestCases @(
        @{ Case = 'on disk is older than -MaxSnapshotAge'; Kind = 'StaleDisk' }
        @{ Case = 'in the cache is older than -MaxSnapshotAge'; Kind = 'StaleCache' }
        @{ Case = 'is younger than 24 h but older than a -MaxSnapshotAge of 0'; Kind = 'ZeroAge' }
        @{ Case = 'does not exist'; Kind = 'None' }
    ) {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server; Kind = $Kind } {
            param ($Server, $Kind)
            $maxAge = New-TimeSpan -Hours 24
            if ($Kind -ne 'None') {
                $null = Update-DnsSnapshot -Server $Server -Force
            }
            if ($Kind -eq 'StaleDisk') {
                $meta = Get-DnsSnapshotMeta -Server $Server
                foreach ($zoneName in @($meta['Zones'].Keys)) {
                    $meta['Zones'][$zoneName]['ExportedAt'] = (Get-Date).AddDays(-3)
                }
                Save-DnsSnapshotMeta -Server $Server -Meta $meta
                $script:SnapshotIndexCache = @{}
            }
            if ($Kind -eq 'StaleCache') {
                $script:SnapshotIndexCache[$Server]['OldestExportedAt'] = (Get-Date).AddDays(-2)
            }
            if ($Kind -eq 'ZeroAge') {
                $maxAge = New-TimeSpan -Seconds 0
            }

            $zoneTable = Get-DnsZoneTable -Server $Server
            $batch = New-DnsBatch -Server $Server
            $references = Get-DnsReference -Name 'srv01.contoso.local' -ZoneTable $zoneTable -Batch $batch -MaxSnapshotAge $maxAge -WarningVariable referenceWarnings -WarningAction SilentlyContinue
            @{
                References = $references
                Batch      = $batch
                Loaded     = $script:SnapshotIndexCache.ContainsKey($Server)
                Warnings   = @($referenceWarnings)
                Forward    = @($zoneTable.ForwardZones)
            }
        }

        $references = $probe['References']
        $references['Source'] | Should -BeExactly 'Wql'
        $references['Age'] | Should -BeNullOrEmpty
        (@($references['Cname']) | Sort-Object) -join ',' | Should -BeExactly 'alias01.lab.contoso.local,gw.contoso.local'
        @($references['Srv']) | Should -Be @('_kerberos._tcp.lab.contoso.local')
        @($references['Ns']).Count | Should -Be 0
        $probe['Batch']['CimSession'] | Should -Not -BeNullOrEmpty
        (@($probe['Batch']['References'].Keys) | Sort-Object) -join ',' | Should -BeExactly ((@($probe['Forward']) | Sort-Object) -join ',')
        $probe['Warnings'].Count | Should -Be 0
        if ($Kind -eq 'StaleDisk' -or $Kind -eq 'None') {
            # Never loaded, so never auto-exported either.
            $probe['Loaded'] | Should -BeFalse
        }
    }

    It 'queries each zone once per batch' {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $zoneTable = Get-DnsZoneTable -Server $Server
            $batch = New-DnsBatch -Server $Server
            $null = Get-DnsReference -Name 'srv01.contoso.local' -ZoneTable $zoneTable -Batch $batch
            $afterFirst = [int]$script:DnsStub.Calls['Get-CimInstance']
            $second = Get-DnsReference -Name 'dc01.contoso.local' -ZoneTable $zoneTable -Batch $batch
            @{ AfterFirst = $afterFirst; AfterSecond = [int]$script:DnsStub.Calls['Get-CimInstance']; Sessions = [int]$script:DnsStub.Calls['New-CimSession']; Second = $second; ZoneCount = @($zoneTable.ForwardZones).Count }
        }

        # One verification query for the session, then four per forward zone.
        $probe['AfterFirst'] | Should -Be (1 + 4 * $probe['ZoneCount'])
        $probe['AfterSecond'] | Should -Be $probe['AfterFirst']
        $probe['Sessions'] | Should -Be 1
        @($probe['Second']['Srv']) | Should -Be @('_ldap._tcp.contoso.local')
    }

    It 'reports Unavailable when <Case>' -TestCases @(
        @{ Case = 'no CIM session can be opened'; Kind = 'NoSession' }
        @{ Case = 'one zone cannot be queried'; Kind = 'ZoneFails' }
    ) {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server; Kind = $Kind } {
            param ($Server, $Kind)
            if ($Kind -eq 'NoSession') {
                $script:DnsStub.CimUnavailable = $true
            }
            else {
                $script:DnsStub.Fail['Get-CimInstance'] = @('lab.contoso.local')
            }
            $zoneTable = Get-DnsZoneTable -Server $Server
            $batch = New-DnsBatch -Server $Server
            $references = Get-DnsReference -Name 'srv01.contoso.local' -ZoneTable $zoneTable -Batch $batch
            @{ References = $references; Batch = $batch; Cache = $script:CimSessionCache[$Server] }
        }

        $references = $probe['References']
        $references['Source'] | Should -BeExactly 'Unavailable'
        foreach ($listName in @('Cname', 'Srv', 'Ns', 'Mx')) {
            @($references[$listName]).Count | Should -Be 0
        }
        if ($Kind -eq 'NoSession') {
            $probe['Batch']['CimSession'] | Should -BeNullOrEmpty
            $probe['Cache'] | Should -BeExactly 'Unavailable'
        }
        else {
            $probe['Batch']['References'].ContainsKey('lab.contoso.local') | Should -BeTrue
            $probe['Batch']['References']['lab.contoso.local'] | Should -BeNullOrEmpty
        }
    }

    It 'skips the check with -SkipReferenceCheck and warns once per batch' {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $zoneTable = Get-DnsZoneTable -Server $Server
            $batch = New-DnsBatch -Server $Server
            $first = Get-DnsReference -Name 'dc01.contoso.local' -ZoneTable $zoneTable -Batch $batch -SkipReferenceCheck -WarningVariable firstWarnings -WarningAction SilentlyContinue
            $null = Get-DnsReference -Name 'srv01.contoso.local' -ZoneTable $zoneTable -Batch $batch -SkipReferenceCheck -WarningVariable secondWarnings -WarningAction SilentlyContinue
            $null = Get-DnsReference -Name 'srv01.contoso.local' -ZoneTable $zoneTable -Batch (New-DnsBatch -Server $Server) -SkipReferenceCheck -WarningVariable otherBatchWarnings -WarningAction SilentlyContinue
            @{ First = $first; FirstWarnings = @($firstWarnings); SecondWarnings = @($secondWarnings); OtherBatchWarnings = @($otherBatchWarnings); CimCalls = [int]$script:DnsStub.Calls['Get-CimInstance'] }
        }

        $probe['First']['Source'] | Should -BeExactly 'Skipped'
        $probe['First']['Age'] | Should -BeNullOrEmpty
        foreach ($listName in @('Cname', 'Srv', 'Ns', 'Mx')) {
            @($probe['First'][$listName]).Count | Should -Be 0
        }
        $probe['FirstWarnings'].Count | Should -Be 1
        [string]$probe['FirstWarnings'][0] | Should -BeLike '*-SkipReferenceCheck*'
        $probe['SecondWarnings'].Count | Should -Be 0
        $probe['OtherBatchWarnings'].Count | Should -Be 1
        $probe['CimCalls'] | Should -Be 0
    }
}

Describe 'Remove-DnsLiveRecord' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-WriteTest -Root $script:Root
    }

    It 'removes only the A record with the given data, through the pipeline form' {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $serverParameter = @{ ComputerName = $Server }
            $outcome = Remove-DnsLiveRecord -ServerParameter $serverParameter -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A -Data '010.0.16.021'
            $left = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A)
            @{ Outcome = $outcome; Left = @($left | ForEach-Object { $_['Data'] }); Log = @($script:DnsStub.CallLog['Remove-DnsServerResourceRecord']) }
        }

        (@($probe['Outcome'].Keys) | Sort-Object) -join ',' | Should -BeExactly 'AlreadyGone,Error,ErrorId,Removed,Unreachable'
        $probe['Outcome']['Removed'] | Should -BeTrue
        $probe['Outcome']['AlreadyGone'] | Should -BeFalse
        $probe['Outcome']['Error'] | Should -BeNullOrEmpty
        $probe['Outcome']['ErrorId'] | Should -BeNullOrEmpty
        $probe['Outcome']['Unreachable'] | Should -BeOfType [bool]
        $probe['Outcome']['Unreachable'] | Should -BeFalse
        $probe['Left'] | Should -Be @('10.0.16.20')
        $probe['Log'].Count | Should -Be 1
        $call = $probe['Log'][0]
        $call.Keys | Should -Contain 'InputObject'
        $call.Keys | Should -Not -Contain 'Name'
        $call.Keys | Should -Not -Contain 'RRType'
        $call.Keys | Should -Not -Contain 'RecordData'
        $call['ZoneName'] | Should -BeExactly 'contoso.local'
        [bool]$call['Force'] | Should -BeTrue
        $call.Keys | Should -Contain 'WhatIf'
        [bool]$call['WhatIf'] | Should -BeFalse
        $call.Keys | Should -Contain 'Confirm'
        [bool]$call['Confirm'] | Should -BeFalse
        $call['InputObject'].RecordData.IPv4Address.IPAddressToString | Should -BeExactly '10.0.16.21'
    }

    It 'removes CNAME and PTR records by their target' {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $serverParameter = @{ ComputerName = $Server }
            @{
                Cname = Remove-DnsLiveRecord -ServerParameter $serverParameter -ZoneName 'contoso.local' -NodeName 'gw' -RRType CNAME -Data 'SRV01.contoso.local.'
                Ptr   = Remove-DnsLiveRecord -ServerParameter $serverParameter -ZoneName '16.0.10.in-addr.arpa' -NodeName '20' -RRType PTR -Data 'srv01.contoso.local'
                Left  = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName 'contoso.local' -NodeName 'gw' -RRType CNAME).Count
            }
        }

        $probe['Cname']['Removed'] | Should -BeTrue
        $probe['Ptr']['Removed'] | Should -BeTrue
        $probe['Left'] | Should -Be 0
    }

    It 'reports AlreadyGone without an error when no record at the node has the data' {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $outcome = Remove-DnsLiveRecord -ServerParameter @{ ComputerName = $Server } -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A -Data '10.0.16.77'
            @{ Outcome = $outcome; Removes = [int]$script:DnsStub.Calls['Remove-DnsServerResourceRecord'] }
        }

        $probe['Outcome']['AlreadyGone'] | Should -BeTrue
        $probe['Outcome']['Removed'] | Should -BeFalse
        $probe['Outcome']['Error'] | Should -BeNullOrEmpty
        $probe['Outcome']['ErrorId'] | Should -BeNullOrEmpty
        $probe['Outcome']['Unreachable'] | Should -BeFalse
        $probe['Removes'] | Should -Be 0
    }

    It 'classifies WIN32 <Code> on the <Stage> (<Case>) as AlreadyGone' -TestCases @(
        @{ Code = 9714; Stage = 'read'; Case = 'the node does not exist'; Node = 'nothere'; Data = '10.0.16.77'; Vanish = 'Nothing'; Removes = 0 }
        @{ Code = 9701; Stage = 'removal'; Case = 'the record vanished after the read, its node kept another record'; Node = 'srv01'; Data = '10.0.16.21'; Vanish = 'Record'; Removes = 1 }
        @{ Code = 9714; Stage = 'removal'; Case = 'the record vanished after the read together with its node'; Node = 'mail'; Data = '10.0.16.50'; Vanish = 'Node'; Removes = 1 }
    ) {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server; Node = $Node; Data = $Data; Vanish = $Vanish } {
            param ($Server, $Node, $Data, $Vanish)

            # Another administrator deletes the record, or its whole node, between
            # the helper's read and its removal.
            if ($Vanish -eq 'Record') {
                $script:DnsStub.BeforeCall['Remove-DnsServerResourceRecord'] = {
                    param ($BoundParameters)
                    $id = $BoundParameters['InputObject'].Id
                    $script:DnsStub.Records['contoso.local'] = @(foreach ($record in @($script:DnsStub.Records['contoso.local'])) { if ($record.Id -ne $id) { $record } })
                }
            }
            elseif ($Vanish -eq 'Node') {
                $script:DnsStub.BeforeCall['Remove-DnsServerResourceRecord'] = {
                    param ($BoundParameters)
                    $hostName = $BoundParameters['InputObject'].HostName
                    $script:DnsStub.Records['contoso.local'] = @(foreach ($record in @($script:DnsStub.Records['contoso.local'])) { if ($record.HostName -ne $hostName) { $record } })
                }
            }

            $outcome = Remove-DnsLiveRecord -ServerParameter @{ ComputerName = $Server } -ZoneName 'contoso.local' -NodeName $Node -RRType A -Data $Data
            @{ Outcome = $outcome; Removes = [int]$script:DnsStub.Calls['Remove-DnsServerResourceRecord'] }
        }

        $probe['Outcome']['AlreadyGone'] | Should -BeTrue
        $probe['Outcome']['Removed'] | Should -BeFalse
        $probe['Outcome']['Error'] | Should -BeNullOrEmpty
        $probe['Outcome']['ErrorId'] | Should -BeLike "WIN32 $Code,*"
        $probe['Outcome']['Unreachable'] | Should -BeFalse
        $probe['Removes'] | Should -Be $Removes
    }
}

Describe 'Add-DnsLiveRecord' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-WriteTest -Root $script:Root
    }

    It 'adds a static <RRType> record with the typed cmdlet and returns the re-read record' -TestCases @(
        @{ RRType = 'A'; Zone = 'contoso.local'; Node = 'new01'; Data = '10.0.16.60'; Expected = '10.0.16.60'; Command = 'Add-DnsServerResourceRecordA'; DataParameter = 'IPv4Address' }
        @{ RRType = 'AAAA'; Zone = 'contoso.local'; Node = 'v6new'; Data = '2001:DB8::60'; Expected = '2001:db8::60'; Command = 'Add-DnsServerResourceRecordAAAA'; DataParameter = 'IPv6Address' }
        @{ RRType = 'CNAME'; Zone = 'contoso.local'; Node = 'alias02'; Data = 'SRV01.contoso.local'; Expected = 'srv01.contoso.local'; Command = 'Add-DnsServerResourceRecordCName'; DataParameter = 'HostNameAlias' }
        @{ RRType = 'PTR'; Zone = '16.0.10.in-addr.arpa'; Node = '60'; Data = 'new01.contoso.local'; Expected = 'new01.contoso.local'; Command = 'Add-DnsServerResourceRecordPtr'; DataParameter = 'PtrDomainName' }
    ) {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server; RRType = $RRType; Zone = $Zone; Node = $Node; Data = $Data; Command = $Command } {
            param ($Server, $RRType, $Zone, $Node, $Data, $Command)
            $outcome = Add-DnsLiveRecord -ServerParameter @{ ComputerName = $Server } -ZoneName $Zone -NodeName $Node -RRType $RRType -Data $Data
            @{ Outcome = $outcome; Log = @($script:DnsStub.CallLog[$Command]) }
        }

        $outcome = $probe['Outcome']
        (@($outcome.Keys) | Sort-Object) -join ',' | Should -BeExactly 'Error,ErrorId,Reason,Record,Unreachable'
        $outcome['Reason'] | Should -BeExactly 'Added'
        $outcome['Error'] | Should -BeNullOrEmpty
        $outcome['ErrorId'] | Should -BeNullOrEmpty
        $outcome['Unreachable'] | Should -BeOfType [bool]
        $outcome['Unreachable'] | Should -BeFalse
        $outcome['Record'] | Should -BeOfType [hashtable]
        $outcome['Record']['Data'] | Should -BeExactly $Expected
        $outcome['Record']['Type'] | Should -BeExactly $RRType
        $outcome['Record']['NodeName'] | Should -BeExactly $Node
        $outcome['Record']['Ttl'] | Should -Be 3600
        $outcome['Record']['Timestamp'] | Should -BeNullOrEmpty

        $probe['Log'].Count | Should -Be 1
        $call = $probe['Log'][0]
        $call.Keys | Should -Contain $DataParameter
        $call['Name'] | Should -BeExactly $Node
        $call['ZoneName'] | Should -BeExactly $Zone
        $call.Keys | Should -Not -Contain 'TimeToLive'
        $call.Keys | Should -Not -Contain 'CreatePtr'
        $call.Keys | Should -Not -Contain 'AgeRecord'
        [bool]$call['WhatIf'] | Should -BeFalse
        $call.Keys | Should -Contain 'Confirm'
    }

    It 'passes -TimeToLive only when -Ttl is given' {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $outcome = Add-DnsLiveRecord -ServerParameter @{ ComputerName = $Server } -ZoneName 'contoso.local' -NodeName 'new02' -RRType A -Data '10.0.16.62' -Ttl 600
            @{ Outcome = $outcome; Log = @($script:DnsStub.CallLog['Add-DnsServerResourceRecordA']) }
        }

        $probe['Log'][0]['TimeToLive'] | Should -Be (New-TimeSpan -Seconds 600)
        $probe['Log'][0].Keys | Should -Not -Contain 'CreatePtr'
        $probe['Log'][0].Keys | Should -Not -Contain 'AgeRecord'
        $probe['Outcome']['Record']['Ttl'] | Should -Be 600
    }

    It 'classifies WIN32 <Code> (<Case>) as <Reason>' -TestCases @(
        @{ Code = 9711; Case = 'the identical record exists'; Zone = 'contoso.local'; Node = 'srv01'; RRType = 'A'; Data = '10.0.16.20'; Reason = 'AlreadyExists'; HasRecord = $true }
        @{ Code = 9708; Case = 'the node is a CNAME'; Zone = 'contoso.local'; Node = 'gw'; RRType = 'A'; Data = '10.0.16.63'; Reason = 'CnameConflict'; HasRecord = $false }
        @{ Code = 9709; Case = 'a CNAME would join other records'; Zone = 'contoso.local'; Node = 'srv01'; RRType = 'CNAME'; Data = 'web.contoso.local'; Reason = 'CnameConflict'; HasRecord = $false }
        @{ Code = 9712; Case = 'the zone is a secondary'; Zone = 'fabrikam.com'; Node = 'srv01'; RRType = 'A'; Data = '10.0.18.5'; Reason = 'Failed'; HasRecord = $false }
    ) {
        $outcome = InModuleScope DnsLathund -Parameters @{ Server = $script:Server; Zone = $Zone; Node = $Node; RRType = $RRType; Data = $Data } {
            param ($Server, $Zone, $Node, $RRType, $Data)
            Add-DnsLiveRecord -ServerParameter @{ ComputerName = $Server } -ZoneName $Zone -NodeName $Node -RRType $RRType -Data $Data
        }

        $outcome['Reason'] | Should -BeExactly $Reason
        $outcome['ErrorId'] | Should -BeLike "WIN32 $Code,*"
        $outcome['Unreachable'] | Should -BeFalse
        if ($HasRecord) {
            $outcome['Record']['Data'] | Should -BeExactly $Data
            $outcome['Error'] | Should -BeNullOrEmpty
        }
        else {
            $outcome['Record'] | Should -BeNullOrEmpty
            $outcome['Error'] | Should -Not -BeNullOrEmpty
        }
    }

    It 'throws when NodeName <NodeName> ends with the zone name' -TestCases @(
        @{ NodeName = 'srv09.contoso.local' }
        @{ NodeName = 'SRV09.Contoso.Local.' }
        @{ NodeName = 'contoso.local' }
    ) {
        {
            InModuleScope DnsLathund -Parameters @{ Server = $script:Server; NodeName = $NodeName } {
                param ($Server, $NodeName)
                Add-DnsLiveRecord -ServerParameter @{ ComputerName = $Server } -ZoneName 'contoso.local' -NodeName $NodeName -RRType A -Data '10.0.16.65'
            }
        } | Should -Throw '*ends with the zone name*'

        InModuleScope DnsLathund { [int]$script:DnsStub.Calls['Add-DnsServerResourceRecordA'] } | Should -Be 0
    }
}

Describe 'Set-DnsLiveRecord' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-WriteTest -Root $script:Root
    }

    It 'changes the TTL of one record and leaves the other record at the node alone' {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $serverParameter = @{ ComputerName = $Server }
            $outcome = Set-DnsLiveRecord -ServerParameter $serverParameter -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A -Data '10.0.16.20' -NewTtl 600
            $records = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A)
            @{ Outcome = $outcome; Ttls = @($records | ForEach-Object { '{0}={1}' -f $_['Data'], $_['Ttl'] }) }
        }

        (@($probe['Outcome'].Keys) | Sort-Object) -join ',' | Should -BeExactly 'Error,ErrorId,Record,Unreachable'
        $probe['Outcome']['Error'] | Should -BeNullOrEmpty
        $probe['Outcome']['ErrorId'] | Should -BeNullOrEmpty
        $probe['Outcome']['Unreachable'] | Should -BeOfType [bool]
        $probe['Outcome']['Unreachable'] | Should -BeFalse
        $probe['Outcome']['Record']['Data'] | Should -BeExactly '10.0.16.20'
        $probe['Outcome']['Record']['Ttl'] | Should -Be 600
        $probe['Ttls'] -join ',' | Should -BeExactly '10.0.16.20=600,10.0.16.21=3600'
    }

    It 'fetches the record twice and writes the new data as a string on the second copy (<RRType>)' -TestCases @(
        @{ RRType = 'A'; Zone = 'contoso.local'; Node = 'srv01'; Data = '10.0.16.21'; NewData = '10.0.16.22'; Expected = '10.0.16.22'; Property = 'IPv4Address'; Written = '10.0.16.22' }
        @{ RRType = 'CNAME'; Zone = 'contoso.local'; Node = 'gw'; Data = 'srv01.contoso.local'; NewData = 'Web.Contoso.Local'; Expected = 'web.contoso.local'; Property = 'HostNameAlias'; Written = 'web.contoso.local.' }
        @{ RRType = 'PTR'; Zone = '16.0.10.in-addr.arpa'; Node = '20'; Data = 'srv01.contoso.local'; NewData = 'srv02.contoso.local.'; Expected = 'srv02.contoso.local'; Property = 'PtrDomainName'; Written = 'srv02.contoso.local.' }
    ) {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server; RRType = $RRType; Zone = $Zone; Node = $Node; Data = $Data; NewData = $NewData } {
            param ($Server, $RRType, $Zone, $Node, $Data, $NewData)
            $serverParameter = @{ ComputerName = $Server }
            $readsBefore = [int]$script:DnsStub.Calls['Get-DnsServerResourceRecord']
            $outcome = Set-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $Zone -NodeName $Node -RRType $RRType -Data $Data -NewData $NewData
            $reads = [int]$script:DnsStub.Calls['Get-DnsServerResourceRecord'] - $readsBefore
            $records = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $Zone -NodeName $Node -RRType $RRType)
            @{ Outcome = $outcome; Reads = $reads; Data = @($records | ForEach-Object { $_['Data'] }); Log = @($script:DnsStub.CallLog['Set-DnsServerResourceRecord']) }
        }

        $probe['Outcome']['Error'] | Should -BeNullOrEmpty
        $probe['Outcome']['Record']['Data'] | Should -BeExactly $Expected
        $probe['Data'] | Should -Contain $Expected
        $probe['Data'] | Should -Not -Contain $Data
        # Two reads before the change, one read-back after it.
        $probe['Reads'] | Should -Be 3

        $probe['Log'].Count | Should -Be 1
        $call = $probe['Log'][0]
        [object]::ReferenceEquals($call['OldInputObject'], $call['NewInputObject']) | Should -BeFalse
        [object]::ReferenceEquals($call['OldInputObject'].RecordData, $call['NewInputObject'].RecordData) | Should -BeFalse
        $call['NewInputObject'].RecordData.$Property | Should -BeOfType [string]
        $call['NewInputObject'].RecordData.$Property | Should -BeExactly $Written
        [string]$call['OldInputObject'].RecordData.$Property | Should -Not -BeExactly $Written
        [bool]$call['WhatIf'] | Should -BeFalse
        $call.Keys | Should -Contain 'Confirm'
    }

    It 'returns the re-read record with the timestamp the server kept' {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $serverParameter = @{ ComputerName = $Server }
            $before = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName 'contoso.local' -NodeName 'dyn01' -RRType A)[0]
            $outcome = Set-DnsLiveRecord -ServerParameter $serverParameter -ZoneName 'contoso.local' -NodeName 'dyn01' -RRType A -Data '10.0.16.30' -NewTtl 1200
            @{ Before = $before; Outcome = $outcome }
        }

        $probe['Before']['Timestamp'] | Should -BeOfType [datetime]
        $probe['Outcome']['Record']['Timestamp'] | Should -Be $probe['Before']['Timestamp']
        $probe['Outcome']['Record']['Ttl'] | Should -Be 1200
    }

    It 'returns an error and no record when <Case>' -TestCases @(
        @{ Case = 'the record does not exist'; Node = 'srv01'; RRType = 'A'; Data = '10.0.16.77'; NewData = '10.0.16.78'; Expected = '*does not exist*'; ErrorId = $null }
        @{ Case = 'the node does not exist (WIN32 9714)'; Node = 'nothere'; RRType = 'A'; Data = '10.0.16.77'; NewData = '10.0.16.78'; Expected = '*does not exist*'; ErrorId = 'WIN32 9714,*' }
        @{ Case = 'the new address is not IPv4'; Node = 'srv01'; RRType = 'A'; Data = '10.0.16.20'; NewData = '2001:db8::1'; Expected = '*not a valid IPv4 address*'; ErrorId = $null }
        @{ Case = 'the new address is not an address'; Node = 'srv01'; RRType = 'A'; Data = '10.0.16.20'; NewData = 'srv01'; Expected = '*not a valid IPv4 address*'; ErrorId = $null }
        @{ Case = 'the new data already exists at the node (WIN32 9711)'; Node = 'srv01'; RRType = 'A'; Data = '10.0.16.20'; NewData = '10.0.16.21'; Expected = '*already exists*'; ErrorId = 'WIN32 9711,*' }
        @{ Case = 'the alias would point at itself (WIN32 9707)'; Node = 'gw'; RRType = 'CNAME'; Data = 'srv01.contoso.local'; NewData = 'gw.contoso.local'; Expected = '*point at itself*'; ErrorId = 'WIN32 9707,*' }
    ) {
        $outcome = InModuleScope DnsLathund -Parameters @{ Server = $script:Server; Node = $Node; RRType = $RRType; Data = $Data; NewData = $NewData } {
            param ($Server, $Node, $RRType, $Data, $NewData)
            Set-DnsLiveRecord -ServerParameter @{ ComputerName = $Server } -ZoneName 'contoso.local' -NodeName $Node -RRType $RRType -Data $Data -NewData $NewData
        }

        $outcome['Record'] | Should -BeNullOrEmpty
        $outcome['Error'] | Should -BeLike $Expected
        $outcome['Unreachable'] | Should -BeFalse
        if ($ErrorId) {
            $outcome['ErrorId'] | Should -BeLike $ErrorId
        }
        else {
            $outcome['ErrorId'] | Should -BeNullOrEmpty
        }
    }

    It 'throws without -NewTtl and -NewData' {
        {
            InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
                param ($Server)
                Set-DnsLiveRecord -ServerParameter @{ ComputerName = $Server } -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A -Data '10.0.16.20'
            }
        } | Should -Throw '*-NewTtl, -NewData or both*'
    }
}

Describe 'Live write helpers on a failing server' {
    BeforeAll {
        function Invoke-FailingWrite {
            <#
            .SYNOPSIS
                Makes one stub fail with a chosen Win32 code and runs one helper
                against it; returns the helper's outcome hashtable.
            #>
            param (
                [string]$Helper,
                [string]$Stub,
                [int]$Code,
                [hashtable]$Target
            )

            InModuleScope DnsLathund -Parameters @{ Server = $script:Server; Helper = $Helper; Stub = $Stub; Code = $Code; Target = $Target } {
                param ($Server, $Helper, $Stub, $Code, $Target)

                $script:DnsStub.Fail[$Stub] = @('*')
                $script:DnsStub.FailCode[$Stub] = $Code
                $arguments = @{
                    ServerParameter = @{ ComputerName = $Server }
                    ZoneName        = $Target['Zone']
                    NodeName        = $Target['Node']
                    RRType          = $Target['RRType']
                    Data            = $Target['Data']
                }
                if ($Helper -eq 'Set-DnsLiveRecord') {
                    $arguments['NewTtl'] = 600
                }
                & $Helper @arguments
            }
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-WriteTest -Root $script:Root
    }

    # Every DnsServer cmdlet call of the three helpers, as the stubs' Fail
    # injection reaches it.
    Context '<Helper> when <Stub> fails' -ForEach @(
        @{ Helper = 'Remove-DnsLiveRecord'; Stub = 'Get-DnsServerResourceRecord'; Zone = 'contoso.local'; Node = 'srv01'; RRType = 'A'; Data = '10.0.16.20' }
        @{ Helper = 'Remove-DnsLiveRecord'; Stub = 'Remove-DnsServerResourceRecord'; Zone = 'contoso.local'; Node = 'srv01'; RRType = 'A'; Data = '10.0.16.20' }
        @{ Helper = 'Add-DnsLiveRecord'; Stub = 'Add-DnsServerResourceRecordA'; Zone = 'contoso.local'; Node = 'new05'; RRType = 'A'; Data = '10.0.16.70' }
        @{ Helper = 'Add-DnsLiveRecord'; Stub = 'Add-DnsServerResourceRecordAAAA'; Zone = 'contoso.local'; Node = 'new05'; RRType = 'AAAA'; Data = '2001:db8::70' }
        @{ Helper = 'Add-DnsLiveRecord'; Stub = 'Add-DnsServerResourceRecordCName'; Zone = 'contoso.local'; Node = 'alias05'; RRType = 'CNAME'; Data = 'web.contoso.local' }
        @{ Helper = 'Add-DnsLiveRecord'; Stub = 'Add-DnsServerResourceRecordPtr'; Zone = '16.0.10.in-addr.arpa'; Node = '70'; RRType = 'PTR'; Data = 'new05.contoso.local' }
        @{ Helper = 'Set-DnsLiveRecord'; Stub = 'Get-DnsServerResourceRecord'; Zone = 'contoso.local'; Node = 'srv01'; RRType = 'A'; Data = '10.0.16.20' }
        @{ Helper = 'Set-DnsLiveRecord'; Stub = 'Set-DnsServerResourceRecord'; Zone = 'contoso.local'; Node = 'srv01'; RRType = 'A'; Data = '10.0.16.20' }
    ) {
        It 'reports an unreachable server for WIN32 1722' {
            $outcome = Invoke-FailingWrite -Helper $Helper -Stub $Stub -Code 1722 -Target @{ Zone = $Zone; Node = $Node; RRType = $RRType; Data = $Data }

            $outcome['Unreachable'] | Should -BeOfType [bool]
            $outcome['Unreachable'] | Should -BeTrue
            $outcome['ErrorId'] | Should -BeLike '*1722*'
            $outcome['Error'] | Should -BeLike '*Stub failure*'
            $outcome['Record'] | Should -BeNullOrEmpty
            $outcome['AlreadyGone'] | Should -Not -BeTrue
            if ($Helper -eq 'Add-DnsLiveRecord') {
                $outcome['Reason'] | Should -BeExactly 'Failed'
            }
        }

        It 'reports access denied (WIN32 5) as a failure, never as already done' {
            $outcome = Invoke-FailingWrite -Helper $Helper -Stub $Stub -Code 5 -Target @{ Zone = $Zone; Node = $Node; RRType = $RRType; Data = $Data }

            $outcome['Unreachable'] | Should -BeOfType [bool]
            $outcome['Unreachable'] | Should -BeFalse
            $outcome['ErrorId'] | Should -BeLike 'WIN32 5,*'
            $outcome['Error'] | Should -BeLike '*Stub failure*'
            $outcome['Record'] | Should -BeNullOrEmpty
            $outcome['AlreadyGone'] | Should -Not -BeTrue
            $outcome['Removed'] | Should -Not -BeTrue
            $outcome['Reason'] | Should -Not -Be 'AlreadyExists'
            if ($Helper -eq 'Add-DnsLiveRecord') {
                $outcome['Reason'] | Should -BeExactly 'Failed'
            }
        }
    }
}

Describe 'Test-DnsConnectionError' {
    It 'returns <Expected> for <Case>' -TestCases @(
        @{ Case = 'the category ConnectionError'; ErrorId = 'SomethingElse'; Category = 'ConnectionError'; Expected = $true }
        @{ Case = 'WIN32 1722 in the error id'; ErrorId = 'WIN32 1722,Remove-DnsServerResourceRecord'; Category = 'NotSpecified'; Expected = $true }
        @{ Case = 'the HRESULT 0x800706BA in lower case'; ErrorId = 'HRESULT 0x800706ba,Microsoft.Management.Infrastructure.CimCmdlets.GetCimInstanceCommand'; Category = 'NotSpecified'; Expected = $true }
        @{ Case = 'a WSMan transport HRESULT (0x8033...)'; ErrorId = 'HRESULT 0x80338126,Microsoft.Management.Infrastructure.CimCmdlets.NewCimSessionCommand'; Category = 'NotSpecified'; Expected = $true }
        @{ Case = 'access denied (WIN32 5)'; ErrorId = 'WIN32 5,Add-DnsServerResourceRecordA'; Category = 'PermissionDenied'; Expected = $false }
        @{ Case = 'a record that already exists (WIN32 9711)'; ErrorId = 'WIN32 9711,Add-DnsServerResourceRecordA'; Category = 'ResourceExists'; Expected = $false }
    ) {
        $result = InModuleScope DnsLathund -Parameters @{ ErrorId = $ErrorId; Category = $Category } {
            param ($ErrorId, $Category)
            Write-Error -Message 'Probe error.' -Category $Category -ErrorId $ErrorId -ErrorAction SilentlyContinue -ErrorVariable probeErrors
            Test-DnsConnectionError -ErrorRecord $probeErrors[0]
        }

        $result | Should -BeOfType [bool]
        $result | Should -Be $Expected
    }

    It 'returns $false for $null' {
        $result = InModuleScope DnsLathund { Test-DnsConnectionError -ErrorRecord $null }

        $result | Should -BeOfType [bool]
        $result | Should -BeFalse
    }
}

Describe 'Write helpers ignore the caller''s -WhatIf' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-WriteTest -Root $script:Root
    }

    It 'still writes when <Case>' -TestCases @(
        @{ Case = 'a SupportsShouldProcess caller is run with -WhatIf'; ThroughProbe = $true }
        @{ Case = '$WhatIfPreference is $true in the calling scope'; ThroughProbe = $false }
    ) {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server; ThroughProbe = $ThroughProbe } {
            param ($Server, $ThroughProbe)

            function Invoke-WriteProbe {
                [CmdletBinding(SupportsShouldProcess)]
                param ([hashtable]$ServerParameter)

                @{
                    Add    = Add-DnsLiveRecord -ServerParameter $ServerParameter -ZoneName 'contoso.local' -NodeName 'probe01' -RRType A -Data '10.0.16.61'
                    Set    = Set-DnsLiveRecord -ServerParameter $ServerParameter -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A -Data '10.0.16.20' -NewTtl 900
                    Remove = Remove-DnsLiveRecord -ServerParameter $ServerParameter -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A -Data '10.0.16.21'
                }
            }

            $serverParameter = @{ ComputerName = $Server }
            if ($ThroughProbe) {
                $outcomes = Invoke-WriteProbe -ServerParameter $serverParameter -WhatIf
            }
            else {
                $WhatIfPreference = $true
                $outcomes = Invoke-WriteProbe -ServerParameter $serverParameter
                $WhatIfPreference = $false
            }

            @{
                Outcomes = $outcomes
                Probe    = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName 'contoso.local' -NodeName 'probe01' -RRType A).Count
                Srv01    = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName 'contoso.local' -NodeName 'srv01' -RRType A | ForEach-Object { '{0}={1}' -f $_['Data'], $_['Ttl'] })
            }
        }

        $probe['Outcomes']['Add']['Reason'] | Should -BeExactly 'Added'
        $probe['Outcomes']['Set']['Error'] | Should -BeNullOrEmpty
        $probe['Outcomes']['Remove']['Removed'] | Should -BeTrue
        $probe['Probe'] | Should -Be 1
        $probe['Srv01'] -join ',' | Should -BeExactly '10.0.16.20=900'
    }
}

Describe 'Resolve-DnsChangeTarget' {
    BeforeAll {
        $script:Root = Join-Path -Path $TestDrive -ChildPath 'resolve'
        $null = New-Item -Path $script:Root -ItemType Directory -Force
        Initialize-WriteTest -Root $script:Root
    }

    It 'resolves the string <Item> (Zone <Zone>) to <Kind>' -TestCases @(
        @{ Item = '10.0.16.20'; Zone = ''; Kind = 'Address'; Fqdn = $null; ZoneName = $null; NodeName = $null; Address = '10.0.16.20' }
        @{ Item = '010.000.016.020'; Zone = ''; Kind = 'Address'; Fqdn = $null; ZoneName = $null; NodeName = $null; Address = '10.0.16.20' }
        @{ Item = '2001:DB8::10'; Zone = ''; Kind = 'Address'; Fqdn = $null; ZoneName = $null; NodeName = $null; Address = '2001:db8::10' }
        @{ Item = ' SRV01.Contoso.Local. '; Zone = ''; Kind = 'Name'; Fqdn = 'srv01.contoso.local'; ZoneName = 'contoso.local'; NodeName = 'srv01'; Address = $null }
        @{ Item = 'test01.lab.contoso.local'; Zone = ''; Kind = 'Name'; Fqdn = 'test01.lab.contoso.local'; ZoneName = 'lab.contoso.local'; NodeName = 'test01'; Address = $null }
        @{ Item = 'test01.lab.contoso.local'; Zone = 'contoso.local'; Kind = 'Name'; Fqdn = 'test01.lab.contoso.local'; ZoneName = 'contoso.local'; NodeName = 'test01.lab'; Address = $null }
        @{ Item = 'contoso.local'; Zone = ''; Kind = 'Name'; Fqdn = 'contoso.local'; ZoneName = 'contoso.local'; NodeName = '@'; Address = $null }
        @{ Item = 'srv01'; Zone = 'Contoso.Local'; Kind = 'Name'; Fqdn = 'srv01.contoso.local'; ZoneName = 'contoso.local'; NodeName = 'srv01'; Address = $null }
        @{ Item = '@'; Zone = 'contoso.local'; Kind = 'Name'; Fqdn = 'contoso.local'; ZoneName = 'contoso.local'; NodeName = '@'; Address = $null }
    ) {
        $probe = Invoke-ResolveProbe -Item $Item -Zone $Zone -Server $script:Server

        $probe['ErrorId'] | Should -BeNullOrEmpty
        $target = $probe['Target']
        (@($target.Keys) | Sort-Object) -join ',' | Should -BeExactly 'Address,Data,Fqdn,Kind,NodeName,Server,Type,Zone'
        $target['Kind'] | Should -BeExactly $Kind
        $target['Fqdn'] | Should -Be $Fqdn
        $target['Zone'] | Should -Be $ZoneName
        $target['NodeName'] | Should -Be $NodeName
        $target['Address'] | Should -Be $Address
        $target['Type'] | Should -BeNullOrEmpty
        $target['Data'] | Should -BeNullOrEmpty
        $target['Server'] | Should -BeNullOrEmpty
    }

    It 'rejects <Item> (Zone <Zone>) with <Reason>' -TestCases @(
        @{ Item = '*sql*'; Zone = ''; Reason = 'PatternNotAllowed'; Category = 'InvalidArgument' }
        @{ Item = 'srv0?.contoso.local'; Zone = ''; Reason = 'PatternNotAllowed'; Category = 'InvalidArgument' }
        @{ Item = '*.contoso.local'; Zone = ''; Reason = 'PatternNotAllowed'; Category = 'InvalidArgument' }
        @{ Item = 'srv01'; Zone = ''; Reason = 'ZoneNotFound'; Category = 'ObjectNotFound' }
        @{ Item = 'host.example.org'; Zone = ''; Reason = 'ZoneNotFound'; Category = 'ObjectNotFound' }
        @{ Item = 'srv01.lab'; Zone = 'contoso.local'; Reason = 'ZoneNotFound'; Category = 'ObjectNotFound' }
        @{ Item = 'srv01'; Zone = 'example.org'; Reason = 'ZoneNotFound'; Category = 'ObjectNotFound' }
        @{ Item = 'srv01.contoso.local'; Zone = 'lab.contoso.local'; Reason = 'ZoneNotFound'; Category = 'ObjectNotFound' }
        @{ Item = '20.16.0.10.in-addr.arpa'; Zone = ''; Reason = 'ZoneNotFound'; Category = 'ObjectNotFound' }
        @{ Item = '   '; Zone = ''; Reason = 'InvalidInput'; Category = 'InvalidArgument' }
    ) {
        $probe = Invoke-ResolveProbe -Item $Item -Zone $Zone -Server $script:Server

        $probe['Target'] | Should -BeNullOrEmpty
        $probe['ErrorId'] | Should -BeLike "DnsLathund.Resolve-DnsChangeTarget.$Reason,*"
        $probe['Category'] | Should -BeExactly $Category
        $probe['Message'] | Should -Not -BeNullOrEmpty
    }

    It 'takes the identity of an Entry object, including a wildcard owner (<Name>)' -TestCases @(
        @{ Name = 'srv01.contoso.local'; Type = 'A'; Data = '10.0.16.20'; NodeName = 'srv01'; Kind = 'Name'; Address = '10.0.16.20' }
        @{ Name = '*.contoso.local'; Type = 'A'; Data = '10.0.16.99'; NodeName = '*'; Kind = 'Name'; Address = '10.0.16.99' }
        @{ Name = 'gw.contoso.local'; Type = 'CNAME'; Data = 'srv01.contoso.local'; NodeName = 'gw'; Kind = 'Cname'; Address = $null }
    ) {
        $entry = InModuleScope DnsLathund -Parameters @{ Name = $Name; Type = $Type; Data = $Data; NodeName = $NodeName } {
            param ($Name, $Type, $Data, $NodeName)
            New-DnsObject -TypeName 'Entry' -Property ([ordered]@{ Name = $Name; Type = $Type; Data = $Data; TTL = 3600; Zone = 'contoso.local'; NodeName = $NodeName; Server = 'dc01' })
        }

        $probe = Invoke-ResolveProbe -Item $entry -Zone '' -Server $script:Server

        $probe['ErrorId'] | Should -BeNullOrEmpty
        $target = $probe['Target']
        $target['Kind'] | Should -BeExactly $Kind
        $target['Fqdn'] | Should -BeExactly $Name
        $target['Zone'] | Should -BeExactly 'contoso.local'
        $target['NodeName'] | Should -BeExactly $NodeName
        $target['Type'] | Should -BeExactly $Type
        $target['Data'] | Should -BeExactly $Data
        $target['Address'] | Should -Be $Address
        $target['Server'] | Should -BeExactly 'dc01'
    }

    It 'accepts a Deserialized.DnsLathund.Entry from Export-Clixml / Import-Clixml' {
        $entry = InModuleScope DnsLathund {
            New-DnsObject -TypeName 'Entry' -Property ([ordered]@{ Name = 'srv01.contoso.local'; Type = 'A'; Data = '10.0.16.21'; TTL = 3600; Zone = 'contoso.local'; NodeName = 'srv01'; Server = 'dc01' })
        }
        $path = Join-Path -Path $script:Root -ChildPath 'entry.xml'
        $entry | Export-Clixml -LiteralPath $path
        $deserialized = Import-Clixml -LiteralPath $path
        $deserialized.PSObject.TypeNames[0] | Should -BeExactly 'Deserialized.DnsLathund.Entry'

        $probe = Invoke-ResolveProbe -Item $deserialized -Zone '' -Server $script:Server

        $probe['ErrorId'] | Should -BeNullOrEmpty
        $probe['Target']['Kind'] | Should -BeExactly 'Name'
        $probe['Target']['Fqdn'] | Should -BeExactly 'srv01.contoso.local'
        $probe['Target']['Data'] | Should -BeExactly '10.0.16.21'
        $probe['Target']['NodeName'] | Should -BeExactly 'srv01'
    }

    It 'rejects an Entry whose zone is not hosted on the server' {
        $entry = InModuleScope DnsLathund {
            New-DnsObject -TypeName 'Entry' -Property ([ordered]@{ Name = 'web.example.org'; Type = 'A'; Data = '192.0.2.10'; Zone = 'example.org'; NodeName = 'web'; Server = 'dc09' })
        }

        $probe = Invoke-ResolveProbe -Item $entry -Zone '' -Server $script:Server

        $probe['ErrorId'] | Should -BeLike 'DnsLathund.Resolve-DnsChangeTarget.ZoneNotFound,*'
    }

    It 'resolves a CSV row with <Case>' -TestCases @(
        @{ Case = 'Name and Address'; Row = @{ Name = 'srv05.contoso.local'; Address = '10.0.16.55'; Target = $null; TTL = '600'; Zone = $null }; Kind = 'Name'; Fqdn = 'srv05.contoso.local'; Type = 'A'; Data = '10.0.16.55'; Address = '10.0.16.55' }
        @{ Case = 'Name and an IPv6 Address'; Row = @{ Name = 'v6new.contoso.local'; Address = '2001:DB8::60'; Target = $null; TTL = $null; Zone = $null }; Kind = 'Name'; Fqdn = 'v6new.contoso.local'; Type = 'AAAA'; Data = '2001:db8::60'; Address = '2001:db8::60' }
        @{ Case = 'Name and Target'; Row = @{ Name = 'www2.contoso.local'; Address = $null; Target = 'Web.Contoso.Local.'; TTL = $null; Zone = $null }; Kind = 'Cname'; Fqdn = 'www2.contoso.local'; Type = 'CNAME'; Data = 'web.contoso.local'; Address = $null }
        @{ Case = 'a bare Name and a Zone column'; Row = @{ Name = 'srv06'; Address = '10.0.17.6'; Target = $null; TTL = $null; Zone = 'lab.contoso.local' }; Kind = 'Name'; Fqdn = 'srv06.lab.contoso.local'; Type = 'A'; Data = '10.0.17.6'; Address = '10.0.17.6' }
        @{ Case = 'only an Address'; Row = @{ Name = $null; Address = '10.0.16.20'; Target = $null; TTL = $null; Zone = $null }; Kind = 'Address'; Fqdn = $null; Type = $null; Data = $null; Address = '10.0.16.20' }
    ) {
        $probe = Invoke-ResolveProbe -Item $Row -Zone '' -Server $script:Server

        $probe['ErrorId'] | Should -BeNullOrEmpty
        $target = $probe['Target']
        $target['Kind'] | Should -BeExactly $Kind
        $target['Fqdn'] | Should -Be $Fqdn
        $target['Type'] | Should -Be $Type
        $target['Data'] | Should -Be $Data
        $target['Address'] | Should -Be $Address
    }

    It 'rejects a CSV row with <Case>' -TestCases @(
        @{ Case = 'both Address and Target'; Row = @{ Name = 'x.contoso.local'; Address = '10.0.16.5'; Target = 'web.contoso.local'; TTL = $null; Zone = $null }; Reason = 'InvalidInput' }
        @{ Case = 'both Address and Target and an empty Name'; Row = @{ Name = $null; Address = '10.0.16.5'; Target = 'web.contoso.local'; TTL = $null; Zone = $null }; Reason = 'InvalidInput' }
        @{ Case = 'an Address that is not an address'; Row = @{ Name = 'x.contoso.local'; Address = 'web'; Target = $null; TTL = $null; Zone = $null }; Reason = 'InvalidInput' }
        @{ Case = 'neither Name nor Address'; Row = @{ Name = $null; Address = $null; Target = 'web.contoso.local'; TTL = $null; Zone = $null }; Reason = 'InvalidInput' }
        @{ Case = 'a pattern as Name'; Row = @{ Name = 'srv*'; Address = $null; Target = $null; TTL = $null; Zone = 'contoso.local' }; Reason = 'PatternNotAllowed' }
    ) {
        $probe = Invoke-ResolveProbe -Item $Row -Zone '' -Server $script:Server

        $probe['Target'] | Should -BeNullOrEmpty
        $probe['ErrorId'] | Should -BeLike "DnsLathund.Resolve-DnsChangeTarget.$Reason,*"
    }
}

Describe 'Get-DnsReverseZoneName' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-WriteTest -Root $script:Root
    }

    It 'derives <ZoneName> from <NetworkId>, as the Add-DnsServerPrimaryZone stub does' -TestCases @(
        @{ NetworkId = '10.0.0.0/8'; ZoneName = '10.in-addr.arpa'; Family = 'IPv4'; Prefix = 8; Network = '10.0.0.0/8' }
        @{ NetworkId = '172.16.0.0/16'; ZoneName = '16.172.in-addr.arpa'; Family = 'IPv4'; Prefix = 16; Network = '172.16.0.0/16' }
        @{ NetworkId = '10.0.18.0/24'; ZoneName = '18.0.10.in-addr.arpa'; Family = 'IPv4'; Prefix = 24; Network = '10.0.18.0/24' }
        @{ NetworkId = ' 10.0.18.77/24 '; ZoneName = '18.0.10.in-addr.arpa'; Family = 'IPv4'; Prefix = 24; Network = '10.0.18.0/24' }
        @{ NetworkId = '2001:DB8:0:1::/64'; ZoneName = '1.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa'; Family = 'IPv6'; Prefix = 64; Network = '2001:db8:0:1::/64' }
        @{ NetworkId = '2001:db8:abcd:12::5/48'; ZoneName = 'd.c.b.a.8.b.d.0.1.0.0.2.ip6.arpa'; Family = 'IPv6'; Prefix = 48; Network = '2001:db8:abcd::/48' }
    ) {
        $probe = InModuleScope DnsLathund -Parameters @{ NetworkId = $NetworkId } {
            param ($NetworkId)
            $reverse = Get-DnsReverseZoneName -NetworkId $NetworkId
            $zone = Add-DnsServerPrimaryZone -NetworkId $reverse['Network'] -ReplicationScope 'Domain' -PassThru -WhatIf:$false -Confirm:$false
            @{ Reverse = $reverse; StubZone = $zone.ZoneName }
        }

        $reverse = $probe['Reverse']
        (@($reverse.Keys) | Sort-Object) -join ',' | Should -BeExactly 'Family,Network,Prefix,ZoneName'
        $reverse['ZoneName'] | Should -BeExactly $ZoneName
        $reverse['Family'] | Should -BeExactly $Family
        $reverse['Prefix'] | Should -Be $Prefix
        $reverse['Prefix'] | Should -BeOfType [int]
        $reverse['Network'] | Should -BeExactly $Network
        $probe['StubZone'] | Should -BeExactly $ZoneName
    }

    It 'rejects <NetworkId> and names <Hint>' -TestCases @(
        @{ NetworkId = '10.0.16.0/20'; Hint = '*Use /16 or /24 instead*' }
        @{ NetworkId = '10.0.0.0/12'; Hint = '*Use /8 or /16 instead*' }
        @{ NetworkId = '10.0.16.0/25'; Hint = '*Use /24 instead.*RFC 2317*' }
        @{ NetworkId = '10.0.0.0/4'; Hint = '*Use /8 instead*' }
        @{ NetworkId = '2001:db8::/66'; Hint = '*Use /64 or /68 instead*' }
        @{ NetworkId = '2001:db8::/126'; Hint = '*Use /124 instead*' }
        @{ NetworkId = '2001:db8::/0'; Hint = '*Use /4 instead*' }
        @{ NetworkId = '10.0.16.0'; Hint = '*not a network in CIDR form*' }
        @{ NetworkId = 'srv01/24'; Hint = '*not an IPv4 or IPv6 address*' }
    ) {
        { InModuleScope DnsLathund -Parameters @{ NetworkId = $NetworkId } { param ($NetworkId) Get-DnsReverseZoneName -NetworkId $NetworkId } } | Should -Throw $Hint
    }
}

Describe 'Test-DnsWriterServer' {
    BeforeEach {
        InModuleScope DnsLathund {
            $script:WriterServer = $null
        }
    }

    AfterAll {
        InModuleScope DnsLathund {
            $script:WriterServer = $null
        }
    }

    It 'remembers the first server silently and warns when another server is changed' {
        $probe = InModuleScope DnsLathund {
            $first = @(Test-DnsWriterServer -Server 'DC01' -WarningVariable firstWarnings -WarningAction SilentlyContinue)
            $same = @(Test-DnsWriterServer -Server 'dc01' -WarningVariable sameWarnings -WarningAction SilentlyContinue)
            $other = @(Test-DnsWriterServer -Server 'DC02' -WarningVariable otherWarnings -WarningAction SilentlyContinue)
            @{
                Output        = $first.Count + $same.Count + $other.Count
                FirstWarnings = @($firstWarnings)
                SameWarnings  = @($sameWarnings)
                OtherWarnings = @($otherWarnings)
                Writer        = $script:WriterServer
            }
        }

        $probe['Output'] | Should -Be 0
        $probe['FirstWarnings'].Count | Should -Be 0
        $probe['SameWarnings'].Count | Should -Be 0
        $probe['OtherWarnings'].Count | Should -Be 1
        [string]$probe['OtherWarnings'][0] | Should -BeExactly "This session already changed DNS on 'dc01'; changes on 'dc02' may be lost if both touch the same node before replication."
        $probe['Writer'] | Should -BeExactly 'dc01'
    }
}

Describe 'Confirm-DnsAction remembers "Yes to all" per impact level' {
    It 'an A on a Medium prompt does not approve a High action' {
        $probe = InModuleScope DnsLathund {
            Mock Write-Host { }
            Mock Read-Host {
                if ($Prompt -like 'Create reverse zone*') {
                    'n'
                }
                else {
                    'a'
                }
            }
            $ConfirmPreference = 'Medium'
            $state = (New-DnsBatch -Server 'dc01')['Confirm']

            $results = @(
                Confirm-DnsAction -Target 'srv05.contoso.local' -Action 'Add DNS records' -Impact Medium -State $state
                Confirm-DnsAction -Target 'srv06.contoso.local' -Action 'Add DNS records' -Impact Medium -State $state
                Confirm-DnsAction -Target '17.0.10.in-addr.arpa' -Action 'Create reverse zone' -Impact High -State $state
            )
            Should -Invoke Read-Host -Times 2 -Exactly
            @{ Results = $results; Medium = $state['All']['Medium']; High = $state['All']['High'] }
        }

        $probe['Results'] -join ',' | Should -BeExactly 'True,True,False'
        $probe['Medium'] | Should -BeTrue
        $probe['High'] | Should -BeNullOrEmpty
    }

    It 'an A on a High prompt approves later High actions without prompting' {
        $probe = InModuleScope DnsLathund {
            Mock Write-Host { }
            Mock Read-Host { 'all' }
            $ConfirmPreference = 'High'
            $state = @{ All = @{} }

            $results = @(
                Confirm-DnsAction -Target 'srv01.contoso.local' -Action 'Remove DNS records' -Impact High -State $state
                Confirm-DnsAction -Target 'srv02.contoso.local' -Action 'Remove DNS records' -Impact High -State $state
            )
            Should -Invoke Read-Host -Times 1 -Exactly
            @{ Results = $results; High = $state['All']['High'] }
        }

        $probe['Results'] -join ',' | Should -BeExactly 'True,True'
        $probe['High'] | Should -BeTrue
    }
}

Describe 'Phase-2 stubs' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-WriteTest -Root $script:Root
    }

    It 'let Get-DnsCimSession open a verified session offline, and fail with CimUnavailable' {
        $probe = InModuleScope DnsLathund -Parameters @{ Server = $script:Server } {
            param ($Server)
            $session = Get-DnsCimSession -Server $Server
            $verification = @($script:DnsStub.CallLog['Get-CimInstance'])[0]
            $script:CimSessionCache = @{}
            $script:DnsStub.CimUnavailable = $true
            $unavailable = Get-DnsCimSession -Server $Server
            @{ Session = $session; Verification = $verification; Unavailable = $unavailable; Cache = $script:CimSessionCache[$Server]; Attempts = [int]$script:DnsStub.Calls['New-CimSession'] }
        }

        $probe['Session'].ComputerName | Should -BeExactly $script:Server
        $probe['Session'].Protocol | Should -BeExactly 'Wsman'
        $probe['Verification']['Query'] | Should -BeExactly 'SELECT Name FROM MicrosoftDNS_Server'
        $probe['Unavailable'] | Should -BeNullOrEmpty
        $probe['Cache'] | Should -BeExactly 'Unavailable'
        # One for the first session, then WSMan and DCOM for the failing one.
        $probe['Attempts'] | Should -Be 3
    }

    It 'give WIN32 <Code> the category <Category>' -TestCases @(
        @{ Code = 5; Category = 'PermissionDenied' }
        @{ Code = 1722; Category = 'ConnectionError' }
        @{ Code = 9701; Category = 'ObjectNotFound' }
        @{ Code = 9711; Category = 'ResourceExists' }
        @{ Code = 9712; Category = 'InvalidOperation' }
        @{ Code = 9714; Category = 'ObjectNotFound' }
    ) {
        InModuleScope DnsLathund -Parameters @{ Code = $Code } {
            param ($Code)
            Get-DnsStubErrorCategory -Code $Code
        } | Should -BeExactly $Category
    }

    It 'return independent copies from Get-DnsServerResourceRecord' {
        $probe = InModuleScope DnsLathund {
            $first = @(Get-DnsServerResourceRecord -ZoneName 'contoso.local' -Name 'srv01' -Node -RRType A)[0]
            $second = @(Get-DnsServerResourceRecord -ZoneName 'contoso.local' -Name 'srv01' -Node -RRType A)[0]
            $second.RecordData.IPv4Address = '10.0.16.250'
            $third = @(Get-DnsServerResourceRecord -ZoneName 'contoso.local' -Name 'srv01' -Node -RRType A)[0]
            @{ First = $first; Second = $second; Third = $third }
        }

        [object]::ReferenceEquals($probe['First'], $probe['Second']) | Should -BeFalse
        $probe['First'].Id | Should -BeExactly $probe['Second'].Id
        $probe['First'].RecordData.IPv4Address.IPAddressToString | Should -BeExactly '10.0.16.20'
        $probe['Third'].RecordData.IPv4Address.IPAddressToString | Should -BeExactly '10.0.16.20'
    }

    It 'answer Get-DnsServerZoneScope, Set-DnsServerZoneAging and skip writes under -WhatIf' {
        $probe = InModuleScope DnsLathund {
            $script:DnsStub.ZoneScopes['contoso.local'] = @('branch')
            $scopes = @(Get-DnsServerZoneScope -ZoneName 'contoso.local' | ForEach-Object { $_.ZoneScope })
            Set-DnsServerZoneAging -Name 'contoso.local' -Aging $true -RefreshInterval (New-TimeSpan -Days 3) -ScavengeServers ([ipaddress]'10.0.16.10') -WhatIf:$false -Confirm:$false
            Add-DnsServerResourceRecordA -ZoneName 'contoso.local' -Name 'skipped' -IPv4Address '10.0.16.66' -WhatIf
            @{
                Scopes   = $scopes
                Aging    = $script:DnsStub.Aging['contoso.local']
                Skipped  = @($script:DnsStub.Records['contoso.local'] | Where-Object { $_.HostName -eq 'skipped' }).Count
                AddCalls = [int]$script:DnsStub.Calls['Add-DnsServerResourceRecordA']
            }
        }

        $probe['Scopes'] -join ',' | Should -BeExactly 'contoso.local,branch'
        $probe['Aging'].AgingEnabled | Should -BeTrue
        $probe['Aging'].RefreshInterval | Should -Be (New-TimeSpan -Days 3)
        @($probe['Aging'].ScavengeServers) | Should -Be @('10.0.16.10')
        $probe['Skipped'] | Should -Be 0
        $probe['AddCalls'] | Should -Be 1
    }
}
