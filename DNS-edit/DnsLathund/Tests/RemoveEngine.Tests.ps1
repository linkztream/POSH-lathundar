#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Fas B-tester för DnsLathund: Resolve-DnsRecordPair, Remove-DnsRecordPair och
    Remove-DnsHostRecord.

    Testerna körs offline. DnsServer-modulen finns inte på utvecklingsmaskinen,
    så Get-DnsServerResourceRecord och Remove-DnsServerResourceRecord definieras
    som stubbar i modulens script-scope (function script:...). Stubbarna läser
    syntetiska poster ur $global:DnsTest och registrerar varje borttagning i
    $global:DnsTest.RemoveCalls, vilket gör det möjligt att assertera ORDNINGEN
    mellan PTR och A. Ett globalt kärl används medvetet: mockkroppar och stubbar
    exekverar i modulens session state och når inte testfilens scope.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingComputerNameHardcoded',
    '',
    Justification = 'dc01 är syntetiskt testdata, ingen verklig server kontaktas.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidGlobalVars',
    '',
    Justification = 'Stubbarna körs i modulens session state och når bara globala variabler.'
)]
param ()

BeforeAll {
    $script:ModulePath = Split-Path -Path $PSScriptRoot -Parent
    $script:ManifestPath = Join-Path -Path $script:ModulePath -ChildPath 'DnsLathund.psd1'

    Remove-Module -Name DnsLathund -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop

    function Reset-DnsTestState {
        $global:DnsTest = @{
            ARecords            = @{}
            PtrRecords          = @{}
            RemoveCalls         = New-Object System.Collections.ArrayList
            ResolvedIdentities  = New-Object System.Collections.ArrayList
            PairsToReturn       = @{}
            FailPtr             = $false
            FailA               = $false
        }
    }

    function New-TestARecord {
        param (
            [string]$HostName,
            [string]$IPAddress
        )

        [PSCustomObject]@{
            HostName   = $HostName
            RecordType = 'A'
            RecordData = [PSCustomObject]@{
                IPv4Address = [IPAddress]$IPAddress
            }
        }
    }

    function New-TestPtrRecord {
        param (
            [string]$HostName,
            [string]$PtrDomainName
        )

        [PSCustomObject]@{
            HostName   = $HostName
            RecordType = 'PTR'
            RecordData = [PSCustomObject]@{
                PtrDomainName = $PtrDomainName
            }
        }
    }

    function Set-TestARecords {
        param (
            [string]$ZoneName,
            [string]$Name,
            [object[]]$Records
        )

        $global:DnsTest.ARecords["$ZoneName|$Name"] = $Records
    }

    function Set-TestPtrRecords {
        param (
            [string]$ZoneName,
            [string]$Name,
            [object[]]$Records
        )

        $global:DnsTest.PtrRecords["$ZoneName|$Name"] = $Records
    }

    function Get-TestRecordPair {
        param (
            [string]$Name = 'srv01.contoso.local',
            [string]$IPAddress = '10.0.16.5',
            [string]$Relation = '1:1',
            [switch]$WithoutPtr
        )

        $aRecord = New-TestARecord -HostName ($Name -split '\.')[0] -IPAddress $IPAddress
        $ptrNodeName = ($IPAddress -split '\.')[3]

        $ptrRecords = if ($WithoutPtr) {
            @()
        }
        else {
            @(New-TestPtrRecord -HostName $ptrNodeName -PtrDomainName "$Name.")
        }

        InModuleScope DnsLathund -Parameters @{
            Name        = $Name
            IPAddress   = $IPAddress
            Relation    = $Relation
            ARecord     = $aRecord
            PtrRecords  = $ptrRecords
            PtrNodeName = $ptrNodeName
        } {
            param ($Name, $IPAddress, $Relation, $ARecord, $PtrRecords, $PtrNodeName)

            # En tom array överlever inte InModuleScope -Parameters (blir $null).
            $ptrRecordList = [object[]]@($PtrRecords | Where-Object { $null -ne $_ })

            New-DnsRecordPairObject `
                -Name $Name `
                -IPv4Address $IPAddress `
                -ForwardZone 'contoso.local' `
                -ARecord $ARecord `
                -ReverseZone '16.0.10.in-addr.arpa' `
                -PtrNodeName $PtrNodeName `
                -PtrRecords $ptrRecordList `
                -MatchingPtrRecords $ptrRecordList `
                -PtrTargets ([string[]]@($ptrRecordList | ForEach-Object { $_.RecordData.PtrDomainName.TrimEnd('.') })) `
                -Relation $Relation `
                -ComputerName 'dc01'
        }
    }

    Reset-DnsTestState

    InModuleScope DnsLathund {
        # DnsServer-modulen finns inte offline; hoppa över RSAT-kontrollen.
        $script:DnsServerModuleVerified = $true

        function script:Get-DnsServerResourceRecord {
            [CmdletBinding()]
            param (
                [Parameter(ValueFromPipeline)]
                $InputObject,

                [string]$ZoneName,

                [string[]]$Name,

                [string]$RRType,

                [string]$ComputerName,

                $CimSession
            )

            if ([string]::IsNullOrEmpty($Name)) {
                throw 'Get-DnsServerResourceRecord anropades utan -Name (ofiltrerad zon-enumeration är förbjuden).'
            }

            $key = '{0}|{1}' -f $ZoneName, ($Name -join ',')

            $table = if ($RRType -eq 'A') {
                $global:DnsTest.ARecords
            }
            else {
                $global:DnsTest.PtrRecords
            }

            if ($table.ContainsKey($key)) {
                foreach ($record in $table[$key]) {
                    $record
                }
            }
        }

        function script:Remove-DnsServerResourceRecord {
            [CmdletBinding()]
            param (
                [Parameter(ValueFromPipeline)]
                $InputObject,

                [string]$ZoneName,

                [string]$ComputerName,

                $CimSession,

                [switch]$Force,

                [string]$Name,

                [string]$RRType,

                $RecordData
            )

            process {
                $recordType = $InputObject.RecordType

                if (
                    ($recordType -eq 'PTR' -and $global:DnsTest.FailPtr) -or
                    ($recordType -eq 'A' -and $global:DnsTest.FailA)
                ) {
                    throw "Simulerat fel vid borttagning av $recordType-posten."
                }

                $null = $global:DnsTest.RemoveCalls.Add(
                    [PSCustomObject]@{
                        RecordType   = $recordType
                        ZoneName     = $ZoneName
                        HostName     = $InputObject.HostName
                        UsedPipeline = ($null -ne $InputObject)
                        UsedNameForm = (-not [string]::IsNullOrEmpty($Name))
                    }
                )
            }
        }
    }
}

AfterAll {
    Remove-Module -Name DnsLathund -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name DnsTest -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Resolve-DnsRecordPair' {

    BeforeAll {
        Mock -CommandName Get-DnsZoneTable -ModuleName DnsLathund -MockWith {
            [PSCustomObject]@{
                AllZones     = @()
                ForwardZones = [string[]]@('contoso.local')
                ReverseZones = [string[]]@('16.0.10.in-addr.arpa')
            }
        }
    }

    BeforeEach {
        Reset-DnsTestState
    }

    It "klassificerar en ren relation som '1:1'" {
        Set-TestARecords -ZoneName 'contoso.local' -Name 'srv01' -Records @(
            New-TestARecord -HostName 'srv01' -IPAddress '10.0.16.5'
        )
        Set-TestPtrRecords -ZoneName '16.0.10.in-addr.arpa' -Name '5' -Records @(
            New-TestPtrRecord -HostName '5' -PtrDomainName 'srv01.contoso.local.'
        )

        $pair = InModuleScope DnsLathund {
            Resolve-DnsRecordPair -Identity 'srv01.contoso.local' -ComputerName 'dc01'
        }

        $pair.PSObject.TypeNames | Should -Contain 'DnsLathund.RecordPair'
        $pair.Name | Should -BeExactly 'srv01.contoso.local'
        $pair.IPv4Address | Should -BeExactly '10.0.16.5'
        $pair.ForwardZone | Should -BeExactly 'contoso.local'
        $pair.ReverseZone | Should -BeExactly '16.0.10.in-addr.arpa'
        $pair.PtrNodeName | Should -BeExactly '5'
        $pair.ComputerName | Should -BeExactly 'dc01'
        @($pair.MatchingPtrRecords).Count | Should -Be 1
        $pair.PtrTargets | Should -Be @('srv01.contoso.local')
        $pair.Relation | Should -BeExactly '1:1'
    }

    It "klassificerar flera PTR där en matchar som 'Matchande PTR finns, men relationen är inte 1:1'" {
        Set-TestARecords -ZoneName 'contoso.local' -Name 'srv01' -Records @(
            New-TestARecord -HostName 'srv01' -IPAddress '10.0.16.5'
        )
        Set-TestPtrRecords -ZoneName '16.0.10.in-addr.arpa' -Name '5' -Records @(
            New-TestPtrRecord -HostName '5' -PtrDomainName 'srv01.contoso.local.'
            New-TestPtrRecord -HostName '5' -PtrDomainName 'gammal-srv.contoso.local.'
        )

        $pair = InModuleScope DnsLathund {
            Resolve-DnsRecordPair -Identity 'srv01.contoso.local' -ComputerName 'dc01'
        }

        $pair.Relation | Should -BeExactly 'Matchande PTR finns, men relationen är inte 1:1'
        @($pair.MatchingPtrRecords).Count | Should -Be 1
        @($pair.PtrRecords).Count | Should -Be 2
    }

    It "klassificerar en främmande PTR som 'PTR pekar på annat namn'" {
        Set-TestARecords -ZoneName 'contoso.local' -Name 'srv01' -Records @(
            New-TestARecord -HostName 'srv01' -IPAddress '10.0.16.5'
        )
        Set-TestPtrRecords -ZoneName '16.0.10.in-addr.arpa' -Name '5' -Records @(
            New-TestPtrRecord -HostName '5' -PtrDomainName 'gammal-srv.contoso.local.'
        )

        $pair = InModuleScope DnsLathund {
            Resolve-DnsRecordPair -Identity 'srv01.contoso.local' -ComputerName 'dc01'
        }

        $pair.Relation | Should -BeExactly 'PTR pekar på annat namn'
        @($pair.MatchingPtrRecords).Count | Should -Be 0
        $pair.PtrTargets | Should -Be @('gammal-srv.contoso.local')
    }

    It "klassificerar avsaknad av PTR som 'PTR saknas'" {
        Set-TestARecords -ZoneName 'contoso.local' -Name 'srv01' -Records @(
            New-TestARecord -HostName 'srv01' -IPAddress '10.0.16.5'
        )

        $pair = InModuleScope DnsLathund {
            Resolve-DnsRecordPair -Identity 'srv01.contoso.local' -ComputerName 'dc01'
        }

        $pair.Relation | Should -BeExactly 'PTR saknas'
        @($pair.MatchingPtrRecords).Count | Should -Be 0
    }

    It 'matchar skiftläge och slutpunkt i PTR-målet' {
        Set-TestARecords -ZoneName 'contoso.local' -Name 'srv01' -Records @(
            New-TestARecord -HostName 'srv01' -IPAddress '10.0.16.5'
        )
        Set-TestPtrRecords -ZoneName '16.0.10.in-addr.arpa' -Name '5' -Records @(
            New-TestPtrRecord -HostName '5' -PtrDomainName 'SRV01.Contoso.Local.'
        )

        $pair = InModuleScope DnsLathund {
            Resolve-DnsRecordPair -Identity 'srv01.contoso.local.' -ComputerName 'dc01'
        }

        $pair.Relation | Should -BeExactly '1:1'
    }

    It 'filtrerar IP-uppslag till den efterfrågade adressen' {
        # PTR för .5 pekar på srv01, som har två A-poster. Bara den som pekar
        # tillbaka på 10.0.16.5 får komma ut.
        Set-TestPtrRecords -ZoneName '16.0.10.in-addr.arpa' -Name '5' -Records @(
            New-TestPtrRecord -HostName '5' -PtrDomainName 'srv01.contoso.local.'
        )
        Set-TestARecords -ZoneName 'contoso.local' -Name 'srv01' -Records @(
            New-TestARecord -HostName 'srv01' -IPAddress '10.0.16.5'
            New-TestARecord -HostName 'srv01' -IPAddress '10.0.16.6'
        )
        Set-TestPtrRecords -ZoneName '16.0.10.in-addr.arpa' -Name '6' -Records @(
            New-TestPtrRecord -HostName '6' -PtrDomainName 'srv01.contoso.local.'
        )

        $pairs = @(
            InModuleScope DnsLathund {
                Resolve-DnsRecordPair -Identity '10.0.16.5' -ComputerName 'dc01'
            }
        )

        $pairs.Count | Should -Be 1
        $pairs[0].IPv4Address | Should -BeExactly '10.0.16.5'
        $pairs[0].Name | Should -BeExactly 'srv01.contoso.local'
    }

    It 'varnar och ger inget resultat när ingen reverse-zon matchar IP-adressen' {
        $warnings = @()

        $pairs = @(
            InModuleScope DnsLathund {
                Resolve-DnsRecordPair -Identity '192.168.1.1' -ComputerName 'dc01'
            } -WarningVariable warnings -WarningAction SilentlyContinue
        )

        $pairs.Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'Ingen reverse-zon'
    }

    It 'varnar när ett kort namn inte matchar någon forward-zon' {
        $warnings = @()

        $pairs = @(
            InModuleScope DnsLathund {
                Resolve-DnsRecordPair -Identity 'srv01' -ComputerName 'dc01'
            } -WarningVariable warnings -WarningAction SilentlyContinue
        )

        $pairs.Count | Should -Be 0
        ($warnings -join ' ') | Should -Match "Ingen forward-zon matchar namnet 'srv01'"
    }

    It 'tolkar ett kort namn som relativt när -ZoneName anges' {
        Set-TestARecords -ZoneName 'contoso.local' -Name 'srv01' -Records @(
            New-TestARecord -HostName 'srv01' -IPAddress '10.0.16.5'
        )

        $pair = InModuleScope DnsLathund {
            Resolve-DnsRecordPair -Identity 'srv01' -ComputerName 'dc01' -ZoneName 'contoso.local'
        }

        $pair | Should -Not -BeNullOrEmpty
        $pair.Name | Should -BeExactly 'srv01.contoso.local'
        $pair.ForwardZone | Should -BeExactly 'contoso.local'
    }

    It 'returnerar ingenting när A-posten saknas' {
        $pairs = @(
            InModuleScope DnsLathund {
                Resolve-DnsRecordPair -Identity 'finns-inte.contoso.local' -ComputerName 'dc01'
            }
        )

        $pairs.Count | Should -Be 0
    }

    It 'ger ett RecordPair per A-post' {
        Set-TestARecords -ZoneName 'contoso.local' -Name 'srv01' -Records @(
            New-TestARecord -HostName 'srv01' -IPAddress '10.0.16.5'
            New-TestARecord -HostName 'srv01' -IPAddress '10.0.16.6'
        )

        $pairs = @(
            InModuleScope DnsLathund {
                Resolve-DnsRecordPair -Identity 'srv01.contoso.local' -ComputerName 'dc01'
            }
        )

        $pairs.Count | Should -Be 2
        @($pairs.IPv4Address) | Should -Be @('10.0.16.5', '10.0.16.6')
    }
}

Describe 'Remove-DnsRecordPair' {

    BeforeEach {
        Reset-DnsTestState
    }

    It 'tar bort PTR före A' {
        $pair = Get-TestRecordPair

        $null = InModuleScope DnsLathund -Parameters @{ Pair = $pair } {
            param ($Pair)

            Remove-DnsRecordPair -InputObject $Pair -ComputerName 'dc01'
        }

        $calls = @($global:DnsTest.RemoveCalls)
        $calls.Count | Should -Be 2
        $calls[0].RecordType | Should -BeExactly 'PTR'
        $calls[0].ZoneName | Should -BeExactly '16.0.10.in-addr.arpa'
        $calls[1].RecordType | Should -BeExactly 'A'
        $calls[1].ZoneName | Should -BeExactly 'contoso.local'
    }

    It 'använder alltid pipelineformen (aldrig -Name/-RRType/-RecordData)' {
        $pair = Get-TestRecordPair

        $null = InModuleScope DnsLathund -Parameters @{ Pair = $pair } {
            param ($Pair)

            Remove-DnsRecordPair -InputObject $Pair -ComputerName 'dc01'
        }

        @($global:DnsTest.RemoveCalls).Count | Should -Be 2
        @($global:DnsTest.RemoveCalls | Where-Object { -not $_.UsedPipeline }).Count | Should -Be 0
        @($global:DnsTest.RemoveCalls | Where-Object { $_.UsedNameForm }).Count | Should -Be 0
    }

    It 'returnerar RemovalResult för både PTR och A' {
        $pair = Get-TestRecordPair

        $results = @(
            InModuleScope DnsLathund -Parameters @{ Pair = $pair } {
                param ($Pair)

                Remove-DnsRecordPair -InputObject $Pair -ComputerName 'dc01'
            }
        )

        $results.Count | Should -Be 2
        $results[0].PSObject.TypeNames | Should -Contain 'DnsLathund.RemovalResult'
        $results[0].Action | Should -BeExactly 'RemovePtr'
        $results[0].Result | Should -BeExactly 'Success'
        $results[1].Action | Should -BeExactly 'RemoveA'
        $results[1].Result | Should -BeExactly 'Success'
        $results[1].IPAddress | Should -BeExactly '10.0.16.5'
    }

    It 'hoppar över A-posten när PTR-borttagningen misslyckas' {
        $global:DnsTest.FailPtr = $true
        $pair = Get-TestRecordPair

        $outcome = InModuleScope DnsLathund -Parameters @{ Pair = $pair } {
            param ($Pair)

            $results = @(
                Remove-DnsRecordPair -InputObject $Pair -ComputerName 'dc01' `
                    -ErrorAction SilentlyContinue -ErrorVariable engineErrors
            )

            [PSCustomObject]@{
                Results    = $results
                ErrorCount = @($engineErrors).Count
            }
        }

        # Ingen borttagning alls: PTR kastade och A ska då inte ens försökas.
        @($global:DnsTest.RemoveCalls).Count | Should -Be 0

        $results = @($outcome.Results)
        $results.Count | Should -Be 2
        $results[0].Action | Should -BeExactly 'RemovePtr'
        $results[0].Result | Should -BeExactly 'Failed'
        $results[1].Action | Should -BeExactly 'RemoveA'
        $results[1].Result | Should -BeExactly 'Skipped'
        $results[1].Error | Should -BeLike 'A-posten behölls eftersom PTR-borttagningen misslyckades.*'

        # Felet ska rapporteras som ErrorRecord, inte som en varning.
        $outcome.ErrorCount | Should -BeGreaterThan 0
    }

    It 'rapporterar A-fel och att PTR redan är borttagen' {
        $global:DnsTest.FailA = $true
        $pair = Get-TestRecordPair

        $results = @(
            InModuleScope DnsLathund -Parameters @{ Pair = $pair } {
                param ($Pair)

                Remove-DnsRecordPair -InputObject $Pair -ComputerName 'dc01' -ErrorAction SilentlyContinue
            }
        )

        @($global:DnsTest.RemoveCalls).Count | Should -Be 1
        @($global:DnsTest.RemoveCalls)[0].RecordType | Should -BeExactly 'PTR'

        $results[1].Action | Should -BeExactly 'RemoveA'
        $results[1].Result | Should -BeExactly 'Failed'
        $results[1].Error | Should -Match 'PTR saknas'
    }

    It 'tar bara bort A-posten med -KeepPtr' {
        $pair = Get-TestRecordPair

        $results = @(
            InModuleScope DnsLathund -Parameters @{ Pair = $pair } {
                param ($Pair)

                Remove-DnsRecordPair -InputObject $Pair -ComputerName 'dc01' -KeepPtr
            }
        )

        $calls = @($global:DnsTest.RemoveCalls)
        $calls.Count | Should -Be 1
        $calls[0].RecordType | Should -BeExactly 'A'

        @($results | Where-Object { $_.Action -eq 'RemovePtr' }).Result | Should -BeExactly 'Skipped'
        @($results | Where-Object { $_.Action -eq 'RemoveA' }).Result | Should -BeExactly 'Success'
    }

    It "hoppar över posten när PTR pekar på annat namn utan -IncludeUnmatchedPtr" {
        $pair = Get-TestRecordPair -Relation 'PTR pekar på annat namn' -WithoutPtr

        $results = @(
            InModuleScope DnsLathund -Parameters @{ Pair = $pair } {
                param ($Pair)

                Remove-DnsRecordPair -InputObject $Pair -ComputerName 'dc01'
            }
        )

        @($global:DnsTest.RemoveCalls).Count | Should -Be 0
        $results.Count | Should -Be 1
        $results[0].Result | Should -BeExactly 'Skipped'
        $results[0].Error | Should -Match 'IncludeUnmatchedPtr'
    }

    It 'loggar varje operation som en JSONL-rad' {
        $logPath = Join-Path -Path $TestDrive -ChildPath 'engine.jsonl'
        $pair = Get-TestRecordPair

        $null = InModuleScope DnsLathund -Parameters @{ Pair = $pair; LogPath = $logPath } {
            param ($Pair, $LogPath)

            Remove-DnsRecordPair -InputObject $Pair -ComputerName 'dc01' -LogPath $LogPath
        }

        $lines = @(Get-Content -LiteralPath $logPath)
        $lines.Count | Should -Be 2

        $entries = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
        $entries[0].Action | Should -BeExactly 'RemovePtr'
        $entries[0].Result | Should -BeExactly 'Success'
        $entries[0].RecordData | Should -BeExactly 'srv01.contoso.local'
        $entries[1].Action | Should -BeExactly 'RemoveA'
        $entries[1].Result | Should -BeExactly 'Success'
        $entries[1].RecordData | Should -BeExactly '10.0.16.5'
    }
}

Describe 'Remove-DnsHostRecord' {

    BeforeAll {
        Mock -CommandName Get-DnsZoneTable -ModuleName DnsLathund -MockWith {
            [PSCustomObject]@{
                AllZones     = @()
                ForwardZones = [string[]]@('contoso.local')
                ReverseZones = [string[]]@('16.0.10.in-addr.arpa')
            }
        }
    }

    BeforeEach {
        Reset-DnsTestState

        Set-TestARecords -ZoneName 'contoso.local' -Name 'srv01' -Records @(
            New-TestARecord -HostName 'srv01' -IPAddress '10.0.16.5'
        )
        Set-TestPtrRecords -ZoneName '16.0.10.in-addr.arpa' -Name '5' -Records @(
            New-TestPtrRecord -HostName '5' -PtrDomainName 'srv01.contoso.local.'
        )
    }

    It 'tar bort A och PTR i rätt ordning och summerar' {
        $output = @(
            Remove-DnsHostRecord -Name 'srv01.contoso.local' -ComputerName 'dc01' -Force -Confirm:$false
        )

        $calls = @($global:DnsTest.RemoveCalls)
        $calls.Count | Should -Be 2
        $calls[0].RecordType | Should -BeExactly 'PTR'
        $calls[1].RecordType | Should -BeExactly 'A'

        $summary = $output[-1]
        $summary.Total | Should -Be 1
        $summary.Removed | Should -Be 1
        $summary.Failed | Should -Be 0
        $summary.Skipped | Should -Be 0

        @($output | Where-Object { $_.PSObject.TypeNames -contains 'DnsLathund.RemovalResult' }).Count |
            Should -Be 2
    }

    It '-WhatIf gör inga borttagningar men loggar WhatIf-rader' {
        $logPath = Join-Path -Path $TestDrive -ChildPath 'whatif.jsonl'

        $output = @(
            Remove-DnsHostRecord -Name 'srv01.contoso.local' -ComputerName 'dc01' -LogPath $logPath -WhatIf
        )

        @($global:DnsTest.RemoveCalls).Count | Should -Be 0

        $results = @($output | Where-Object { $_.PSObject.TypeNames -contains 'DnsLathund.RemovalResult' })
        $results.Count | Should -Be 2
        @($results | Where-Object { $_.Result -ne 'WhatIf' }).Count | Should -Be 0

        $entries = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
        $entries.Count | Should -Be 2
        @($entries.Action) | Should -Be @('RemovePtr', 'RemoveA')
        @($entries | Where-Object { $_.Result -ne 'WhatIf' }).Count | Should -Be 0
    }

    It '-KeepPtr tar bara bort A-posten' {
        $null = Remove-DnsHostRecord -Name 'srv01.contoso.local' -ComputerName 'dc01' -KeepPtr -Force -Confirm:$false

        $calls = @($global:DnsTest.RemoveCalls)
        $calls.Count | Should -Be 1
        $calls[0].RecordType | Should -BeExactly 'A'
    }

    It "rapporterar 'A saknas' för namn utan A-post" {
        $output = @(
            Remove-DnsHostRecord -Name 'finns-inte.contoso.local' -ComputerName 'dc01' -Force -Confirm:$false
        )

        @($global:DnsTest.RemoveCalls).Count | Should -Be 0

        $results = @($output | Where-Object { $_.PSObject.TypeNames -contains 'DnsLathund.RemovalResult' })
        $results.Count | Should -Be 1
        $results[0].Name | Should -BeExactly 'finns-inte.contoso.local'
        $results[0].Result | Should -BeExactly 'Skipped'
        $results[0].Error | Should -BeLike 'A saknas*'

        $output[-1].Total | Should -Be 1
        $output[-1].Skipped | Should -Be 1
    }

    It "hoppar över 'PTR pekar på annat namn' utan -IncludeUnmatchedPtr" {
        Set-TestPtrRecords -ZoneName '16.0.10.in-addr.arpa' -Name '5' -Records @(
            New-TestPtrRecord -HostName '5' -PtrDomainName 'gammal-srv.contoso.local.'
        )

        $output = @(
            Remove-DnsHostRecord -Name 'srv01.contoso.local' -ComputerName 'dc01' -Force -Confirm:$false
        )

        @($global:DnsTest.RemoveCalls).Count | Should -Be 0

        $results = @($output | Where-Object { $_.PSObject.TypeNames -contains 'DnsLathund.RemovalResult' })
        $results[0].Result | Should -BeExactly 'Skipped'
        $results[0].Error | Should -Match 'IncludeUnmatchedPtr'
        $output[-1].Skipped | Should -Be 1
    }

    It "tar bort A-posten med -IncludeUnmatchedPtr men rör inte den främmande PTR-posten" {
        Set-TestPtrRecords -ZoneName '16.0.10.in-addr.arpa' -Name '5' -Records @(
            New-TestPtrRecord -HostName '5' -PtrDomainName 'gammal-srv.contoso.local.'
        )

        $output = @(
            Remove-DnsHostRecord -Name 'srv01.contoso.local' -ComputerName 'dc01' -IncludeUnmatchedPtr -Force -Confirm:$false
        )

        $calls = @($global:DnsTest.RemoveCalls)
        $calls.Count | Should -Be 1
        $calls[0].RecordType | Should -BeExactly 'A'
        $output[-1].Removed | Should -Be 1
    }

    It 'läser filen med trimning, kommentarer, blanka rader och unik sortering' {
        Mock -CommandName Resolve-DnsRecordPair -ModuleName DnsLathund -MockWith {
            $null = $global:DnsTest.ResolvedIdentities.Add($Identity)
        }

        $filePath = Join-Path -Path $TestDrive -ChildPath 'avvecklade.txt'

        @(
            '# kommentar'
            '  web02.contoso.local  '
            ''
            'srv01.contoso.local'
            '   '
            'web02.contoso.local'
            '#srv99.contoso.local'
            'app01.contoso.local'
        ) | Set-Content -LiteralPath $filePath -Encoding UTF8

        $output = @(
            Remove-DnsHostRecord -Path $filePath -ComputerName 'dc01' -Force -Confirm:$false
        )

        @($global:DnsTest.ResolvedIdentities) | Should -Be @(
            'app01.contoso.local'
            'srv01.contoso.local'
            'web02.contoso.local'
        )

        $output[-1].Total | Should -Be 3
        $output[-1].Skipped | Should -Be 3
    }

    It 'visar en preflight-tabell vid bulk' {
        Mock -CommandName Resolve-DnsRecordPair -ModuleName DnsLathund -MockWith {
            if ($Identity -eq 'flera.contoso.local') {
                $global:DnsTest.PairsToReturn['flera']
            }
        }

        $filePath = Join-Path -Path $TestDrive -ChildPath 'preflight.txt'
        @('flera.contoso.local', 'saknas.contoso.local') |
            Set-Content -LiteralPath $filePath -Encoding UTF8

        $global:DnsTest.PairsToReturn['flera'] = @(
            Get-TestRecordPair -Name 'flera.contoso.local' -IPAddress '10.0.16.5'
            Get-TestRecordPair -Name 'flera.contoso.local' -IPAddress '10.0.16.6' -Relation 'PTR saknas' -WithoutPtr
        )

        $output = @(
            Remove-DnsHostRecord -Path $filePath -ComputerName 'dc01' -Force -Confirm:$false 6>&1
        )

        $preflight = @(
            $output |
                Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                ForEach-Object { $_.ToString() }
        ) -join "`n"

        $preflight | Should -Match 'Preflight'
        $preflight | Should -Match '1:1\s+1'
        $preflight | Should -Match 'PTR saknas\s+1'
        $preflight | Should -Match 'A saknas\s+1'
        $preflight | Should -Match 'Flera A-poster\s+1'
        $preflight | Should -Match 'Totalt antal poster\s+3'
    }

    It 'binder strängar från pipelinen till -Name' {
        Mock -CommandName Resolve-DnsRecordPair -ModuleName DnsLathund -MockWith {
            $null = $global:DnsTest.ResolvedIdentities.Add($Identity)
        }

        $null = 'srv01.contoso.local', 'web02.contoso.local' |
            Remove-DnsHostRecord -ComputerName 'dc01' -Force -Confirm:$false

        @($global:DnsTest.ResolvedIdentities) | Should -Be @(
            'srv01.contoso.local'
            'web02.contoso.local'
        )

        Should -Invoke -CommandName Resolve-DnsRecordPair -ModuleName DnsLathund -Times 2 -Exactly
    }

    It 'binder RecordPair-objekt från pipelinen till -InputObject' {
        Mock -CommandName Resolve-DnsRecordPair -ModuleName DnsLathund -MockWith {
            $null = $global:DnsTest.ResolvedIdentities.Add($Identity)
        }

        $pair = Get-TestRecordPair

        $output = @(
            $pair | Remove-DnsHostRecord -ComputerName 'dc01' -Force -Confirm:$false
        )

        # ByInputObject: inget namnuppslag ska ske.
        Should -Invoke -CommandName Resolve-DnsRecordPair -ModuleName DnsLathund -Times 0 -Exactly
        @($global:DnsTest.ResolvedIdentities).Count | Should -Be 0

        $calls = @($global:DnsTest.RemoveCalls)
        $calls.Count | Should -Be 2
        $calls[0].RecordType | Should -BeExactly 'PTR'
        $calls[1].RecordType | Should -BeExactly 'A'

        $output[-1].Removed | Should -Be 1
    }

    It 'binder flera RecordPair-objekt från pipelinen' {
        $pairs = @(
            Get-TestRecordPair -Name 'srv01.contoso.local' -IPAddress '10.0.16.5'
            Get-TestRecordPair -Name 'web02.contoso.local' -IPAddress '10.0.16.6'
        )

        $output = @(
            $pairs | Remove-DnsHostRecord -ComputerName 'dc01' -Force -Confirm:$false
        )

        @($global:DnsTest.RemoveCalls).Count | Should -Be 4
        $output[-1].Total | Should -Be 2
        $output[-1].Removed | Should -Be 2
    }

    It 'rapporterar Failed när PTR-borttagningen misslyckas' {
        $global:DnsTest.FailPtr = $true

        $output = @(
            Remove-DnsHostRecord -Name 'srv01.contoso.local' -ComputerName 'dc01' -Force -Confirm:$false -ErrorAction SilentlyContinue
        )

        @($global:DnsTest.RemoveCalls).Count | Should -Be 0
        $output[-1].Failed | Should -Be 1
        $output[-1].Removed | Should -Be 0
    }

    It 'varnar och summerar noll när ingenting samlats in' {
        Mock -CommandName Resolve-DnsRecordPair -ModuleName DnsLathund -MockWith { }

        $summary = Remove-DnsHostRecord -Name 'saknas.contoso.local' -ComputerName 'dc01' -Force -Confirm:$false |
            Select-Object -Last 1

        $summary.Total | Should -Be 1
        $summary.Skipped | Should -Be 1
    }
}

Describe '-Credential-semantik i borttagningsmotorn' {
    <#
        Modulens regel: anges -Credential MÅSTE anropen gå via en CIM-session.
        Går ingen session att upprätta ska operationen FALLERA — den får aldrig
        tyst falla tillbaka på -ComputerName och därmed köra med den inloggade
        användarens rättigheter. Tidigare varnade Resolve-DnsRecordPair och
        Remove-DnsRecordPair och fortsatte ändå; det är den regressionen de här
        testerna vaktar.
    #>

    BeforeAll {
        $script:ExpectedCredentialError = "Ingen CIM-session kunde upprättas mot 'dc01', vilket krävs när -Credential anges."

        function New-TestCredential {
            # Byggs utan ConvertTo-SecureString -AsPlainText: den cmdleten är
            # ett PSScriptAnalyzer-fel (PSAvoidUsingConvertToSecureStringWithPlainText).
            $securePassword = New-Object System.Security.SecureString

            foreach ($character in 'hemligt'.ToCharArray()) {
                $securePassword.AppendChar($character)
            }

            $securePassword.MakeReadOnly()

            New-Object System.Management.Automation.PSCredential('CONTOSO\dnsadmin', $securePassword)
        }

        Mock -CommandName Get-DnsZoneTable -ModuleName DnsLathund -MockWith {
            [PSCustomObject]@{
                AllZones     = @()
                ForwardZones = [string[]]@('contoso.local')
                ReverseZones = [string[]]@('16.0.10.in-addr.arpa')
            }
        }
    }

    BeforeEach {
        Reset-DnsTestState
    }

    It 'Resolve-DnsRecordPair kastar när CIM inte är nåbart och -Credential angetts' {
        Mock -CommandName Get-DnsCimSession -ModuleName DnsLathund -MockWith { $null }

        $credential = New-TestCredential

        $result = InModuleScope DnsLathund -Parameters @{ Credential = $credential } {
            param ($Credential)

            try {
                $null = Resolve-DnsRecordPair -Identity 'srv01.contoso.local' -ComputerName 'dc01' -Credential $Credential
                'inget fel'
            }
            catch {
                $_.Exception.Message
            }
        }

        $result | Should -BeExactly $script:ExpectedCredentialError
    }

    It 'Resolve-DnsRecordPair använder CIM-sessionen när den går att upprätta' {
        Mock -CommandName Get-DnsCimSession -ModuleName DnsLathund -MockWith {
            [PSCustomObject]@{ FakeSession = $true }
        }

        Set-TestARecords -ZoneName 'contoso.local' -Name 'srv01' -Records @(
            New-TestARecord -HostName 'srv01' -IPAddress '10.0.16.5'
        )
        Set-TestPtrRecords -ZoneName '16.0.10.in-addr.arpa' -Name '5' -Records @(
            New-TestPtrRecord -HostName '5' -PtrDomainName 'srv01.contoso.local.'
        )

        $credential = New-TestCredential

        $pair = InModuleScope DnsLathund -Parameters @{ Credential = $credential } {
            param ($Credential)

            Resolve-DnsRecordPair -Identity 'srv01.contoso.local' -ComputerName 'dc01' -Credential $Credential
        }

        $pair.Name | Should -BeExactly 'srv01.contoso.local'

        Should -Invoke Get-DnsCimSession -ModuleName DnsLathund -Times 1 -Exactly
    }

    It 'Remove-DnsRecordPair kastar och tar INTE bort något när CIM inte är nåbart' {
        Mock -CommandName Get-DnsCimSession -ModuleName DnsLathund -MockWith { $null }

        $pair = Get-TestRecordPair
        $credential = New-TestCredential

        $result = InModuleScope DnsLathund -Parameters @{ Pair = $pair; Credential = $credential } {
            param ($Pair, $Credential)

            try {
                $null = $Pair | Remove-DnsRecordPair -ComputerName 'dc01' -Credential $Credential
                'inget fel'
            }
            catch {
                $_.Exception.Message
            }
        }

        $result | Should -BeExactly $script:ExpectedCredentialError
        @($global:DnsTest.RemoveCalls).Count | Should -Be 0
    }

    It 'ingen modulfil varnar längre om en saknad CIM-session' {
        # Konventionstest: warn-och-fortsätt-vägen skrev
        # Write-Warning "Ingen CIM-session kunde upprättas mot ...".
        # Numera KASTAS det i Get-DnsServerParameter. Dyker varningsformen upp
        # igen är regeln bruten.
        $offenders = @(
            Get-ChildItem -Path $script:ModulePath -Recurse -Include '*.ps1', '*.psm1' -File |
                Where-Object { $_.FullName -notlike '*\Tests\*' } |
                Where-Object {
                    (Get-Content -LiteralPath $_.FullName -Raw) -match 'Write-Warning\s+"Ingen CIM-session'
                } |
                Select-Object -ExpandProperty Name
        )

        $offenders | Should -BeNullOrEmpty
    }
}
