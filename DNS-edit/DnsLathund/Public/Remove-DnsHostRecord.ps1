function Remove-DnsHostRecord {
    <#
        .SYNOPSIS
            Tar bort A-poster tillsammans med deras PTR-poster.

        .DESCRIPTION
            Ersätter de gamla scripten remove-dnsEntry.ps1 och
            "Remove-DnsRecordsFromFile .ps1". Namn kan anges direkt (-Name),
            läsas från en textfil (-Path, en post per rad; blanka rader och
            rader som börjar med # hoppas över, resten trimmas och sorteras
            unikt) eller pipas in som DnsLathund.RecordPair-objekt från
            Find-DnsRecord (-InputObject).

            process-blocket samlar in, end-blocket agerar: först en
            preflight-tabell (1:1 / PTR saknas / PTR pekar på annat namn /
            A saknas / flera A-poster), därefter en ShouldContinue-grind om
            -Force inte angetts, sedan ShouldProcess per post.

            PTR tas bort före A. Ett avbrott lämnar då en ofarlig "A utan PTR"
            som en omkörning självläker, i stället för de orphan-PTR som modulen
            är byggd för att jaga.

            PTR som pekar på ett annat namn hoppas över om inte
            -IncludeUnmatchedPtr anges. Med -KeepPtr tas endast A-posten bort.

            Alla operationer, även -WhatIf, loggas till JSONL-loggen.

        .EXAMPLE
            Remove-DnsHostRecord -Name 'srv01.contoso.local' -ComputerName 'dc01' -WhatIf

            Visar vad som skulle tas bort utan att ändra något.

        .EXAMPLE
            Remove-DnsHostRecord -Path '.\avvecklade.txt' -ComputerName 'dc01' -Force

            Massborttagning från fil utan bekräftelsegrind.

        .EXAMPLE
            Find-DnsRecord -Identity 'srv0*' -ComputerName 'dc01' -ZoneName 'contoso.local' | Remove-DnsHostRecord -ComputerName 'dc01'

            Tar bort de poster en sökning hittade.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingWriteHost',
        '',
        Justification = 'interaktiv preflight-rapport'
    )]
    [CmdletBinding(
        DefaultParameterSetName = 'ByName',
        SupportsShouldProcess,
        ConfirmImpact = 'High'
    )]
    [OutputType([PSCustomObject])]
    param (
        # OBS: -Name får INTE ha ValueFromPipelineByPropertyName. RecordPair har
        # en Name-egenskap, och namnbindningen (fas 2 i parameterbindningen)
        # vinner då över värdebindningen till -InputObject. Följden blir att
        # "Find-DnsRecord | Remove-DnsHostRecord" hamnar i ByName och gör ett
        # onödigt — och med -ZoneName potentiellt felaktigt — omuppslag.
        # Verifierat på både 5.1 och 7.
        [Parameter(
            Mandatory,
            Position = 0,
            ValueFromPipeline,
            ParameterSetName = 'ByName'
        )]
        [ValidateNotNullOrEmpty()]
        [Alias('HostName')]
        [string[]]$Name,

        [Parameter(Mandatory, ParameterSetName = 'ByFile')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            if (Test-Path -LiteralPath $_ -PathType Leaf) {
                $true
            }
            else {
                throw "Filen '$_' hittades inte."
            }
        })]
        [Alias('FullName', 'FilePath')]
        [string]$Path,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByInputObject')]
        [PSTypeName('DnsLathund.RecordPair')]
        [PSObject[]]$InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ZoneName,

        [Parameter()]
        [switch]$IncludeUnmatchedPtr,

        [Parameter()]
        [switch]$KeepPtr,

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
        Assert-DnsServerModule

        # -Force ska slippa både batchgrinden och ShouldProcess-frågan (som
        # annars alltid ställs eftersom ConfirmImpact är High). -WhatIf och ett
        # uttryckligt -Confirm väger tyngre.
        if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
            $ConfirmPreference = 'None'
        }

        $collectedNames = [System.Collections.Generic.List[string]]::new()
        $collectedPairs = [System.Collections.Generic.List[object]]::new()

        $unmatchedPtrRelation = 'PTR pekar på annat namn'
    }

    process {
        switch ($PSCmdlet.ParameterSetName) {
            'ByName' {
                foreach ($nameValue in $Name) {
                    if (-not [string]::IsNullOrWhiteSpace($nameValue)) {
                        $collectedNames.Add($nameValue.Trim())
                    }
                }
            }

            'ByInputObject' {
                foreach ($pairValue in $InputObject) {
                    if ($null -ne $pairValue) {
                        $collectedPairs.Add($pairValue)
                    }
                }
            }
        }
    }

    end {
        # --- 1. Samla ihop de namn som ska slås upp ---
        $namesToResolve = @()

        if ($PSCmdlet.ParameterSetName -eq 'ByFile') {
            # Beprövat mönster från de gamla scripten: trimma, hoppa över
            # blanka rader och kommentarer, sortera unikt.
            $namesToResolve = @(
                Get-Content -LiteralPath $Path -ErrorAction Stop |
                    ForEach-Object { $_.Trim() } |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace($_) -and
                        -not $_.StartsWith('#')
                    } |
                    Sort-Object -Unique
            )
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'ByName') {
            $namesToResolve = @($collectedNames)
        }

        # --- 2. Lös upp namnen till RecordPair-objekt ---
        $pairs = [System.Collections.Generic.List[object]]::new()
        $missingNames = [System.Collections.Generic.List[string]]::new()
        $multipleARecordCount = 0

        if ($PSCmdlet.ParameterSetName -eq 'ByInputObject') {
            foreach ($collectedPair in $collectedPairs) {
                $pairs.Add($collectedPair)
            }
        }
        else {
            $resolveParameters = @{ ComputerName = $ComputerName }

            if ($PSBoundParameters.ContainsKey('ZoneName')) {
                $resolveParameters['ZoneName'] = $ZoneName
            }

            if ($null -ne $Credential) {
                $resolveParameters['Credential'] = $Credential
            }

            foreach ($nameToResolve in $namesToResolve) {
                $resolvedPairs = @(
                    Resolve-DnsRecordPair -Identity $nameToResolve @resolveParameters
                )

                if ($resolvedPairs.Count -eq 0) {
                    $missingNames.Add($nameToResolve)
                    continue
                }

                if ($resolvedPairs.Count -gt 1) {
                    $multipleARecordCount++
                }

                foreach ($resolvedPair in $resolvedPairs) {
                    $pairs.Add($resolvedPair)
                }
            }
        }

        $totalEntries = $pairs.Count + $missingNames.Count

        if ($totalEntries -eq 0) {
            Write-Warning 'Inga poster att behandla.'

            [PSCustomObject]@{
                Total   = 0
                Removed = 0
                Failed  = 0
                Skipped = 0
            }

            return
        }

        # --- 3. Preflight-rapport vid bulk ---
        $isBulk = (
            $PSCmdlet.ParameterSetName -eq 'ByFile' -or
            $totalEntries -gt 1
        )

        if ($isBulk) {
            $relationCounts = [ordered]@{
                '1:1'                                             = 0
                'PTR saknas'                                      = 0
                $unmatchedPtrRelation                             = 0
                'Matchande PTR finns, men relationen är inte 1:1' = 0
            }

            foreach ($pair in $pairs) {
                if ($relationCounts.Contains($pair.Relation)) {
                    $relationCounts[$pair.Relation] = $relationCounts[$pair.Relation] + 1
                }
            }

            Write-Host ''
            Write-Host "Preflight — DNS-rensning mot $ComputerName" -ForegroundColor Cyan
            Write-Host ('-' * 62)

            foreach ($relationKey in $relationCounts.Keys) {
                $label = $relationKey

                if ($relationKey -eq $unmatchedPtrRelation -and -not $IncludeUnmatchedPtr) {
                    $label = "$relationKey (hoppas över)"
                }

                Write-Host ('  {0,-52}{1,6}' -f $label, $relationCounts[$relationKey])
            }

            Write-Host ('  {0,-52}{1,6}' -f 'A saknas', $missingNames.Count)
            Write-Host ('  {0,-52}{1,6}' -f 'Flera A-poster', $multipleARecordCount)
            Write-Host ('-' * 62)
            Write-Host ('  {0,-52}{1,6}' -f 'Totalt antal poster', $totalEntries)

            if ($KeepPtr) {
                Write-Host '  -KeepPtr angavs: endast A-posterna tas bort.'
            }

            Write-Host ''
        }

        # --- 4. Bekräftelsegrind för hela batchen ---
        $batchDeclined = $false

        if ($isBulk -and -not $Force -and -not $WhatIfPreference) {
            $batchDeclined = -not $PSCmdlet.ShouldContinue(
                "Ta bort $($pairs.Count) poster (A + matchande PTR) på '$ComputerName'?",
                'DNS-rensning'
            )
        }

        # --- 5. Agera per post ---
        $removeParameters = @{ ComputerName = $ComputerName }

        if ($KeepPtr) {
            $removeParameters['KeepPtr'] = $true
        }

        if ($IncludeUnmatchedPtr) {
            $removeParameters['IncludeUnmatchedPtr'] = $true
        }

        if ($PSBoundParameters.ContainsKey('LogPath')) {
            $removeParameters['LogPath'] = $LogPath
        }

        if ($null -ne $Credential) {
            $removeParameters['Credential'] = $Credential
        }

        $logParameters = @{ ComputerName = $ComputerName }

        if ($PSBoundParameters.ContainsKey('LogPath')) {
            $logParameters['LogPath'] = $LogPath
        }

        $removedCount = 0
        $failedCount = 0
        $skippedCount = 0

        foreach ($missingName in $missingNames) {
            New-DnsRemovalResultObject `
                -Name $missingName `
                -RecordType 'A' `
                -Action 'RemoveA' `
                -Result 'Skipped' `
                -ErrorMessage 'A saknas — ingen A-post hittades för namnet.'

            $skippedCount++
        }

        foreach ($pair in $pairs) {
            if ($batchDeclined) {
                New-DnsRemovalResultObject `
                    -Name $pair.Name `
                    -IPAddress $pair.IPv4Address `
                    -ZoneName $pair.ForwardZone `
                    -RecordType 'A' `
                    -Action 'RemoveA' `
                    -Result 'Skipped' `
                    -ErrorMessage 'Borttagningen avbröts vid bekräftelsegrinden.'

                $skippedCount++
                continue
            }

            if ($pair.Relation -eq $unmatchedPtrRelation -and -not $IncludeUnmatchedPtr) {
                Write-DnsAdminLog @logParameters `
                    -Action 'RemoveA' `
                    -ZoneName $pair.ForwardZone `
                    -RecordName $pair.Name `
                    -RecordType 'A' `
                    -RecordData $pair.IPv4Address `
                    -Result 'Skipped' `
                    -ErrorMessage $unmatchedPtrRelation

                New-DnsRemovalResultObject `
                    -Name $pair.Name `
                    -IPAddress $pair.IPv4Address `
                    -ZoneName $pair.ForwardZone `
                    -RecordType 'A' `
                    -Action 'RemoveA' `
                    -Result 'Skipped' `
                    -ErrorMessage "$unmatchedPtrRelation — posten hoppades över. Ange -IncludeUnmatchedPtr för att ta bort A-posten ändå."

                $skippedCount++
                continue
            }

            $shouldProcessTarget = '{0} ({1}) + PTR' -f $pair.Name, $pair.IPv4Address

            if ($PSCmdlet.ShouldProcess($shouldProcessTarget, 'Ta bort A- och PTR-post')) {
                $pairResults = @(Remove-DnsRecordPair -InputObject $pair @removeParameters)

                foreach ($pairResult in $pairResults) {
                    $pairResult
                }

                $hasFailure = @(
                    $pairResults | Where-Object { $_.Result -eq 'Failed' }
                ).Count -gt 0

                $aRemoved = @(
                    $pairResults |
                        Where-Object { $_.Action -eq 'RemoveA' -and $_.Result -eq 'Success' }
                ).Count -gt 0

                if ($hasFailure) {
                    $failedCount++
                }
                elseif ($aRemoved) {
                    $removedCount++
                }
                else {
                    $skippedCount++
                }

                continue
            }

            if ($WhatIfPreference) {
                $plannedPtrCount = @(
                    $pair.MatchingPtrRecords | Where-Object { $null -ne $_ }
                ).Count

                if (-not $KeepPtr -and $plannedPtrCount -gt 0) {
                    Write-DnsAdminLog @logParameters `
                        -Action 'RemovePtr' `
                        -ZoneName $pair.ReverseZone `
                        -RecordName $pair.PtrNodeName `
                        -RecordType 'PTR' `
                        -RecordData $pair.Name `
                        -Result 'WhatIf'

                    New-DnsRemovalResultObject `
                        -Name $pair.Name `
                        -IPAddress $pair.IPv4Address `
                        -ZoneName $pair.ReverseZone `
                        -RecordType 'PTR' `
                        -Action 'RemovePtr' `
                        -Result 'WhatIf'
                }

                Write-DnsAdminLog @logParameters `
                    -Action 'RemoveA' `
                    -ZoneName $pair.ForwardZone `
                    -RecordName $pair.Name `
                    -RecordType 'A' `
                    -RecordData $pair.IPv4Address `
                    -Result 'WhatIf'

                New-DnsRemovalResultObject `
                    -Name $pair.Name `
                    -IPAddress $pair.IPv4Address `
                    -ZoneName $pair.ForwardZone `
                    -RecordType 'A' `
                    -Action 'RemoveA' `
                    -Result 'WhatIf'

                continue
            }

            # ShouldProcess besvarades med nej.
            Write-DnsAdminLog @logParameters `
                -Action 'RemoveA' `
                -ZoneName $pair.ForwardZone `
                -RecordName $pair.Name `
                -RecordType 'A' `
                -RecordData $pair.IPv4Address `
                -Result 'Skipped' `
                -ErrorMessage 'Operatören avböjde borttagningen.'

            New-DnsRemovalResultObject `
                -Name $pair.Name `
                -IPAddress $pair.IPv4Address `
                -ZoneName $pair.ForwardZone `
                -RecordType 'A' `
                -Action 'RemoveA' `
                -Result 'Skipped' `
                -ErrorMessage 'Operatören avböjde borttagningen.'

            $skippedCount++
        }

        # --- 6. Summering ---
        [PSCustomObject]@{
            Total   = $totalEntries
            Removed = $removedCount
            Failed  = $failedCount
            Skipped = $skippedCount
        }
    }
}
