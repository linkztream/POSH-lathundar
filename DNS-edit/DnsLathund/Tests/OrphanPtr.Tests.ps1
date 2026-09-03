#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Fas A-tester för de publika funktionerna Get-DnsOrphanPtr och
    Remove-DnsPtrRecord.

    Allt körs offline. DnsServer-cmdletarna finns som globala stubbar som Pester
    mockar, Export-DnsZoneFile mockas till kopior av fixturerna (kopior, inte
    originalen — Get-DnsOrphanPtr städar sina temporära filer) och zontabellen
    är syntetisk.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingComputerNameHardcoded',
    '',
    Justification = 'dc01 är syntetiskt testdata, ingen verklig server kontaktas.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidGlobalVars',
    '',
    Justification = 'Mockkroppar körs i modulens sessionstillstånd och når testets tillstånd enklast via en global variabel.'
)]
param ()

BeforeAll {
    $script:ModulePath = Split-Path -Path $PSScriptRoot -Parent
    $script:ManifestPath = Join-Path -Path $script:ModulePath -ChildPath 'DnsLathund.psd1'

    Remove-Module -Name DnsLathund -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop

    # Stubbar för DnsServer-cmdletarna (maskinen saknar RSAT).
    function global:Get-DnsServerResourceRecord {
        [CmdletBinding()]
        param (
            [string]$ComputerName,
            [string]$ZoneName,
            [string]$Name,
            [string]$RRType,
            $CimSession
        )
    }

    function global:Remove-DnsServerResourceRecord {
        [CmdletBinding()]
        param (
            [Parameter(ValueFromPipeline)]
            $InputObject,

            [string]$ComputerName,
            [string]$ZoneName,
            [string]$Name,
            [string]$RRType,
            $RecordData,
            [switch]$Force,
            $CimSession
        )

        process { }
    }

    $script:TemporaryZoneRoot = Join-Path -Path $TestDrive -ChildPath 'zonexport'
    $null = New-Item -Path $script:TemporaryZoneRoot -ItemType Directory -Force

    # Mockkroppar körs i modulens sessionstillstånd och ser därför inte
    # testfilens $script:-variabler. Fixturplatserna delas via en global.
    $global:DnsLathundTestState = @{
        ForwardFixture    = Join-Path -Path $PSScriptRoot -ChildPath 'Fixtures\forward-zone.txt'
        ReverseFixture    = Join-Path -Path $PSScriptRoot -ChildPath 'Fixtures\reverse-zone.txt'
        TemporaryZoneRoot = $script:TemporaryZoneRoot
    }

    function New-TestOrphanPtr {
        param (
            [string]$PtrOwnerName = '90',
            [string]$IPAddress = '10.0.16.90',
            [string]$PtrTarget = 'gammal-srv.contoso.local',
            [string]$Status = 'NoARecord',
            [string]$ReverseZone = '16.0.10.in-addr.arpa'
        )

        [PSCustomObject]@{
            PSTypeName   = 'DnsLathund.OrphanPtr'
            IPAddress    = $IPAddress
            PtrOwnerName = $PtrOwnerName
            PtrTarget    = $PtrTarget
            ReverseZone  = $ReverseZone
            Status       = $Status
            ComputerName = 'dc01'
        }
    }
}

AfterAll {
    Remove-Item -Path 'function:\Get-DnsServerResourceRecord' -Force -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:\Remove-DnsServerResourceRecord' -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name 'DnsLathundTestState' -Scope Global -Force -ErrorAction SilentlyContinue
    Remove-Module -Name DnsLathund -Force -ErrorAction SilentlyContinue
}

Describe 'Get-DnsOrphanPtr' {

    BeforeEach {
        Mock -CommandName Assert-DnsServerModule -ModuleName DnsLathund -MockWith { }

        Mock -CommandName Get-DnsZoneTable -ModuleName DnsLathund -MockWith {
            [PSCustomObject]@{
                AllZones     = @(
                    [PSCustomObject]@{ ZoneName = 'contoso.local'; ZoneType = 'Primary'; IsReverseLookupZone = $false }
                    [PSCustomObject]@{ ZoneName = 'speglad.contoso.local'; ZoneType = 'Secondary'; IsReverseLookupZone = $false }
                    [PSCustomObject]@{ ZoneName = '16.0.10.in-addr.arpa'; ZoneType = 'Primary'; IsReverseLookupZone = $true }
                    [PSCustomObject]@{ ZoneName = '0/25.17.0.10.in-addr.arpa'; ZoneType = 'Primary'; IsReverseLookupZone = $true }
                )
                ForwardZones = [string[]]@('contoso.local', 'speglad.contoso.local')
                ReverseZones = [string[]]@('16.0.10.in-addr.arpa', '0/25.17.0.10.in-addr.arpa')
            }
        }

        # Returnerar en kopia av fixturen: den anropande funktionen tar bort
        # filen i sitt finally-block.
        Mock -CommandName Export-DnsZoneFile -ModuleName DnsLathund -MockWith {
            $fixturePath = if ($ZoneName -like '*.in-addr.arpa') {
                $global:DnsLathundTestState.ReverseFixture
            }
            else {
                $global:DnsLathundTestState.ForwardFixture
            }

            $copyPath = Join-Path -Path $global:DnsLathundTestState.TemporaryZoneRoot -ChildPath (
                '{0}.txt' -f [guid]::NewGuid().ToString('N')
            )

            Copy-Item -LiteralPath $fixturePath -Destination $copyPath -Force

            $copyPath
        }
    }

    It 'hittar exakt de två föräldralösa PTR-posterna' {
        $result = @(Get-DnsOrphanPtr -ComputerName 'dc01' -WarningAction SilentlyContinue)

        $result.Count | Should -Be 2
        @($result.Status | Sort-Object -Unique) | Should -Be @('NoARecord')
        @($result.PtrOwnerName | Sort-Object) | Should -Be @('90', '91')
        @($result.IPAddress | Sort-Object) | Should -Be @('10.0.16.90', '10.0.16.91')
        @($result.PtrTarget | Sort-Object) | Should -Be @('avvecklad.contoso.local', 'gammal-srv.contoso.local')
        @($result.ReverseZone | Sort-Object -Unique) | Should -Be @('16.0.10.in-addr.arpa')
        @($result.ComputerName | Sort-Object -Unique) | Should -Be @('dc01')
    }

    It 'ger objekt med rätt PSTypeName' {
        $result = @(Get-DnsOrphanPtr -ComputerName 'dc01' -WarningAction SilentlyContinue)

        $result[0].PSObject.TypeNames | Should -Contain 'DnsLathund.OrphanPtr'
    }

    It 'tar bara med felpekande PTR-poster med -IncludeMismatch' {
        $utan = @(Get-DnsOrphanPtr -ComputerName 'dc01' -WarningAction SilentlyContinue)
        $med = @(Get-DnsOrphanPtr -ComputerName 'dc01' -IncludeMismatch -WarningAction SilentlyContinue)

        @($utan | Where-Object { $_.Status -eq 'IpMismatch' }) | Should -BeNullOrEmpty

        $med.Count | Should -Be 3

        $mismatch = @($med | Where-Object { $_.Status -eq 'IpMismatch' })

        $mismatch.Count | Should -Be 1
        $mismatch[0].IPAddress | Should -BeExactly '10.0.16.99'
        $mismatch[0].PtrOwnerName | Should -BeExactly '99'
        $mismatch[0].PtrTarget | Should -BeExactly 'web02.contoso.local'
    }

    It 'hoppar över klasslösa RFC 2317-zoner med varning' {
        $streams = Get-DnsOrphanPtr -ComputerName 'dc01' 3>&1

        $warnings = @($streams | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

        "$warnings" | Should -Match 'Klasslös reverse-zon 0/25\.17\.0\.10\.in-addr\.arpa stöds inte ännu'

        Should -Invoke -CommandName Export-DnsZoneFile -ModuleName DnsLathund -Times 0 -Exactly -ParameterFilter {
            $ZoneName -eq '0/25.17.0.10.in-addr.arpa'
        }
    }

    It 'exporterar bara primära zoner' {
        $null = Get-DnsOrphanPtr -ComputerName 'dc01' -WarningAction SilentlyContinue

        Should -Invoke -CommandName Export-DnsZoneFile -ModuleName DnsLathund -Times 1 -Exactly -ParameterFilter {
            $ZoneName -eq 'contoso.local'
        }

        Should -Invoke -CommandName Export-DnsZoneFile -ModuleName DnsLathund -Times 0 -Exactly -ParameterFilter {
            $ZoneName -eq 'speglad.contoso.local'
        }

        Should -Invoke -CommandName Export-DnsZoneFile -ModuleName DnsLathund -Times 1 -Exactly -ParameterFilter {
            $ZoneName -eq '16.0.10.in-addr.arpa'
        }
    }

    It 'respekterar uttryckliga -ReverseZone och -ForwardZone' {
        $result = @(
            Get-DnsOrphanPtr `
                -ComputerName 'dc01' `
                -ReverseZone '16.0.10.in-addr.arpa' `
                -ForwardZone 'contoso.local' `
                -WarningAction SilentlyContinue
        )

        $result.Count | Should -Be 2

        Should -Invoke -CommandName Export-DnsZoneFile -ModuleName DnsLathund -Times 2 -Exactly
    }

    It 'städar de temporära zonfilerna' {
        $null = Get-DnsOrphanPtr -ComputerName 'dc01' -WarningAction SilentlyContinue

        @(Get-ChildItem -LiteralPath $script:TemporaryZoneRoot -File) | Should -BeNullOrEmpty
    }

    It 'lämnar fixturerna orörda' {
        $null = Get-DnsOrphanPtr -ComputerName 'dc01' -WarningAction SilentlyContinue

        Test-Path -LiteralPath $global:DnsLathundTestState.ForwardFixture | Should -BeTrue
        Test-Path -LiteralPath $global:DnsLathundTestState.ReverseFixture | Should -BeTrue
    }

    It 'varnar och avbryter när det inte finns några forwardzoner' {
        Mock -CommandName Get-DnsZoneTable -ModuleName DnsLathund -MockWith {
            [PSCustomObject]@{
                AllZones     = @(
                    [PSCustomObject]@{ ZoneName = '16.0.10.in-addr.arpa'; ZoneType = 'Primary'; IsReverseLookupZone = $true }
                )
                ForwardZones = [string[]]@()
                ReverseZones = [string[]]@('16.0.10.in-addr.arpa')
            }
        }

        $streams = Get-DnsOrphanPtr -ComputerName 'dc01' 3>&1
        $warnings = @($streams | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

        "$warnings" | Should -Match 'Inga forwardzoner'

        Should -Invoke -CommandName Export-DnsZoneFile -ModuleName DnsLathund -Times 0 -Exactly
    }

    It 'felar med hänvisning till ZoneExport när CIM inte är nåbart' {
        Mock -CommandName Get-DnsCimSession -ModuleName DnsLathund -MockWith { $null }

        {
            Get-DnsOrphanPtr -ComputerName 'dc01' -Method Cim -ErrorAction Stop
        } | Should -Throw -ExpectedMessage '*-Method ZoneExport*'
    }
}

Describe 'Remove-DnsPtrRecord' {

    BeforeEach {
        $script:LogPath = Join-Path -Path $TestDrive -ChildPath ('logg_{0}.jsonl' -f ([guid]::NewGuid().ToString('N')))

        Mock -CommandName Assert-DnsServerModule -ModuleName DnsLathund -MockWith { }

        Mock -CommandName Get-DnsZoneTable -ModuleName DnsLathund -MockWith {
            [PSCustomObject]@{
                AllZones     = @()
                ForwardZones = [string[]]@('contoso.local')
                ReverseZones = [string[]]@('16.0.10.in-addr.arpa')
            }
        }

        # PTR-uppslaget svarar med den post exportvägen hittade.
        Mock -CommandName Get-DnsServerResourceRecord -ModuleName DnsLathund -ParameterFilter {
            $RRType -eq 'PTR'
        } -MockWith {
            $ptrTargets = @{
                '90' = 'gammal-srv.contoso.local.'
                '91' = 'avvecklad.contoso.local.'
                '99' = 'web02.contoso.local.'
            }

            [PSCustomObject]@{
                HostName   = $Name
                RecordType = 'PTR'
                RecordData = [PSCustomObject]@{ PtrDomainName = $ptrTargets[$Name] }
            }
        }

        # A-posten saknas fortfarande.
        Mock -CommandName Get-DnsServerResourceRecord -ModuleName DnsLathund -ParameterFilter {
            $RRType -eq 'A'
        } -MockWith { }

        Mock -CommandName Remove-DnsServerResourceRecord -ModuleName DnsLathund -MockWith { }
    }

    It 'tar bort en verifierad föräldralös PTR-post' {
        $result = @(
            New-TestOrphanPtr | Remove-DnsPtrRecord -ComputerName 'dc01' -Force -LogPath $script:LogPath
        )

        $result.Count | Should -Be 1
        $result[0].PSObject.TypeNames | Should -Contain 'DnsLathund.RemovalResult'
        $result[0].Result | Should -BeExactly 'Success'
        $result[0].Name | Should -BeExactly '90'
        $result[0].ZoneName | Should -BeExactly '16.0.10.in-addr.arpa'
        $result[0].RecordType | Should -BeExactly 'PTR'
        $result[0].Action | Should -BeExactly 'RemovePtr'

        Should -Invoke -CommandName Remove-DnsServerResourceRecord -ModuleName DnsLathund -Times 1 -Exactly

        $entry = (Get-Content -LiteralPath $script:LogPath | Select-Object -First 1) | ConvertFrom-Json

        $entry.Action | Should -BeExactly 'RemovePtr'
        $entry.Result | Should -BeExactly 'Success'
        $entry.RecordData | Should -BeExactly 'gammal-srv.contoso.local'
    }

    It 'slår alltid upp PTR-posten med -Name' {
        $null = New-TestOrphanPtr | Remove-DnsPtrRecord -ComputerName 'dc01' -Force -LogPath $script:LogPath

        Should -Invoke -CommandName Get-DnsServerResourceRecord -ModuleName DnsLathund -ParameterFilter {
            $RRType -eq 'PTR' -and -not [string]::IsNullOrEmpty($Name)
        } -Times 1 -Exactly
    }

    It 'tar bort med pipelineformen (posten skickas som indata)' {
        $null = New-TestOrphanPtr | Remove-DnsPtrRecord -ComputerName 'dc01' -Force -LogPath $script:LogPath

        Should -Invoke -CommandName Remove-DnsServerResourceRecord -ModuleName DnsLathund -Times 1 -Exactly -ParameterFilter {
            $null -ne $InputObject -and
            $ZoneName -eq '16.0.10.in-addr.arpa' -and
            $ComputerName -eq 'dc01' -and
            $Force.IsPresent -and
            [string]::IsNullOrEmpty($Name)
        }
    }

    It 'hanterar flera poster från pipelinen' {
        $result = @(
            @(
                (New-TestOrphanPtr -PtrOwnerName '90' -IPAddress '10.0.16.90' -PtrTarget 'gammal-srv.contoso.local')
                (New-TestOrphanPtr -PtrOwnerName '91' -IPAddress '10.0.16.91' -PtrTarget 'avvecklad.contoso.local')
            ) | Remove-DnsPtrRecord -ComputerName 'dc01' -Force -LogPath $script:LogPath
        )

        $result.Count | Should -Be 2
        @($result.Result | Sort-Object -Unique) | Should -Be @('Success')

        Should -Invoke -CommandName Remove-DnsServerResourceRecord -ModuleName DnsLathund -Times 2 -Exactly
    }

    It 'hoppar över en PTR-post som inte längre pekar på samma namn' {
        Mock -CommandName Get-DnsServerResourceRecord -ModuleName DnsLathund -ParameterFilter {
            $RRType -eq 'PTR'
        } -MockWith {
            [PSCustomObject]@{
                HostName   = $Name
                RecordType = 'PTR'
                RecordData = [PSCustomObject]@{ PtrDomainName = 'nyserver.contoso.local.' }
            }
        }

        $result = @(
            New-TestOrphanPtr |
                Remove-DnsPtrRecord -ComputerName 'dc01' -Force -LogPath $script:LogPath -WarningAction SilentlyContinue
        )

        $result.Count | Should -Be 1
        $result[0].Result | Should -BeExactly 'Skipped'

        Should -Invoke -CommandName Remove-DnsServerResourceRecord -ModuleName DnsLathund -Times 0 -Exactly
    }

    It 'hoppar över en PTR-post vars A-post har återskapats' {
        Mock -CommandName Get-DnsServerResourceRecord -ModuleName DnsLathund -ParameterFilter {
            $RRType -eq 'A'
        } -MockWith {
            [PSCustomObject]@{
                HostName   = 'gammal-srv'
                RecordType = 'A'
                RecordData = [PSCustomObject]@{ IPv4Address = '10.0.16.90' }
            }
        }

        $result = @(
            New-TestOrphanPtr |
                Remove-DnsPtrRecord -ComputerName 'dc01' -Force -LogPath $script:LogPath -WarningAction SilentlyContinue
        )

        $result.Count | Should -Be 1
        $result[0].Result | Should -BeExactly 'Skipped'
        $result[0].Error | Should -Match 'finns igen'

        Should -Invoke -CommandName Remove-DnsServerResourceRecord -ModuleName DnsLathund -Times 0 -Exactly
    }

    It 'hoppar över en IpMismatch som inte längre gäller' {
        Mock -CommandName Get-DnsServerResourceRecord -ModuleName DnsLathund -ParameterFilter {
            $RRType -eq 'A'
        } -MockWith {
            [PSCustomObject]@{
                HostName   = 'web02'
                RecordType = 'A'
                RecordData = [PSCustomObject]@{ IPv4Address = '10.0.16.99' }
            }
        }

        $result = @(
            New-TestOrphanPtr -PtrOwnerName '99' -IPAddress '10.0.16.99' -PtrTarget 'web02.contoso.local' -Status 'IpMismatch' |
                Remove-DnsPtrRecord -ComputerName 'dc01' -Force -LogPath $script:LogPath -WarningAction SilentlyContinue
        )

        $result[0].Result | Should -BeExactly 'Skipped'

        Should -Invoke -CommandName Remove-DnsServerResourceRecord -ModuleName DnsLathund -Times 0 -Exactly
    }

    It 'tar bort en IpMismatch som fortfarande gäller' {
        Mock -CommandName Get-DnsServerResourceRecord -ModuleName DnsLathund -ParameterFilter {
            $RRType -eq 'A'
        } -MockWith {
            [PSCustomObject]@{
                HostName   = 'web02'
                RecordType = 'A'
                RecordData = [PSCustomObject]@{ IPv4Address = '10.0.16.31' }
            }
        }

        $result = @(
            New-TestOrphanPtr -PtrOwnerName '99' -IPAddress '10.0.16.99' -PtrTarget 'web02.contoso.local' -Status 'IpMismatch' |
                Remove-DnsPtrRecord -ComputerName 'dc01' -Force -LogPath $script:LogPath
        )

        $result[0].Result | Should -BeExactly 'Success'

        Should -Invoke -CommandName Remove-DnsServerResourceRecord -ModuleName DnsLathund -Times 1 -Exactly
    }

    It '-WhatIf tar inte bort något men loggar ändå' {
        $result = @(
            New-TestOrphanPtr |
                Remove-DnsPtrRecord -ComputerName 'dc01' -Force -LogPath $script:LogPath -WhatIf
        )

        $result.Count | Should -Be 1
        $result[0].Result | Should -BeExactly 'WhatIf'

        Should -Invoke -CommandName Remove-DnsServerResourceRecord -ModuleName DnsLathund -Times 0 -Exactly

        $entry = (Get-Content -LiteralPath $script:LogPath | Select-Object -First 1) | ConvertFrom-Json

        $entry.Result | Should -BeExactly 'WhatIf'
        $entry.RecordName | Should -BeExactly '90'
    }

    It 'rapporterar Failed när borttagningen misslyckas' {
        Mock -CommandName Remove-DnsServerResourceRecord -ModuleName DnsLathund -MockWith {
            throw 'Åtkomst nekad.'
        }

        $result = @(
            New-TestOrphanPtr |
                Remove-DnsPtrRecord -ComputerName 'dc01' -Force -LogPath $script:LogPath -ErrorAction SilentlyContinue
        )

        $result.Count | Should -Be 1
        $result[0].Result | Should -BeExactly 'Failed'
        $result[0].Error | Should -Match 'Åtkomst nekad'

        $entry = (Get-Content -LiteralPath $script:LogPath | Select-Object -First 1) | ConvertFrom-Json

        $entry.Result | Should -BeExactly 'Failed'
    }

    It 'hoppar över ett ofullständigt OrphanPtr-objekt' {
        $ofullstandig = [PSCustomObject]@{
            PSTypeName   = 'DnsLathund.OrphanPtr'
            IPAddress    = '10.0.16.90'
            PtrOwnerName = ''
            PtrTarget    = 'gammal-srv.contoso.local'
            ReverseZone  = ''
            Status       = 'NoARecord'
            ComputerName = 'dc01'
        }

        $result = @(
            $ofullstandig |
                Remove-DnsPtrRecord -ComputerName 'dc01' -Force -LogPath $script:LogPath -WarningAction SilentlyContinue
        )

        $result.Count | Should -Be 1
        $result[0].Result | Should -BeExactly 'Skipped'

        Should -Invoke -CommandName Remove-DnsServerResourceRecord -ModuleName DnsLathund -Times 0 -Exactly
        Should -Invoke -CommandName Get-DnsServerResourceRecord -ModuleName DnsLathund -Times 0 -Exactly
    }
}


Describe 'Get-DnsOrphanPtr — zonurval och feltålighet' {

    BeforeEach {
        Mock -CommandName Assert-DnsServerModule -ModuleName DnsLathund -MockWith { }

        # Zontabell med auto-skapade zoner och TrustAnchors — sådana finns på
        # varje riktig DC och gick före fixen sönder i defaultsvepet:
        # Export-DnsServerZone kan inte exportera dem (verifierat live).
        Mock -CommandName Get-DnsZoneTable -ModuleName DnsLathund -MockWith {
            [PSCustomObject]@{
                AllZones     = @(
                    [PSCustomObject]@{ ZoneName = 'contoso.local'; ZoneType = 'Primary'; IsReverseLookupZone = $false; IsAutoCreated = $false }
                    [PSCustomObject]@{ ZoneName = 'TrustAnchors'; ZoneType = 'Primary'; IsReverseLookupZone = $false; IsAutoCreated = $false }
                    [PSCustomObject]@{ ZoneName = '16.0.10.in-addr.arpa'; ZoneType = 'Primary'; IsReverseLookupZone = $true; IsAutoCreated = $false }
                    [PSCustomObject]@{ ZoneName = '0.in-addr.arpa'; ZoneType = 'Primary'; IsReverseLookupZone = $true; IsAutoCreated = $true }
                    [PSCustomObject]@{ ZoneName = '127.in-addr.arpa'; ZoneType = 'Primary'; IsReverseLookupZone = $true; IsAutoCreated = $true }
                )
                ForwardZones = [string[]]@('contoso.local', 'TrustAnchors')
                ReverseZones = [string[]]@('16.0.10.in-addr.arpa', '0.in-addr.arpa', '127.in-addr.arpa')
            }
        }

        Mock -CommandName Export-DnsZoneFile -ModuleName DnsLathund -MockWith {
            $fixturePath = if ($ZoneName -like '*.in-addr.arpa') {
                $global:DnsLathundTestState.ReverseFixture
            }
            else {
                $global:DnsLathundTestState.ForwardFixture
            }

            $copyPath = Join-Path -Path $global:DnsLathundTestState.TemporaryZoneRoot -ChildPath (
                '{0}.txt' -f [guid]::NewGuid().ToString('N')
            )

            Copy-Item -LiteralPath $fixturePath -Destination $copyPath -Force

            $copyPath
        }
    }

    It 'utesluter auto-skapade zoner och TrustAnchors ur defaultsvepet' {
        $result = @(Get-DnsOrphanPtr -ComputerName 'dc01' -WarningAction SilentlyContinue)

        # Svepet ska fungera och bara röra de riktiga zonerna.
        $result.Count | Should -Be 2

        Should -Invoke -CommandName Export-DnsZoneFile -ModuleName DnsLathund -Times 0 -Exactly -ParameterFilter {
            $ZoneName -in @('0.in-addr.arpa', '127.in-addr.arpa', 'TrustAnchors')
        }
    }

    It 'varnar och fortsätter när en reverse-zon inte kan exporteras' {
        # 16.0.10-zonen felar; den auto-skapade filtreringen testas ovan, så
        # här får den trasiga zonen sällskap av en frisk.
        Mock -CommandName Get-DnsZoneTable -ModuleName DnsLathund -MockWith {
            [PSCustomObject]@{
                AllZones     = @(
                    [PSCustomObject]@{ ZoneName = 'contoso.local'; ZoneType = 'Primary'; IsReverseLookupZone = $false; IsAutoCreated = $false }
                    [PSCustomObject]@{ ZoneName = '16.0.10.in-addr.arpa'; ZoneType = 'Primary'; IsReverseLookupZone = $true; IsAutoCreated = $false }
                    [PSCustomObject]@{ ZoneName = 'trasig.17.0.10.in-addr.arpa'; ZoneType = 'Primary'; IsReverseLookupZone = $true; IsAutoCreated = $false }
                )
                ForwardZones = [string[]]@('contoso.local')
                ReverseZones = [string[]]@('trasig.17.0.10.in-addr.arpa', '16.0.10.in-addr.arpa')
            }
        }

        Mock -CommandName Export-DnsZoneFile -ModuleName DnsLathund -ParameterFilter {
            $ZoneName -eq 'trasig.17.0.10.in-addr.arpa'
        } -MockWith {
            throw "Kunde inte exportera zonen 'trasig.17.0.10.in-addr.arpa' på 'dc01': testfel."
        }

        $streams = Get-DnsOrphanPtr -ComputerName 'dc01' 3>&1

        $warnings = @($streams | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $result = @($streams | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })

        "$warnings" | Should -Match "Reverse-zonen 'trasig\.17\.0\.10\.in-addr\.arpa' kunde inte läsas och hoppas över"

        # Den friska zonens orphans kommer ändå.
        $result.Count | Should -Be 2
    }

    It 'avbryter när en forwardzon inte kan exporteras (ofullständigt A-index vore farligt)' {
        Mock -CommandName Export-DnsZoneFile -ModuleName DnsLathund -ParameterFilter {
            $ZoneName -eq 'contoso.local'
        } -MockWith {
            throw "Kunde inte exportera zonen 'contoso.local' på 'dc01': testfel."
        }

        { Get-DnsOrphanPtr -ComputerName 'dc01' -WarningAction SilentlyContinue -ErrorAction Stop } |
            Should -Throw '*contoso.local*'
    }
}
