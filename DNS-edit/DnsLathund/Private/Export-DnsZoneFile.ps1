function Export-DnsZoneFile {
    <#
        .SYNOPSIS
            Exporterar en DNS-zon till en lokal textfil (BIND-format).

        .DESCRIPTION
            Kör Export-DnsServerZone på servern med ett tidsstämplat filnamn
            (cmdleten vägrar skriva över befintlig fil), hämtar filen lokalt
            (lokal sökväg -> UNC \\server\admin$\System32\dns\ -> Invoke-Command)
            till "$env:TEMP\DnsLathund\" och städar serverfilen i ett finally-block.

            Serverfilen hamnar alltid i %windir%\System32\dns på DNS-servern.
            Misslyckas städningen skrivs en varning med serverns sökväg —
            funktionen kastar aldrig på grund av en misslyckad städning.

            Den lokala kopian tas INTE bort här; det ansvaret ligger på
            anroparen (normalt ett finally-block i Get-DnsOrphanPtr).

            Returnerar sökvägen till den lokala kopian.

        .EXAMPLE
            Export-DnsZoneFile -ZoneName 'contoso.local' -ComputerName 'dc01'

            Exporterar zonen och returnerar sökvägen till den lokala kopian.

        .EXAMPLE
            Export-DnsZoneFile -ZoneName 'contoso.local' -ComputerName 'dc01' -KeepRemoteFile

            Behåller exportfilen på servern för felsökning.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ZoneName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        # Katalog dit den lokala kopian skrivs. Standard: $env:TEMP\DnsLathund.
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential,

        [Parameter()]
        [switch]$KeepRemoteFile
    )

    Assert-DnsServerModule

    # Zonnamn kan innehålla tecken som inte duger i filnamn (klasslösa
    # reverse-zoner har snedstreck). Tidsstämpeln gör namnet unikt eftersom
    # Export-DnsServerZone vägrar skriva över en befintlig fil.
    $safeZoneName = [regex]::Replace($ZoneName, '[^A-Za-z0-9._-]', '_')

    $exportFileName = 'dnslathund_{0}_{1}.txt' -f $safeZoneName, (Get-Date -Format 'yyyyMMddHHmmss')

    $isLocalComputer = $false

    foreach ($localAlias in @($env:COMPUTERNAME, 'localhost', '.', '127.0.0.1')) {
        if (
            -not [string]::IsNullOrEmpty($localAlias) -and
            [string]::Equals($localAlias, $ComputerName, [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            $isLocalComputer = $true
            break
        }
    }

    $localServerPath = Join-Path -Path (Join-Path -Path $env:windir -ChildPath 'System32\dns') -ChildPath $exportFileName
    $uncServerPath = '\\{0}\admin$\System32\dns\{1}' -f $ComputerName, $exportFileName

    # Sökvägen så som den ser ut PÅ servern — används i Invoke-Command och i
    # varningstexten när städningen misslyckas.
    $remoteServerPath = 'System32\dns\{0}' -f $exportFileName

    # Utanför try-blocket med flit: hjälparens fel om en saknad CIM-session är
    # redan tydligt och ska inte packas om till "Kunde inte exportera zonen".
    $serverParameters = Get-DnsServerParameter -ComputerName $ComputerName -Credential $Credential

    try {
        Export-DnsServerZone -Name $ZoneName -FileName $exportFileName @serverParameters -ErrorAction Stop
    }
    catch {
        throw [System.InvalidOperationException]::new(
            "Kunde inte exportera zonen '$ZoneName' på '$ComputerName': $($_.Exception.Message)",
            $_.Exception
        )
    }

    # Metoden som lyckades med hämtningen återanvänds vid städningen.
    $retrievalMethod = $null

    try {
        $destinationDirectory = $DestinationPath

        if ([string]::IsNullOrWhiteSpace($destinationDirectory)) {
            $destinationDirectory = Join-Path -Path $env:TEMP -ChildPath 'DnsLathund'
        }

        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            $null = New-Item -Path $destinationDirectory -ItemType Directory -Force -ErrorAction Stop
        }

        $localCopyPath = Join-Path -Path $destinationDirectory -ChildPath $exportFileName

        $retrievalErrors = New-Object System.Collections.Generic.List[string]

        # (a) Lokal maskin — läs direkt ur %windir%\System32\dns.
        if ($isLocalComputer) {
            try {
                Copy-Item -LiteralPath $localServerPath -Destination $localCopyPath -Force -ErrorAction Stop

                $retrievalMethod = 'Local'
            }
            catch {
                $retrievalErrors.Add("lokal sökväg: $($_.Exception.Message)")
            }
        }

        # (b) UNC mot administrativ utdelning.
        if ($null -eq $retrievalMethod) {
            try {
                Copy-Item -LiteralPath $uncServerPath -Destination $localCopyPath -Force -ErrorAction Stop

                $retrievalMethod = 'Unc'
            }
            catch {
                $retrievalErrors.Add("UNC: $($_.Exception.Message)")
            }
        }

        # (c) Fjärranrop — läs filens innehåll över WinRM.
        if ($null -eq $retrievalMethod) {
            try {
                $invokeParameters = @{
                    ComputerName = $ComputerName
                    ScriptBlock  = {
                        [System.IO.File]::ReadAllText(
                            (Join-Path -Path $env:windir -ChildPath $using:remoteServerPath)
                        )
                    }
                    ErrorAction  = 'Stop'
                }

                if ($null -ne $Credential) {
                    $invokeParameters['Credential'] = $Credential
                }

                $content = Invoke-Command @invokeParameters

                [System.IO.File]::WriteAllText(
                    $localCopyPath,
                    [string]$content,
                    (New-Object System.Text.UTF8Encoding($false))
                )

                $retrievalMethod = 'Remote'
            }
            catch {
                $retrievalErrors.Add("Invoke-Command: $($_.Exception.Message)")
            }
        }

        if ($null -eq $retrievalMethod) {
            throw "Kunde inte hämta exportfilen '$exportFileName' från '$ComputerName'. Försök: $($retrievalErrors -join ' | ')"
        }

        Write-Verbose "Zonen '$ZoneName' exporterades från '$ComputerName' (hämtningsmetod: $retrievalMethod) till '$localCopyPath'."

        return $localCopyPath
    }
    finally {
        if ($KeepRemoteFile) {
            Write-Verbose "Behåller serverfilen '$remoteServerPath' på '$ComputerName' (-KeepRemoteFile)."
        }
        else {
            # Städningen får aldrig avbryta flödet: en kvarlämnad exportfil är
            # ett städproblem, inte ett fel i uppslaget.
            try {
                switch ($retrievalMethod) {
                    'Local' {
                        Remove-Item -LiteralPath $localServerPath -Force -ErrorAction Stop
                    }
                    'Remote' {
                        $removeParameters = @{
                            ComputerName = $ComputerName
                            ScriptBlock  = {
                                Remove-Item -LiteralPath (
                                    Join-Path -Path $env:windir -ChildPath $using:remoteServerPath
                                ) -Force -ErrorAction Stop
                            }
                            ErrorAction  = 'Stop'
                        }

                        if ($null -ne $Credential) {
                            $removeParameters['Credential'] = $Credential
                        }

                        Invoke-Command @removeParameters
                    }
                    default {
                        # Både 'Unc' och misslyckad hämtning städas via UNC —
                        # filen kan ha skapats även om hämtningen sedan sprack.
                        Remove-Item -LiteralPath $uncServerPath -Force -ErrorAction Stop
                    }
                }
            }
            catch {
                $serverPathForWarning = if ($isLocalComputer -and $retrievalMethod -eq 'Local') {
                    $localServerPath
                }
                else {
                    $uncServerPath
                }

                Write-Warning "Kunde inte ta bort exportfilen på servern: '$serverPathForWarning'. Ta bort den manuellt. ($($_.Exception.Message))"
            }
        }
    }
}
