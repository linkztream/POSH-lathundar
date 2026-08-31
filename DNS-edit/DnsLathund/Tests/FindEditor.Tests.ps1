#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Fas C-tester: Find-DnsRecord och Invoke-DnsRecordEditor.

    Testerna körs helt offline. DnsServer-cmdletarna ersätts med globala
    stubbar i BeforeAll (och tas bort i AfterAll) så att sviten beter sig
    likadant på maskiner med och utan RSAT; därefter mockas de i modulens
    scope med InModuleScope.

    De interaktiva delarna (PromptForChoice och Read-Host) ligger i de egna
    hjälparna Invoke-DnsMenuChoice och Read-DnsIPv4Input just för att kunna
    mockas — annars skulle testerna blockera på en prompt.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingComputerNameHardcoded',
    '',
    Justification = 'dc01 är syntetiskt testdata, ingen verklig server kontaktas.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidGlobalVars',
    '',
    Justification = 'Mockkroppar körs i modulens scope och ser varken testets lokala variabler eller InModuleScope-parametrar; en global variabel är den enda kanalen in i en mockkropp. Den tas bort i samma test.'
)]
param ()

BeforeAll {
    $script:ModulePath = Split-Path -Path $PSScriptRoot -Parent
    $script:ManifestPath = Join-Path -Path $script:ModulePath -ChildPath 'DnsLathund.psd1'

    Remove-Module -Name DnsLathund -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop

    # Globala stubbar för DnsServer-cmdletarna. De skuggar medvetet eventuella
    # riktiga cmdletar så att parameterbindningen blir densamma överallt.
    $script:StubNames = @(
        'Get-DnsServerResourceRecord'
        'Remove-DnsServerResourceRecord'
        'Set-DnsServerResourceRecord'
        'Add-DnsServerResourceRecordA'
        'Add-DnsServerResourceRecordPtr'
    )

    function global:Get-DnsServerResourceRecord {
        [CmdletBinding()]
        param (
            [Parameter()] [string]$Name,
            [Parameter()] [string]$ZoneName,
            [Parameter()] [string]$ComputerName,
            [Parameter()] [string]$RRType
        )
    }

    function global:Remove-DnsServerResourceRecord {
        [CmdletBinding()]
        param (
            [Parameter(ValueFromPipeline)] [object]$InputObject,
            [Parameter()] [string]$ZoneName,
            [Parameter()] [string]$ComputerName,
            [Parameter()] [switch]$Force
        )

        process { }
    }

    function global:Set-DnsServerResourceRecord {
        [CmdletBinding()]
        param (
            [Parameter()] [string]$ZoneName,
            [Parameter()] [string]$ComputerName,
            [Parameter()] [object]$OldInputObject,
            [Parameter()] [object]$NewInputObject
        )
    }

    function global:Add-DnsServerResourceRecordA {
        [CmdletBinding()]
        param (
            [Parameter()] [string]$Name,
            [Parameter()] [string]$ZoneName,
            [Parameter()] [string]$ComputerName,
            [Parameter()] [string]$IPv4Address,
            [Parameter()] [switch]$CreatePtr
        )
    }

    function global:Add-DnsServerResourceRecordPtr {
        [CmdletBinding()]
        param (
            [Parameter()] [string]$Name,
            [Parameter()] [string]$ZoneName,
            [Parameter()] [string]$ComputerName,
            [Parameter()] [string]$PtrDomainName
        )
    }

    # Syntetiskt RecordPair för editortesterna. Objektet byggs med modulens
    # egen konstruktor (via & $module { ... }) så att testerna aldrig kan
    # glida ifrån det frysta kontraktet. Funktionen ligger globalt eftersom
    # mockkropparna körs i modulens scope och därifrån når globala funktioner.
    function global:New-DnsTestRecordPair {
        [CmdletBinding()]
        param (
            # Med -WithClone får A-posten en Clone()-metod (Windows PowerShell
            # 5.1). Utan den simuleras det deserialiserade PS 7-objektet.
            [Parameter()] [switch]$WithClone
        )

        $aRecord = [PSCustomObject]@{
            HostName   = 'srv01'
            RecordType = 'A'
            RecordData = [PSCustomObject]@{
                IPv4Address = [System.Net.IPAddress]::Parse('10.0.16.5')
            }
        }

        if ($WithClone) {
            $aRecord | Add-Member -MemberType ScriptMethod -Name 'Clone' -Value {
                [PSCustomObject]@{
                    HostName   = $this.HostName
                    RecordType = $this.RecordType
                    RecordData = [PSCustomObject]@{ IPv4Address = $this.RecordData.IPv4Address }
                }
            }
        }

        $ptrRecord = [PSCustomObject]@{
            HostName   = '5'
            RecordType = 'PTR'
            RecordData = [PSCustomObject]@{ PtrDomainName = 'srv01.contoso.local.' }
        }

        $dnsLathund = Get-Module -Name DnsLathund

        return & $dnsLathund {
            param ($ARecord, $PtrRecord)

            New-DnsRecordPairObject `
                -Name 'srv01.contoso.local' `
                -IPv4Address '10.0.16.5' `
                -ForwardZone 'contoso.local' `
                -ARecord $ARecord `
                -ReverseZone '16.0.10.in-addr.arpa' `
                -PtrNodeName '5' `
                -PtrRecords @($PtrRecord) `
                -MatchingPtrRecords @($PtrRecord) `
                -PtrTargets @('srv01.contoso.local') `
                -Relation '1:1' `
                -ComputerName 'dc01'
        } $aRecord $ptrRecord
    }
}

AfterAll {
    foreach ($stubName in $script:StubNames) {
        Remove-Item -LiteralPath "function:global:$stubName" -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath 'function:global:New-DnsTestRecordPair' -Force -ErrorAction SilentlyContinue

    Remove-Module -Name DnsLathund -Force -ErrorAction SilentlyContinue
}

Describe 'Find-DnsRecord' {

    It 'delegerar ett exakt namn till Resolve-DnsRecordPair' {
        InModuleScope DnsLathund {
            Mock Resolve-DnsRecordPair {
                New-DnsRecordPairObject `
                    -Name 'srv01.contoso.local' `
                    -IPv4Address '10.0.16.5' `
                    -ForwardZone 'contoso.local' `
                    -Relation '1:1' `
                    -ComputerName 'dc01'
            }

            $result = @(Find-DnsRecord -Identity 'srv01.contoso.local' -ComputerName 'dc01')

            $result.Count | Should -Be 1
            $result[0].PSObject.TypeNames | Should -Contain 'DnsLathund.RecordPair'

            Should -Invoke Resolve-DnsRecordPair -Times 1 -Exactly -ParameterFilter {
                $Identity -eq 'srv01.contoso.local' -and $ComputerName -eq 'dc01'
            }
        }
    }

    It 'skickar med -ZoneName vid exakt namnuppslag' {
        InModuleScope DnsLathund {
            Mock Resolve-DnsRecordPair {
                New-DnsRecordPairObject -Name 'srv01.contoso.local' -ComputerName 'dc01'
            }

            $null = Find-DnsRecord -Identity 'srv01' -ComputerName 'dc01' -ZoneName 'contoso.local'

            Should -Invoke Resolve-DnsRecordPair -Times 1 -Exactly -ParameterFilter {
                $Identity -eq 'srv01' -and $ZoneName -eq 'contoso.local'
            }
        }
    }

    It 'delegerar en IPv4-adress till Resolve-DnsRecordPair utan -ZoneName' {
        InModuleScope DnsLathund {
            Mock Resolve-DnsRecordPair {
                New-DnsRecordPairObject `
                    -Name 'srv01.contoso.local' `
                    -IPv4Address '10.0.16.5' `
                    -ComputerName 'dc01'
            }

            $null = Find-DnsRecord -Identity '10.0.16.5' -ComputerName 'dc01' -ZoneName 'contoso.local'

            # -ZoneName är forward-zonen och får inte styra ett reverse-uppslag.
            Should -Invoke Resolve-DnsRecordPair -Times 1 -Exactly -ParameterFilter {
                $Identity -eq '10.0.16.5' -and [string]::IsNullOrEmpty($ZoneName)
            }
        }
    }

    It 'kräver -ZoneName vid wildcard-sökning' {
        InModuleScope DnsLathund {
            Mock Resolve-DnsRecordPair { }
            Mock Get-DnsCimSession { }

            $errors = @()

            $result = @(
                Find-DnsRecord -Identity 'web*' -ComputerName 'dc01' `
                    -ErrorAction SilentlyContinue -ErrorVariable errors
            )

            $result.Count | Should -Be 0
            @($errors).Count | Should -Be 1
            $errors[0].Exception.Message | Should -BeExactly 'Ange -ZoneName vid wildcard-sökning.'
            $errors[0].FullyQualifiedErrorId | Should -BeLike 'ZoneNameRequiredForWildcard*'

            Should -Invoke Get-DnsCimSession -Times 0 -Exactly
        }
    }

    It 'bygger ett WQL-mönster mot fullständigt FQDN och slår upp träffarna' {
        InModuleScope DnsLathund {
            Mock Get-DnsCimSession {
                [Microsoft.Management.Infrastructure.CimSession]::Create('dc01')
            }

            Mock Get-CimInstance {
                [PSCustomObject]@{ OwnerName = 'web01.contoso.local.'; IPAddress = '10.0.16.11' }
                [PSCustomObject]@{ OwnerName = 'web02.contoso.local'; IPAddress = '10.0.16.12' }
                # Dubblett: två A-poster på samma ägare ska bara ge ett uppslag.
                [PSCustomObject]@{ OwnerName = 'WEB02.contoso.local'; IPAddress = '10.0.16.13' }
            }

            Mock Resolve-DnsRecordPair {
                New-DnsRecordPairObject -Name $Identity -ForwardZone 'contoso.local' -ComputerName 'dc01'
            }

            $result = @(
                Find-DnsRecord -Identity 'web*' -ComputerName 'dc01' -ZoneName 'contoso.local'
            )

            $result.Count | Should -Be 2

            Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter {
                $Namespace -eq 'root\MicrosoftDNS' -and
                $OperationTimeoutSec -eq 300 -and
                $Query -eq (
                    "SELECT OwnerName, IPAddress FROM MicrosoftDNS_AType " +
                    "WHERE ContainerName='contoso.local' AND OwnerName LIKE 'web%.contoso.local'"
                )
            }

            Should -Invoke Resolve-DnsRecordPair -Times 2 -Exactly
            Should -Invoke Resolve-DnsRecordPair -Times 1 -Exactly -ParameterFilter {
                $Identity -eq 'web01.contoso.local' -and $ZoneName -eq 'contoso.local'
            }
        }
    }

    It 'lämnar ett mönster som redan innehåller punkt orört' {
        InModuleScope DnsLathund {
            Mock Get-DnsCimSession {
                [Microsoft.Management.Infrastructure.CimSession]::Create('dc01')
            }

            Mock Get-CimInstance { }
            Mock Resolve-DnsRecordPair { }

            $null = Find-DnsRecord -Identity 'web*.contoso.local' -ComputerName 'dc01' `
                -ZoneName 'contoso.local' -WarningAction SilentlyContinue

            Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter {
                $Query -like "*OwnerName LIKE 'web%.contoso.local'"
            }
        }
    }

    It 'faller tillbaka på zonexport när CIM inte är nåbart' {
        $exportPath = Join-Path -Path $TestDrive -ChildPath 'contoso.local.dns'
        Set-Content -LiteralPath $exportPath -Value '; syntetisk zonexport' -Encoding UTF8

        # Mockkroppar körs i modulens scope och ser inte InModuleScope-
        # parametrarna, därför går sökvägen via en global variabel.
        $global:DnsLathundTestExportPath = $exportPath

        InModuleScope DnsLathund {
            Mock Get-DnsCimSession { }
            Mock Get-CimInstance { throw 'Get-CimInstance ska inte anropas i fallbackvägen.' }
            Mock Export-DnsZoneFile { $global:DnsLathundTestExportPath }

            Mock ConvertFrom-DnsZoneFile {
                [PSCustomObject]@{ OwnerFqdn = 'web01.contoso.local'; IPv4Address = '10.0.16.11' }
                [PSCustomObject]@{ OwnerFqdn = 'db01.contoso.local'; IPv4Address = '10.0.16.20' }
            }

            Mock Resolve-DnsRecordPair {
                New-DnsRecordPairObject -Name $Identity -ComputerName 'dc01'
            }

            $warnings = @()

            $result = @(
                Find-DnsRecord -Identity 'web*' -ComputerName 'dc01' -ZoneName 'contoso.local' `
                    -WarningAction SilentlyContinue -WarningVariable warnings
            )

            $result.Count | Should -Be 1

            @($warnings)[0].Message | Should -BeExactly 'CIM-namnrymden root\MicrosoftDNS gick inte att nå – använder zonexport i stället (långsammare).'

            Should -Invoke Export-DnsZoneFile -Times 1 -Exactly -ParameterFilter {
                $ZoneName -eq 'contoso.local' -and $ComputerName -eq 'dc01'
            }

            Should -Invoke ConvertFrom-DnsZoneFile -Times 1 -Exactly -ParameterFilter {
                $RecordType -eq 'A'
            }

            # Klientsidig -like-matchning mot det FQDN-iserade mönstret.
            Should -Invoke Resolve-DnsRecordPair -Times 1 -Exactly -ParameterFilter {
                $Identity -eq 'web01.contoso.local'
            }
        }

        Remove-Item -LiteralPath 'variable:global:DnsLathundTestExportPath' -Force -ErrorAction SilentlyContinue

        # Temporärfilen städas i finally-blocket.
        Test-Path -LiteralPath $exportPath | Should -BeFalse
    }

    It 'varnar och returnerar ingenting när inget matchar' {
        InModuleScope DnsLathund {
            Mock Resolve-DnsRecordPair { }

            $warnings = @()

            $result = @(
                Find-DnsRecord -Identity 'saknas.contoso.local' -ComputerName 'dc01' `
                    -WarningAction SilentlyContinue -WarningVariable warnings
            )

            $result.Count | Should -Be 0
            @($warnings)[0].Message | Should -BeExactly "Inga poster matchade 'saknas.contoso.local'."
        }
    }

    It 'hanterar flera Identity-värden från pipeline' {
        InModuleScope DnsLathund {
            Mock Resolve-DnsRecordPair {
                New-DnsRecordPairObject -Name $Identity -ComputerName 'dc01'
            }

            $result = @('srv01.contoso.local', 'srv02.contoso.local' | Find-DnsRecord -ComputerName 'dc01')

            $result.Count | Should -Be 2
            Should -Invoke Resolve-DnsRecordPair -Times 2 -Exactly
        }
    }
}

Describe 'Invoke-DnsRecordEditor' {

    BeforeAll {
        $script:LogRoot = Join-Path -Path $TestDrive -ChildPath 'editorlogs'
        $null = New-Item -Path $script:LogRoot -ItemType Directory -Force
    }

    It 'redigerar via Clone och Set-DnsServerResourceRecord samt synkar PTR' {
        $logPath = Join-Path -Path $script:LogRoot -ChildPath 'clone.jsonl'

        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)

            Mock Assert-DnsServerModule { }
            Mock Invoke-DnsMenuChoice { 0 }
            Mock Read-DnsIPv4Input { '10.0.16.6' }
            Mock Set-DnsServerResourceRecord { }
            Mock Remove-DnsServerResourceRecord { }
            Mock Add-DnsServerResourceRecordPtr { }
            Mock Add-DnsServerResourceRecordA { }
            Mock Get-DnsServerResourceRecord { }
            Mock Remove-DnsHostRecord { }

            Mock Get-DnsReverseZoneForAddress {
                [PSCustomObject]@{
                    ZoneName    = '16.0.10.in-addr.arpa'
                    NodeName    = '6'
                    ReverseFqdn = '6.16.0.10.in-addr.arpa'
                }
            }

            Mock Find-DnsRecord { New-DnsTestRecordPair -WithClone }

            Invoke-DnsRecordEditor -Identity 'srv01.contoso.local' -ComputerName 'dc01' -LogPath $LogPath

            Should -Invoke Set-DnsServerResourceRecord -Times 1 -Exactly -ParameterFilter {
                $ZoneName -eq 'contoso.local' -and
                $ComputerName -eq 'dc01' -and
                "$($OldInputObject.RecordData.IPv4Address)" -eq '10.0.16.5' -and
                "$($NewInputObject.RecordData.IPv4Address)" -eq '10.0.16.6'
            }

            Should -Invoke Add-DnsServerResourceRecordA -Times 0 -Exactly

            # Gammal PTR bort ...
            Should -Invoke Remove-DnsServerResourceRecord -Times 1 -Exactly -ParameterFilter {
                $ZoneName -eq '16.0.10.in-addr.arpa' -and $Force.IsPresent
            }

            # ... och ny PTR på plats.
            Should -Invoke Add-DnsServerResourceRecordPtr -Times 1 -Exactly -ParameterFilter {
                $Name -eq '6' -and
                $ZoneName -eq '16.0.10.in-addr.arpa' -and
                $PtrDomainName -eq 'srv01.contoso.local'
            }
        }

        $entries = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })

        @($entries | Where-Object { $_.Action -eq 'SetA' -and $_.Result -eq 'Success' }).Count | Should -Be 1
        @($entries | Where-Object { $_.Action -eq 'RemovePtr' -and $_.Result -eq 'Success' }).Count | Should -Be 1
        @($entries | Where-Object { $_.Action -eq 'AddPtr' -and $_.Result -eq 'Success' }).Count | Should -Be 1
    }

    It 'byter A-post med Add + Remove när Clone saknas' {
        $logPath = Join-Path -Path $script:LogRoot -ChildPath 'noclone.jsonl'

        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)

            Mock Assert-DnsServerModule { }
            Mock Invoke-DnsMenuChoice { 0 }
            Mock Read-DnsIPv4Input { '10.0.16.6' }
            Mock Set-DnsServerResourceRecord { }
            Mock Remove-DnsServerResourceRecord { }
            Mock Add-DnsServerResourceRecordPtr { }
            Mock Add-DnsServerResourceRecordA { }
            Mock Remove-DnsHostRecord { }

            Mock Get-DnsServerResourceRecord {
                [PSCustomObject]@{
                    HostName   = 'srv01'
                    RecordType = 'A'
                    RecordData = [PSCustomObject]@{ IPv4Address = '10.0.16.5' }
                }
            }

            Mock Get-DnsReverseZoneForAddress {
                [PSCustomObject]@{
                    ZoneName    = '16.0.10.in-addr.arpa'
                    NodeName    = '6'
                    ReverseFqdn = '6.16.0.10.in-addr.arpa'
                }
            }

            Mock Find-DnsRecord { New-DnsTestRecordPair }

            Invoke-DnsRecordEditor -Identity 'srv01.contoso.local' -ComputerName 'dc01' -LogPath $LogPath

            Should -Invoke Set-DnsServerResourceRecord -Times 0 -Exactly

            Should -Invoke Add-DnsServerResourceRecordA -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'srv01' -and
                $ZoneName -eq 'contoso.local' -and
                $IPv4Address -eq '10.0.16.6' -and
                -not $CreatePtr.IsPresent
            }

            Should -Invoke Get-DnsServerResourceRecord -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'srv01' -and $RRType -eq 'A'
            }

            # En för den gamla A-posten, en för PTR-posten.
            Should -Invoke Remove-DnsServerResourceRecord -Times 1 -Exactly -ParameterFilter {
                $ZoneName -eq 'contoso.local'
            }

            Should -Invoke Remove-DnsServerResourceRecord -Times 1 -Exactly -ParameterFilter {
                $ZoneName -eq '16.0.10.in-addr.arpa'
            }

            Should -Invoke Add-DnsServerResourceRecordPtr -Times 1 -Exactly
        }

        $entries = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })

        @($entries | Where-Object { $_.Action -eq 'AddA' -and $_.Result -eq 'Success' }).Count | Should -Be 1
        @($entries | Where-Object { $_.Action -eq 'RemoveA' -and $_.Result -eq 'Success' }).Count | Should -Be 1
        @($entries | Where-Object { $_.Action -eq 'SetA' }).Count | Should -Be 0
    }

    It 'rör inte PTR när A-ändringen misslyckas' {
        $logPath = Join-Path -Path $script:LogRoot -ChildPath 'failed.jsonl'

        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)

            Mock Assert-DnsServerModule { }
            Mock Invoke-DnsMenuChoice { 0 }
            Mock Read-DnsIPv4Input { '10.0.16.6' }
            Mock Set-DnsServerResourceRecord { throw 'Nekad åtkomst.' }
            Mock Remove-DnsServerResourceRecord { }
            Mock Add-DnsServerResourceRecordPtr { }
            Mock Add-DnsServerResourceRecordA { }
            Mock Get-DnsServerResourceRecord { }
            Mock Remove-DnsHostRecord { }

            Mock Get-DnsReverseZoneForAddress {
                [PSCustomObject]@{ ZoneName = '16.0.10.in-addr.arpa'; NodeName = '6'; ReverseFqdn = '6.16.0.10.in-addr.arpa' }
            }

            Mock Find-DnsRecord { New-DnsTestRecordPair -WithClone }

            Invoke-DnsRecordEditor -Identity 'srv01.contoso.local' -ComputerName 'dc01' `
                -LogPath $LogPath -ErrorAction SilentlyContinue

            Should -Invoke Remove-DnsServerResourceRecord -Times 0 -Exactly
            Should -Invoke Add-DnsServerResourceRecordPtr -Times 0 -Exactly
        }

        $entries = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })

        @($entries | Where-Object { $_.Action -eq 'SetA' -and $_.Result -eq 'Failed' }).Count | Should -Be 1
    }

    It 'ändrar ingenting med -WhatIf men loggar stegen' {
        $logPath = Join-Path -Path $script:LogRoot -ChildPath 'whatif.jsonl'

        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)

            Mock Assert-DnsServerModule { }
            Mock Invoke-DnsMenuChoice { 0 }
            Mock Read-DnsIPv4Input { '10.0.16.6' }
            Mock Set-DnsServerResourceRecord { }
            Mock Remove-DnsServerResourceRecord { }
            Mock Add-DnsServerResourceRecordPtr { }
            Mock Add-DnsServerResourceRecordA { }
            Mock Get-DnsServerResourceRecord { }
            Mock Remove-DnsHostRecord { }

            Mock Get-DnsReverseZoneForAddress {
                [PSCustomObject]@{ ZoneName = '16.0.10.in-addr.arpa'; NodeName = '6'; ReverseFqdn = '6.16.0.10.in-addr.arpa' }
            }

            Mock Find-DnsRecord { New-DnsTestRecordPair -WithClone }

            Invoke-DnsRecordEditor -Identity 'srv01.contoso.local' -ComputerName 'dc01' `
                -LogPath $LogPath -WhatIf

            Should -Invoke Set-DnsServerResourceRecord -Times 0 -Exactly
            Should -Invoke Add-DnsServerResourceRecordA -Times 0 -Exactly
            Should -Invoke Add-DnsServerResourceRecordPtr -Times 0 -Exactly
            Should -Invoke Remove-DnsServerResourceRecord -Times 0 -Exactly
            Should -Invoke Assert-DnsServerModule -Times 0 -Exactly
        }

        $entries = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })

        @($entries).Count | Should -Be 3
        @($entries | Where-Object { $_.Result -ne 'WhatIf' }).Count | Should -Be 0
        @($entries | ForEach-Object { $_.Action } | Sort-Object) |
            Should -Be (@('AddPtr', 'RemovePtr', 'SetA') | Sort-Object)
    }

    It 'delegerar Ta bort till Remove-DnsHostRecord via pipeline' {
        InModuleScope DnsLathund {
            Mock Assert-DnsServerModule { }
            Mock Invoke-DnsMenuChoice { 1 }
            Mock Read-DnsIPv4Input { throw 'Read-DnsIPv4Input ska inte anropas.' }
            Mock Set-DnsServerResourceRecord { }
            Mock Remove-DnsServerResourceRecord { }
            Mock Add-DnsServerResourceRecordA { }
            Mock Add-DnsServerResourceRecordPtr { }
            Mock Get-DnsServerResourceRecord { }
            Mock Remove-DnsHostRecord { }
            Mock Find-DnsRecord { New-DnsTestRecordPair -WithClone }

            Invoke-DnsRecordEditor -Identity 'srv01.contoso.local' -ComputerName 'dc01'

            Should -Invoke Remove-DnsHostRecord -Times 1 -Exactly -ParameterFilter {
                $ComputerName -eq 'dc01' -and
                @($InputObject)[0].Name -eq 'srv01.contoso.local'
            }

            Should -Invoke Set-DnsServerResourceRecord -Times 0 -Exactly
        }
    }

    It 'avbryter utan att röra något när Avbryt väljs' {
        InModuleScope DnsLathund {
            Mock Assert-DnsServerModule { }
            Mock Invoke-DnsMenuChoice { 2 }
            Mock Set-DnsServerResourceRecord { }
            Mock Remove-DnsServerResourceRecord { }
            Mock Add-DnsServerResourceRecordA { }
            Mock Add-DnsServerResourceRecordPtr { }
            Mock Get-DnsServerResourceRecord { }
            Mock Remove-DnsHostRecord { }
            Mock Find-DnsRecord { New-DnsTestRecordPair -WithClone }

            Invoke-DnsRecordEditor -Identity 'srv01.contoso.local' -ComputerName 'dc01'

            Should -Invoke Remove-DnsHostRecord -Times 0 -Exactly
            Should -Invoke Set-DnsServerResourceRecord -Times 0 -Exactly
        }
    }

    It 'ber om förfining vid fler än 20 träffar' {
        InModuleScope DnsLathund {
            Mock Invoke-DnsMenuChoice { throw 'Ingen meny ska visas vid fler än 20 träffar.' }
            Mock Find-DnsRecord {
                1..21 | ForEach-Object {
                    New-DnsRecordPairObject -Name "srv$_.contoso.local" -IPv4Address "10.0.16.$_" -ComputerName 'dc01'
                }
            }

            $warnings = @()

            Invoke-DnsRecordEditor -Identity 'srv*' -ComputerName 'dc01' -ZoneName 'contoso.local' `
                -WarningAction SilentlyContinue -WarningVariable warnings

            @($warnings)[0].Message | Should -BeExactly 'Fler än 20 träffar – förfina sökningen.'
            Should -Invoke Invoke-DnsMenuChoice -Times 0 -Exactly
        }
    }

    It 'erbjuder inte Skapa när Identity är en IPv4-adress' {
        InModuleScope DnsLathund {
            Mock Invoke-DnsMenuChoice { throw 'Skapa ska inte erbjudas för en IP-adress.' }
            Mock Find-DnsRecord { }

            $warnings = @()

            Invoke-DnsRecordEditor -Identity '10.0.16.5' -ComputerName 'dc01' `
                -WarningAction SilentlyContinue -WarningVariable warnings

            @($warnings)[0].Message | Should -BeExactly "Inga poster matchade '10.0.16.5'."
            Should -Invoke Invoke-DnsMenuChoice -Times 0 -Exactly
        }
    }

    It 'skapar A med -CreatePtr när reverse-zonen finns' {
        $logPath = Join-Path -Path $script:LogRoot -ChildPath 'create.jsonl'

        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)

            Mock Assert-DnsServerModule { }
            Mock Invoke-DnsMenuChoice { 0 }
            Mock Read-DnsIPv4Input { '10.0.16.9' }
            Mock Add-DnsServerResourceRecordA { }
            Mock Add-DnsServerResourceRecordPtr { }
            Mock Get-DnsServerResourceRecord { }
            Mock Find-DnsRecord { }

            Mock Get-DnsReverseZoneForAddress {
                [PSCustomObject]@{ ZoneName = '16.0.10.in-addr.arpa'; NodeName = '9'; ReverseFqdn = '9.16.0.10.in-addr.arpa' }
            }

            Invoke-DnsRecordEditor -Identity 'ny01' -ComputerName 'dc01' `
                -ZoneName 'contoso.local' -LogPath $LogPath -WarningAction SilentlyContinue

            Should -Invoke Add-DnsServerResourceRecordA -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'ny01' -and
                $ZoneName -eq 'contoso.local' -and
                $IPv4Address -eq '10.0.16.9' -and
                $CreatePtr.IsPresent
            }

            # -CreatePtr sköter PTR — inget separat Add-Ptr i lyckat fall.
            Should -Invoke Add-DnsServerResourceRecordPtr -Times 0 -Exactly
        }

        $entries = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })

        @($entries | Where-Object { $_.Action -eq 'AddA' -and $_.Result -eq 'Success' }).Count | Should -Be 1
        @($entries | Where-Object { $_.Action -eq 'AddPtr' -and $_.Result -eq 'Success' }).Count | Should -Be 1
    }

    It 'skapar A utan -CreatePtr och varnar när reverse-zon saknas' {
        InModuleScope DnsLathund {
            Mock Assert-DnsServerModule { }
            Mock Invoke-DnsMenuChoice { 0 }
            Mock Read-DnsIPv4Input { '192.168.99.9' }
            Mock Add-DnsServerResourceRecordA { }
            Mock Add-DnsServerResourceRecordPtr { }
            Mock Get-DnsServerResourceRecord { }
            Mock Find-DnsRecord { }
            Mock Get-DnsReverseZoneForAddress { }

            $warnings = @()

            Invoke-DnsRecordEditor -Identity 'ny01' -ComputerName 'dc01' -ZoneName 'contoso.local' `
                -WarningAction SilentlyContinue -WarningVariable warnings

            Should -Invoke Add-DnsServerResourceRecordA -Times 1 -Exactly -ParameterFilter {
                $IPv4Address -eq '192.168.99.9' -and -not $CreatePtr.IsPresent
            }

            Should -Invoke Add-DnsServerResourceRecordPtr -Times 0 -Exactly

            @($warnings | ForEach-Object { $_.Message }) |
                Should -Contain 'Ingen reverse-zon finns för 192.168.99.9 – PTR skapades inte.'
        }
    }

    It 'skapar PTR manuellt när -CreatePtr misslyckades men A-posten finns' {
        InModuleScope DnsLathund {
            Mock Assert-DnsServerModule { }
            Mock Invoke-DnsMenuChoice { 0 }
            Mock Read-DnsIPv4Input { '10.0.16.9' }
            Mock Add-DnsServerResourceRecordA { throw 'PTR kunde inte skapas.' }
            Mock Add-DnsServerResourceRecordPtr { }
            Mock Find-DnsRecord { }

            Mock Get-DnsServerResourceRecord {
                [PSCustomObject]@{
                    HostName   = 'ny01'
                    RecordType = 'A'
                    RecordData = [PSCustomObject]@{ IPv4Address = '10.0.16.9' }
                }
            }

            Mock Get-DnsReverseZoneForAddress {
                [PSCustomObject]@{ ZoneName = '16.0.10.in-addr.arpa'; NodeName = '9'; ReverseFqdn = '9.16.0.10.in-addr.arpa' }
            }

            Invoke-DnsRecordEditor -Identity 'ny01' -ComputerName 'dc01' -ZoneName 'contoso.local' `
                -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

            Should -Invoke Add-DnsServerResourceRecordPtr -Times 1 -Exactly -ParameterFilter {
                $Name -eq '9' -and
                $ZoneName -eq '16.0.10.in-addr.arpa' -and
                $PtrDomainName -eq 'ny01.contoso.local'
            }
        }
    }

    It 'väljer post ur urvalsmenyn vid flera träffar' {
        InModuleScope DnsLathund {
            Mock Assert-DnsServerModule { }
            Mock Read-DnsIPv4Input { throw 'Ingen redigering ska ske.' }
            Mock Set-DnsServerResourceRecord { }
            Mock Remove-DnsServerResourceRecord { }
            Mock Add-DnsServerResourceRecordA { }
            Mock Add-DnsServerResourceRecordPtr { }
            Mock Get-DnsServerResourceRecord { }
            Mock Remove-DnsHostRecord { }

            Mock Find-DnsRecord {
                New-DnsRecordPairObject -Name 'srv01.contoso.local' -IPv4Address '10.0.16.5' -ForwardZone 'contoso.local' -ComputerName 'dc01'
                New-DnsRecordPairObject -Name 'srv02.contoso.local' -IPv4Address '10.0.16.6' -ForwardZone 'contoso.local' -ComputerName 'dc01'
            }

            # Val 1 i urvalsmenyn är post nummer två; val 1 i åtgärdsmenyn är
            # Ta bort. Ett och samma mocksvar täcker alltså båda stegen.
            Mock Invoke-DnsMenuChoice { 1 }

            Invoke-DnsRecordEditor -Identity 'srv*' -ComputerName 'dc01' -ZoneName 'contoso.local'

            Should -Invoke Invoke-DnsMenuChoice -Times 2 -Exactly

            Should -Invoke Remove-DnsHostRecord -Times 1 -Exactly -ParameterFilter {
                @($InputObject)[0].Name -eq 'srv02.contoso.local'
            }
        }
    }
}
