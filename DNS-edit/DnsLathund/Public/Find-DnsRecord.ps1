function Find-DnsRecord {
    <#
        .SYNOPSIS
            Söker upp A- och PTR-poster i en Microsoft DNS-miljö.

        .DESCRIPTION
            Tar emot namn, IPv4-adresser eller wildcardmönster och returnerar
            DnsLathund.RecordPair-objekt.

            Dispatch:
            - IPv4-adress: reverse-uppslag följt av A-uppslag.
            - Wildcardmönster: zonexport + parsning (kräver -ZoneName). WQL med
              LIKE mot root\MicrosoftDNS är inte ett alternativ — DNS-providern
              stödjer inte LIKE-operatorn och returnerar tyst noll rader.
            - Exakt namn: punktuppslag via -Name.

            Ofiltrerad zon-enumeration via cmdletarna används aldrig — zonerna
            i den här miljön kan innehålla hundratusentals poster. Exportvägen
            parsar zonfilen strömmande och klarar den storleken på sekunder.

            Om wildcardsökning: matchningen görs mot postens fullständiga FQDN,
            inte nodnamnet. Mönster utan punkt kompletteras därför automatiskt
            med zonen, så att 'web*' i zonen 'contoso.local' blir mönstret
            'web*.contoso.local'. Innehåller mönstret redan en punkt används
            det som det är — då förutsätts anroparen ha skrivit ett
            fullständigt mönster.

            Varje träff slås därefter upp punktvis med Resolve-DnsRecordPair
            för att få PTR-relationen klassificerad. Ett mycket brett mönster som
            ger tusentals träffar innebär alltså tusentals punktuppslag — håll
            mönstren smala.

            Identity som inte matchar något ger en varning och inget objekt.

        .EXAMPLE
            Find-DnsRecord -Identity 'srv01.contoso.local' -ComputerName 'dc01'

            Slår upp en enskild post.

        .EXAMPLE
            'srv01', 'srv02' | Find-DnsRecord -ComputerName 'dc01' -ZoneName 'contoso.local'

            Slår upp flera namn via pipeline.

        .EXAMPLE
            Find-DnsRecord -Identity 'web*' -ComputerName 'dc01' -ZoneName 'contoso.local'

            Mönstersökning via zonexport.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('Name', 'HostName', 'IPAddress')]
        [string[]]$Identity,

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
        # Gemensamma parametrar vidarebefordras till hjälparna. -Credential
        # skickas bara med när den faktiskt angetts, så att hjälparna inte
        # tvingas gå CIM-vägen i onödan.
        $credentialSplat = @{}

        if ($null -ne $Credential) {
            $credentialSplat['Credential'] = $Credential
        }

        $hasZoneName = -not [string]::IsNullOrWhiteSpace($ZoneName)
        $normalizedZone = if ($hasZoneName) { $ZoneName.TrimEnd('.') } else { $null }
    }

    process {
        foreach ($identityItem in $Identity) {
            if ([string]::IsNullOrWhiteSpace($identityItem)) {
                continue
            }

            $current = $identityItem.Trim()
            $found = @()

            if (Test-IPv4Address -Value $current) {
                # IPv4: Resolve-DnsRecordPair gör reverse-uppslaget och
                # filtrerar bort A-poster med andra adresser. -ZoneName är
                # forward-zonen och ska inte styra ett reverse-uppslag.
                $found = @(
                    Resolve-DnsRecordPair -Identity $current -ComputerName $ComputerName @credentialSplat
                )
            }
            elseif ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($current)) {
                if (-not $hasZoneName) {
                    $PSCmdlet.WriteError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.ArgumentException]::new('Ange -ZoneName vid wildcard-sökning.'),
                            'ZoneNameRequiredForWildcard',
                            [System.Management.Automation.ErrorCategory]::InvalidArgument,
                            $current
                        )
                    )

                    continue
                }

                # Matchningen görs mot fullständigt FQDN. Ett mönster utan
                # punkt kompletteras därför med zonen.
                $searchPattern = if ($current.Contains('.')) {
                    $current
                }
                else {
                    "$current.$normalizedZone"
                }

                $ownerNames = [System.Collections.Generic.List[string]]::new()
                $seenOwners = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase
                )

                # Wildcard går via zonexport + parser. Den till synes självklara
                # vägen — WQL med LIKE mot root\MicrosoftDNS — fungerar inte:
                # DNS-providern stödjer inte LIKE-operatorn och returnerar tyst
                # noll rader (verifierat mot riktig server 2026-09-03).
                # Exportvägen skalar dessutom till zoner med hundratusentals
                # poster.
                $exportPath = $null

                try {
                    $exportPath = Export-DnsZoneFile `
                        -ZoneName $normalizedZone `
                        -ComputerName $ComputerName `
                        @credentialSplat

                    $zoneRecords = @(
                        ConvertFrom-DnsZoneFile `
                            -Path $exportPath `
                            -ZoneName $normalizedZone `
                            -RecordType A
                    )

                    foreach ($zoneRecord in $zoneRecords) {
                        $ownerFqdn = ConvertTo-CanonicalDnsName -Name $zoneRecord.OwnerFqdn

                        if ([string]::IsNullOrWhiteSpace($ownerFqdn)) {
                            continue
                        }

                        if (
                            $ownerFqdn -like $searchPattern -and
                            $seenOwners.Add($ownerFqdn)
                        ) {
                            $ownerNames.Add($ownerFqdn)
                        }
                    }
                }
                catch {
                    $PSCmdlet.WriteError($_)
                    continue
                }
                finally {
                    if (
                        -not [string]::IsNullOrWhiteSpace($exportPath) -and
                        (Test-Path -LiteralPath $exportPath -ErrorAction SilentlyContinue)
                    ) {
                        Remove-Item -LiteralPath $exportPath -Force -ErrorAction SilentlyContinue
                    }
                }

                # Punktuppslag per träff ger PTR-relationen klassificerad.
                $found = @(
                    foreach ($ownerName in $ownerNames) {
                        Resolve-DnsRecordPair `
                            -Identity $ownerName `
                            -ComputerName $ComputerName `
                            -ZoneName $normalizedZone `
                            @credentialSplat
                    }
                )
            }
            else {
                $resolveParameters = @{
                    Identity     = $current
                    ComputerName = $ComputerName
                }

                if ($hasZoneName) {
                    $resolveParameters['ZoneName'] = $normalizedZone
                }

                $found = @(Resolve-DnsRecordPair @resolveParameters @credentialSplat)
            }

            if ($found.Count -eq 0) {
                Write-Warning "Inga poster matchade '$current'."

                continue
            }

            $found
        }
    }
}
