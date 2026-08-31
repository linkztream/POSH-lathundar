#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Fas 0-tester för DnsLathund.

    De privata hjälparna nås med InModuleScope DnsLathund { ... }. Det valet
    (framför att exportera hjälparna eller anropa dem via
    $module.Invoke()) gör att modulens exportkontrakt kan testas exakt:
    Export-ModuleMember får inte läcka något utöver de fem publika funktionerna,
    samtidigt som testerna ändå kommer åt Private\-funktionerna.
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

    Remove-Module -Name DnsLathund -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module -Name DnsLathund -Force -ErrorAction SilentlyContinue
}

Describe 'Modulimport' {

    It 'importerar utan fel även när DnsServer-modulen inte laddats' {
        Remove-Module -Name DnsLathund -Force -ErrorAction SilentlyContinue

        { Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop } |
            Should -Not -Throw

        Get-Module -Name DnsLathund | Should -Not -BeNullOrEmpty
    }

    It 'kräver inte DnsServer vid import (RequiredModules är tom)' {
        $manifest = Import-PowerShellDataFile -Path $script:ManifestPath

        @($manifest.RequiredModules) | Should -BeNullOrEmpty
    }

    It 'har manifestvärden enligt fas 0' {
        $manifest = Import-PowerShellDataFile -Path $script:ManifestPath

        $manifest.RootModule | Should -BeExactly 'DnsLathund.psm1'
        $manifest.ModuleVersion | Should -BeExactly '0.1.0'
        $manifest.PowerShellVersion | Should -BeExactly '5.1'
        $manifest.CompatiblePSEditions | Should -Be @('Desktop', 'Core')
        [guid]::Parse($manifest.GUID) | Should -Not -BeNullOrEmpty
    }

    It 'initierar script-scope-cacharna' {
        InModuleScope DnsLathund {
            $script:DnsZoneCache | Should -BeOfType [hashtable]
            $script:DnsCimSessionCache | Should -BeOfType [hashtable]
        }
    }
}

Describe 'Exportkontrakt' {

    BeforeAll {
        $script:ExpectedFunctions = @(
            'Find-DnsRecord'
            'Get-DnsOrphanPtr'
            'Invoke-DnsRecordEditor'
            'Remove-DnsHostRecord'
            'Remove-DnsPtrRecord'
        ) | Sort-Object
    }

    It 'exporterar exakt de fem publika funktionerna' {
        $exported = @(
            Get-Command -Module DnsLathund -CommandType Function |
                Select-Object -ExpandProperty Name |
                Sort-Object
        )

        $exported | Should -Be $script:ExpectedFunctions
    }

    It 'exporterar varken cmdletar, alias eller variabler' {
        @(Get-Command -Module DnsLathund -CommandType Cmdlet) | Should -BeNullOrEmpty
        @(Get-Command -Module DnsLathund -CommandType Alias) | Should -BeNullOrEmpty
    }

    It 'läcker inte de privata hjälparna' {
        Get-Command -Module DnsLathund -Name 'Test-DnsNameEqual' -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }
}

Describe 'Objektkonstruktorer' {

    It 'New-DnsRecordPairObject ger rätt PSTypeName och egenskaper' {
        $result = InModuleScope DnsLathund {
            New-DnsRecordPairObject -Name 'srv01.contoso.local' -ComputerName 'dc01'
        }

        $result.PSObject.TypeNames | Should -Contain 'DnsLathund.RecordPair'

        $actual = @($result.PSObject.Properties.Name | Sort-Object)
        $expected = @(
            'ARecord'
            'ComputerName'
            'ForwardZone'
            'IPv4Address'
            'MatchingPtrRecords'
            'Name'
            'PtrNodeName'
            'PtrRecords'
            'PtrTargets'
            'Relation'
            'ReverseZone'
        ) | Sort-Object

        $actual | Should -Be $expected
    }

    It 'New-DnsOrphanPtrObject ger rätt PSTypeName och egenskaper' {
        $result = InModuleScope DnsLathund {
            New-DnsOrphanPtrObject -IPAddress '10.0.16.90' -Status 'NoARecord' -ComputerName 'dc01'
        }

        $result.PSObject.TypeNames | Should -Contain 'DnsLathund.OrphanPtr'

        $actual = @($result.PSObject.Properties.Name | Sort-Object)
        $expected = @(
            'ComputerName'
            'IPAddress'
            'PtrOwnerName'
            'PtrTarget'
            'ReverseZone'
            'Status'
        ) | Sort-Object

        $actual | Should -Be $expected
    }

    It 'New-DnsRemovalResultObject ger rätt PSTypeName och egenskaper' {
        $result = InModuleScope DnsLathund {
            New-DnsRemovalResultObject -Name 'srv01.contoso.local' -Result 'Success'
        }

        $result.PSObject.TypeNames | Should -Contain 'DnsLathund.RemovalResult'

        $actual = @($result.PSObject.Properties.Name | Sort-Object)
        $expected = @(
            'Action'
            'Error'
            'IPAddress'
            'Name'
            'RecordType'
            'Result'
            'ZoneName'
        ) | Sort-Object

        $actual | Should -Be $expected
    }

    It 'New-DnsRemovalResultObject accepterar aliaset -Error' {
        $result = InModuleScope DnsLathund {
            New-DnsRemovalResultObject -Name 'srv01' -Result 'Failed' -Error 'Nekad åtkomst.'
        }

        $result.Error | Should -BeExactly 'Nekad åtkomst.'
    }
}

Describe 'Test-DnsNameEqual' {

    It "'<First>' och '<Second>' ger <Expected>" -ForEach @(
        @{ First = 'a.b.c.'; Second = 'A.B.C'; Expected = $true }
        @{ First = 'a'; Second = 'b'; Expected = $false }
        @{ First = ''; Second = ''; Expected = $true }
        @{ First = 'srv01.contoso.local'; Second = 'srv01.contoso.local.'; Expected = $true }
        @{ First = 'a'; Second = ''; Expected = $false }
        @{ First = $null; Second = $null; Expected = $true }
    ) {
        $result = InModuleScope DnsLathund -Parameters @{ First = $First; Second = $Second } {
            param ($First, $Second)

            Test-DnsNameEqual -First $First -Second $Second
        }

        $result | Should -Be $Expected
    }
}

Describe 'ConvertTo-CanonicalDnsName' {

    It 'tar bort avslutande punkt' {
        $result = InModuleScope DnsLathund {
            ConvertTo-CanonicalDnsName -Name 'srv01.contoso.local.'
        }

        $result | Should -BeExactly 'srv01.contoso.local'
    }

    It 'lämnar namn utan punkt orört' {
        $result = InModuleScope DnsLathund {
            ConvertTo-CanonicalDnsName -Name 'srv01.contoso.local'
        }

        $result | Should -BeExactly 'srv01.contoso.local'
    }
}

Describe 'ConvertTo-ReverseFqdn' {

    It "'<Address>' blir '<Expected>'" -ForEach @(
        @{ Address = '10.1.2.3'; Expected = '3.2.1.10.in-addr.arpa' }
        @{ Address = '10.0.0.1'; Expected = '1.0.0.10.in-addr.arpa' }
        @{ Address = '192.168.16.255'; Expected = '255.16.168.192.in-addr.arpa' }
    ) {
        $result = InModuleScope DnsLathund -Parameters @{ Address = $Address } {
            param ($Address)

            ConvertTo-ReverseFqdn -IPAddress $Address
        }

        $result | Should -BeExactly $Expected
    }

    It 'avvisar en icke-IPv4-adress' {
        {
            InModuleScope DnsLathund { ConvertTo-ReverseFqdn -IPAddress 'inte-en-ip' }
        } | Should -Throw
    }
}

Describe 'Test-IPv4Address' {

    It "'<Value>' ger <Expected>" -ForEach @(
        @{ Value = '10.0.16.5'; Expected = $true }
        @{ Value = '255.255.255.255'; Expected = $true }
        @{ Value = 'srv01.contoso.local'; Expected = $false }
        @{ Value = '::1'; Expected = $false }
        @{ Value = ''; Expected = $false }
    ) {
        $result = InModuleScope DnsLathund -Parameters @{ Value = $Value } {
            param ($Value)

            Test-IPv4Address -Value $Value
        }

        $result | Should -Be $Expected
    }
}

Describe 'Get-MatchingDnsZone' {

    It 'väljer den längsta matchande zonen' {
        $result = InModuleScope DnsLathund {
            Get-MatchingDnsZone -DnsName 'srv01.lab.contoso.local' -ZoneNames @('contoso.local', 'lab.contoso.local')
        }

        $result | Should -BeExactly 'lab.contoso.local'
    }

    It 'returnerar ingenting när ingen zon matchar' {
        $result = InModuleScope DnsLathund {
            Get-MatchingDnsZone -DnsName 'srv01.fabrikam.com' -ZoneNames @('contoso.local')
        }

        $result | Should -BeNullOrEmpty
    }
}

Describe 'Get-RelativeRecordName' {

    It 'ger relativt nodnamn' {
        $result = InModuleScope DnsLathund {
            Get-RelativeRecordName -DnsName 'srv01.contoso.local' -ZoneName 'contoso.local'
        }

        $result | Should -BeExactly 'srv01'
    }

    It "ger '@' för zonens apex" {
        $result = InModuleScope DnsLathund {
            Get-RelativeRecordName -DnsName 'contoso.local.' -ZoneName 'contoso.local'
        }

        $result | Should -BeExactly '@'
    }
}

Describe 'New-DnsWqlFilter' {

    It "'<Pattern>' blir <Expected>" -ForEach @(
        @{ Pattern = 'web*'; Expected = "OwnerName LIKE 'web%'" }
        @{ Pattern = 'host?'; Expected = "OwnerName LIKE 'host_'" }
        @{ Pattern = 'plain'; Expected = "OwnerName = 'plain'" }
        @{ Pattern = "o'brien*"; Expected = "OwnerName LIKE 'o''brien%'" }
        @{ Pattern = "o'brien"; Expected = "OwnerName = 'o''brien'" }
        @{ Pattern = '50%*'; Expected = "OwnerName LIKE '50[%]%'" }
        @{ Pattern = 'my_host*'; Expected = "OwnerName LIKE 'my[_]host%'" }
    ) {
        $result = InModuleScope DnsLathund -Parameters @{ Pattern = $Pattern } {
            param ($Pattern)

            New-DnsWqlFilter -Pattern $Pattern
        }

        $result | Should -BeExactly $Expected
    }

    It 'respekterar -Property' {
        $result = InModuleScope DnsLathund {
            New-DnsWqlFilter -Pattern 'srv01.contoso.local' -Property 'PTRDomainName'
        }

        $result | Should -BeExactly "PTRDomainName = 'srv01.contoso.local'"
    }
}

Describe 'Write-DnsAdminLog' {

    It 'skriver exakt en giltig JSON-rad med förväntade fält' {
        $logPath = Join-Path -Path $TestDrive -ChildPath 'logs\dnslathund.jsonl'

        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)

            Write-DnsAdminLog `
                -LogPath $LogPath `
                -ComputerName 'dc01' `
                -Action 'RemoveA' `
                -ZoneName 'contoso.local' `
                -RecordName 'srv01' `
                -RecordType 'A' `
                -RecordData '10.0.16.20' `
                -Result 'Success'
        }

        Test-Path -LiteralPath $logPath | Should -BeTrue

        $lines = @(Get-Content -LiteralPath $logPath)
        $lines.Count | Should -Be 1

        $entry = $lines[0] | ConvertFrom-Json

        @($entry.PSObject.Properties.Name | Sort-Object) | Should -Be (
            @(
                'Action'
                'ComputerName'
                'Error'
                'Operator'
                'RecordData'
                'RecordName'
                'RecordType'
                'Result'
                'Timestamp'
                'ZoneName'
            ) | Sort-Object
        )

        $entry.ComputerName | Should -BeExactly 'dc01'
        $entry.Action | Should -BeExactly 'RemoveA'
        $entry.ZoneName | Should -BeExactly 'contoso.local'
        $entry.RecordName | Should -BeExactly 'srv01'
        $entry.RecordType | Should -BeExactly 'A'
        $entry.RecordData | Should -BeExactly '10.0.16.20'
        $entry.Result | Should -BeExactly 'Success'
        $entry.Operator | Should -BeExactly "$env:USERDOMAIN\$env:USERNAME"

        { [datetime]::Parse($entry.Timestamp) } | Should -Not -Throw
    }

    It 'lägger till en rad per anrop' {
        $logPath = Join-Path -Path $TestDrive -ChildPath 'logs2\dnslathund.jsonl'

        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)

            1..3 | ForEach-Object {
                Write-DnsAdminLog -LogPath $LogPath -ComputerName 'dc01' -Action 'RemovePtr' -Result 'WhatIf'
            }
        }

        @(Get-Content -LiteralPath $logPath).Count | Should -Be 3
    }

    It 'använder DNSLATHUND_LOGPATH när -LogPath saknas' {
        $logPath = Join-Path -Path $TestDrive -ChildPath 'env\dnslathund.jsonl'
        $original = $env:DNSLATHUND_LOGPATH

        try {
            $env:DNSLATHUND_LOGPATH = $logPath

            InModuleScope DnsLathund {
                Write-DnsAdminLog -ComputerName 'dc01' -Action 'AddA' -Result 'Success'
            }

            @(Get-Content -LiteralPath $logPath).Count | Should -Be 1
        }
        finally {
            $env:DNSLATHUND_LOGPATH = $original
        }
    }

    It 'varnar men kastar aldrig när loggen inte går att skriva' {
        $badPath = Join-Path -Path $TestDrive -ChildPath 'ogiltig|sokvag\log.jsonl'

        {
            InModuleScope DnsLathund -Parameters @{ LogPath = $badPath } {
                param ($LogPath)

                Write-DnsAdminLog -LogPath $LogPath -ComputerName 'dc01' -Action 'AddA' -Result 'Success' -WarningAction SilentlyContinue
            }
        } | Should -Not -Throw
    }
}

Describe 'Assert-DnsServerModule' {

    It 'kastar ett svenskt fel när DnsServer saknas' {
        $result = InModuleScope DnsLathund {
            $script:DnsServerModuleVerified = $false

            Mock -CommandName Get-Module -MockWith { } -ParameterFilter { $ListAvailable.IsPresent }

            try {
                Assert-DnsServerModule
                'inget fel'
            }
            catch {
                $_.Exception.Message
            }
            finally {
                $script:DnsServerModuleVerified = $false
            }
        }

        $result | Should -BeExactly 'DnsServer-modulen (RSAT) saknas på den här datorn. Installera RSAT: DNS Server Tools och försök igen.'
    }
}

Describe 'Publika kommandon' {

    It '<Name> exporteras' -ForEach @(
        @{ Name = 'Find-DnsRecord' }
        @{ Name = 'Get-DnsOrphanPtr' }
        @{ Name = 'Remove-DnsHostRecord' }
        @{ Name = 'Remove-DnsPtrRecord' }
        @{ Name = 'Invoke-DnsRecordEditor' }
    ) {
        Get-Command -Module DnsLathund -Name $Name -ErrorAction Stop |
            Should -Not -BeNullOrEmpty
    }

    It 'Remove-DnsHostRecord har de tre parameteruppsättningarna' {
        $command = Get-Command -Module DnsLathund -Name 'Remove-DnsHostRecord'

        @($command.ParameterSets.Name | Sort-Object) |
            Should -Be (@('ByFile', 'ByInputObject', 'ByName') | Sort-Object)

        $command.Parameters['ComputerName'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
            ForEach-Object { $_.Mandatory } |
            Should -Contain $true
    }

    It '<Name> stödjer ShouldProcess med ConfirmImpact High' -ForEach @(
        @{ Name = 'Remove-DnsHostRecord' }
        @{ Name = 'Remove-DnsPtrRecord' }
    ) {
        $command = Get-Command -Module DnsLathund -Name $Name

        $cmdletBinding = $command.ScriptBlock.Ast.Body.ParamBlock.Attributes |
            Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }

        $cmdletBinding | Should -Not -BeNullOrEmpty

        $text = $cmdletBinding.Extent.Text
        $text | Should -Match 'SupportsShouldProcess'
        $text | Should -Match "ConfirmImpact\s*=\s*'High'"
    }
}

Describe 'Get-DnsServerParameter' {
    <#
        Hjälparen samlar modulens -Credential-regel på ett ställe: utan
        -Credential används -ComputerName, med -Credential MÅSTE en CIM-session
        finnas — annars kastas ett fel. Ingen tyst nedgradering till den
        inloggade användarens rättigheter.
    #>

    BeforeAll {
        $script:ExpectedCimError = "Ingen CIM-session kunde upprättas mot 'dc01', vilket krävs när -Credential anges."

        function New-TestCredential {
            # Byggs utan ConvertTo-SecureString -AsPlainText (PSScriptAnalyzer-fel).
            $securePassword = New-Object System.Security.SecureString

            foreach ($character in 'hemligt'.ToCharArray()) {
                $securePassword.AppendChar($character)
            }

            $securePassword.MakeReadOnly()

            New-Object System.Management.Automation.PSCredential('CONTOSO\dnsadmin', $securePassword)
        }
    }

    It 'returnerar @{ ComputerName } utan -Credential' {
        $result = InModuleScope DnsLathund {
            Get-DnsServerParameter -ComputerName 'dc01'
        }

        $result | Should -BeOfType [hashtable]
        $result.Keys | Should -Be @('ComputerName')
        $result['ComputerName'] | Should -BeExactly 'dc01'
    }

    It 'anropar inte Get-DnsCimSession utan -Credential' {
        Mock -CommandName Get-DnsCimSession -ModuleName DnsLathund -MockWith { $null }

        $null = InModuleScope DnsLathund {
            Get-DnsServerParameter -ComputerName 'dc01'
        }

        Should -Invoke Get-DnsCimSession -ModuleName DnsLathund -Times 0 -Exactly
    }

    It 'returnerar @{ CimSession } när -Credential angetts och sessionen går att upprätta' {
        Mock -CommandName Get-DnsCimSession -ModuleName DnsLathund -MockWith {
            [PSCustomObject]@{ FakeSession = 'dc01' }
        }

        $credential = New-TestCredential

        $result = InModuleScope DnsLathund -Parameters @{ Credential = $credential } {
            param ($Credential)

            Get-DnsServerParameter -ComputerName 'dc01' -Credential $Credential
        }

        $result | Should -BeOfType [hashtable]
        $result.Keys | Should -Be @('CimSession')
        $result['CimSession'].FakeSession | Should -BeExactly 'dc01'
    }

    It 'kastar med svensk text när -Credential angetts men ingen CIM-session finns' {
        Mock -CommandName Get-DnsCimSession -ModuleName DnsLathund -MockWith { $null }

        $credential = New-TestCredential

        $result = InModuleScope DnsLathund -Parameters @{ Credential = $credential } {
            param ($Credential)

            try {
                $null = Get-DnsServerParameter -ComputerName 'dc01' -Credential $Credential
                'inget fel'
            }
            catch {
                $_.Exception.Message
            }
        }

        $result | Should -BeExactly $script:ExpectedCimError
    }
}

Describe 'Kodningskonvention' {
    <#
        Windows PowerShell 5.1 läser BOM-lösa filer som ANSI (kodsida 1252 här).
        En BOM-lös .ps1 med åäö i strängar och kommentarer laddas då med
        felaktiga tecken — det inträffade under utvecklingen. Alla kodfiler ska
        därför sparas som UTF-8 MED BOM (0xEF 0xBB 0xBF).

        Fixturerna undantas: de är syntetiska zonexportfiler och ska likna det
        DNS-servern faktiskt skriver.
    #>

    BeforeAll {
        $script:CodeFiles = @(
            Get-ChildItem -Path $script:ModulePath -Recurse -Include '*.ps1', '*.psm1', '*.psd1' -File |
                Where-Object { $_.FullName -notlike '*\Tests\Fixtures\*' }
        )
    }

    It 'hittar modulens kodfiler' {
        $script:CodeFiles.Count | Should -BeGreaterThan 0
    }

    It 'varje .ps1/.psm1/.psd1 inleds med UTF-8-BOM' {
        $missingBom = @(
            foreach ($codeFile in $script:CodeFiles) {
                $bytes = [System.IO.File]::ReadAllBytes($codeFile.FullName)

                $hasBom = (
                    $bytes.Length -ge 3 -and
                    $bytes[0] -eq 0xEF -and
                    $bytes[1] -eq 0xBB -and
                    $bytes[2] -eq 0xBF
                )

                if (-not $hasBom) {
                    $codeFile.FullName
                }
            }
        )

        $missingBom | Should -BeNullOrEmpty
    }
}

Describe 'Fixturer' {

    It '<Name> finns och innehåller förväntade zonelement' -ForEach @(
        @{ Name = 'forward-zone.txt'; Origin = '$ORIGIN contoso.local.' }
        @{ Name = 'reverse-zone.txt'; Origin = '$ORIGIN 16.0.10.in-addr.arpa.' }
    ) {
        $path = Join-Path -Path $PSScriptRoot -ChildPath "Fixtures\$Name"

        Test-Path -LiteralPath $path | Should -BeTrue

        $content = Get-Content -LiteralPath $path -Raw

        $content | Should -BeLike '*SOA*'
        $content | Should -BeLike '*NS*'
        # -Match i stället för -BeLike: hakparentesen i [AGE: är ett
        # wildcardmetatecken och skulle göra BeLike-mönstret ogiltigt.
        $content | Should -Match '\[AGE:\d+\]'
        $content | Should -Match ([regex]::Escape($Origin))
    }

    It 'reverse-fixturen innehåller de föräldralösa PTR-posterna' {
        $path = Join-Path -Path $PSScriptRoot -ChildPath 'Fixtures\reverse-zone.txt'
        $content = Get-Content -LiteralPath $path -Raw

        $content | Should -BeLike '*gammal-srv.contoso.local.*'
        $content | Should -BeLike '*avvecklad.contoso.local.*'
        $content | Should -BeLike '*web02.contoso.local.*'
    }

    It 'forward-fixturen saknar de föräldralösa målnamnen' {
        $path = Join-Path -Path $PSScriptRoot -ChildPath 'Fixtures\forward-zone.txt'
        $content = Get-Content -LiteralPath $path -Raw

        $content | Should -Not -BeLike '*gammal-srv*'
        $content | Should -Not -BeLike '*avvecklad*'
    }
}
