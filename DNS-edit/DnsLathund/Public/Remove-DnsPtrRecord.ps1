function Remove-DnsPtrRecord {
    <#
        .SYNOPSIS
            Tar bort föräldralösa PTR-poster.

        .DESCRIPTION
            Tar emot DnsLathund.OrphanPtr-objekt från Get-DnsOrphanPtr.

            Varje post omverifieras mot servern innan borttagning: PTR-posten
            hämtas på nytt med ett punktuppslag via -Name, och det kontrolleras
            att A-posten fortfarande saknas. Exportdata kan vara timmar gammalt,
            och en post som hunnit återskapas får inte tas bort.

            Utan -Force ställs en ShouldContinue-fråga innan bulkborttagning.
            Alla operationer, även -WhatIf, loggas till JSONL-loggen.

            DnsServer-cmdletarna saknar -Credential. Anges -Credential går
            därför både uppslagen och borttagningarna via en CIM-session från
            Get-DnsCimSession; kan ingen session upprättas avbryts körningen.

        .EXAMPLE
            Get-DnsOrphanPtr -ComputerName 'dc01' | Remove-DnsPtrRecord -ComputerName 'dc01' -WhatIf

            Visar vilka PTR-poster som skulle tas bort.

        .EXAMPLE
            Get-DnsOrphanPtr -ComputerName 'dc01' -ReverseZone '16.0.10.in-addr.arpa' | Remove-DnsPtrRecord -ComputerName 'dc01' -Force

            Städar en reverse-zon utan bekräftelsegrind.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [PSTypeName('DnsLathund.OrphanPtr')]
        [PSObject[]]$InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    begin {
        $collectedRecords = New-Object System.Collections.Generic.List[PSObject]
    }

    process {
        foreach ($orphanPtr in $InputObject) {
            if ($null -ne $orphanPtr) {
                $collectedRecords.Add($orphanPtr)
            }
        }
    }

    end {
        if ($collectedRecords.Count -eq 0) {
            Write-Verbose 'Inga PTR-poster att ta bort.'
            return
        }

        Assert-DnsServerModule

        # -Force är avsett för obevakad bulkkörning: utan det här skulle
        # ConfirmImpact 'High' ändå ge en fråga per post. Ett uttryckligt
        # -Confirm från anroparen vinner alltid.
        if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
            $ConfirmPreference = 'None'
        }

        $credentialParameters = @{}

        if ($null -ne $Credential) {
            $credentialParameters['Credential'] = $Credential
        }

        # DnsServer-cmdletarna saknar -Credential; med andra uppgifter måste
        # anropen gå via en CIM-session i stället för -ComputerName. Kan ingen
        # session upprättas kastar hjälparen och körningen avbryts.
        $serverParameters = Get-DnsServerParameter -ComputerName $ComputerName -Credential $Credential

        $logParameters = @{}

        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            $logParameters['LogPath'] = $LogPath
        }

        # --- Preflight -------------------------------------------------------
        $summaryLines = New-Object System.Collections.Generic.List[string]

        foreach ($zoneGroup in ($collectedRecords | Group-Object -Property ReverseZone)) {
            $summaryLines.Add(('  {0}: {1} PTR-post(er)' -f $zoneGroup.Name, $zoneGroup.Count))
        }

        $preflightText = "Följande PTR-poster är markerade för borttagning på '$ComputerName':" +
            [System.Environment]::NewLine +
            ($summaryLines -join [System.Environment]::NewLine)

        Write-Verbose $preflightText

        # ShouldContinue får inte ställa någon fråga under -WhatIf; då sköter
        # ShouldProcess simuleringen längre ned i stället.
        if (-not $Force -and -not $WhatIfPreference) {
            $shouldContinueQuery = $preflightText +
                [System.Environment]::NewLine +
                ('Vill du ta bort {0} PTR-post(er)?' -f $collectedRecords.Count)

            if (-not $PSCmdlet.ShouldContinue($shouldContinueQuery, 'Ta bort föräldralösa PTR-poster')) {
                Write-Verbose 'Borttagningen avbröts av användaren.'
                return
            }
        }

        $zoneTable = $null

        foreach ($orphanPtr in $collectedRecords) {
            $reverseZoneName = [string]$orphanPtr.ReverseZone
            $ptrOwnerName = [string]$orphanPtr.PtrOwnerName
            $ptrTarget = [string]$orphanPtr.PtrTarget
            $ipAddressText = [string]$orphanPtr.IPAddress
            $orphanStatus = [string]$orphanPtr.Status

            if (
                [string]::IsNullOrWhiteSpace($reverseZoneName) -or
                [string]::IsNullOrWhiteSpace($ptrOwnerName)
            ) {
                Write-Warning 'En post saknar ReverseZone eller PtrOwnerName – hoppas över.'

                Write-DnsAdminLog @logParameters `
                    -ComputerName $ComputerName `
                    -Action 'RemovePtr' `
                    -ZoneName $reverseZoneName `
                    -RecordName $ptrOwnerName `
                    -RecordType 'PTR' `
                    -RecordData $ptrTarget `
                    -Result 'Skipped' `
                    -ErrorMessage 'Ofullständigt OrphanPtr-objekt.'

                New-DnsRemovalResultObject `
                    -Name $ptrOwnerName `
                    -IPAddress $ipAddressText `
                    -ZoneName $reverseZoneName `
                    -RecordType 'PTR' `
                    -Action 'RemovePtr' `
                    -Result 'Skipped' `
                    -ErrorMessage 'Ofullständigt OrphanPtr-objekt.'

                continue
            }

            # --- Omverifiering 1: finns PTR-posten kvar och pekar den likadant?
            $currentPtrRecords = @(
                Get-DnsServerResourceRecord @serverParameters `
                    -ZoneName $reverseZoneName `
                    -Name $ptrOwnerName `
                    -RRType 'PTR' `
                    -ErrorAction SilentlyContinue
            )

            $matchingPtrRecords = @(
                $currentPtrRecords |
                    Where-Object {
                        Test-DnsNameEqual -First $_.RecordData.PtrDomainName -Second $ptrTarget
                    }
            )

            if ($matchingPtrRecords.Count -eq 0) {
                $skipReason = "PTR-posten '$ptrOwnerName' i '$reverseZoneName' pekar inte längre på '$ptrTarget'."

                Write-Warning "$skipReason Hoppas över."

                Write-DnsAdminLog @logParameters `
                    -ComputerName $ComputerName `
                    -Action 'RemovePtr' `
                    -ZoneName $reverseZoneName `
                    -RecordName $ptrOwnerName `
                    -RecordType 'PTR' `
                    -RecordData $ptrTarget `
                    -Result 'Skipped' `
                    -ErrorMessage $skipReason

                New-DnsRemovalResultObject `
                    -Name $ptrOwnerName `
                    -IPAddress $ipAddressText `
                    -ZoneName $reverseZoneName `
                    -RecordType 'PTR' `
                    -Action 'RemovePtr' `
                    -Result 'Skipped' `
                    -ErrorMessage $skipReason

                continue
            }

            # --- Omverifiering 2: har A-posten hunnit återskapas? -------------
            if ($null -eq $zoneTable) {
                $zoneTable = Get-DnsZoneTable -ComputerName $ComputerName @credentialParameters
            }

            $forwardZoneName = Get-MatchingDnsZone -DnsName $ptrTarget -ZoneNames $zoneTable.ForwardZones
            $currentARecords = @()

            if ([string]::IsNullOrWhiteSpace($forwardZoneName)) {
                Write-Verbose "Ingen forwardzon på '$ComputerName' matchar '$ptrTarget' — A-posten kan inte finnas."
            }
            else {
                $relativeTargetName = Get-RelativeRecordName -DnsName $ptrTarget -ZoneName $forwardZoneName

                $currentARecords = @(
                    Get-DnsServerResourceRecord @serverParameters `
                        -ZoneName $forwardZoneName `
                        -Name $relativeTargetName `
                        -RRType 'A' `
                        -ErrorAction SilentlyContinue
                )
            }

            $skipReason = $null

            if ($orphanStatus -eq 'IpMismatch') {
                # Mismatchen ska fortfarande gälla: hittas IP-adressen nu bland
                # målnamnets A-poster är PTR-posten korrekt och ska vara kvar.
                foreach ($aRecord in $currentARecords) {
                    $currentAddress = [string]$aRecord.RecordData.IPv4Address

                    if ([string]::Equals($currentAddress, $ipAddressText, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $skipReason = "A-posten '$ptrTarget' pekar nu på $ipAddressText — PTR-posten är inte längre felaktig."
                        break
                    }
                }
            }
            elseif ($currentARecords.Count -gt 0) {
                $skipReason = "A-posten '$ptrTarget' finns igen — PTR-posten är inte längre föräldralös."
            }

            if ($null -ne $skipReason) {
                Write-Warning "$skipReason Hoppas över."

                Write-DnsAdminLog @logParameters `
                    -ComputerName $ComputerName `
                    -Action 'RemovePtr' `
                    -ZoneName $reverseZoneName `
                    -RecordName $ptrOwnerName `
                    -RecordType 'PTR' `
                    -RecordData $ptrTarget `
                    -Result 'Skipped' `
                    -ErrorMessage $skipReason

                New-DnsRemovalResultObject `
                    -Name $ptrOwnerName `
                    -IPAddress $ipAddressText `
                    -ZoneName $reverseZoneName `
                    -RecordType 'PTR' `
                    -Action 'RemovePtr' `
                    -Result 'Skipped' `
                    -ErrorMessage $skipReason

                continue
            }

            # --- Borttagning -------------------------------------------------
            $shouldProcessTarget = "PTR $ptrOwnerName i $reverseZoneName ($ipAddressText -> $ptrTarget)"

            if (-not $PSCmdlet.ShouldProcess($shouldProcessTarget, 'Ta bort PTR-post')) {
                Write-DnsAdminLog @logParameters `
                    -ComputerName $ComputerName `
                    -Action 'RemovePtr' `
                    -ZoneName $reverseZoneName `
                    -RecordName $ptrOwnerName `
                    -RecordType 'PTR' `
                    -RecordData $ptrTarget `
                    -Result 'WhatIf'

                New-DnsRemovalResultObject `
                    -Name $ptrOwnerName `
                    -IPAddress $ipAddressText `
                    -ZoneName $reverseZoneName `
                    -RecordType 'PTR' `
                    -Action 'RemovePtr' `
                    -Result 'WhatIf'

                continue
            }

            $removalError = $null

            foreach ($ptrRecord in $matchingPtrRecords) {
                try {
                    # Pipelineformen är den enda som fungerar rent: parameter-
                    # uppsättningen -Name/-RRType/-RecordData raderar posten men
                    # felrapporterar på Windows Server 2022/2025.
                    $ptrRecord |
                        Remove-DnsServerResourceRecord @serverParameters `
                            -ZoneName $reverseZoneName `
                            -Force `
                            -ErrorAction Stop
                }
                catch {
                    $removalError = $_
                    Write-Error -ErrorRecord $_
                    break
                }
            }

            if ($null -eq $removalError) {
                Write-DnsAdminLog @logParameters `
                    -ComputerName $ComputerName `
                    -Action 'RemovePtr' `
                    -ZoneName $reverseZoneName `
                    -RecordName $ptrOwnerName `
                    -RecordType 'PTR' `
                    -RecordData $ptrTarget `
                    -Result 'Success'

                New-DnsRemovalResultObject `
                    -Name $ptrOwnerName `
                    -IPAddress $ipAddressText `
                    -ZoneName $reverseZoneName `
                    -RecordType 'PTR' `
                    -Action 'RemovePtr' `
                    -Result 'Success'
            }
            else {
                Write-DnsAdminLog @logParameters `
                    -ComputerName $ComputerName `
                    -Action 'RemovePtr' `
                    -ZoneName $reverseZoneName `
                    -RecordName $ptrOwnerName `
                    -RecordType 'PTR' `
                    -RecordData $ptrTarget `
                    -Result 'Failed' `
                    -ErrorMessage $removalError.Exception.Message

                New-DnsRemovalResultObject `
                    -Name $ptrOwnerName `
                    -IPAddress $ipAddressText `
                    -ZoneName $reverseZoneName `
                    -RecordType 'PTR' `
                    -Action 'RemovePtr' `
                    -Result 'Failed' `
                    -ErrorMessage $removalError.Exception.Message
            }
        }
    }
}
