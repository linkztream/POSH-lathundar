#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
<#
    Tests for Export-DnsZoneFile (CONTRACTS.md section 9.1).

    The DnsServer stubs run in the module scope. $script:DnsServerExportRoot and the
    stub export root point at the same per-test folder, so passing
    -Server $env:COMPUTERNAME exercises the "server is this computer" path for real.
    The admin$ and WinRM paths are exercised with mocks of Copy-Item, Remove-Item and
    Invoke-Command inside InModuleScope.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\DnsLathund.psd1" -Force
    $script:StubPath = Join-Path -Path $PSScriptRoot -ChildPath 'Stubs\DnsServerStubs.ps1'

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

        # Mocks call through to these, so a mock can record a call and still do the work.
        $script:RealCopyItem = Get-Command -Name 'Copy-Item' -CommandType Cmdlet
        $script:RealRemoveItem = Get-Command -Name 'Remove-Item' -CommandType Cmdlet
        $script:RealNewItem = Get-Command -Name 'New-Item' -CommandType Cmdlet
        $script:RealAddContent = Get-Command -Name 'Add-Content' -CommandType Cmdlet
        $script:StubExportCommand = Get-Command -Name 'Export-DnsServerZone' -CommandType Function
    }

    function Initialize-ExportTest {
        <#
        .SYNOPSIS
            Resets the stub store, points both export roots at a fresh folder and adds contoso.local.
        #>
        param ([string]$Root)

        InModuleScope DnsLathund -Parameters @{ Root = $Root } {
            param ($Root)

            $script:DnsServerExportRoot = Join-Path -Path $Root -ChildPath 'server-dns'
            Reset-DnsStubStore -ExportRoot $script:DnsServerExportRoot
            $null = New-Item -Path $script:DnsServerExportRoot -ItemType Directory -Force
            $script:ZoneTableCache = @{}
            $script:CimSessionCache = @{}

            Add-DnsStubZone -Name 'contoso.local'
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name '@' -RRType NS -Data 'dc01.contoso.local'
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'srv01' -RRType A -Data '10.0.16.20'
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'srv02' -RRType A -Data '10.0.16.21' -AgeHours 3636304
            Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'gw' -RRType CNAME -Data 'srv01.contoso.local'
        }
    }

    # Module code treats only this computer's names as local; anything else is remote.
    $script:RemoteServer = 'dnsl-remote-01'
}

AfterAll {
    InModuleScope DnsLathund {
        $script:DnsServerExportRoot = Join-Path $env:windir 'System32\dns'
    }
}

Describe 'Export-DnsZoneFile when the DNS server is this computer' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-ExportTest -Root $script:Root
    }

    It 'copies the export from the local DNS folder, returns the path and removes the server copy' {
        InModuleScope DnsLathund -Parameters @{ Root = $script:Root } {
            param ($Root)

            $destination = Join-Path -Path $Root -ChildPath 'snapshot\contoso.local.txt'
            $result = Export-DnsZoneFile -ZoneName 'contoso.local' -Server $env:COMPUTERNAME -DestinationPath $destination

            $result | Should -BeExactly (Convert-Path -LiteralPath $destination)
            Test-Path -LiteralPath $destination -PathType Leaf | Should -BeTrue
            $script:DnsStub.Calls['Export-DnsServerZone'] | Should -Be 1
            @(Get-ChildItem -LiteralPath $script:DnsServerExportRoot -Force).Count | Should -Be 0

            $parsed = ConvertFrom-DnsZoneFile -Path $destination -ZoneName 'contoso.local'
            $parsed.Rows | Should -Contain "srv01.contoso.local`tA`t10.0.16.20`t3600`t0`t"
            $parsed.Rows | Should -Contain "gw.contoso.local`tCNAME`tsrv01.contoso.local`t3600`t0`t"
        }
    }

    It 'treats <Name> as this computer' -TestCases @(
        @{ Name = $env:COMPUTERNAME.ToUpperInvariant() }
        @{ Name = $env:COMPUTERNAME.ToLowerInvariant() }
        @{ Name = 'localhost' }
        @{ Name = '127.0.0.1' }
    ) {
        InModuleScope DnsLathund -Parameters @{ Root = $script:Root; Name = $Name } {
            param ($Root, $Name)

            Mock Invoke-Command { throw 'Invoke-Command must not be called for a local server.' }
            $destination = Join-Path -Path $Root -ChildPath 'local.txt'
            Export-DnsZoneFile -ZoneName 'contoso.local' -Server $Name -DestinationPath $destination | Should -Not -BeNullOrEmpty

            Test-Path -LiteralPath $destination | Should -BeTrue
            Should -Invoke Invoke-Command -Times 0 -Exactly
            @(Get-ChildItem -LiteralPath $script:DnsServerExportRoot -Force).Count | Should -Be 0
        }
    }

    It 'refuses to overwrite an existing destination and does not export' {
        InModuleScope DnsLathund -Parameters @{ Root = $script:Root } {
            param ($Root)

            $destination = Join-Path -Path $Root -ChildPath 'existing.txt'
            Set-Content -LiteralPath $destination -Value 'previous snapshot'

            { Export-DnsZoneFile -ZoneName 'contoso.local' -Server $env:COMPUTERNAME -DestinationPath $destination } |
                Should -Throw '*already exists*'

            Get-Content -LiteralPath $destination | Should -Be 'previous snapshot'
            $script:DnsStub.Calls['Export-DnsServerZone'] | Should -BeNullOrEmpty
        }
    }

    It 'throws with the zone name when the zone does not exist' {
        InModuleScope DnsLathund -Parameters @{ Root = $script:Root } {
            param ($Root)

            $destination = Join-Path -Path $Root -ChildPath 'missing.txt'
            { Export-DnsZoneFile -ZoneName 'missing.example' -Server $env:COMPUTERNAME -DestinationPath $destination } |
                Should -Throw "*'missing.example'*"

            Test-Path -LiteralPath $destination | Should -BeFalse
            @(Get-ChildItem -LiteralPath $script:DnsServerExportRoot -Force).Count | Should -Be 0
        }
    }

    It 'warns with the exact remote path when the server copy cannot be removed' {
        InModuleScope DnsLathund -Parameters @{ Root = $script:Root } {
            param ($Root)

            Mock Remove-Item { throw 'Access to the path is denied (test).' } -ParameterFilter { "$LiteralPath" -like '*dnslathund_*' }
            $destination = Join-Path -Path $Root -ChildPath 'contoso.local.txt'

            $result = Export-DnsZoneFile -ZoneName 'contoso.local' -Server $env:COMPUTERNAME -DestinationPath $destination -WarningVariable warnings -WarningAction SilentlyContinue

            $result | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $destination | Should -BeTrue
            $leftOver = @(Get-ChildItem -LiteralPath $script:DnsServerExportRoot -File)
            $leftOver.Count | Should -Be 1
            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike "*$($leftOver[0].FullName)*"
            "$($warnings[0])" | Should -BeLike '*Access to the path is denied (test).*'
        }
    }

    It 'keeps the server copy with -KeepRemoteFile, under a unique dnslathund_ name' {
        InModuleScope DnsLathund -Parameters @{ Root = $script:Root } {
            param ($Root)

            $destination = Join-Path -Path $Root -ChildPath 'contoso.local.txt'
            $null = Export-DnsZoneFile -ZoneName 'contoso.local' -Server $env:COMPUTERNAME -DestinationPath $destination -KeepRemoteFile

            $kept = @(Get-ChildItem -LiteralPath $script:DnsServerExportRoot -File)
            $kept.Count | Should -Be 1
            $kept[0].Name | Should -Match '^dnslathund_contoso\.local_\d{17}\.txt$'
            (Get-Content -LiteralPath $destination -Raw) | Should -Be (Get-Content -LiteralPath $kept[0].FullName -Raw)
        }
    }

    It 'replaces unsafe characters of the zone name in the remote file name' {
        InModuleScope DnsLathund -Parameters @{ Root = $script:Root } {
            param ($Root)

            Add-DnsStubZone -Name '0/25.16.0.10.in-addr.arpa'
            Add-DnsStubRecord -ZoneName '0/25.16.0.10.in-addr.arpa' -Name '5' -RRType PTR -Data 'srv05.contoso.local'
            $destination = Join-Path -Path $Root -ChildPath 'classless.txt'
            $null = Export-DnsZoneFile -ZoneName '0/25.16.0.10.in-addr.arpa' -Server $env:COMPUTERNAME -DestinationPath $destination -KeepRemoteFile

            (Get-ChildItem -LiteralPath $script:DnsServerExportRoot -File).Name | Should -Match '^dnslathund_0_25\.16\.0\.10\.in-addr\.arpa_\d{17}\.txt$'
        }
    }

    It 'still writes and cleans up when the caller runs under -WhatIf' {
        InModuleScope DnsLathund -Parameters @{ Root = $script:Root } {
            param ($Root)

            $destination = Join-Path -Path $Root -ChildPath 'whatif\contoso.local.txt'
            $WhatIfPreference = $true
            $null = Export-DnsZoneFile -ZoneName 'contoso.local' -Server $env:COMPUTERNAME -DestinationPath $destination
            $WhatIfPreference = $false

            Test-Path -LiteralPath $destination -PathType Leaf | Should -BeTrue
            @(Get-ChildItem -LiteralPath $script:DnsServerExportRoot -Force).Count | Should -Be 0
        }
    }

    It 'calls every file write with -WhatIf:$false and -Confirm:$false' {
        InModuleScope DnsLathund -Parameters @{ Root = $script:Root } {
            param ($Root)

            Mock Copy-Item { & $script:RealCopyItem @PesterBoundParameters }
            Mock Remove-Item { & $script:RealRemoveItem @PesterBoundParameters }
            Mock New-Item { & $script:RealNewItem @PesterBoundParameters }
            Mock Export-DnsServerZone { & $script:StubExportCommand @PesterBoundParameters }

            $destination = Join-Path -Path $Root -ChildPath 'new-folder\contoso.local.txt'
            $null = Export-DnsZoneFile -ZoneName 'contoso.local' -Server $env:COMPUTERNAME -DestinationPath $destination
            Test-Path -LiteralPath $destination | Should -BeTrue

            $safeCall = {
                $PesterBoundParameters.ContainsKey('WhatIf') -and -not $PesterBoundParameters['WhatIf'] -and
                $PesterBoundParameters.ContainsKey('Confirm') -and -not $PesterBoundParameters['Confirm']
            }
            $unsafeCall = { -not (& $safeCall) }
            foreach ($command in @('Export-DnsServerZone', 'Copy-Item', 'Remove-Item', 'New-Item')) {
                Should -Invoke $command -ParameterFilter $safeCall -Because "$command must not obey a caller's -WhatIf"
                Should -Invoke $command -ParameterFilter $unsafeCall -Times 0 -Exactly -Because "$command must carry -WhatIf:`$false -Confirm:`$false"
            }
        }
    }
}

Describe 'Export-DnsZoneFile when the DNS server is remote' {
    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-ExportTest -Root $script:Root
    }

    It 'copies the export from \\<server>\admin$ and removes it there' {
        InModuleScope DnsLathund -Parameters @{ Root = $script:Root; Server = $script:RemoteServer } {
            param ($Root, $Server)

            # The admin$ share of the stub server is its export root.
            Mock Copy-Item -ParameterFilter { "$LiteralPath" -like '\\*' } {
                $leaf = Split-Path -Path "$LiteralPath" -Leaf
                & $script:RealCopyItem -LiteralPath (Join-Path -Path $script:DnsStub.ExportRoot -ChildPath $leaf) -Destination $Destination -ErrorAction Stop
            }
            Mock Remove-Item -ParameterFilter { "$LiteralPath" -like '\\*' } {
                $leaf = Split-Path -Path "$LiteralPath" -Leaf
                & $script:RealRemoveItem -LiteralPath (Join-Path -Path $script:DnsStub.ExportRoot -ChildPath $leaf) -ErrorAction Stop
            }
            Mock Invoke-Command { throw 'Invoke-Command must not be called when admin$ works.' }

            $destination = Join-Path -Path $Root -ChildPath 'contoso.local.txt'
            $result = Export-DnsZoneFile -ZoneName 'contoso.local' -Server $Server -DestinationPath $destination

            $result | Should -BeExactly (Convert-Path -LiteralPath $destination)
            Should -Invoke Copy-Item -Times 1 -Exactly -ParameterFilter { "$LiteralPath" -like "\\$Server\admin$\System32\dns\dnslathund_contoso.local_*.txt" }
            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { "$LiteralPath" -like "\\$Server\admin$\System32\dns\dnslathund_contoso.local_*.txt" }
            Should -Invoke Invoke-Command -Times 0 -Exactly
            @(Get-ChildItem -LiteralPath $script:DnsServerExportRoot -Force).Count | Should -Be 0
            (ConvertFrom-DnsZoneFile -Path $destination -ZoneName 'contoso.local').Rows | Should -Contain "srv01.contoso.local`tA`t10.0.16.20`t3600`t0`t"
        }
    }

    It 'streams the file over WinRM in chunks when the admin$ copy fails' {
        InModuleScope DnsLathund -Parameters @{ Root = $script:Root; Server = $script:RemoteServer } {
            param ($Root, $Server)

            Mock Copy-Item -ParameterFilter { "$LiteralPath" -like '\\*' } { throw 'The network path was not found (test).' }
            Mock Remove-Item -ParameterFilter { "$LiteralPath" -like '\\*' } { throw 'Remove-Item on admin$ must not be called after WinRM worked.' }
            Mock Add-Content { & $script:RealAddContent @PesterBoundParameters }
            # Three chunks, as Get-Content -ReadCount sends them.
            Mock Invoke-Command -ParameterFilter { "$ScriptBlock" -match 'Get-Content' } {
                , [string[]]@('line 1', 'line 2', 'line 3')
                , [string[]]@('line 4', 'line 5', 'line 6')
                , [string[]]@('line 7')
            }
            Mock Invoke-Command -ParameterFilter { "$ScriptBlock" -match 'Remove-Item' } { }

            $destination = Join-Path -Path $Root -ChildPath 'streamed.txt'
            $null = Export-DnsZoneFile -ZoneName 'contoso.local' -Server $Server -DestinationPath $destination

            Get-Content -LiteralPath $destination | Should -Be @('line 1', 'line 2', 'line 3', 'line 4', 'line 5', 'line 6', 'line 7')
            Should -Invoke Copy-Item -Times 1 -Exactly
            Should -Invoke Invoke-Command -Times 1 -Exactly -ParameterFilter {
                "$ScriptBlock" -match 'Get-Content' -and "$ScriptBlock" -match '-ReadCount 2000' -and $ComputerName -eq $Server -and $null -eq $PesterBoundParameters['Credential']
            }
            Should -Invoke Invoke-Command -Times 1 -Exactly -ParameterFilter { "$ScriptBlock" -match 'Remove-Item' -and $ComputerName -eq $Server }
            $safeCall = {
                $PesterBoundParameters.ContainsKey('WhatIf') -and -not $PesterBoundParameters['WhatIf'] -and
                $PesterBoundParameters.ContainsKey('Confirm') -and -not $PesterBoundParameters['Confirm']
            }
            $unsafeCall = { -not (& $safeCall) }
            Should -Invoke Add-Content -ParameterFilter $safeCall
            Should -Invoke Add-Content -ParameterFilter { "$($PesterBoundParameters['Encoding'])" -match 'UTF8' }
            Should -Invoke Add-Content -Times 0 -Exactly -ParameterFilter $unsafeCall
        }
    }

    It 'skips admin$ with -Credential and passes the credential to Invoke-Command' {
        InModuleScope DnsLathund -Parameters @{ Root = $script:Root; Server = $script:RemoteServer } {
            param ($Root, $Server)

            # No CIM session in a unit test; the credential must still reach this call.
            Mock Get-DnsServerParameter { @{ ComputerName = $Server } }
            Mock Copy-Item { throw 'Copy-Item must not be called with -Credential.' }
            Mock Invoke-Command -ParameterFilter { "$ScriptBlock" -match 'Get-Content' } {
                , [string[]]@('first chunk line 1', 'first chunk line 2')
                , [string[]]@('second chunk line 1')
            }
            Mock Invoke-Command -ParameterFilter { "$ScriptBlock" -match 'Remove-Item' } { }

            $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList 'CONTOSO\dnsexport', (New-Object -TypeName System.Security.SecureString)
            $destination = Join-Path -Path $Root -ChildPath 'with-credential.txt'
            $null = Export-DnsZoneFile -ZoneName 'contoso.local' -Server $Server -DestinationPath $destination -Credential $credential

            Get-Content -LiteralPath $destination | Should -Be @('first chunk line 1', 'first chunk line 2', 'second chunk line 1')
            Should -Invoke Copy-Item -Times 0 -Exactly
            $withCredential = { $null -ne $PesterBoundParameters['Credential'] -and $PesterBoundParameters['Credential'].UserName -eq 'CONTOSO\dnsexport' }
            Should -Invoke Get-DnsServerParameter -Times 1 -Exactly -ParameterFilter $withCredential
            Should -Invoke Invoke-Command -Times 1 -Exactly -ParameterFilter { "$ScriptBlock" -match 'Get-Content' -and (& $withCredential) }
            Should -Invoke Invoke-Command -Times 1 -Exactly -ParameterFilter { "$ScriptBlock" -match 'Remove-Item' -and (& $withCredential) }
            Should -Invoke Invoke-Command -Times 2 -Exactly
        }
    }

    It 'throws when no retrieval method works, leaves no partial file and warns about the remote file' {
        InModuleScope DnsLathund -Parameters @{ Root = $script:Root; Server = $script:RemoteServer } {
            param ($Root, $Server)

            Mock Copy-Item -ParameterFilter { "$LiteralPath" -like '\\*' } { throw 'The network path was not found (test).' }
            Mock Remove-Item -ParameterFilter { "$LiteralPath" -like '\\*' } { throw 'The network path was not found (test).' }
            Mock Invoke-Command { throw 'WinRM cannot complete the operation (test).' }

            $destination = Join-Path -Path $Root -ChildPath 'never.txt'
            $caught = $null
            try {
                $null = Export-DnsZoneFile -ZoneName 'contoso.local' -Server $Server -DestinationPath $destination -WarningVariable warnings -WarningAction SilentlyContinue
            }
            catch {
                $caught = $_
            }

            $caught | Should -Not -BeNullOrEmpty
            $caught.Exception.Message | Should -BeLike '*could not be copied here*WinRM cannot complete the operation (test).*'
            Test-Path -LiteralPath $destination | Should -BeFalse
            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike "*%windir%\System32\dns\dnslathund_contoso.local_*.txt*$Server*"
        }
    }
}
