#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Fas A-tester för zonexportvägen: ConvertFrom-DnsZoneFile (BIND-parsern) och
    Export-DnsZoneFile.

    Båda är privata hjälpare och nås därför via InModuleScope DnsLathund, precis
    som i DnsLathund.Tests.ps1. Inga riktiga DNS-servrar kontaktas: fixturerna
    under Fixtures\ läses från disk och DnsServer-cmdletarna stubbas + mockas.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingComputerNameHardcoded',
    '',
    Justification = 'dc01 är syntetiskt testdata, ingen verklig server kontaktas.'
)]
param ()

BeforeAll {
    $script:ModulePath = Split-Path -Path $PSScriptRoot -Parent
    $script:ManifestPath = Join-Path -Path $script:ModulePath -ChildPath 'DnsLathund.psd1'

    $script:ForwardFixture = Join-Path -Path $PSScriptRoot -ChildPath 'Fixtures\forward-zone.txt'
    $script:ReverseFixture = Join-Path -Path $PSScriptRoot -ChildPath 'Fixtures\reverse-zone.txt'

    Remove-Module -Name DnsLathund -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop

    # Stubbar för DnsServer-cmdletarna. De skapas globalt så att både Mock och
    # modulens egen kommandouppslagning hittar dem på en maskin utan RSAT.
    function global:Export-DnsServerZone {
        [CmdletBinding()]
        param (
            [string]$Name,
            [string]$FileName,
            [string]$ComputerName,
            $CimSession
        )
    }
}

AfterAll {
    Remove-Item -Path 'function:\Export-DnsServerZone' -Force -ErrorAction SilentlyContinue
    Remove-Module -Name DnsLathund -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-DnsZoneFile — forwardzon' {

    BeforeAll {
        $script:ForwardResult = InModuleScope DnsLathund -Parameters @{ Path = $script:ForwardFixture } {
            param ($Path)

            $skipped = 0
            $warnings = @()

            $records = @(
                ConvertFrom-DnsZoneFile `
                    -Path $Path `
                    -ZoneName 'contoso.local' `
                    -RecordType 'A' `
                    -SkippedLineCount ([ref]$skipped) `
                    -WarningVariable warnings
            )

            [PSCustomObject]@{
                Records  = $records
                Skipped  = $skipped
                Warnings = @($warnings)
            }
        }
    }

    It 'hittar samtliga 14 A-poster' {
        $script:ForwardResult.Records.Count | Should -Be 14
    }

    It 'räknar inga ogiltiga rader i fixturen' {
        $script:ForwardResult.Skipped | Should -Be 0
    }

    It 'varnar inte om kommentarer, SOA-fortsättningar eller WINS-rader' {
        $script:ForwardResult.Warnings | Should -BeNullOrEmpty
    }

    It 'tar inte med andra posttyper (WINS, NS, SOA, CNAME)' {
        @($script:ForwardResult.Records | Where-Object { $_.RecordType -ne 'A' }) |
            Should -BeNullOrEmpty
    }

    It "mappar '@' till zonens apex" {
        $apex = @($script:ForwardResult.Records | Where-Object { $_.OwnerFqdn -eq 'contoso.local' })

        $apex.Count | Should -Be 2
        @($apex.RecordData) | Should -Be @('10.0.16.1', '10.0.16.2')
    }

    It 'ärver ägaren från föregående rad' {
        $print01 = @($script:ForwardResult.Records | Where-Object { $_.OwnerFqdn -eq 'print01.contoso.local' })

        $print01.Count | Should -Be 2
        @($print01.RecordData) | Should -Be @('10.0.16.50', '10.0.16.51')
    }

    It 'hoppar över [AGE:nnnn] men behåller posten' {
        $dc02 = @($script:ForwardResult.Records | Where-Object { $_.OwnerFqdn -eq 'dc02.contoso.local' })

        $dc02.Count | Should -Be 1
        $dc02[0].RecordData | Should -BeExactly '10.0.16.11'
    }

    It 'hanterar valfri TTL och klass (mail01 3600 IN A)' {
        $mail01 = @($script:ForwardResult.Records | Where-Object { $_.OwnerFqdn -eq 'mail01.contoso.local' })

        $mail01.Count | Should -Be 1
        $mail01[0].RecordData | Should -BeExactly '10.0.16.55'
    }

    It 'kanoniserar ett absolut ägarnamn med slutpunkt' {
        $fs01 = @($script:ForwardResult.Records | Where-Object { $_.OwnerFqdn -eq 'fs01.contoso.local' })

        $fs01.Count | Should -Be 1

        @($script:ForwardResult.Records.OwnerFqdn) |
            Should -Not -Contain 'fs01.contoso.local.contoso.local'
    }

    It 'följer $ORIGIN-växlingen till lab.contoso.local' {
        $test01 = @($script:ForwardResult.Records | Where-Object { $_.OwnerFqdn -eq 'test01.lab.contoso.local' })
        $test02 = @($script:ForwardResult.Records | Where-Object { $_.OwnerFqdn -eq 'test02.lab.contoso.local' })

        $test01.Count | Should -Be 1
        $test01[0].RecordData | Should -BeExactly '10.0.16.60'
        $test02.Count | Should -Be 1
        $test02[0].RecordData | Should -BeExactly '10.0.16.61'
    }
}

Describe 'ConvertFrom-DnsZoneFile — reverse-zon' {

    BeforeAll {
        $script:ReverseResult = InModuleScope DnsLathund -Parameters @{ Path = $script:ReverseFixture } {
            param ($Path)

            $skipped = 0
            $warnings = @()

            $records = @(
                ConvertFrom-DnsZoneFile `
                    -Path $Path `
                    -ZoneName '16.0.10.in-addr.arpa' `
                    -RecordType 'PTR' `
                    -SkippedLineCount ([ref]$skipped) `
                    -WarningVariable warnings
            )

            [PSCustomObject]@{
                Records  = $records
                Skipped  = $skipped
                Warnings = @($warnings)
            }
        }
    }

    It 'hittar samtliga 12 PTR-poster' {
        $script:ReverseResult.Records.Count | Should -Be 12
    }

    It 'hoppar över WINSR-raden utan att varna' {
        $script:ReverseResult.Warnings | Should -BeNullOrEmpty
        $script:ReverseResult.Skipped | Should -Be 0
    }

    It 'returnerar kanoniska målnamn utan slutpunkt' {
        @($script:ReverseResult.Records.RecordData) |
            Where-Object { $_.EndsWith('.') } |
            Should -BeNullOrEmpty

        $dc01 = @($script:ReverseResult.Records | Where-Object { $_.OwnerFqdn -eq '10.16.0.10.in-addr.arpa' })

        $dc01.Count | Should -Be 1
        $dc01[0].RecordData | Should -BeExactly 'dc01.contoso.local'
    }

    It 'kvalificerar relativa ägarnamn mot zonen' {
        @($script:ReverseResult.Records.OwnerFqdn) | Should -Contain '90.16.0.10.in-addr.arpa'
        @($script:ReverseResult.Records.OwnerFqdn) | Should -Contain '91.16.0.10.in-addr.arpa'
    }

    It 'kanoniserar ett absolut ägarnamn i reverse-zonen' {
        $node99 = @($script:ReverseResult.Records | Where-Object { $_.OwnerFqdn -eq '99.16.0.10.in-addr.arpa' })

        $node99.Count | Should -Be 1
        $node99[0].RecordData | Should -BeExactly 'web02.contoso.local'
    }

    It 'filtrerar bort A-poster när bara PTR efterfrågas' {
        @($script:ReverseResult.Records | Where-Object { $_.RecordType -ne 'PTR' }) |
            Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-DnsZoneFile — standardtyper' {

    It 'tolkar både A och PTR när -RecordType utelämnas' {
        $result = InModuleScope DnsLathund -Parameters @{ Path = $script:ForwardFixture } {
            param ($Path)

            @(ConvertFrom-DnsZoneFile -Path $Path -ZoneName 'contoso.local')
        }

        @($result | Where-Object { $_.RecordType -eq 'A' }).Count | Should -Be 14
        @($result | Where-Object { $_.RecordType -eq 'PTR' }).Count | Should -Be 0
    }

    It 'kastar när filen saknas' {
        {
            InModuleScope DnsLathund {
                ConvertFrom-DnsZoneFile -Path 'X:\finns\inte\zone.txt' -ZoneName 'contoso.local'
            }
        } | Should -Throw
    }
}

Describe 'ConvertFrom-DnsZoneFile — -AsIndex' {

    BeforeAll {
        $script:Index = InModuleScope DnsLathund -Parameters @{ Path = $script:ForwardFixture } {
            param ($Path)

            ConvertFrom-DnsZoneFile -Path $Path -ZoneName 'contoso.local' -AsIndex
        }
    }

    It 'returnerar en Dictionary[string, List[string]]' {
        $script:Index.GetType().Name | Should -BeExactly 'Dictionary`2'
        $script:Index.Count | Should -Be 12
    }

    It 'är skiftlägesokänsligt' {
        $script:Index.ContainsKey('DC01.CONTOSO.LOCAL') | Should -BeTrue
        @($script:Index['dc01.CONTOSO.local']) | Should -Be @('10.0.16.10')
    }

    It 'samlar flera IP-adresser per namn' {
        @($script:Index['print01.contoso.local']) | Should -Be @('10.0.16.50', '10.0.16.51')
        @($script:Index['contoso.local']) | Should -Be @('10.0.16.1', '10.0.16.2')
    }

    It 'indexerar även namn under det växlade origin' {
        $script:Index.ContainsKey('test02.lab.contoso.local') | Should -BeTrue
    }

    It 'indexerar aldrig PTR-poster (-AsIndex innebär A)' {
        $reverseIndex = InModuleScope DnsLathund -Parameters @{ Path = $script:ReverseFixture } {
            param ($Path)

            ConvertFrom-DnsZoneFile -Path $Path -ZoneName '16.0.10.in-addr.arpa' -RecordType 'PTR' -AsIndex
        }

        $reverseIndex.Count | Should -Be 0
    }
}

Describe 'ConvertFrom-DnsZoneFile — ogiltiga rader' {

    It 'räknar ogiltiga rader utan att kasta' {
        $zoneFile = Join-Path -Path $TestDrive -ChildPath 'trasig-zon.txt'

        $lines = @(
            '$ORIGIN test.local.'
            "bra`t`tA`t10.0.0.1"
            "trasig`t`tA`tinte-en-ip"
            "tom`t`tA"
        )

        Set-Content -LiteralPath $zoneFile -Value $lines -Encoding ASCII

        $result = InModuleScope DnsLathund -Parameters @{ Path = $zoneFile } {
            param ($Path)

            $skipped = 0

            $records = @(
                ConvertFrom-DnsZoneFile -Path $Path -ZoneName 'test.local' -RecordType 'A' -SkippedLineCount ([ref]$skipped)
            )

            [PSCustomObject]@{
                Records = $records
                Skipped = $skipped
            }
        }

        $result.Records.Count | Should -Be 1
        $result.Records[0].OwnerFqdn | Should -BeExactly 'bra.test.local'
        $result.Skipped | Should -Be 2
    }

    It 'hanterar $ORIGIN både med och utan slutpunkt' {
        $zoneFile = Join-Path -Path $TestDrive -ChildPath 'origin-zon.txt'

        $lines = @(
            '$TTL 3600'
            '$ORIGIN sub.test.local'
            "x`t`tA`t10.0.0.9"
            '$ORIGIN annan.test.local.'
            "y`t`tA`t10.0.0.10"
        )

        Set-Content -LiteralPath $zoneFile -Value $lines -Encoding ASCII

        $records = InModuleScope DnsLathund -Parameters @{ Path = $zoneFile } {
            param ($Path)

            @(ConvertFrom-DnsZoneFile -Path $Path -ZoneName 'test.local' -RecordType 'A')
        }

        $records.Count | Should -Be 2
        $records[0].OwnerFqdn | Should -BeExactly 'x.sub.test.local'
        $records[1].OwnerFqdn | Should -BeExactly 'y.annan.test.local'
    }
}

Describe 'Export-DnsZoneFile' {

    BeforeEach {
        $script:DestinationDirectory = Join-Path -Path $TestDrive -ChildPath ('export_{0}' -f ([guid]::NewGuid().ToString('N')))

        $null = New-Item -Path $script:DestinationDirectory -ItemType Directory -Force

        Mock -CommandName Assert-DnsServerModule -ModuleName DnsLathund -MockWith { }
        Mock -CommandName Export-DnsServerZone -ModuleName DnsLathund -MockWith { }
        Mock -CommandName Copy-Item -ModuleName DnsLathund -MockWith {
            Set-Content -LiteralPath $Destination -Value 'exporterad zon' -Encoding ASCII
        }
        Mock -CommandName Remove-Item -ModuleName DnsLathund -MockWith { }
    }

    It 'använder ett tidsstämplat filnamn och returnerar den lokala kopian' {
        $result = InModuleScope DnsLathund -Parameters @{ Destination = $script:DestinationDirectory } {
            param ($Destination)

            Export-DnsZoneFile -ZoneName 'contoso.local' -ComputerName 'dc01' -DestinationPath $Destination
        }

        $result | Should -Match 'dnslathund_contoso\.local_\d{14}\.txt$'
        Test-Path -LiteralPath $result | Should -BeTrue

        Should -Invoke -CommandName Export-DnsServerZone -ModuleName DnsLathund -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'contoso.local' -and
            $ComputerName -eq 'dc01' -and
            $FileName -match '^dnslathund_contoso\.local_\d{14}\.txt$'
        }
    }

    It 'ersätter otillåtna tecken i zonnamnet' {
        $result = InModuleScope DnsLathund -Parameters @{ Destination = $script:DestinationDirectory } {
            param ($Destination)

            Export-DnsZoneFile -ZoneName '0/25.16.0.10.in-addr.arpa' -ComputerName 'dc01' -DestinationPath $Destination
        }

        $result | Should -Match 'dnslathund_0_25\.16\.0\.10\.in-addr\.arpa_\d{14}\.txt$'
    }

    It 'hämtar via UNC när servern inte är den lokala maskinen' {
        $null = InModuleScope DnsLathund -Parameters @{ Destination = $script:DestinationDirectory } {
            param ($Destination)

            Export-DnsZoneFile -ZoneName 'contoso.local' -ComputerName 'dc01' -DestinationPath $Destination
        }

        Should -Invoke -CommandName Copy-Item -ModuleName DnsLathund -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -like '\\dc01\admin$\System32\dns\dnslathund_*'
        }
    }

    It 'läser lokalt när ComputerName är den egna maskinen' {
        $null = InModuleScope DnsLathund -Parameters @{
            Destination = $script:DestinationDirectory
            Computer    = $env:COMPUTERNAME
        } {
            param ($Destination, $Computer)

            Export-DnsZoneFile -ZoneName 'contoso.local' -ComputerName $Computer -DestinationPath $Destination
        }

        Should -Invoke -CommandName Copy-Item -ModuleName DnsLathund -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -like "$env:windir\System32\dns\dnslathund_*"
        }
    }

    It 'städar serverfilen när hämtningen är klar' {
        $null = InModuleScope DnsLathund -Parameters @{ Destination = $script:DestinationDirectory } {
            param ($Destination)

            Export-DnsZoneFile -ZoneName 'contoso.local' -ComputerName 'dc01' -DestinationPath $Destination
        }

        Should -Invoke -CommandName Remove-Item -ModuleName DnsLathund -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -like '\\dc01\admin$\System32\dns\dnslathund_*'
        }
    }

    It 'behåller serverfilen med -KeepRemoteFile' {
        $null = InModuleScope DnsLathund -Parameters @{ Destination = $script:DestinationDirectory } {
            param ($Destination)

            Export-DnsZoneFile -ZoneName 'contoso.local' -ComputerName 'dc01' -DestinationPath $Destination -KeepRemoteFile
        }

        Should -Invoke -CommandName Remove-Item -ModuleName DnsLathund -Times 0 -Exactly
    }

    It 'varnar men kastar inte när serverfilen inte går att ta bort' {
        Mock -CommandName Remove-Item -ModuleName DnsLathund -MockWith { throw 'Åtkomst nekad.' }

        $streams = InModuleScope DnsLathund -Parameters @{ Destination = $script:DestinationDirectory } {
            param ($Destination)

            Export-DnsZoneFile -ZoneName 'contoso.local' -ComputerName 'dc01' -DestinationPath $Destination
        } 3>&1

        $warnings = @($streams | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

        $warnings | Should -Not -BeNullOrEmpty
        "$warnings" | Should -Match 'admin\$'
    }

    It 'kastar ett tydligt fel när ingen hämtningsmetod fungerar' {
        Mock -CommandName Copy-Item -ModuleName DnsLathund -MockWith { throw 'Sökvägen hittades inte.' }
        Mock -CommandName Invoke-Command -ModuleName DnsLathund -MockWith { throw 'WinRM svarar inte.' }

        {
            InModuleScope DnsLathund -Parameters @{ Destination = $script:DestinationDirectory } {
                param ($Destination)

                Export-DnsZoneFile -ZoneName 'contoso.local' -ComputerName 'dc01' -DestinationPath $Destination -WarningAction SilentlyContinue
            }
        } | Should -Throw -ExpectedMessage '*Kunde inte hämta exportfilen*'
    }
}
