function Remove-DnsRecordsFromFile {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateScript({
            if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
                throw "Filen hittades inte: $_"
            }

            $true
        })]
        [string]$Path,

        [Parameter()]
        [string]$DnsServer = 'pangdc01',

        [Parameter()]
        [string]$ForwardZone = 'pangkaka.com'
    )

    $recordsToRemove = @(
        Get-Content -LiteralPath $Path |
            ForEach-Object { $_.Trim() } |
            Where-Object {
                $_ -and
                -not $_.StartsWith('#')
            } |
            Sort-Object -Unique
    )

    if ($recordsToRemove.Count -eq 0) {
        Write-Warning "Filen innehåller inga DNS-namn."
        return
    }

    $success = 0
    $failed  = 0
    $skipped = 0

    Write-Host ""
    Write-Host "DNS-rensning" -ForegroundColor Cyan
    Write-Host "  Server:     $DnsServer"
    Write-Host "  Zon:        $ForwardZone"
    Write-Host "  Fil:        $Path"
    Write-Host "  Antal namn: $($recordsToRemove.Count)"
    Write-Host ""

    foreach ($name in $recordsToRemove) {
        Write-Host "[$name]" -ForegroundColor Cyan

        try {
            #
            # Hämta A-post
            #
            Write-Host "  Söker A-post..." -NoNewline

            $aRecords = @(
                Get-DnsServerResourceRecord `
                    -ComputerName $DnsServer `
                    -ZoneName $ForwardZone `
                    -Name $name `
                    -RRType A `
                    -Node `
                    -ErrorAction Stop
            )

            if ($aRecords.Count -ne 1) {
                throw "'$name': hittade $($aRecords.Count) A-poster, förväntade exakt 1."
            }

            $aRecord = $aRecords[0]
            $ip = $aRecord.RecordData.IPv4Address.IPAddressToString
            $fqdn = "$($aRecord.HostName).$ForwardZone".TrimEnd('.')

            Write-Host " hittad: $fqdn → $ip" -ForegroundColor Green

            #
            # Hämta PTR-post
            #
            Write-Host "  Söker PTR-post..." -NoNewline

            $ptrInfo = ptr `
                $aRecord.RecordData.IPv4Address `
                -Server $DnsServer `
                -ErrorAction Stop

            if (-not $ptrInfo) {
                throw "Ingen PTR-post hittades för $ip."
            }

            Write-Host (
                " hittad: {0}.{1} → {2}" -f
                    $ptrInfo.Node,
                    $ptrInfo.Zone,
                    $ptrInfo.PTR
            ) -ForegroundColor Green

            #
            # Verifiera att PTR pekar tillbaka på samma FQDN
            #
            $ptrTarget = $ptrInfo.PTR.ToString().TrimEnd('.')

            if ($ptrTarget -ine $fqdn) {
                throw "PTR pekar på '$ptrTarget', inte på '$fqdn'."
            }

            #
            # WhatIf/Confirm
            #
            if (-not $PSCmdlet.ShouldProcess(
                "$fqdn och PTR $($ptrInfo.Node).$($ptrInfo.Zone)",
                'Ta bort A- och PTR-post'
            )) {
                Write-Host "  Hoppades över." -ForegroundColor Yellow
                $skipped++
                Write-Host ""
                continue
            }

            #
            # Ta bort A-post
            #
            Write-Host "  Tar bort A-post..." -NoNewline

            try {
                Remove-DnsServerResourceRecord `
                    -ComputerName $DnsServer `
                    -ZoneName $ForwardZone `
                    -Name $aRecord.HostName `
                    -RRType A `
                    -RecordData $ip `
                    -Force `
                    -ErrorAction Stop

                Write-Host " klar" -ForegroundColor Green
            }
            catch {
                $aStillExists = @(
                    Get-DnsServerResourceRecord `
                        -ComputerName $DnsServer `
                        -ZoneName $ForwardZone `
                        -Name $aRecord.HostName `
                        -RRType A `
                        -Node `
                        -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.RecordData.IPv4Address.IPAddressToString -eq $ip
                    }
                )

                if ($aStillExists.Count -eq 0) {
                    Write-Host (
                        " klar, men DNS-cmdleten rapporterade fel efter borttagningen"
                    ) -ForegroundColor Yellow
                }
                else {
                    throw
                }
            }

            #
            # Ta bort PTR-post
            #
            Write-Host "  Tar bort PTR-post..." -NoNewline

            try {
                Remove-DnsServerResourceRecord `
                    -ComputerName $DnsServer `
                    -ZoneName $ptrInfo.Zone `
                    -Name $ptrInfo.Node `
                    -RRType PTR `
                    -RecordData $ptrInfo.PTR `
                    -Force `
                    -ErrorAction Stop

                Write-Host " klar" -ForegroundColor Green
            }
            catch {
                $ptrStillExists = @(
                    Get-DnsServerResourceRecord `
                        -ComputerName $DnsServer `
                        -ZoneName $ptrInfo.Zone `
                        -Name $ptrInfo.Node `
                        -RRType PTR `
                        -Node `
                        -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.RecordData.PtrDomainName.ToString().TrimEnd('.') -ieq
                        $ptrTarget
                    }
                )

                if ($ptrStillExists.Count -eq 0) {
                    Write-Host (
                        " klar, men DNS-cmdleten rapporterade fel efter borttagningen"
                    ) -ForegroundColor Yellow
                }
                else {
                    throw
                }
            }

            $success++
        }
        catch {
            Write-Host "  FEL" -ForegroundColor Red
            Write-Warning $_.Exception.Message
            $failed++
        }

        Write-Host ""
    }

    Write-Host "Körningen är färdig." -ForegroundColor Cyan
    Write-Host "  Borttagna:      $success" -ForegroundColor Green
    Write-Host "  Misslyckade:    $failed" -ForegroundColor Red
    Write-Host "  Överhoppade:    $skipped" -ForegroundColor Yellow

    [PSCustomObject]@{
        Path        = $Path
        DnsServer   = $DnsServer
        ForwardZone = $ForwardZone
        Total       = $recordsToRemove.Count
        Removed     = $success
        Failed      = $failed
        Skipped     = $skipped
    }
}