#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }

BeforeAll {
    Import-Module "$PSScriptRoot\..\DnsLathund.psd1" -Force
    $script:StubPath = Join-Path -Path $PSScriptRoot -ChildPath 'Stubs\DnsServerStubs.ps1'

    function Initialize-DnsStub {
        <#
        .SYNOPSIS
            Loads the DnsServer stubs into the module scope and fills them with a
            standard zone set.
        #>
        param (
            [string]$StubPath,
            [string]$ExportRoot
        )

        InModuleScope DnsLathund -Parameters @{ StubPath = $StubPath; ExportRoot = $ExportRoot } {
            param ($StubPath, $ExportRoot)

            . $StubPath
            Reset-DnsStubStore -ExportRoot $ExportRoot
            $script:ZoneTableCache = @{}
            $script:CimSessionCache = @{}

            Add-DnsStubZone -Name 'Contoso.LOCAL.' -AgingEnabled $true -NoRefreshInterval (New-TimeSpan -Days 3) -RefreshInterval (New-TimeSpan -Days 4) -ScavengeServers '10.0.16.10'
            Add-DnsStubZone -Name 'lab.contoso.local' -ReplicationScope 'Forest' -DirectoryPartitionName 'ForestDnsZones.contoso.local'
            Add-DnsStubZone -Name '16.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '10.in-addr.arpa'
            Add-DnsStubZone -Name '0/25.16.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '64-26.16.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '0-127.17.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '8.b.d.0.1.0.0.2.ip6.arpa'
            Add-DnsStubZone -Name '0.in-addr.arpa' -IsAutoCreated -IsDsIntegrated $false
            Add-DnsStubZone -Name 'TrustAnchors' -ReplicationScope 'Forest'
            Add-DnsStubZone -Name 'fabrikam.com' -ZoneType Secondary -IsDsIntegrated $false
            Add-DnsStubZone -Name 'partner.example' -ZoneType Forwarder -ReplicationScope 'Forest'
        }
    }

    function Get-FileByte {
        <#
        .SYNOPSIS
            Reads a file as bytes on both PowerShell editions.
        #>
        param ([string]$Path)

        if ($PSVersionTable.PSVersion.Major -ge 6) {
            Get-Content -LiteralPath $Path -AsByteStream -Raw
        }
        else {
            Get-Content -LiteralPath $Path -Encoding Byte -Raw
        }
    }
}

Describe 'Module foundation' {
    It 'imports as version 1.0.0' {
        (Get-Module -Name DnsLathund).Version | Should -Be ([version]'1.0.0')
    }

    It 'exports only functions that exist in Public and are listed in the manifest' {
        $module = Get-Module -Name DnsLathund
        $manifest = Import-PowerShellDataFile -Path "$PSScriptRoot\..\DnsLathund.psd1"
        foreach ($name in $module.ExportedFunctions.Keys) {
            $manifest.FunctionsToExport | Should -Contain $name
            Test-Path -LiteralPath "$PSScriptRoot\..\Public\$name.ps1" | Should -BeTrue
        }
    }

    It 'initialises the script-scope state' {
        InModuleScope DnsLathund {
            $script:ModuleRoot | Should -Not -BeNullOrEmpty
            $script:LanguageMode | Should -Be 'FullLanguage'
            $script:ZoneTableCache | Should -BeOfType [hashtable]
            $script:CimSessionCache | Should -BeOfType [hashtable]
            $script:SnapshotIndexCache | Should -BeOfType [hashtable]
            $script:DnsServerExportRoot | Should -BeLike '*\System32\dns'
        }
    }

    It 'does not export private helpers' {
        Get-Command -Name 'New-DnsObject' -Module DnsLathund -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'New-DnsObject' {
    It 'keeps the dictionary order of the properties' {
        InModuleScope DnsLathund {
            $dnsObject = New-DnsObject -TypeName 'Probe' -Property ([ordered]@{ Zeta = 1; Alpha = 2; Mid = 3 })
            ($dnsObject.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -Be 'Zeta,Alpha,Mid'
        }
    }

    It 'puts DnsLathund.<TypeName> first in TypeNames' {
        InModuleScope DnsLathund {
            $dnsObject = New-DnsObject -TypeName 'Probe' -Property ([ordered]@{ A = 1 })
            $dnsObject.PSObject.TypeNames[0] | Should -Be 'DnsLathund.Probe'
        }
    }

    It 'keeps $null and array values as they are' {
        InModuleScope DnsLathund {
            $dnsObject = New-DnsObject -TypeName 'Probe' -Property ([ordered]@{ Empty = $null; List = [string[]]@('a', 'b'); None = @() })
            $dnsObject.Empty | Should -BeNullOrEmpty
            $dnsObject.List.Count | Should -Be 2
            $dnsObject.None.Count | Should -Be 0
        }
    }
}

Describe 'Resolve-DnsServerName' {
    BeforeAll {
        $script:SavedLogonServer = $env:LOGONSERVER
    }

    AfterEach {
        $env:LOGONSERVER = $script:SavedLogonServer
    }

    It 'returns an explicit server name in lower case' {
        InModuleScope DnsLathund {
            Resolve-DnsServerName -Server ' DC01.Contoso.Local ' | Should -BeExactly 'dc01.contoso.local'
        }
    }

    It 'defaults to LOGONSERVER without the leading backslashes' {
        $env:LOGONSERVER = '\\DC02'
        InModuleScope DnsLathund {
            Resolve-DnsServerName | Should -BeExactly 'dc02'
        }
    }

    It 'throws with a hint when no server is given and LOGONSERVER is empty' {
        $env:LOGONSERVER = ''
        InModuleScope DnsLathund {
            { Resolve-DnsServerName } | Should -Throw 'No default DNS server (LOGONSERVER is not set). Specify -Server.'
        }
    }
}

Describe 'Import-DnsServerModule' {
    BeforeAll {
        Initialize-DnsStub -StubPath $script:StubPath -ExportRoot $TestDrive
    }

    BeforeEach {
        InModuleScope DnsLathund {
            $script:DnsServerModuleChecked = $false
        }
    }

    It 'accepts commands that are already resolvable (stubs) without importing' {
        InModuleScope DnsLathund {
            Mock Import-Module { }
            Import-DnsServerModule
            Should -Invoke Import-Module -Times 0 -Exactly
            $script:DnsServerModuleChecked | Should -BeTrue
        }
    }

    It 'throws with the RSAT install hint when DnsServer is missing' {
        InModuleScope DnsLathund {
            Mock Get-Command { } -ParameterFilter { $Name -eq 'Get-DnsServerResourceRecord' }
            Mock Import-Module { throw 'The specified module was not loaded.' } -ParameterFilter { $Name -eq 'DnsServer' }
            { Import-DnsServerModule } | Should -Throw '*Rsat.Dns.Tools~~~~0.0.1.0*Install-WindowsFeature RSAT-DNS-Server*'
            $script:DnsServerModuleChecked | Should -BeFalse
        }
    }

    It 'does nothing once the check has succeeded' {
        InModuleScope DnsLathund {
            $script:DnsServerModuleChecked = $true
            Mock Get-Command { }
            Import-DnsServerModule
            Should -Invoke Get-Command -Times 0 -Exactly
        }
    }
}

Describe 'Get-DnsCimSession' {
    BeforeEach {
        InModuleScope DnsLathund {
            $script:CimSessionCache = @{}
            Mock New-CimSessionOption { [string]$Protocol }
            Mock Remove-CimSession { } -RemoveParameterType CimSession
        }
    }

    It 'opens a WSMan session, verifies root\MicrosoftDNS and caches it' {
        InModuleScope DnsLathund {
            Mock New-CimSession { New-Object PSObject -Property @{ Protocol = $SessionOption } } -RemoveParameterType SessionOption
            Mock Get-CimInstance { } -RemoveParameterType CimSession
            $credential = New-Object System.Management.Automation.PSCredential ('CONTOSO\admin', (New-Object System.Security.SecureString))

            $session = Get-DnsCimSession -Server 'DC01' -Credential $credential
            $again = Get-DnsCimSession -Server 'dc01' -Credential $credential

            $session.Protocol | Should -Be 'Wsman'
            [object]::ReferenceEquals($session, $again) | Should -BeTrue
            Should -Invoke New-CimSession -Times 1 -Exactly
            Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $Namespace -eq 'root\MicrosoftDNS' -and $Query -like '*MicrosoftDNS_Server*' }
        }
    }

    It 'falls back to DCOM when WSMan cannot connect' {
        InModuleScope DnsLathund {
            Mock New-CimSession {
                if ($SessionOption -eq 'Wsman') {
                    throw 'WinRM cannot complete the operation.'
                }
                New-Object PSObject -Property @{ Protocol = $SessionOption }
            } -RemoveParameterType SessionOption
            Mock Get-CimInstance { } -RemoveParameterType CimSession

            (Get-DnsCimSession -Server 'dc01').Protocol | Should -Be 'Dcom'
            Should -Invoke New-CimSession -Times 2 -Exactly
        }
    }

    It 'closes a session that cannot read root\MicrosoftDNS and tries the next protocol' {
        InModuleScope DnsLathund {
            Mock New-CimSession { New-Object PSObject -Property @{ Protocol = $SessionOption } } -RemoveParameterType SessionOption
            Mock Get-CimInstance {
                if ($CimSession.Protocol -eq 'Wsman') {
                    throw 'Invalid namespace'
                }
            } -RemoveParameterType CimSession

            (Get-DnsCimSession -Server 'dc01').Protocol | Should -Be 'Dcom'
            Should -Invoke Remove-CimSession -Times 1 -Exactly
        }
    }

    It 'returns $null and caches Unavailable when no protocol works' {
        InModuleScope DnsLathund {
            Mock New-CimSession { throw 'The RPC server is unavailable.' } -RemoveParameterType SessionOption

            Get-DnsCimSession -Server 'dc01' | Should -BeNullOrEmpty
            $script:CimSessionCache['dc01'] | Should -Be 'Unavailable'
            Get-DnsCimSession -Server 'dc01' | Should -BeNullOrEmpty
            Should -Invoke New-CimSession -Times 2 -Exactly
        }
    }
}

Describe 'Get-DnsServerParameter' {
    It 'returns ComputerName without a credential and opens no session' {
        InModuleScope DnsLathund {
            Mock Get-DnsCimSession { 'unexpected' }
            $serverParameters = Get-DnsServerParameter -Server 'dc01'
            $serverParameters | Should -BeOfType [hashtable]
            @($serverParameters.Keys) | Should -Be @('ComputerName')
            $serverParameters['ComputerName'] | Should -Be 'dc01'
            Should -Invoke Get-DnsCimSession -Times 0 -Exactly
        }
    }

    It 'treats an explicit $null or empty credential as no credential' {
        InModuleScope DnsLathund {
            Mock Get-DnsCimSession { 'unexpected' }
            (Get-DnsServerParameter -Server 'dc01' -Credential $null).Keys | Should -Be 'ComputerName'
            (Get-DnsServerParameter -Server 'dc01' -Credential ([System.Management.Automation.PSCredential]::Empty)).Keys | Should -Be 'ComputerName'
            Should -Invoke Get-DnsCimSession -Times 0 -Exactly
        }
    }

    It 'returns the CIM session when a credential is given' {
        InModuleScope DnsLathund {
            Mock Get-DnsCimSession { 'fake-session' }
            $credential = New-Object System.Management.Automation.PSCredential ('CONTOSO\admin', (New-Object System.Security.SecureString))

            $serverParameters = Get-DnsServerParameter -Server 'dc01' -Credential $credential

            @($serverParameters.Keys) | Should -Be @('CimSession')
            $serverParameters['CimSession'] | Should -Be 'fake-session'
            Should -Invoke Get-DnsCimSession -Times 1 -Exactly -ParameterFilter { $Server -eq 'dc01' -and $Credential.UserName -eq 'CONTOSO\admin' }
        }
    }

    It 'throws instead of falling back to the logged-on user when no session can be opened' {
        InModuleScope DnsLathund {
            Mock Get-DnsCimSession { $null }
            $credential = New-Object System.Management.Automation.PSCredential ('CONTOSO\admin', (New-Object System.Security.SecureString))

            { Get-DnsServerParameter -Server 'dc01' -Credential $credential } | Should -Throw "Could not open a CIM session to 'dc01'*"
        }
    }
}

Describe 'ConvertTo-DnsNormalizedName' {
    It 'normalises <Name> to <Expected>' -TestCases @(
        @{ Name = 'SRV01.Contoso.LOCAL'; Expected = 'srv01.contoso.local' }
        @{ Name = 'srv01.contoso.local.'; Expected = 'srv01.contoso.local' }
        @{ Name = 'Print\040Server.contoso.local.'; Expected = 'print server.contoso.local' }
        @{ Name = 'iO\040Sense.pangkaka.com.'; Expected = 'io sense.pangkaka.com' }
        @{ Name = 'host\050a\051.contoso.local'; Expected = 'host(a).contoso.local' }
        @{ Name = 'back\134slash.contoso.local'; Expected = 'back\slash.contoso.local' }
        @{ Name = 'a\134040b.contoso.local'; Expected = 'a\040b.contoso.local' }
        @{ Name = 'k\345ken.contoso.local'; Expected = 'kåken.contoso.local' }
        @{ Name = 'a\400b.contoso.local'; Expected = 'a\400b.contoso.local' }
        @{ Name = 'a\089b.contoso.local'; Expected = 'a\089b.contoso.local' }
        @{ Name = 'a\xyz.contoso.local'; Expected = 'a\xyz.contoso.local' }
        @{ Name = 'a\04.contoso.local'; Expected = 'a\04.contoso.local' }
        @{ Name = '  srv01.contoso.local  '; Expected = 'srv01.contoso.local' }
        @{ Name = "`tsrv01.contoso.local.`r`n"; Expected = 'srv01.contoso.local' }
        @{ Name = '@'; Expected = '@' }
        @{ Name = ''; Expected = '' }
        @{ Name = '   '; Expected = '' }
    ) {
        InModuleScope DnsLathund -Parameters @{ Name = $Name; Expected = $Expected } {
            param ($Name, $Expected)
            ConvertTo-DnsNormalizedName -Name $Name | Should -BeExactly $Expected
        }
    }

    It 'decodes \DDD as octal, so \032 is character 26 and not a space' {
        InModuleScope DnsLathund {
            $normalized = ConvertTo-DnsNormalizedName -Name 'a\032b.contoso.local'
            $normalized | Should -BeExactly ('a' + [string][char]26 + 'b.contoso.local')
            $normalized | Should -Not -Match ' '
        }
    }

    It 'decodes the full octal range \000 to \377' {
        InModuleScope DnsLathund {
            [int][char](ConvertTo-DnsNormalizedName -Name 'x\000')[1] | Should -Be 0
            [int][char](ConvertTo-DnsNormalizedName -Name 'x\177')[1] | Should -Be 127
            [int][char](ConvertTo-DnsNormalizedName -Name 'x\377')[1] | Should -Be 255
        }
    }

    It 'accepts $null and returns an empty string' {
        InModuleScope DnsLathund {
            ConvertTo-DnsNormalizedName -Name $null | Should -BeExactly ''
        }
    }
}

Describe 'ConvertTo-DnsNormalizedAddress' {
    It 'normalises <Address> to <Expected>' -TestCases @(
        @{ Address = '10.0.16.5'; Expected = '10.0.16.5' }
        @{ Address = '010.0.0.1'; Expected = '10.0.0.1' }
        @{ Address = '010.000.016.005'; Expected = '10.0.16.5' }
        @{ Address = ' 10.0.16.5 '; Expected = '10.0.16.5' }
        @{ Address = '2001:0DB8:0000:0000:0000:0000:0000:0001'; Expected = '2001:db8::1' }
        @{ Address = 'FE80::1'; Expected = 'fe80::1' }
        @{ Address = 'fd00:0:0:0:0:0:0:5'; Expected = 'fd00::5' }
    ) {
        InModuleScope DnsLathund -Parameters @{ Address = $Address; Expected = $Expected } {
            param ($Address, $Expected)
            ConvertTo-DnsNormalizedAddress -Address $Address | Should -BeExactly $Expected
        }
    }

    It 'returns $null for <Address>' -TestCases @(
        @{ Address = 'srv01.contoso.local' }
        @{ Address = '256.1.1.1' }
        @{ Address = '10.0.0' }
        @{ Address = '10.1' }
        @{ Address = '12345' }
        @{ Address = '10.0.0.1.5' }
        @{ Address = '2001:db8::zz' }
        @{ Address = '' }
    ) {
        InModuleScope DnsLathund -Parameters @{ Address = $Address } {
            param ($Address)
            ConvertTo-DnsNormalizedAddress -Address $Address | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-DnsReverseName' {
    It 'builds the in-addr.arpa name of an IPv4 address' {
        InModuleScope DnsLathund {
            $reverse = ConvertTo-DnsReverseName -Address '010.000.016.005'
            $reverse | Should -BeOfType [hashtable]
            $reverse.Address | Should -Be '10.0.16.5'
            $reverse.Family | Should -Be 'IPv4'
            $reverse.ReverseName | Should -BeExactly '5.16.0.10.in-addr.arpa'
        }
    }

    It 'builds the 32-nibble ip6.arpa name of an IPv6 address' {
        InModuleScope DnsLathund {
            $reverse = ConvertTo-DnsReverseName -Address '2001:DB8::1'
            $reverse.Address | Should -Be '2001:db8::1'
            $reverse.Family | Should -Be 'IPv6'
            $reverse.ReverseName | Should -BeExactly '1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa'
            ($reverse.ReverseName -replace '\.ip6\.arpa$', '').Split('.').Count | Should -Be 32
        }
    }

    It 'returns $null for something that is not an address' {
        InModuleScope DnsLathund {
            ConvertTo-DnsReverseName -Address 'srv01' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-DnsReverseNodeName' {
    It 'returns <Expected> for <ReverseName> in <ZoneName>' -TestCases @(
        @{ ReverseName = '5.16.0.10.in-addr.arpa'; ZoneName = '16.0.10.in-addr.arpa'; Classless = $false; Expected = '5' }
        @{ ReverseName = '5.16.0.10.in-addr.arpa'; ZoneName = '0.10.in-addr.arpa'; Classless = $false; Expected = '5.16' }
        @{ ReverseName = '5.16.0.10.IN-ADDR.ARPA.'; ZoneName = '16.0.10.in-addr.arpa.'; Classless = $false; Expected = '5' }
        @{ ReverseName = '16.0.10.in-addr.arpa'; ZoneName = '16.0.10.in-addr.arpa'; Classless = $false; Expected = '@' }
        @{ ReverseName = '5.16.0.10.in-addr.arpa'; ZoneName = '0/25.16.0.10.in-addr.arpa'; Classless = $true; Expected = '5' }
        @{ ReverseName = '5.0/25.16.0.10.in-addr.arpa'; ZoneName = '0/25.16.0.10.in-addr.arpa'; Classless = $false; Expected = '5' }
        @{ ReverseName = '70.16.0.10.in-addr.arpa'; ZoneName = '64-127.16.0.10.in-addr.arpa'; Classless = $true; Expected = '70' }
        @{ ReverseName = '45.18.0.10.in-addr.arpa'; ZoneName = '40-50.18.0.10.in-addr.arpa'; Classless = $true; Expected = '45' }
        @{ ReverseName = '15.25.0.10.in-addr.arpa'; ZoneName = '10-20.25.0.10.in-addr.arpa'; Classless = $true; Expected = '15' }
        @{ ReverseName = '5.19.0.10.in-addr.arpa'; ZoneName = '5/32.19.0.10.in-addr.arpa'; Classless = $true; Expected = '5' }
        @{ ReverseName = '70.64-127.16.0.10.in-addr.arpa'; ZoneName = '64-127.16.0.10.in-addr.arpa'; Classless = $false; Expected = '70' }
        @{ ReverseName = '1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa'; ZoneName = '8.b.d.0.1.0.0.2.ip6.arpa'; Classless = $false; Expected = '1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0' }
    ) {
        InModuleScope DnsLathund -Parameters @{ ReverseName = $ReverseName; ZoneName = $ZoneName; Classless = $Classless; Expected = $Expected } {
            param ($ReverseName, $ZoneName, $Classless, $Expected)
            Get-DnsReverseNodeName -ReverseName $ReverseName -ZoneName $ZoneName -ClasslessHostLabel:$Classless | Should -BeExactly $Expected
        }
    }

    It 'returns $null when the name is not in the zone' {
        InModuleScope DnsLathund {
            Get-DnsReverseNodeName -ReverseName '5.17.0.10.in-addr.arpa' -ZoneName '16.0.10.in-addr.arpa' | Should -BeNullOrEmpty
            Get-DnsReverseNodeName -ReverseName '5.17.0.10.in-addr.arpa' -ZoneName '0/25.16.0.10.in-addr.arpa' -ClasslessHostLabel | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-DnsAddressInNetwork' {
    It '<Address> in <Network> is <Expected>' -TestCases @(
        @{ Address = '10.0.50.17'; Network = @('10.0.50.0/24'); Expected = $true }
        @{ Address = '10.0.51.17'; Network = @('10.0.50.0/24'); Expected = $false }
        @{ Address = '10.0.16.127'; Network = @('10.0.16.0/25'); Expected = $true }
        @{ Address = '10.0.16.128'; Network = @('10.0.16.0/25'); Expected = $false }
        @{ Address = '10.0.16.5'; Network = @('10.0.16.5/32'); Expected = $true }
        @{ Address = '10.0.16.5'; Network = @('10.0.16.5'); Expected = $true }
        @{ Address = '10.0.16.6'; Network = @('10.0.16.5'); Expected = $false }
        @{ Address = '192.168.1.1'; Network = @('0.0.0.0/0'); Expected = $true }
        @{ Address = '10.0.50.17'; Network = @('10.0.50.7/24'); Expected = $true }
        @{ Address = '10.0.60.1'; Network = @('10.0.50.0/24', '10.0.60.0/24'); Expected = $true }
        @{ Address = 'fd00::1'; Network = @('fd00::/8'); Expected = $true }
        @{ Address = '2001:db8::1'; Network = @('fd00::/8'); Expected = $false }
        @{ Address = '2001:db8::1'; Network = @('2001:db8::/32'); Expected = $true }
        @{ Address = '2001:db9::1'; Network = @('2001:db8::/32'); Expected = $false }
        @{ Address = '2001:db8::1'; Network = @('2001:db8::1/128'); Expected = $true }
        @{ Address = 'fd00::1'; Network = @('10.0.0.0/8'); Expected = $false }
        @{ Address = '10.0.0.1'; Network = @('::/0'); Expected = $false }
        @{ Address = 'srv01'; Network = @('10.0.0.0/8'); Expected = $false }
    ) {
        InModuleScope DnsLathund -Parameters @{ Address = $Address; Network = $Network; Expected = $Expected } {
            param ($Address, $Network, $Expected)
            Test-DnsAddressInNetwork -Address $Address -Network $Network | Should -Be $Expected
        }
    }

    It 'warns about the invalid entry <Network> and treats it as no match' -TestCases @(
        @{ Network = '10.0.0.0/33' }
        @{ Network = 'fd00::/129' }
        @{ Network = '10.0.0.0/x' }
        @{ Network = 'garbage' }
        @{ Network = '10.0.0/8' }
    ) {
        InModuleScope DnsLathund -Parameters @{ Network = $Network } {
            param ($Network)
            $result = Test-DnsAddressInNetwork -Address '10.0.0.1' -Network $Network -WarningVariable warnings -WarningAction SilentlyContinue
            $result | Should -BeFalse
            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike "*'$Network'*"
        }
    }

    It 'still matches valid entries and warns once per distinct invalid entry' {
        InModuleScope DnsLathund {
            $networks = @('bad', '10.0.0.0/8', 'bad', 'worse/99')
            $result = Test-DnsAddressInNetwork -Address '10.1.2.3' -Network $networks -WarningVariable warnings -WarningAction SilentlyContinue
            $result | Should -BeTrue
            @($warnings).Count | Should -Be 2
        }
    }
}

Describe 'Get-DnsZoneTable' {
    BeforeEach {
        Initialize-DnsStub -StubPath $script:StubPath -ExportRoot $TestDrive
    }

    It 'returns a DnsLathund.ZoneTable for the lower-case server name' {
        InModuleScope DnsLathund {
            $zoneTable = Get-DnsZoneTable -Server 'DC01'
            $zoneTable.PSObject.TypeNames[0] | Should -Be 'DnsLathund.ZoneTable'
            $zoneTable.Server | Should -BeExactly 'dc01'
            $zoneTable.RetrievedAt | Should -BeOfType [datetime]
            ($zoneTable.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' |
                Should -Be 'Server,RetrievedAt,Zones,ZoneLookup,ForwardZones,ReverseZones,ClasslessZones,ServerScavenging'
        }
    }

    It 'builds one ZoneInfo per zone with the contract property order' {
        InModuleScope DnsLathund {
            $zoneTable = Get-DnsZoneTable -Server 'dc01'
            $zoneTable.Zones.Count | Should -Be 12
            foreach ($zoneInfo in $zoneTable.Zones) {
                $zoneInfo.PSObject.TypeNames[0] | Should -Be 'DnsLathund.ZoneInfo'
                ($zoneInfo.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' |
                    Should -Be 'ZoneName,IsReverse,ZoneType,IsDsIntegrated,ReplicationScope,DirectoryPartitionName,DynamicUpdate,IsAutoCreated,IsReadOnly,IsExportable,AgingEnabled,NoRefreshInterval,RefreshInterval,ScavengeServers,IsClassless,ClasslessNetwork,ClasslessHostRange'
                $zoneTable.ZoneLookup[$zoneInfo.ZoneName] | Should -Be $zoneInfo
            }
        }
    }

    It 'normalises zone names and splits forward and reverse zones' {
        InModuleScope DnsLathund {
            $zoneTable = Get-DnsZoneTable -Server 'dc01'
            $zoneTable.ZoneLookup.ContainsKey('contoso.local') | Should -BeTrue
            , $zoneTable.ForwardZones | Should -BeOfType [string[]]
            , $zoneTable.ReverseZones | Should -BeOfType [string[]]

            $expectedForward = @('contoso.local', 'lab.contoso.local', 'trustanchors', 'fabrikam.com', 'partner.example')
            $expectedReverse = @(
                '16.0.10.in-addr.arpa', '10.in-addr.arpa', '0/25.16.0.10.in-addr.arpa', '64-26.16.0.10.in-addr.arpa',
                '0-127.17.0.10.in-addr.arpa', '8.b.d.0.1.0.0.2.ip6.arpa', '0.in-addr.arpa'
            )
            $zoneTable.ForwardZones.Count | Should -Be $expectedForward.Count
            $zoneTable.ReverseZones.Count | Should -Be $expectedReverse.Count
            foreach ($zoneName in $expectedForward) {
                $zoneTable.ForwardZones | Should -Contain $zoneName
            }
            foreach ($zoneName in $expectedReverse) {
                $zoneTable.ReverseZones | Should -Contain $zoneName
            }
        }
    }

    It 'classifies a primary AD-integrated zone with aging' {
        InModuleScope DnsLathund {
            $zoneInfo = (Get-DnsZoneTable -Server 'dc01').ZoneLookup['contoso.local']
            $zoneInfo.IsReverse | Should -BeFalse
            $zoneInfo.ZoneType | Should -Be 'Primary'
            $zoneInfo.IsDsIntegrated | Should -BeTrue
            $zoneInfo.ReplicationScope | Should -Be 'Domain'
            $zoneInfo.DirectoryPartitionName | Should -Be 'DomainDnsZones.contoso.local'
            $zoneInfo.DynamicUpdate | Should -Be 'Secure'
            $zoneInfo.IsReadOnly | Should -BeFalse
            $zoneInfo.IsExportable | Should -BeTrue
            $zoneInfo.AgingEnabled | Should -BeTrue
            $zoneInfo.NoRefreshInterval | Should -Be (New-TimeSpan -Days 3)
            $zoneInfo.RefreshInterval | Should -Be (New-TimeSpan -Days 4)
            $zoneInfo.ScavengeServers | Should -Be @('10.0.16.10')
            $zoneInfo.IsClassless | Should -BeFalse
            $zoneInfo.ClasslessNetwork | Should -BeNullOrEmpty
            $zoneInfo.ClasslessHostRange | Should -BeNullOrEmpty
        }
    }

    It 'marks <ZoneName> read-only <IsReadOnly> and exportable <IsExportable>' -TestCases @(
        @{ ZoneName = 'contoso.local'; IsReadOnly = $false; IsExportable = $true }
        @{ ZoneName = '0.in-addr.arpa'; IsReadOnly = $true; IsExportable = $false }
        @{ ZoneName = 'trustanchors'; IsReadOnly = $false; IsExportable = $false }
        @{ ZoneName = 'fabrikam.com'; IsReadOnly = $true; IsExportable = $false }
        @{ ZoneName = 'partner.example'; IsReadOnly = $true; IsExportable = $false }
    ) {
        InModuleScope DnsLathund -Parameters @{ ZoneName = $ZoneName; IsReadOnly = $IsReadOnly; IsExportable = $IsExportable } {
            param ($ZoneName, $IsReadOnly, $IsExportable)
            $zoneInfo = (Get-DnsZoneTable -Server 'dc01').ZoneLookup[$ZoneName]
            $zoneInfo.IsReadOnly | Should -Be $IsReadOnly
            $zoneInfo.IsExportable | Should -Be $IsExportable
        }
    }

    It 'reads aging once per exportable zone only and leaves the others $null' {
        InModuleScope DnsLathund {
            $zoneTable = Get-DnsZoneTable -Server 'dc01'
            $exportable = @($zoneTable.Zones | Where-Object { $_.IsExportable })
            $script:DnsStub.Calls['Get-DnsServerZoneAging'] | Should -Be $exportable.Count
            $zoneTable.ZoneLookup['fabrikam.com'].AgingEnabled | Should -BeNullOrEmpty
            $zoneTable.ZoneLookup['0.in-addr.arpa'].RefreshInterval | Should -BeNullOrEmpty
        }
    }

    It 'reads properties defensively (a forwarder has no DynamicUpdate)' {
        InModuleScope DnsLathund {
            $zoneInfo = (Get-DnsZoneTable -Server 'dc01').ZoneLookup['partner.example']
            $zoneInfo.ZoneType | Should -Be 'Forwarder'
            $zoneInfo.DynamicUpdate | Should -BeNullOrEmpty
        }
    }

    It 'detects classless zone <ZoneName> (<Form>) as <Network> covering <First>-<Last>' -TestCases @(
        @{ ZoneName = '0/25.16.0.10.in-addr.arpa'; Form = 'prefix, slash'; Network = '10.0.16.0/25'; First = 0; Last = 127 }
        @{ ZoneName = '64-26.16.0.10.in-addr.arpa'; Form = 'prefix, hyphen'; Network = '10.0.16.64/26'; First = 64; Last = 127 }
        @{ ZoneName = '0-25.21.0.10.in-addr.arpa'; Form = 'prefix 25, hyphen'; Network = '10.0.21.0/25'; First = 0; Last = 127 }
        @{ ZoneName = '5/32.19.0.10.in-addr.arpa'; Form = 'prefix 32, single host'; Network = '10.0.19.5/32'; First = 5; Last = 5 }
        @{ ZoneName = '0-127.17.0.10.in-addr.arpa'; Form = 'range, aligned'; Network = '10.0.17.0/25'; First = 0; Last = 127 }
        @{ ZoneName = '64-127.22.0.10.in-addr.arpa'; Form = 'range, aligned'; Network = '10.0.22.64/26'; First = 64; Last = 127 }
        @{ ZoneName = '128-255.22.0.10.in-addr.arpa'; Form = 'range, aligned'; Network = '10.0.22.128/25'; First = 128; Last = 255 }
        @{ ZoneName = '40-50.18.0.10.in-addr.arpa'; Form = 'range, not a block'; Network = '10.0.18.40-50'; First = 40; Last = 50 }
        @{ ZoneName = '64-191.23.0.10.in-addr.arpa'; Form = 'range, block not aligned'; Network = '10.0.23.64-191'; First = 64; Last = 191 }
        @{ ZoneName = '64/25.24.0.10.in-addr.arpa'; Form = 'prefix, not aligned'; Network = '10.0.24.64-191'; First = 64; Last = 191 }
        @{ ZoneName = '10-20.25.0.10.in-addr.arpa'; Form = 'range, last host below 25'; Network = '10.0.25.10-20'; First = 10; Last = 20 }
        @{ ZoneName = '0-24.25.0.10.in-addr.arpa'; Form = 'range, last host below 25'; Network = '10.0.25.0-24'; First = 0; Last = 24 }
        @{ ZoneName = '8-15.25.0.10.in-addr.arpa'; Form = 'range, small aligned block'; Network = '10.0.25.8/29'; First = 8; Last = 15 }
        @{ ZoneName = '7-7.25.0.10.in-addr.arpa'; Form = 'range, single host'; Network = '10.0.25.7/32'; First = 7; Last = 7 }
        @{ ZoneName = '0-26.26.0.10.in-addr.arpa'; Form = 'hyphen 25-32 reads as prefix'; Network = '10.0.26.0/26'; First = 0; Last = 63 }
        @{ ZoneName = '0-31.27.0.10.in-addr.arpa'; Form = 'hyphen 25-32 reads as prefix'; Network = '10.0.27.0/31'; First = 0; Last = 1 }
    ) {
        InModuleScope DnsLathund -Parameters @{ ZoneName = $ZoneName; Network = $Network; First = $First; Last = $Last } {
            param ($ZoneName, $Network, $First, $Last)
            if ($null -eq $script:DnsStub.Zones[$ZoneName]) {
                Add-DnsStubZone -Name $ZoneName
            }

            $zoneTable = Get-DnsZoneTable -Server 'dc01'
            $zoneInfo = $zoneTable.ZoneLookup[$ZoneName]
            $zoneInfo.IsReverse | Should -BeTrue
            $zoneInfo.IsClassless | Should -BeTrue
            $zoneInfo.ClasslessNetwork | Should -BeExactly $Network
            $zoneInfo.ClasslessHostRange | Should -Be @($First, $Last)
            $zoneTable.ClasslessZones.ZoneName | Should -Contain $ZoneName
        }
    }

    It 'treats <ZoneName> (<Reason>) as an ordinary reverse zone' -TestCases @(
        @{ ZoneName = '100-64.20.0.10.in-addr.arpa'; Reason = 'last host below first' }
        @{ ZoneName = '64-300.20.0.10.in-addr.arpa'; Reason = 'last host above 255' }
        @{ ZoneName = '300-310.20.0.10.in-addr.arpa'; Reason = 'first host above 255' }
        @{ ZoneName = '200/25.20.0.10.in-addr.arpa'; Reason = 'prefix block runs past 255' }
        @{ ZoneName = '20-10.20.0.10.in-addr.arpa'; Reason = 'range below 25 with last host below first' }
        @{ ZoneName = '0/16.20.0.10.in-addr.arpa'; Reason = 'slash prefix shorter than 25' }
        @{ ZoneName = '0/40.20.0.10.in-addr.arpa'; Reason = 'slash form is never a range' }
        @{ ZoneName = '0/127.20.0.10.in-addr.arpa'; Reason = 'slash form is never a range' }
        @{ ZoneName = '0-99999999999.20.0.10.in-addr.arpa'; Reason = 'number too large for an integer' }
    ) {
        InModuleScope DnsLathund -Parameters @{ ZoneName = $ZoneName } {
            param ($ZoneName)
            Add-DnsStubZone -Name $ZoneName

            $zoneTable = Get-DnsZoneTable -Server 'dc01'
            $zoneInfo = $zoneTable.ZoneLookup[$ZoneName]
            $zoneInfo.IsReverse | Should -BeTrue
            $zoneInfo.IsClassless | Should -BeFalse
            $zoneInfo.ClasslessNetwork | Should -BeNullOrEmpty
            $zoneInfo.ClasslessHostRange | Should -BeNullOrEmpty
            $zoneTable.ClasslessZones.ZoneName | Should -Not -Contain $ZoneName
        }
    }

    It 'writes the both-readings Verbose line only for a hyphen with 25-32 that is also a valid range' {
        InModuleScope DnsLathund {
            Add-DnsStubZone -Name '0-31.27.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '0-26.26.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '10-20.25.0.10.in-addr.arpa'
            Add-DnsStubZone -Name '5/32.19.0.10.in-addr.arpa'

            $output = Get-DnsZoneTable -Server 'dc01' -Verbose 4>&1
            $ambiguity = @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -and $_.Message -like '*could also mean the host range*' })

            # Silent: 0/25 and 5/32 (slash), 0-127 and 10-20 (range), 64-26 (26 < 64, no valid range reading).
            ($ambiguity | ForEach-Object { $_.Message }) -join "`n" | Should -BeExactly (@(
                    "Zone '0-31.27.0.10.in-addr.arpa': '0-31' was read as prefix /31 (hosts 0-1); it could also mean the host range 0-31."
                    "Zone '0-26.26.0.10.in-addr.arpa': '0-26' was read as prefix /26 (hosts 0-63); it could also mean the host range 0-26."
                ) -join "`n")
        }
    }

    It 'lists every classless zone in ClasslessZones' {
        InModuleScope DnsLathund {
            $zoneTable = Get-DnsZoneTable -Server 'dc01'
            ($zoneTable.ClasslessZones | ForEach-Object { $_.ZoneName }) -join ',' |
                Should -Be '0/25.16.0.10.in-addr.arpa,64-26.16.0.10.in-addr.arpa,0-127.17.0.10.in-addr.arpa'
        }
    }

    It 'returns the server scavenging settings' {
        InModuleScope DnsLathund {
            $scavenging = (Get-DnsZoneTable -Server 'dc01').ServerScavenging
            $scavenging.PSObject.TypeNames[0] | Should -Be 'DnsLathund.ServerScavenging'
            $scavenging.ScavengingState | Should -BeTrue
            $scavenging.ScavengingInterval | Should -Be (New-TimeSpan -Days 7)
            $scavenging.LastScavengeTime | Should -BeOfType [datetime]
        }
    }

    It 'caches the table per server, case-insensitively' {
        InModuleScope DnsLathund {
            $first = Get-DnsZoneTable -Server 'dc01'
            $second = Get-DnsZoneTable -Server 'DC01'
            [object]::ReferenceEquals($first, $second) | Should -BeTrue
            $script:DnsStub.Calls['Get-DnsServerZone'] | Should -Be 1
            $script:ZoneTableCache.ContainsKey('dc01') | Should -BeTrue
        }
    }

    It 'reads the zones again with -Refresh' {
        InModuleScope DnsLathund {
            $first = Get-DnsZoneTable -Server 'dc01'
            Add-DnsStubZone -Name 'new.contoso.local'
            $second = Get-DnsZoneTable -Server 'dc01' -Refresh
            [object]::ReferenceEquals($first, $second) | Should -BeFalse
            $script:DnsStub.Calls['Get-DnsServerZone'] | Should -Be 2
            $second.ZoneLookup.ContainsKey('new.contoso.local') | Should -BeTrue
            [object]::ReferenceEquals($script:ZoneTableCache['dc01'], $second) | Should -BeTrue
        }
    }

    It 'tolerates a failing aging query (fields $null, one Verbose line, no error)' {
        InModuleScope DnsLathund {
            $script:DnsStub.Fail['Get-DnsServerZoneAging'] = @('contoso.local')
            $output = Get-DnsZoneTable -Server 'dc01' -Verbose -WarningVariable warnings 4>&1 2>&1
            $zoneTable = $output | Where-Object { $_.PSObject.TypeNames[0] -eq 'DnsLathund.ZoneTable' }
            $verbose = @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -and $_.Message -like "Could not read aging settings of 'contoso.local'*" })
            $errors = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })

            $verbose.Count | Should -Be 1
            $errors.Count | Should -Be 0
            @($warnings).Count | Should -Be 0
            $zoneTable.ZoneLookup['contoso.local'].AgingEnabled | Should -BeNullOrEmpty
            $zoneTable.ZoneLookup['contoso.local'].NoRefreshInterval | Should -BeNullOrEmpty
            $zoneTable.ZoneLookup['contoso.local'].ScavengeServers | Should -BeNullOrEmpty
            $zoneTable.ZoneLookup['lab.contoso.local'].AgingEnabled | Should -BeFalse
            $zoneTable.ZoneLookup['lab.contoso.local'].RefreshInterval | Should -Be (New-TimeSpan -Days 7)
        }
    }

    It 'tolerates a failing scavenging query (ServerScavenging $null and a warning)' {
        InModuleScope DnsLathund {
            $script:DnsStub.Fail['Get-DnsServerScavenging'] = @('*')
            $zoneTable = Get-DnsZoneTable -Server 'dc01' -WarningVariable warnings -WarningAction SilentlyContinue
            $zoneTable.ServerScavenging | Should -BeNullOrEmpty
            $zoneTable.Zones.Count | Should -Be 12
            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike "*scavenging settings of 'dc01'*"
        }
    }

    It 'throws with a hint when the zone list cannot be read' {
        InModuleScope DnsLathund {
            $script:DnsStub.Fail['Get-DnsServerZone'] = @('*')
            { Get-DnsZoneTable -Server 'dc01' } | Should -Throw "Could not read the zone list from 'dc01'*Specify another -Server."
            $script:ZoneTableCache.ContainsKey('dc01') | Should -BeFalse
        }
    }

    It 'goes through Get-DnsServerParameter with the credential' {
        InModuleScope DnsLathund {
            Mock Get-DnsCimSession { 'fake-session' }
            $credential = New-Object System.Management.Automation.PSCredential ('CONTOSO\admin', (New-Object System.Security.SecureString))
            $zoneTable = Get-DnsZoneTable -Server 'dc01' -Credential $credential
            $zoneTable.Zones.Count | Should -Be 12
            Should -Invoke Get-DnsCimSession -Times 1 -Exactly
        }
    }
}

Describe 'Find-DnsZoneForName' {
    BeforeAll {
        Initialize-DnsStub -StubPath $script:StubPath -ExportRoot $TestDrive
    }

    It 'finds <Expected> for <Name> (Reverse: <Reverse>)' -TestCases @(
        @{ Name = 'test01.lab.contoso.local'; Reverse = $false; Expected = 'lab.contoso.local,contoso.local' }
        @{ Name = 'SRV01.Contoso.Local.'; Reverse = $false; Expected = 'contoso.local' }
        @{ Name = 'contoso.local'; Reverse = $false; Expected = 'contoso.local' }
        @{ Name = 'srv01.fabrikam.org'; Reverse = $false; Expected = '' }
        @{ Name = '5.16.0.10.in-addr.arpa'; Reverse = $true; Expected = '0/25.16.0.10.in-addr.arpa,16.0.10.in-addr.arpa,10.in-addr.arpa' }
        @{ Name = '70.16.0.10.in-addr.arpa'; Reverse = $true; Expected = '64-26.16.0.10.in-addr.arpa,0/25.16.0.10.in-addr.arpa,16.0.10.in-addr.arpa,10.in-addr.arpa' }
        @{ Name = '200.16.0.10.in-addr.arpa'; Reverse = $true; Expected = '16.0.10.in-addr.arpa,10.in-addr.arpa' }
        @{ Name = '5.16.0.10.in-addr.arpa'; Reverse = $false; Expected = '16.0.10.in-addr.arpa,10.in-addr.arpa' }
        @{ Name = '5.0/25.16.0.10.in-addr.arpa'; Reverse = $true; Expected = '0/25.16.0.10.in-addr.arpa,16.0.10.in-addr.arpa,10.in-addr.arpa' }
        @{ Name = '5.17.0.10.in-addr.arpa'; Reverse = $true; Expected = '0-127.17.0.10.in-addr.arpa,10.in-addr.arpa' }
        @{ Name = '128.17.0.10.in-addr.arpa'; Reverse = $true; Expected = '10.in-addr.arpa' }
        @{ Name = '1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa'; Reverse = $true; Expected = '8.b.d.0.1.0.0.2.ip6.arpa' }
        @{ Name = '9.9.9.9.in-addr.arpa'; Reverse = $true; Expected = '' }
    ) {
        InModuleScope DnsLathund -Parameters @{ Name = $Name; Reverse = $Reverse; Expected = $Expected } {
            param ($Name, $Reverse, $Expected)
            $zoneTable = Get-DnsZoneTable -Server 'dc01'
            $zones = @(Find-DnsZoneForName -Name $Name -ZoneTable $zoneTable -Reverse:$Reverse)
            $zones -join ',' | Should -BeExactly $Expected
        }
    }

    It 'returns nothing (an empty array with @()) when no zone matches' {
        InModuleScope DnsLathund {
            $zoneTable = Get-DnsZoneTable -Server 'dc01'
            @(Find-DnsZoneForName -Name 'host.example.org' -ZoneTable $zoneTable).Count | Should -Be 0
        }
    }

    Context 'overlapping classless zones' {
        BeforeAll {
            # Zone table order: 0/25 (0-127), 64-26 (64-127), then 64-127 (64-127, a tie
            # with 64-26) and 70/32 (70 only). The larger zones come first on purpose.
            Initialize-DnsStub -StubPath $script:StubPath -ExportRoot $TestDrive
            InModuleScope DnsLathund {
                Add-DnsStubZone -Name '64-127.16.0.10.in-addr.arpa'
                Add-DnsStubZone -Name '70/32.16.0.10.in-addr.arpa'
            }
        }

        It 'orders <Name> smallest host range first, ties in zone table order' -TestCases @(
            @{ Name = '70.16.0.10.in-addr.arpa'; Expected = '70/32.16.0.10.in-addr.arpa,64-26.16.0.10.in-addr.arpa,64-127.16.0.10.in-addr.arpa,0/25.16.0.10.in-addr.arpa,16.0.10.in-addr.arpa,10.in-addr.arpa' }
            @{ Name = '71.16.0.10.in-addr.arpa'; Expected = '64-26.16.0.10.in-addr.arpa,64-127.16.0.10.in-addr.arpa,0/25.16.0.10.in-addr.arpa,16.0.10.in-addr.arpa,10.in-addr.arpa' }
            @{ Name = '63.16.0.10.in-addr.arpa'; Expected = '0/25.16.0.10.in-addr.arpa,16.0.10.in-addr.arpa,10.in-addr.arpa' }
        ) {
            InModuleScope DnsLathund -Parameters @{ Name = $Name; Expected = $Expected } {
                param ($Name, $Expected)
                $zoneTable = Get-DnsZoneTable -Server 'dc01'
                @(Find-DnsZoneForName -Name $Name -ZoneTable $zoneTable -Reverse) -join ',' | Should -BeExactly $Expected
            }
        }
    }
}

Describe 'Confirm-DnsAction' {
    BeforeEach {
        InModuleScope DnsLathund {
            Mock Write-Host { }
        }
    }

    It 'rule 1: under -WhatIf prints the What if line and returns $false, even with -Force' {
        InModuleScope DnsLathund {
            Mock Read-Host { 'y' }
            $WhatIfPreference = $true
            $state = @{ All = $true }

            Confirm-DnsAction -Target 'srv01.contoso.local' -Action 'Remove A record' -Impact High -State $state -Force | Should -BeFalse

            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq 'What if: Performing the operation "Remove A record" on target "srv01.contoso.local".' }
            Should -Invoke Read-Host -Times 0 -Exactly
        }
    }

    It 'rule 2: -Force returns $true without prompting' {
        InModuleScope DnsLathund {
            Mock Read-Host { 'n' }
            $ConfirmPreference = 'Low'
            Confirm-DnsAction -Target 't' -Action 'a' -Impact High -State @{ All = $false } -Force | Should -BeTrue
            Should -Invoke Read-Host -Times 0 -Exactly
        }
    }

    It 'rule 2: State.All returns $true without prompting' {
        InModuleScope DnsLathund {
            Mock Read-Host { 'n' }
            $ConfirmPreference = 'Low'
            Confirm-DnsAction -Target 't' -Action 'a' -Impact High -State @{ All = $true } | Should -BeTrue
            Should -Invoke Read-Host -Times 0 -Exactly
        }
    }

    It 'rule 3: ConfirmPreference <Preference> and impact <Impact> prompts: <Prompts>' -TestCases @(
        @{ Preference = 'High'; Impact = 'High'; Prompts = $true }
        @{ Preference = 'High'; Impact = 'Medium'; Prompts = $false }
        @{ Preference = 'High'; Impact = 'Low'; Prompts = $false }
        @{ Preference = 'Medium'; Impact = 'High'; Prompts = $true }
        @{ Preference = 'Medium'; Impact = 'Medium'; Prompts = $true }
        @{ Preference = 'Medium'; Impact = 'Low'; Prompts = $false }
        @{ Preference = 'Low'; Impact = 'Low'; Prompts = $true }
        @{ Preference = 'None'; Impact = 'High'; Prompts = $false }
    ) {
        InModuleScope DnsLathund -Parameters @{ Preference = $Preference; Impact = $Impact; Prompts = $Prompts } {
            param ($Preference, $Impact, $Prompts)
            Mock Read-Host { 'n' }
            $ConfirmPreference = $Preference

            $result = Confirm-DnsAction -Target 't' -Action 'a' -Impact $Impact -State @{ All = $false }

            if ($Prompts) {
                Should -Invoke Read-Host -Times 1 -Exactly
                $result | Should -BeFalse
            }
            else {
                Should -Invoke Read-Host -Times 0 -Exactly
                $result | Should -BeTrue
            }
        }
    }

    It 'rule 4: shows the action and target in the prompt' {
        InModuleScope DnsLathund {
            Mock Read-Host { 'y' }
            $ConfirmPreference = 'High'
            Confirm-DnsAction -Target 'srv01.contoso.local' -Action 'Remove A record' -Impact High -State @{ All = $false } | Should -BeTrue
            Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter {
                $Prompt -eq "Remove A record`n  srv01.contoso.local`n[Y] Yes  [N] No  [A] Yes to all  [S] Stop (default is N)"
            }
        }
    }

    It 'rule 4: answer <Answer> returns <Expected>' -TestCases @(
        @{ Answer = 'y'; Expected = $true }
        @{ Answer = 'YES'; Expected = $true }
        @{ Answer = ' Y '; Expected = $true }
        @{ Answer = 'n'; Expected = $false }
        @{ Answer = ''; Expected = $false }
        @{ Answer = 'maybe'; Expected = $false }
    ) {
        InModuleScope DnsLathund -Parameters @{ Answer = $Answer; Expected = $Expected } {
            param ($Answer, $Expected)
            $script:FoundationTestAnswer = $Answer
            Mock Read-Host { $script:FoundationTestAnswer }
            $ConfirmPreference = 'High'
            Confirm-DnsAction -Target 't' -Action 'a' -Impact High -State @{ All = $false } | Should -Be $Expected
        }
    }

    It 'rule 4: "a" sets State.All so later calls do not prompt' {
        InModuleScope DnsLathund {
            Mock Read-Host { 'A' }
            $ConfirmPreference = 'High'
            $state = @{ All = $false }

            Confirm-DnsAction -Target 'first' -Action 'a' -Impact High -State $state | Should -BeTrue
            $state.All | Should -BeTrue
            Confirm-DnsAction -Target 'second' -Action 'a' -Impact High -State $state | Should -BeTrue

            Should -Invoke Read-Host -Times 1 -Exactly
        }
    }

    It 'rule 4: "s" throws "Operation stopped by the operator."' {
        InModuleScope DnsLathund {
            Mock Read-Host { 'stop' }
            $ConfirmPreference = 'High'
            { Confirm-DnsAction -Target 't' -Action 'a' -Impact High -State @{ All = $false } } | Should -Throw 'Operation stopped by the operator.'
        }
    }

    It 'rule 5: a host that cannot prompt gives a NonInteractive error and $false' {
        InModuleScope DnsLathund {
            Mock Read-Host { throw 'PowerShell is in NonInteractive mode. Read and Prompt functionality is not available.' }
            $ConfirmPreference = 'High'

            $result = Confirm-DnsAction -Target 'srv01' -Action 'a' -Impact High -State @{ All = $false } -ErrorVariable errors -ErrorAction SilentlyContinue

            $result | Should -BeFalse
            # -ErrorVariable also collects the exception thrown by Read-Host and caught inside.
            $nonInteractive = @($errors | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -and $_.FullyQualifiedErrorId -like 'DnsLathund.Confirm.NonInteractive*' })
            $nonInteractive.Count | Should -Be 1
            $nonInteractive[0].CategoryInfo.Category | Should -Be 'InvalidOperation'
            $nonInteractive[0].Exception.Message | Should -Be 'This session cannot prompt. Re-run with -Force to confirm all actions, or -WhatIf to preview.'
        }
    }

    Context 'through a function that declares SupportsShouldProcess' {
        It '-Confirm:$false never prompts, even for High impact' {
            InModuleScope DnsLathund {
                function Invoke-ConfirmProbe {
                    [CmdletBinding(SupportsShouldProcess)]
                    param ([string]$Impact = 'High')
                    Confirm-DnsAction -Target 'srv01' -Action 'Remove A record' -Impact $Impact -State @{ All = $false }
                }
                Mock Read-Host { 'n' }
                $ConfirmPreference = 'Low'

                Invoke-ConfirmProbe -Impact High -Confirm:$false | Should -BeTrue
                Should -Invoke Read-Host -Times 0 -Exactly
            }
        }

        It '-Confirm prompts even for Low impact' {
            InModuleScope DnsLathund {
                function Invoke-ConfirmProbe {
                    [CmdletBinding(SupportsShouldProcess)]
                    param ([string]$Impact = 'High')
                    Confirm-DnsAction -Target 'srv01' -Action 'Remove A record' -Impact $Impact -State @{ All = $false }
                }
                Mock Read-Host { 'y' }
                $ConfirmPreference = 'High'

                Invoke-ConfirmProbe -Impact Low -Confirm | Should -BeTrue
                Should -Invoke Read-Host -Times 1 -Exactly
            }
        }

        It '-WhatIf returns $false and prints the What if line' {
            InModuleScope DnsLathund {
                function Invoke-ConfirmProbe {
                    [CmdletBinding(SupportsShouldProcess)]
                    param ([string]$Impact = 'High')
                    Confirm-DnsAction -Target 'srv01' -Action 'Remove A record' -Impact $Impact -State @{ All = $false }
                }
                Mock Read-Host { 'y' }

                Invoke-ConfirmProbe -WhatIf | Should -BeFalse
                Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like 'What if: *' }
                Should -Invoke Read-Host -Times 0 -Exactly
            }
        }
    }
}

Describe 'Write-DnsChangeLog' {
    BeforeAll {
        $script:SavedLogPathVariable = $env:DNSLATHUND_LOGPATH
        $script:SavedLocalAppData = $env:LOCALAPPDATA
    }

    AfterEach {
        $env:DNSLATHUND_LOGPATH = $script:SavedLogPathVariable
        $env:LOCALAPPDATA = $script:SavedLocalAppData
    }

    It 'writes to -LogPath even when DNSLATHUND_LOGPATH is set' {
        $env:DNSLATHUND_LOGPATH = Join-Path $TestDrive 'from-env.jsonl'
        $logPath = Join-Path $TestDrive 'param\from-param.jsonl'
        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)
            Write-DnsChangeLog -Entry @{ Action = 'RemoveA' } -LogPath $LogPath
        }
        Test-Path -LiteralPath $logPath | Should -BeTrue
        Test-Path -LiteralPath $env:DNSLATHUND_LOGPATH | Should -BeFalse
    }

    It 'writes to DNSLATHUND_LOGPATH when -LogPath is not given' {
        $env:DNSLATHUND_LOGPATH = Join-Path $TestDrive 'env\from-env.jsonl'
        $env:LOCALAPPDATA = Join-Path $TestDrive 'appdata-env'
        InModuleScope DnsLathund {
            Write-DnsChangeLog -Entry @{ Action = 'RemoveA' }
        }
        Test-Path -LiteralPath $env:DNSLATHUND_LOGPATH | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $TestDrive 'appdata-env') | Should -BeFalse
    }

    It 'defaults to LOCALAPPDATA\DnsLathund\log\DnsLathund_yyyy-MM.jsonl and creates the folder' {
        $env:DNSLATHUND_LOGPATH = ''
        $env:LOCALAPPDATA = Join-Path $TestDrive 'appdata'
        InModuleScope DnsLathund {
            Write-DnsChangeLog -Entry @{ Action = 'RemoveA' }
        }
        $expected = Join-Path $TestDrive ('appdata\DnsLathund\log\DnsLathund_{0}.jsonl' -f (Get-Date).ToString('yyyy-MM'))
        Test-Path -LiteralPath $expected | Should -BeTrue
    }

    It 'writes every schema key in order, null when not supplied, and fills Id, Timestamp and Operator' {
        $logPath = Join-Path $TestDrive 'schema.jsonl'
        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)
            $entry = @{
                BatchId  = 'b7d3c2a1-0000-4000-8000-000000000001'
                Server   = 'dc01'
                Action   = 'RemoveA'
                Zone     = 'contoso.local'
                NodeName = 'srv01'
                Type     = 'A'
                Before   = @{ Data = '10.0.16.5'; Ttl = 3600; Timestamp = $null; IsStatic = $true }
                Result   = 'Success'
            }
            Write-DnsChangeLog -Entry $entry -LogPath $LogPath
        }

        $lines = @(Get-Content -LiteralPath $logPath -Encoding UTF8)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match '^\{"Id":"[0-9a-f-]{36}","BatchId":"b7d3c2a1-0000-4000-8000-000000000001","Timestamp":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}[+-]\d\d:\d\d","Operator":'

        $record = $lines[0] | ConvertFrom-Json
        ($record.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' |
            Should -Be 'Id,BatchId,Timestamp,Operator,Server,Action,Zone,NodeName,Type,Before,After,Result,Error'
        $record.Operator | Should -Not -BeNullOrEmpty
        $record.After | Should -BeNullOrEmpty
        $record.Error | Should -BeNullOrEmpty
        $record.Before.Data | Should -Be '10.0.16.5'
        $record.Before.Ttl | Should -Be 3600
        $record.Before.IsStatic | Should -BeTrue
        $lines[0] | Should -Match '"After":null'
        $lines[0] | Should -Match '"Error":null'
    }

    It 'keeps a supplied Id, Timestamp and Operator and writes dates in round-trip format' {
        $logPath = Join-Path $TestDrive 'supplied.jsonl'
        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)
            $when = New-Object -TypeName System.DateTime -ArgumentList 2026, 10, 9, 15, 0, 0, ([System.DateTimeKind]::Local)
            Write-DnsChangeLog -LogPath $LogPath -Entry @{
                Id        = 'fixed-id'
                Timestamp = $when
                Operator  = 'CONTOSO\operator'
                Before    = @{ Timestamp = $when }
            }
        }
        $line = Get-Content -LiteralPath $logPath -Encoding UTF8
        $line | Should -Match '"Id":"fixed-id"'
        $line | Should -Match '"Timestamp":"2026-10-09T15:00:00\.0000000[+-]\d\d:\d\d"'
        $line | Should -Match '"Operator":"CONTOSO\\\\operator"'
        $line | Should -Match '"Before":\{"Timestamp":"2026-10-09T15:00:00\.0000000[+-]\d\d:\d\d"\}'
    }

    It 'appends exactly one line per call' {
        $logPath = Join-Path $TestDrive 'lines.jsonl'
        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)
            Write-DnsChangeLog -Entry @{ Action = 'RemoveA' } -LogPath $LogPath
            Write-DnsChangeLog -Entry @{ Action = 'RemovePtr' } -LogPath $LogPath
            Write-DnsChangeLog -Entry @{ Action = 'AddA' } -LogPath $LogPath
        }
        $lines = @(Get-Content -LiteralPath $logPath -Encoding UTF8)
        $lines.Count | Should -Be 3
        ($lines | ForEach-Object { ($_ | ConvertFrom-Json).Action }) -join ',' | Should -Be 'RemoveA,RemovePtr,AddA'
    }

    It 'writes non-ASCII as UTF-8' {
        $logPath = Join-Path $TestDrive 'utf8.jsonl'
        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)
            Write-DnsChangeLog -Entry @{ NodeName = 'skrivare-åäö'; Zone = 'contoso.local' } -LogPath $LogPath
        }
        (Get-Content -LiteralPath $logPath -Encoding UTF8 | ConvertFrom-Json).NodeName | Should -BeExactly 'skrivare-åäö'

        # 'å' is C3 A5 in UTF-8 (E5 in ANSI).
        $bytes = Get-FileByte -Path $logPath
        $hex = -join ($bytes | ForEach-Object { '{0:X2}' -f $_ })
        $hex | Should -Match 'C3A5C3A4C3B6'
    }

    It 'is not suppressed by -WhatIf in the caller' {
        $logPath = Join-Path $TestDrive 'whatif.jsonl'
        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)
            $WhatIfPreference = $true
            Write-DnsChangeLog -Entry @{ Action = 'RemoveA'; Result = 'WhatIf' } -LogPath $LogPath
        }
        (Get-Content -LiteralPath $logPath -Encoding UTF8 | ConvertFrom-Json).Result | Should -Be 'WhatIf'
    }

    It 'retries once after an IOException' {
        $logPath = Join-Path $TestDrive 'retry.jsonl'
        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)
            $script:FoundationTestAddContentCalls = 0
            Mock Start-Sleep { }
            Mock Add-Content {
                $script:FoundationTestAddContentCalls++
                if ($script:FoundationTestAddContentCalls -eq 1) {
                    throw (New-Object System.IO.IOException 'The process cannot access the file because it is being used by another process.')
                }
                Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Value $Value -Encoding UTF8
            }

            Write-DnsChangeLog -Entry @{ Action = 'RemoveA' } -LogPath $LogPath -WarningVariable warnings

            Should -Invoke Add-Content -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 200 }
            @($warnings).Count | Should -Be 0
        }
        @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count | Should -Be 1
    }

    It 'warns after the second IOException and does not throw' {
        $logPath = Join-Path $TestDrive 'locked.jsonl'
        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)
            Mock Start-Sleep { }
            Mock Add-Content { throw (New-Object System.IO.IOException 'The file is locked.') }

            { Write-DnsChangeLog -Entry @{ Action = 'RemoveA' } -LogPath $LogPath -WarningVariable warnings -WarningAction SilentlyContinue } | Should -Not -Throw
            Write-DnsChangeLog -Entry @{ Action = 'RemoveA' } -LogPath $LogPath -WarningVariable warnings -WarningAction SilentlyContinue

            Should -Invoke Add-Content -Times 4 -Exactly
            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike "*$LogPath*The file is locked.*"
        }
    }

    It 'does not retry other failures' {
        $logPath = Join-Path $TestDrive 'denied.jsonl'
        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)
            Mock Start-Sleep { }
            Mock Add-Content { throw (New-Object System.UnauthorizedAccessException 'Access is denied.') }

            Write-DnsChangeLog -Entry @{ Action = 'RemoveA' } -LogPath $LogPath -WarningVariable warnings -WarningAction SilentlyContinue

            Should -Invoke Add-Content -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
            @($warnings).Count | Should -Be 1
        }
    }

    It 'never throws, even for an unusable path under ErrorActionPreference Stop' {
        $logPath = Join-Path $TestDrive 'bad|name\log.jsonl'
        InModuleScope DnsLathund -Parameters @{ LogPath = $logPath } {
            param ($LogPath)
            $ErrorActionPreference = 'Stop'
            { Write-DnsChangeLog -Entry @{ Action = 'RemoveA' } -LogPath $LogPath -WarningAction SilentlyContinue } | Should -Not -Throw
            Write-DnsChangeLog -Entry @{ Action = 'RemoveA' } -LogPath $LogPath -WarningVariable warnings -WarningAction SilentlyContinue
            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike "*bad|name*"
        }
    }
}

Describe 'DnsServer stubs' {
    BeforeAll {
        Initialize-DnsStub -StubPath $script:StubPath -ExportRoot $TestDrive
        InModuleScope DnsLathund {
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name '@' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'srv01' -RRType A -Data '10.0.16.20'
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'srv01' -RRType A -Data '10.0.16.21' -AgeHours 3636304 -TimeToLive 1200
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'test01.lab' -RRType A -Data '10.0.16.60'
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'print server' -RRType A -Data '10.0.16.50'
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'gw' -RRType CNAME -Data 'srv01.contoso.local'
            Add-DnsStubRecord -ZoneName '16.0.10.in-addr.arpa' -Name '20' -RRType PTR -Data 'srv01.contoso.local.'
        }
    }

    It 'returns child nodes for -Name without -Node, like the real cmdlet' {
        InModuleScope DnsLathund {
            @(Get-DnsServerResourceRecord -ZoneName 'contoso.local' -Name 'lab').HostName | Should -Be @('test01.lab')
            @(Get-DnsServerResourceRecord -ZoneName 'contoso.local' -Name 'lab' -Node -ErrorAction SilentlyContinue).Count | Should -Be 0
        }
    }

    It 'returns only the node itself with -Node, filtered by -RRType' {
        InModuleScope DnsLathund {
            $records = @(Get-DnsServerResourceRecord -ZoneName 'contoso.local' -Name 'srv01.contoso.local.' -Node -RRType A)
            $records.Count | Should -Be 2
            $records[0].RecordData.IPv4Address.IPAddressToString | Should -Be '10.0.16.20'
            $records[0].Timestamp | Should -BeNullOrEmpty
            $records[1].Timestamp | Should -BeOfType [datetime]
            $records[1].TimeToLive | Should -Be (New-TimeSpan -Seconds 1200)
            $records[0].PSObject.TypeNames[0] | Should -BeLike '*DnsServerResourceRecord'
        }
    }

    It 'writes ObjectNotFound for a name without records' {
        InModuleScope DnsLathund {
            Get-DnsServerResourceRecord -ZoneName 'contoso.local' -Name 'nosuch' -Node -ErrorVariable errors -ErrorAction SilentlyContinue
            $errors[0].CategoryInfo.Category | Should -Be 'ObjectNotFound'
        }
    }

    It 'exports in the zone file grammar and refuses to overwrite' {
        InModuleScope DnsLathund {
            Export-DnsServerZone -Name 'contoso.local' -FileName 'contoso.local.export'
            $path = Join-Path $script:DnsStub.ExportRoot 'contoso.local.export'
            $lines = @(Get-Content -LiteralPath $path -Encoding UTF8)
            $lines | Should -Contain '$ORIGIN contoso.local.'
            $lines | Should -Contain "@`t`t`tNS`tdc01.contoso.local."
            $lines | Should -Contain "srv01`tA`t10.0.16.20"
            $lines | Should -Contain "`t[AGE:3636304]`t1200`tA`t10.0.16.21"
            $lines | Should -Contain "print\040server`tA`t10.0.16.50"
            $lines | Should -Contain "gw`tCNAME`tsrv01.contoso.local."

            { Export-DnsServerZone -Name 'contoso.local' -FileName 'contoso.local.export' -ErrorAction Stop } | Should -Throw '*already exists*'
        }
    }

    It 'refuses to export an auto-created zone' {
        InModuleScope DnsLathund {
            { Export-DnsServerZone -Name '0.in-addr.arpa' -FileName 'auto.export' -ErrorAction Stop } | Should -Throw '*auto-created*'
        }
    }

    It 'Export-DnsServerZone accepts -WhatIf:$false -Confirm:$false and writes the file' {
        InModuleScope DnsLathund {
            Export-DnsServerZone -Name 'contoso.local' -FileName 'explicit-false.export' -WhatIf:$false -Confirm:$false -ErrorAction Stop
            Test-Path -LiteralPath (Join-Path $script:DnsStub.ExportRoot 'explicit-false.export') | Should -BeTrue
        }
    }

    It 'Export-DnsServerZone with -WhatIf counts the call but writes nothing and raises no error' {
        InModuleScope DnsLathund {
            $callsBefore = [int]$script:DnsStub.Calls['Export-DnsServerZone']
            Export-DnsServerZone -Name 'contoso.local' -FileName 'whatif.export' -WhatIf -ErrorAction Stop
            Test-Path -LiteralPath (Join-Path $script:DnsStub.ExportRoot 'whatif.export') | Should -BeFalse
            $script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be ($callsBefore + 1)

            # A failure set up for the zone does not fire either: the real cmdlet stops before contacting the server.
            $script:DnsStub.Fail['Export-DnsServerZone'] = @('*')
            try {
                { Export-DnsServerZone -Name 'contoso.local' -FileName 'whatif-fail.export' -WhatIf -ErrorAction Stop } | Should -Not -Throw
            }
            finally {
                $script:DnsStub.Fail.Remove('Export-DnsServerZone')
            }
        }
    }

    It 'Export-DnsServerZone honours an inherited WhatIfPreference unless the call passes -WhatIf:$false' {
        InModuleScope DnsLathund {
            function Invoke-ExportProbe {
                [CmdletBinding(SupportsShouldProcess)]
                param ([string]$FileName, [switch]$ForceWrite)
                if ($ForceWrite) {
                    Export-DnsServerZone -Name 'contoso.local' -FileName $FileName -WhatIf:$false -Confirm:$false
                }
                else {
                    Export-DnsServerZone -Name 'contoso.local' -FileName $FileName
                }
            }

            Invoke-ExportProbe -FileName 'inherited.export' -WhatIf
            Test-Path -LiteralPath (Join-Path $script:DnsStub.ExportRoot 'inherited.export') | Should -BeFalse

            Invoke-ExportProbe -FileName 'overridden.export' -ForceWrite -WhatIf
            Test-Path -LiteralPath (Join-Path $script:DnsStub.ExportRoot 'overridden.export') | Should -BeTrue
        }
    }
}
