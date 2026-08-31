function Get-DnsOrphanPtr {
    <#
        .SYNOPSIS
            Hittar PTR-poster som saknar motsvarande A-post.

        .DESCRIPTION
            Bygger ett index över A-posterna i forwardzonerna (FQDN -> IP-lista)
            och sveper därefter reverse-zonerna. En PTR vars målnamn saknar
            A-post rapporteras med Status 'NoARecord'. Med -IncludeMismatch
            rapporteras även PTR vars målnamn har en A-post med en annan
            IP-adress, med Status 'IpMismatch'.

            Standardmetoden är ZoneExport (Export-DnsServerZone + egen parser),
            som skalar till zoner med hundratusentals poster. Med -Method Cim
            används i stället WQL-frågor mot root\MicrosoftDNS.

            Utan -ReverseZone sveps alla primära reverse-zoner på servern, och
            utan -ForwardZone byggs indexet av alla primära forwardzoner.

            Klasslösa RFC 2317-zoner (snedstreck i zonnamnet) hoppas över med
            en varning.

            Utdata (DnsLathund.OrphanPtr) kan pipas direkt till
            Remove-DnsPtrRecord.

        .EXAMPLE
            Get-DnsOrphanPtr -ComputerName 'dc01'

            Sveper alla reverse-zoner på servern.

        .EXAMPLE
            Get-DnsOrphanPtr -ComputerName 'dc01' -ReverseZone '16.0.10.in-addr.arpa' -IncludeMismatch

            Kontrollerar en zon och tar även med felpekande PTR-poster.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]]$ReverseZone,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]]$ForwardZone,

        [Parameter()]
        [ValidateSet('ZoneExport', 'Cim')]
        [string]$Method = 'ZoneExport',

        [Parameter()]
        [switch]$IncludeMismatch,

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Assert-DnsServerModule

    $credentialParameters = @{}

    if ($null -ne $Credential) {
        $credentialParameters['Credential'] = $Credential
    }

    $zoneTable = Get-DnsZoneTable -ComputerName $ComputerName @credentialParameters

    # Bara primära zoner är intressanta: sekundära och stub-zoner ägs inte av
    # den här servern och ska varken exporteras eller städas här.
    $primaryZoneNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($zone in @($zoneTable.AllZones)) {
        if ($null -ne $zone -and $zone.ZoneType -eq 'Primary') {
            $null = $primaryZoneNames.Add([string]$zone.ZoneName)
        }
    }

    if ($PSBoundParameters.ContainsKey('ReverseZone')) {
        $selectedReverseZones = @($ReverseZone)
    }
    else {
        $selectedReverseZones = @(
            $zoneTable.ReverseZones | Where-Object { $primaryZoneNames.Contains($_) }
        )
    }

    if ($PSBoundParameters.ContainsKey('ForwardZone')) {
        $selectedForwardZones = @($ForwardZone)
    }
    else {
        $selectedForwardZones = @(
            $zoneTable.ForwardZones | Where-Object { $primaryZoneNames.Contains($_) }
        )
    }

    # Klasslösa RFC 2317-delegeringar har snedstreck i zonnamnet och kräver en
    # helt annan tolkning av ägarnamnet — de hoppas över tills stöd finns.
    $reverseZonesToSweep = New-Object System.Collections.Generic.List[string]

    foreach ($zoneName in $selectedReverseZones) {
        if ($zoneName -like '*/*') {
            Write-Warning "Klasslös reverse-zon $zoneName stöds inte ännu – hoppas över."
            continue
        }

        $reverseZonesToSweep.Add($zoneName)
    }

    if ($reverseZonesToSweep.Count -eq 0) {
        Write-Warning "Inga reverse-zoner att svepa på '$ComputerName'."
        return
    }

    if ($selectedForwardZones.Count -eq 0) {
        # Utan A-index skulle varenda PTR se föräldralös ut. Avbryt hellre.
        Write-Warning "Inga forwardzoner att bygga A-index av på '$ComputerName' — avbryter för att undvika falska träffar."
        return
    }

    $cimSession = $null

    if ($Method -eq 'Cim') {
        $cimSession = Get-DnsCimSession -ComputerName $ComputerName @credentialParameters

        if ($null -eq $cimSession) {
            Write-Error "CIM (root\MicrosoftDNS) är inte nåbart på '$ComputerName'. Kör om med -Method ZoneExport."
            return
        }
    }

    # Temporära zonfiler städas oavsett hur körningen slutar.
    $temporaryFiles = New-Object System.Collections.Generic.List[string]

    # Producent för PTR-posterna i en zon. Två implementationer, en konsument.
    # Scriptblocken körs med & i funktionens scope och kan därför läsa
    # $ComputerName, $credentialParameters, $cimSession och $temporaryFiles.
    $ptrProducer = if ($Method -eq 'Cim') {
        {
            param ($Zone)

            $wqlQuery = "SELECT OwnerName,PTRDomainName FROM MicrosoftDNS_PTRType WHERE ContainerName='{0}'" -f
                $Zone.Replace("'", "''")

            Get-CimInstance `
                -CimSession $cimSession `
                -Namespace 'root\MicrosoftDNS' `
                -Query $wqlQuery `
                -OperationTimeoutSec 300 `
                -ErrorAction Stop |
                ForEach-Object {
                    # Provider-versionerna skiljer sig åt: PTRDomainName finns
                    # alltid i den dokumenterade klassen, RecordData i vissa
                    # nyare varianter.
                    $ptrTarget = $_.PTRDomainName

                    if ([string]::IsNullOrWhiteSpace($ptrTarget)) {
                        $ptrTarget = $_.RecordData
                    }

                    [PSCustomObject]@{
                        OwnerFqdn  = $_.OwnerName
                        RecordData = $ptrTarget
                    }
                }
        }
    }
    else {
        {
            param ($Zone)

            $zoneFile = Export-DnsZoneFile -ZoneName $Zone -ComputerName $ComputerName @credentialParameters

            $temporaryFiles.Add($zoneFile)

            ConvertFrom-DnsZoneFile -Path $zoneFile -ZoneName $Zone -RecordType PTR
        }
    }

    try {
        # --- A-index över forwardzonerna -------------------------------------
        $aIndex = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        $forwardZoneCount = $selectedForwardZones.Count
        $forwardZoneNumber = 0

        foreach ($forwardZoneName in $selectedForwardZones) {
            $forwardZoneNumber++

            Write-Progress `
                -Id 1 `
                -Activity 'Bygger A-index från forwardzonerna' `
                -Status "Zon $forwardZoneNumber av ${forwardZoneCount}: $forwardZoneName" `
                -PercentComplete (($forwardZoneNumber - 1) * 100 / $forwardZoneCount)

            if ($Method -eq 'Cim') {
                $wqlQuery = "SELECT OwnerName,IPAddress FROM MicrosoftDNS_AType WHERE ContainerName='{0}'" -f
                    $forwardZoneName.Replace("'", "''")

                Get-CimInstance `
                    -CimSession $cimSession `
                    -Namespace 'root\MicrosoftDNS' `
                    -Query $wqlQuery `
                    -OperationTimeoutSec 300 `
                    -ErrorAction Stop |
                    ForEach-Object {
                        $addressText = $_.IPAddress

                        if ([string]::IsNullOrWhiteSpace($addressText)) {
                            $addressText = $_.RecordData
                        }

                        $ownerName = ConvertTo-CanonicalDnsName -Name ([string]$_.OwnerName)

                        if (
                            -not [string]::IsNullOrWhiteSpace($ownerName) -and
                            -not [string]::IsNullOrWhiteSpace($addressText)
                        ) {
                            if ($aIndex.ContainsKey($ownerName)) {
                                $aIndex[$ownerName].Add([string]$addressText)
                            }
                            else {
                                $addressList = New-Object System.Collections.Generic.List[string]
                                $addressList.Add([string]$addressText)
                                $aIndex.Add($ownerName, $addressList)
                            }
                        }
                    }
            }
            else {
                $zoneFile = Export-DnsZoneFile -ZoneName $forwardZoneName -ComputerName $ComputerName @credentialParameters

                $temporaryFiles.Add($zoneFile)

                $zoneIndex = ConvertFrom-DnsZoneFile -Path $zoneFile -ZoneName $forwardZoneName -AsIndex

                foreach ($entry in $zoneIndex.GetEnumerator()) {
                    if ($aIndex.ContainsKey($entry.Key)) {
                        $aIndex[$entry.Key].AddRange($entry.Value)
                    }
                    else {
                        $aIndex.Add($entry.Key, $entry.Value)
                    }
                }
            }
        }

        Write-Progress -Id 1 -Activity 'Bygger A-index från forwardzonerna' -Completed

        Write-Verbose "A-indexet innehåller $($aIndex.Count) namn från $forwardZoneCount forwardzon(er)."

        # --- Svep över reverse-zonerna ---------------------------------------
        $reverseZoneCount = $reverseZonesToSweep.Count
        $reverseZoneNumber = 0

        foreach ($reverseZoneName in $reverseZonesToSweep) {
            $reverseZoneNumber++

            Write-Progress `
                -Id 2 `
                -Activity 'Söker föräldralösa PTR-poster' `
                -Status "Zon $reverseZoneNumber av ${reverseZoneCount}: $reverseZoneName" `
                -PercentComplete (($reverseZoneNumber - 1) * 100 / $reverseZoneCount)

            $canonicalReverseZone = ConvertTo-CanonicalDnsName -Name $reverseZoneName

            & $ptrProducer $reverseZoneName |
                ForEach-Object {
                    $ownerFqdn = ConvertTo-CanonicalDnsName -Name ([string]$_.OwnerFqdn)
                    $ptrTarget = ConvertTo-CanonicalDnsName -Name ([string]$_.RecordData)

                    if (
                        [string]::IsNullOrWhiteSpace($ownerFqdn) -or
                        [string]::IsNullOrWhiteSpace($ptrTarget)
                    ) {
                        return
                    }

                    # IP-adressen härleds ur ägarnamnet. Zonen kan vara en
                    # /16- eller /8-zon, så alla fyra oktetterna tas från det
                    # fullständiga ägarnamnet, inte från zonnamnet.
                    if (-not $ownerFqdn.EndsWith('.in-addr.arpa', [System.StringComparison]::OrdinalIgnoreCase)) {
                        Write-Verbose "PTR-ägaren '$ownerFqdn' ligger inte under in-addr.arpa — hoppas över."
                        return
                    }

                    $octetPart = $ownerFqdn.Substring(0, $ownerFqdn.Length - '.in-addr.arpa'.Length)
                    $octets = $octetPart.Split('.')

                    if ($octets.Length -ne 4) {
                        Write-Verbose "PTR-ägaren '$ownerFqdn' har inte fyra oktetter — hoppas över (klasslös delegering?)."
                        return
                    }

                    $addressText = '{3}.{2}.{1}.{0}' -f $octets
                    $parsedAddress = $null

                    if (
                        -not [System.Net.IPAddress]::TryParse($addressText, [ref]$parsedAddress) -or
                        $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork
                    ) {
                        Write-Verbose "PTR-ägaren '$ownerFqdn' ger ingen giltig IPv4-adress — hoppas över."
                        return
                    }

                    $addressText = $parsedAddress.IPAddressToString

                    $status = $null

                    if (-not $aIndex.ContainsKey($ptrTarget)) {
                        $status = 'NoARecord'
                    }
                    elseif (-not $aIndex[$ptrTarget].Contains($addressText)) {
                        if (-not $IncludeMismatch) {
                            return
                        }

                        $status = 'IpMismatch'
                    }
                    else {
                        return
                    }

                    $relativeOwnerName = if (
                        $ownerFqdn.EndsWith(".$canonicalReverseZone", [System.StringComparison]::OrdinalIgnoreCase) -or
                        [string]::Equals($ownerFqdn, $canonicalReverseZone, [System.StringComparison]::OrdinalIgnoreCase)
                    ) {
                        Get-RelativeRecordName -DnsName $ownerFqdn -ZoneName $canonicalReverseZone
                    }
                    else {
                        $ownerFqdn
                    }

                    New-DnsOrphanPtrObject `
                        -IPAddress $addressText `
                        -PtrOwnerName $relativeOwnerName `
                        -PtrTarget $ptrTarget `
                        -ReverseZone $reverseZoneName `
                        -Status $status `
                        -ComputerName $ComputerName
                }
        }

        Write-Progress -Id 2 -Activity 'Söker föräldralösa PTR-poster' -Completed
    }
    finally {
        foreach ($temporaryFile in $temporaryFiles) {
            try {
                if (-not [string]::IsNullOrWhiteSpace($temporaryFile)) {
                    Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction Stop
                }
            }
            catch {
                Write-Warning "Kunde inte ta bort den temporära zonfilen '$temporaryFile': $($_.Exception.Message)"
            }
        }
    }
}
