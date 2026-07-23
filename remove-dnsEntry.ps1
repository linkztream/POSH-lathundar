function Remove-DnsEntry {
    [CmdletBinding()]
    param (
        [Parameter(
            Mandatory,
            Position = 0,
            ValueFromPipeline
        )]
        [ValidateNotNullOrEmpty()]
        [string]$Identity,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName = $env:COMPUTERNAME
    )

    begin {
        Import-Module DnsServer -ErrorAction Stop

        function Test-IPv4Address {
            param (
                [Parameter(Mandatory)]
                [string]$Value
            )

            $parsedAddress = $null

            return (
                [IPAddress]::TryParse($Value, [ref]$parsedAddress) -and
                $parsedAddress.AddressFamily -eq
                    [System.Net.Sockets.AddressFamily]::InterNetwork
            )
        }

        function Get-MatchingDnsZone {
            param (
                [Parameter(Mandatory)]
                [string]$DnsName,

                [Parameter(Mandatory)]
                [string[]]$ZoneNames
            )

            $normalizedName = $DnsName.TrimEnd('.')

            return $ZoneNames |
                Where-Object {
                    $normalizedName -ieq $_ -or
                    $normalizedName.EndsWith(
                        ".$_",
                        [StringComparison]::OrdinalIgnoreCase
                    )
                } |
                Sort-Object Length -Descending |
                Select-Object -First 1
        }

        function Get-RelativeRecordName {
            param (
                [Parameter(Mandatory)]
                [string]$DnsName,

                [Parameter(Mandatory)]
                [string]$ZoneName
            )

            $normalizedName = $DnsName.TrimEnd('.')
            $normalizedZone = $ZoneName.TrimEnd('.')

            if ($normalizedName -ieq $normalizedZone) {
                return '@'
            }

            return $normalizedName.Substring(
                0,
                $normalizedName.Length - $normalizedZone.Length - 1
            )
        }
    }

    process {
        try {
            $zones = @(
                Get-DnsServerZone `
                    -ComputerName $ComputerName `
                    -ErrorAction Stop
            )
        }
        catch {
            throw "Kunde inte läsa DNS-zoner från '$ComputerName': $($_.Exception.Message)"
        }

        $forwardZones = @(
            $zones |
                Where-Object {
                    $_.ZoneName -notlike '*.in-addr.arpa' -and
                    $_.ZoneName -notlike '*.ip6.arpa' -and
                    -not $_.IsReverseLookupZone
                } |
                Select-Object -ExpandProperty ZoneName
        )

        $reverseZones = @(
            $zones |
                Where-Object {
                    $_.ZoneName -like '*.in-addr.arpa' -or
                    $_.IsReverseLookupZone
                } |
                Select-Object -ExpandProperty ZoneName
        )

        $inputIsIp = Test-IPv4Address -Value $Identity
        $queriedIp = $null
        $candidateNames = [System.Collections.Generic.List[string]]::new()

        if ($inputIsIp) {
            $queriedIp = ([IPAddress]$Identity).IPAddressToString

            $reverseFqdn = (
                ($queriedIp -split '\.')[3..0] -join '.'
            ) + '.in-addr.arpa'

            $reverseZone = Get-MatchingDnsZone `
                -DnsName $reverseFqdn `
                -ZoneNames $reverseZones

            if (-not $reverseZone) {
                Write-Warning "Ingen reverse-zon matchar IP-adressen '$queriedIp'."
                return
            }

            $ptrNodeName = Get-RelativeRecordName `
                -DnsName $reverseFqdn `
                -ZoneName $reverseZone

            $inputPtrRecords = @(
                Get-DnsServerResourceRecord `
                    -ComputerName $ComputerName `
                    -ZoneName $reverseZone `
                    -Name $ptrNodeName `
                    -RRType PTR `
                    -ErrorAction SilentlyContinue
            )

            if ($inputPtrRecords.Count -eq 0) {
                Write-Warning "Ingen PTR-post hittades för '$queriedIp'."
                return
            }

            foreach ($ptrRecord in $inputPtrRecords) {
                $ptrTarget = $ptrRecord.RecordData.PtrDomainName.TrimEnd('.')

                if (-not $candidateNames.Contains($ptrTarget)) {
                    $candidateNames.Add($ptrTarget)
                }
            }
        }
        else {
            $candidateNames.Add($Identity.TrimEnd('.'))
        }

        $entries = [System.Collections.Generic.List[object]]::new()

        foreach ($candidateName in $candidateNames) {
            $forwardZone = Get-MatchingDnsZone `
                -DnsName $candidateName `
                -ZoneNames $forwardZones

            if (-not $forwardZone) {
                Write-Warning "Ingen forward-zon matchar namnet '$candidateName'."
                continue
            }

            $recordName = Get-RelativeRecordName `
                -DnsName $candidateName `
                -ZoneName $forwardZone

            $aRecords = @(
                Get-DnsServerResourceRecord `
                    -ComputerName $ComputerName `
                    -ZoneName $forwardZone `
                    -Name $recordName `
                    -RRType A `
                    -ErrorAction SilentlyContinue
            )

            foreach ($aRecord in $aRecords) {
                $ipAddress =
                    $aRecord.RecordData.IPv4Address.IPAddressToString

                $reverseFqdn = (
                    ($ipAddress -split '\.')[3..0] -join '.'
                ) + '.in-addr.arpa'

                $reverseZone = Get-MatchingDnsZone `
                    -DnsName $reverseFqdn `
                    -ZoneNames $reverseZones

                $ptrRecords = @()
                $ptrNodeName = $null

                if ($reverseZone) {
                    $ptrNodeName = Get-RelativeRecordName `
                        -DnsName $reverseFqdn `
                        -ZoneName $reverseZone

                    $ptrRecords = @(
                        Get-DnsServerResourceRecord `
                            -ComputerName $ComputerName `
                            -ZoneName $reverseZone `
                            -Name $ptrNodeName `
                            -RRType PTR `
                            -ErrorAction SilentlyContinue
                    )
                }

                $fqdn = if ($recordName -eq '@') {
                    $forwardZone
                }
                else {
                    "$recordName.$forwardZone"
                }

                $matchingPtrRecords = @(
                    $ptrRecords |
                        Where-Object {
                            $_.RecordData.PtrDomainName.TrimEnd('.') -ieq
                                $fqdn.TrimEnd('.')
                        }
                )

                $allPtrTargets = @(
                    $ptrRecords |
                        ForEach-Object {
                            $_.RecordData.PtrDomainName.TrimEnd('.')
                        }
                )

                $relationStatus = switch ($true) {
                    ($matchingPtrRecords.Count -eq 1 -and
                     $ptrRecords.Count -eq 1) {
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
                    [PSCustomObject]@{
                        Name               = $fqdn.TrimEnd('.')
                        IPv4Address        = $ipAddress
                        ForwardZone        = $forwardZone
                        ARecord            = $aRecord
                        ReverseZone        = $reverseZone
                        PtrNodeName        = $ptrNodeName
                        PtrRecords         = $ptrRecords
                        MatchingPtrRecords = $matchingPtrRecords
                        PtrTargets         = $allPtrTargets
                        Relation           = $relationStatus
                    }
                )
            }
        }

        if ($inputIsIp) {
            $entries = [System.Collections.Generic.List[object]]@(
                $entries |
                    Where-Object {
                        $_.IPv4Address -eq $queriedIp
                    }
            )
        }

        if ($entries.Count -eq 0) {
            Write-Warning "Inga matchande A-poster hittades för '$Identity'."
            return
        }

        Write-Host ''
        Write-Host "DNS-information från $ComputerName" -ForegroundColor Cyan
        Write-Host ('-' * 78)

        for ($index = 0; $index -lt $entries.Count; $index++) {
            $entry = $entries[$index]

            $ptrDisplay = if ($entry.PtrTargets.Count -gt 0) {
                $entry.PtrTargets -join ', '
            }
            else {
                '<saknas>'
            }

            Write-Host ('[{0}] {1}' -f ($index + 1), $entry.Name)
            Write-Host ('    A   : {0}' -f $entry.IPv4Address)
            Write-Host ('    PTR : {0}' -f $ptrDisplay)
            Write-Host ('    Status: {0}' -f $entry.Relation)
            Write-Host ''
        }

        if (
            $entries.Count -eq 1 -and
            $entries[0].Relation -eq '1:1'
        ) {
            $choice = Read-Host 'Ta bort denna A- och PTR-post? [J/N]'

            if ($choice -notmatch '^(J|Y)$') {
                Write-Host 'Ingen post togs bort.'
                return
            }

            $selectedEntries = @($entries[0])
        }
        else {
            do {
                $choice = Read-Host (
                    'Vilket entry ska tas bort? ' +
                    "[1-$($entries.Count)], [A]ll, [N]one"
                )

                if ($choice -match '^[Nn]$') {
                    Write-Host 'Ingen post togs bort.'
                    return
                }

                if ($choice -match '^[Aa]$') {
                    $selectedEntries = @($entries)
                    break
                }

                $selectedNumber = 0
                $validNumber = (
                    [int]::TryParse($choice, [ref]$selectedNumber) -and
                    $selectedNumber -ge 1 -and
                    $selectedNumber -le $entries.Count
                )

                if ($validNumber) {
                    $selectedEntries = @(
                        $entries[$selectedNumber - 1]
                    )
                    break
                }

                Write-Warning 'Ogiltigt val.'
            }
            while ($true)
        }

        Write-Host ''
        Write-Host 'Följande poster har valts:' -ForegroundColor Yellow

        foreach ($entry in $selectedEntries) {
            Write-Host (
                '  {0} -> {1} [{2}]' -f
                    $entry.Name,
                    $entry.IPv4Address,
                    $entry.Relation
            )
        }

        $finalChoice = Read-Host 'Bekräfta borttagning? [J/N]'

        if ($finalChoice -notmatch '^(J|Y)$') {
            Write-Host 'Ingen post togs bort.'
            return
        }

        foreach ($entry in $selectedEntries) {
            try {
                # A-posten tas bort först. Det använda CIM-objektet
                # representerar exakt den valda namn/IP-kombinationen.
                $entry.ARecord |
                    Remove-DnsServerResourceRecord `
                        -ComputerName $ComputerName `
                        -ZoneName $entry.ForwardZone `
                        -Force `
                        -ErrorAction Stop

                Write-Host (
                    "Tog bort A: {0} -> {1}" -f
                        $entry.Name,
                        $entry.IPv4Address
                ) -ForegroundColor Green
            }
            catch {
                Write-Error (
                    "Kunde inte ta bort A-posten {0} -> {1}: {2}" -f
                        $entry.Name,
                        $entry.IPv4Address,
                        $_.Exception.Message
                )

                # Behåll PTR om A-borttagningen misslyckades.
                continue
            }

            foreach ($ptrRecord in $entry.MatchingPtrRecords) {
                try {
                    $ptrRecord |
                        Remove-DnsServerResourceRecord `
                            -ComputerName $ComputerName `
                            -ZoneName $entry.ReverseZone `
                            -Force `
                            -ErrorAction Stop

                    Write-Host (
                        "Tog bort PTR: {0} -> {1}" -f
                            $entry.IPv4Address,
                            $entry.Name
                    ) -ForegroundColor Green
                }
                catch {
                    Write-Warning (
                        "A-posten togs bort, men PTR-posten kunde inte tas bort: {0}" -f
                            $_.Exception.Message
                    )
                }
            }

            if ($entry.MatchingPtrRecords.Count -eq 0) {
                Write-Warning (
                    "A-posten togs bort, men ingen matchande PTR-post fanns för {0}." -f
                        $entry.IPv4Address
                )
            }
        }
    }
}