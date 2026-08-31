function Remove-DnsRecordPair {
    <#
        .SYNOPSIS
            Delad borttagningsmotor för A- och PTR-poster.

        .DESCRIPTION
            Tar bort PTR först och därefter A. Ordningen är medveten: ett avbrott
            mitt i lämnar en ofarlig "A utan PTR" som en omkörning självläker,
            medan motsatt ordning skapar exakt de orphan-PTR som modulen jagar.

            Misslyckas PTR-borttagningen tas A-posten INTE bort. Att radera A
            när PTR ligger kvar skulle skapa en föräldralös PTR, alltså precis
            det tillstånd ordningen är till för att undvika.

            Borttagning sker enbart via pipelineformen
            "$record | Remove-DnsServerResourceRecord -ZoneName z -ComputerName s -Force",
            vilket undviker det kosmetiska felet på Server 2022/2025.

            Varje operation loggas med Write-DnsAdminLog och returnerar ett
            DnsLathund.RemovalResult.

            Funktionen anropar medvetet INTE ShouldProcess — grindarna
            (preflight, ShouldContinue och ShouldProcess) ligger i den publika
            anroparen Remove-DnsHostRecord. Ett ärvt $WhatIfPreference slår
            ändå igenom på Remove-DnsServerResourceRecord.

        .EXAMPLE
            $pair | Remove-DnsRecordPair -ComputerName 'dc01'

            Tar bort PTR och A för ett RecordPair.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Grindarna (preflight, ShouldContinue och ShouldProcess) ligger i den publika anroparen Remove-DnsHostRecord.'
    )]
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSTypeName('DnsLathund.RecordPair')]
        [PSObject]$InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [switch]$KeepPtr,

        [Parameter()]
        [switch]$IncludeUnmatchedPtr,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    begin {
        # Remove-DnsServerResourceRecord saknar -Credential. När andra
        # uppgifter anges måste borttagningen gå via en CIM-session; kan ingen
        # session upprättas kastar hjälparen. En tyst nedgradering till den
        # inloggade användarens rättigheter vore oacceptabel just här: det är
        # den här funktionen som faktiskt raderar poster.
        $serverParameters = Get-DnsServerParameter -ComputerName $ComputerName -Credential $Credential

        $logParameters = @{ ComputerName = $ComputerName }

        if ($PSBoundParameters.ContainsKey('LogPath')) {
            $logParameters['LogPath'] = $LogPath
        }
    }

    process {
        $recordName = $InputObject.Name
        $ipAddress = $InputObject.IPv4Address
        # Filtret tål ett handbyggt eller deserialiserat RecordPair där
        # MatchingPtrRecords är $null — @($null) hade annars gett ett element.
        $matchingPtrRecords = @(
            $InputObject.MatchingPtrRecords | Where-Object { $null -ne $_ }
        )

        if (
            $InputObject.Relation -eq 'PTR pekar på annat namn' -and
            -not $IncludeUnmatchedPtr
        ) {
            # Skyddsnät om motorn anropas utan den publika grinden.
            Write-DnsAdminLog @logParameters `
                -Action 'RemoveA' `
                -ZoneName $InputObject.ForwardZone `
                -RecordName $recordName `
                -RecordType 'A' `
                -RecordData $ipAddress `
                -Result 'Skipped' `
                -ErrorMessage 'PTR pekar på annat namn.'

            New-DnsRemovalResultObject `
                -Name $recordName `
                -IPAddress $ipAddress `
                -ZoneName $InputObject.ForwardZone `
                -RecordType 'A' `
                -Action 'RemoveA' `
                -Result 'Skipped' `
                -ErrorMessage 'PTR pekar på annat namn. Ange -IncludeUnmatchedPtr för att ta bort A-posten ändå.'

            return
        }

        $ptrRemovalFailed = $false

        # --- PTR först ---
        if ($KeepPtr) {
            if ($matchingPtrRecords.Count -gt 0) {
                Write-DnsAdminLog @logParameters `
                    -Action 'RemovePtr' `
                    -ZoneName $InputObject.ReverseZone `
                    -RecordName $InputObject.PtrNodeName `
                    -RecordType 'PTR' `
                    -RecordData $recordName `
                    -Result 'Skipped' `
                    -ErrorMessage '-KeepPtr angavs.'

                New-DnsRemovalResultObject `
                    -Name $recordName `
                    -IPAddress $ipAddress `
                    -ZoneName $InputObject.ReverseZone `
                    -RecordType 'PTR' `
                    -Action 'RemovePtr' `
                    -Result 'Skipped' `
                    -ErrorMessage 'PTR-posten behölls eftersom -KeepPtr angavs.'
            }
        }
        else {
            foreach ($ptrRecord in $matchingPtrRecords) {
                $ptrTarget = ConvertTo-CanonicalDnsName -Name $ptrRecord.RecordData.PtrDomainName

                try {
                    $ptrRecord |
                        Remove-DnsServerResourceRecord @serverParameters `
                            -ZoneName $InputObject.ReverseZone `
                            -Force `
                            -ErrorAction Stop

                    Write-DnsAdminLog @logParameters `
                        -Action 'RemovePtr' `
                        -ZoneName $InputObject.ReverseZone `
                        -RecordName $InputObject.PtrNodeName `
                        -RecordType 'PTR' `
                        -RecordData $ptrTarget `
                        -Result 'Success'

                    New-DnsRemovalResultObject `
                        -Name $recordName `
                        -IPAddress $ipAddress `
                        -ZoneName $InputObject.ReverseZone `
                        -RecordType 'PTR' `
                        -Action 'RemovePtr' `
                        -Result 'Success'
                }
                catch {
                    $ptrRemovalFailed = $true

                    $failureMessage = "Kunde inte ta bort PTR-posten för $ipAddress ($ptrTarget): $($_.Exception.Message)"

                    Write-DnsAdminLog @logParameters `
                        -Action 'RemovePtr' `
                        -ZoneName $InputObject.ReverseZone `
                        -RecordName $InputObject.PtrNodeName `
                        -RecordType 'PTR' `
                        -RecordData $ptrTarget `
                        -Result 'Failed' `
                        -ErrorMessage $failureMessage

                    New-DnsRemovalResultObject `
                        -Name $recordName `
                        -IPAddress $ipAddress `
                        -ZoneName $InputObject.ReverseZone `
                        -RecordType 'PTR' `
                        -Action 'RemovePtr' `
                        -Result 'Failed' `
                        -ErrorMessage $failureMessage

                    Write-Error -ErrorRecord $_
                }
            }
        }

        # --- Därefter A ---
        if ($ptrRemovalFailed) {
            $skipMessage = 'A-posten behölls eftersom PTR-borttagningen misslyckades. Annars hade en föräldralös PTR-post lämnats kvar.'

            Write-DnsAdminLog @logParameters `
                -Action 'RemoveA' `
                -ZoneName $InputObject.ForwardZone `
                -RecordName $recordName `
                -RecordType 'A' `
                -RecordData $ipAddress `
                -Result 'Skipped' `
                -ErrorMessage $skipMessage

            New-DnsRemovalResultObject `
                -Name $recordName `
                -IPAddress $ipAddress `
                -ZoneName $InputObject.ForwardZone `
                -RecordType 'A' `
                -Action 'RemoveA' `
                -Result 'Skipped' `
                -ErrorMessage $skipMessage

            return
        }

        try {
            $InputObject.ARecord |
                Remove-DnsServerResourceRecord @serverParameters `
                    -ZoneName $InputObject.ForwardZone `
                    -Force `
                    -ErrorAction Stop

            Write-DnsAdminLog @logParameters `
                -Action 'RemoveA' `
                -ZoneName $InputObject.ForwardZone `
                -RecordName $recordName `
                -RecordType 'A' `
                -RecordData $ipAddress `
                -Result 'Success'

            New-DnsRemovalResultObject `
                -Name $recordName `
                -IPAddress $ipAddress `
                -ZoneName $InputObject.ForwardZone `
                -RecordType 'A' `
                -Action 'RemoveA' `
                -Result 'Success'
        }
        catch {
            $failureMessage = "Kunde inte ta bort A-posten $recordName ($ipAddress): $($_.Exception.Message)"

            if (-not $KeepPtr -and $matchingPtrRecords.Count -gt 0) {
                $failureMessage += ' PTR-posten är redan borttagen; en omkörning rapporterar därför "PTR saknas", vilket är väntat och självläkande.'
            }

            Write-DnsAdminLog @logParameters `
                -Action 'RemoveA' `
                -ZoneName $InputObject.ForwardZone `
                -RecordName $recordName `
                -RecordType 'A' `
                -RecordData $ipAddress `
                -Result 'Failed' `
                -ErrorMessage $failureMessage

            New-DnsRemovalResultObject `
                -Name $recordName `
                -IPAddress $ipAddress `
                -ZoneName $InputObject.ForwardZone `
                -RecordType 'A' `
                -Action 'RemoveA' `
                -Result 'Failed' `
                -ErrorMessage $failureMessage

            Write-Error -ErrorRecord $_
        }
    }
}
