function Resolve-DnsRecordPair {
    <#
        .SYNOPSIS
            Slår upp ett namn eller en IPv4-adress och bygger RecordPair-objekt.

        .DESCRIPTION
            Modulens kärnuppslag. Använder alltid punktuppslag via -Name mot
            Get-DnsServerResourceRecord (ofiltrerad zon-enumeration är förbjuden).
            IPv4-indata löses först via reverse-zonen till kandidatnamn, därefter
            slås A-posterna upp och PTR-relationen klassificeras.

            Returnerar ett DnsLathund.RecordPair per A-post.

            Zonval för namn:
            - Utan -ZoneName väljs forward-zonen med longest-suffix-match mot
              zontabellen. Matchar ingen zon skrivs en varning och namnet
              hoppas över.
            - Med -ZoneName används zonen direkt. Namn som ligger i zonen
              (eller saknar punkt) blir relativa nodnamn i den, medan ett
              punktförsett namn utanför zonen ändå faller tillbaka på
              zontabellen. Det sista behövs för IP-uppslag, där kandidatnamnen
              kommer från PTR-posterna och kan ligga i en annan zon.

            Hittas ingen A-post returneras ingenting; anroparen avgör hur det
            ska rapporteras.

        .EXAMPLE
            Resolve-DnsRecordPair -Identity 'srv01.contoso.local' -ComputerName 'dc01'

            Returnerar RecordPair-objekt för namnet.

        .EXAMPLE
            Resolve-DnsRecordPair -Identity '10.0.16.5' -ComputerName 'dc01'

            Slår upp PTR först och returnerar RecordPair för adressen.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string]$Identity,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ZoneName,

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    begin {
        Assert-DnsServerModule

        # Get-DnsServerResourceRecord saknar -Credential. När andra uppgifter
        # anges måste uppslagen därför gå via en CIM-session; går den inte att
        # upprätta kastar hjälparen i stället för att tyst köra med den
        # inloggade användarens rättigheter.
        $serverParameters = Get-DnsServerParameter -ComputerName $ComputerName -Credential $Credential

        $zoneTableParameters = @{ ComputerName = $ComputerName }

        if ($null -ne $Credential) {
            $zoneTableParameters['Credential'] = $Credential
        }
    }

    process {
        $zoneTable = Get-DnsZoneTable @zoneTableParameters

        $forwardZones = [string[]]@($zoneTable.ForwardZones)
        $reverseZones = [string[]]@($zoneTable.ReverseZones)

        $identityValue = $Identity.Trim()
        $inputIsIp = Test-IPv4Address -Value $identityValue
        $queriedIp = $null

        $candidateNames = [System.Collections.Generic.List[string]]::new()
        $seenCandidates = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        if ($inputIsIp) {
            $queriedIp = ([IPAddress]$identityValue).IPAddressToString
            $reverseFqdn = ConvertTo-ReverseFqdn -IPAddress $queriedIp

            $inputReverseZone = Get-MatchingDnsZone -DnsName $reverseFqdn -ZoneNames $reverseZones

            if (-not $inputReverseZone) {
                Write-Warning "Ingen reverse-zon matchar IP-adressen '$queriedIp'."
                return
            }

            $inputPtrNodeName = Get-RelativeRecordName -DnsName $reverseFqdn -ZoneName $inputReverseZone

            $inputPtrRecords = @(
                Get-DnsServerResourceRecord @serverParameters `
                    -ZoneName $inputReverseZone `
                    -Name $inputPtrNodeName `
                    -RRType PTR `
                    -ErrorAction SilentlyContinue
            )

            if ($inputPtrRecords.Count -eq 0) {
                Write-Warning "Ingen PTR-post hittades för '$queriedIp'."
                return
            }

            foreach ($inputPtrRecord in $inputPtrRecords) {
                $ptrTarget = ConvertTo-CanonicalDnsName -Name $inputPtrRecord.RecordData.PtrDomainName

                if (-not [string]::IsNullOrWhiteSpace($ptrTarget) -and $seenCandidates.Add($ptrTarget)) {
                    $candidateNames.Add($ptrTarget)
                }
            }
        }
        else {
            $candidateName = ConvertTo-CanonicalDnsName -Name $identityValue

            if ($seenCandidates.Add($candidateName)) {
                $candidateNames.Add($candidateName)
            }
        }

        $entries = [System.Collections.Generic.List[object]]::new()

        foreach ($candidateName in $candidateNames) {
            $forwardZone = $null
            $recordName = $null

            if ($PSBoundParameters.ContainsKey('ZoneName')) {
                $explicitZone = ConvertTo-CanonicalDnsName -Name $ZoneName
                $candidateIsInZone = (
                    (Test-DnsNameEqual -First $candidateName -Second $explicitZone) -or
                    $candidateName.EndsWith(".$explicitZone", [System.StringComparison]::OrdinalIgnoreCase)
                )

                if ($candidateIsInZone) {
                    $forwardZone = $explicitZone
                    $recordName = Get-RelativeRecordName -DnsName $candidateName -ZoneName $explicitZone
                }
                elseif ($candidateName -notmatch '\.') {
                    # Kort namn tolkas som relativt nodnamn i den angivna zonen.
                    $forwardZone = $explicitZone
                    $recordName = $candidateName
                }
            }

            if (-not $forwardZone) {
                $forwardZone = Get-MatchingDnsZone -DnsName $candidateName -ZoneNames $forwardZones

                if (-not $forwardZone) {
                    Write-Warning "Ingen forward-zon matchar namnet '$candidateName'."
                    continue
                }

                $recordName = Get-RelativeRecordName -DnsName $candidateName -ZoneName $forwardZone
            }

            $aRecords = @(
                Get-DnsServerResourceRecord @serverParameters `
                    -ZoneName $forwardZone `
                    -Name $recordName `
                    -RRType A `
                    -ErrorAction SilentlyContinue
            )

            if ($aRecords.Count -eq 0) {
                Write-Verbose "Ingen A-post hittades för '$candidateName' i zonen '$forwardZone'."
                continue
            }

            foreach ($aRecord in $aRecords) {
                $ipAddress = $aRecord.RecordData.IPv4Address.IPAddressToString

                $reverseZone = $null
                $ptrNodeName = $null
                $ptrRecords = @()

                if (-not [string]::IsNullOrWhiteSpace($ipAddress) -and (Test-IPv4Address -Value $ipAddress)) {
                    $recordReverseFqdn = ConvertTo-ReverseFqdn -IPAddress $ipAddress
                    $reverseZone = Get-MatchingDnsZone -DnsName $recordReverseFqdn -ZoneNames $reverseZones

                    if ($reverseZone) {
                        $ptrNodeName = Get-RelativeRecordName -DnsName $recordReverseFqdn -ZoneName $reverseZone

                        $ptrRecords = @(
                            Get-DnsServerResourceRecord @serverParameters `
                                -ZoneName $reverseZone `
                                -Name $ptrNodeName `
                                -RRType PTR `
                                -ErrorAction SilentlyContinue
                        )
                    }
                }

                $fqdn = if ($recordName -eq '@') {
                    $forwardZone
                }
                else {
                    "$recordName.$forwardZone"
                }

                $fqdn = ConvertTo-CanonicalDnsName -Name $fqdn

                $matchingPtrRecords = @(
                    $ptrRecords |
                        Where-Object {
                            Test-DnsNameEqual -First $_.RecordData.PtrDomainName -Second $fqdn
                        }
                )

                $ptrTargets = [string[]]@(
                    $ptrRecords |
                        ForEach-Object {
                            ConvertTo-CanonicalDnsName -Name $_.RecordData.PtrDomainName
                        }
                )

                # Exakt samma klassificering (och strängar) som det gamla
                # remove-dnsEntry.ps1 använde.
                $relationStatus = switch ($true) {
                    ($matchingPtrRecords.Count -eq 1 -and $ptrRecords.Count -eq 1) {
                        '1:1'
                        break
                    }

                    ($matchingPtrRecords.Count -gt 0) {
                        'Matchande PTR finns, men relationen är inte 1:1'
                        break
                    }

                    ($ptrRecords.Count -gt 0) {
                        'PTR pekar på annat namn'
                        break
                    }

                    default {
                        'PTR saknas'
                    }
                }

                $entries.Add(
                    (New-DnsRecordPairObject `
                        -Name $fqdn `
                        -IPv4Address $ipAddress `
                        -ForwardZone $forwardZone `
                        -ARecord $aRecord `
                        -ReverseZone $reverseZone `
                        -PtrNodeName $ptrNodeName `
                        -PtrRecords $ptrRecords `
                        -MatchingPtrRecords $matchingPtrRecords `
                        -PtrTargets $ptrTargets `
                        -Relation $relationStatus `
                        -ComputerName $ComputerName)
                )
            }
        }

        if ($inputIsIp) {
            # En kandidat från PTR kan ha flera A-poster. Bara den som pekar
            # tillbaka på den efterfrågade adressen är relevant.
            $filteredEntries = @(
                $entries |
                    Where-Object { $_.IPv4Address -eq $queriedIp }
            )

            foreach ($entry in $filteredEntries) {
                Write-Output $entry
            }

            return
        }

        foreach ($entry in $entries) {
            Write-Output $entry
        }
    }
}
