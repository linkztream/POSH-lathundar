function Invoke-DnsMenuChoice {
    <#
        .SYNOPSIS
            Visar en konsolmeny och returnerar index för det valda alternativet.

        .DESCRIPTION
            Tunn inkapsling av $Host.UI.PromptForChoice. Finns som egen funktion
            av två skäl: all interaktivitet i Invoke-DnsRecordEditor samlas på
            ett ställe, och testerna kan mocka den i stället för att blockera på
            en riktig prompt.

            Varje alternativ anges som en hashtabell med nycklarna Label och
            Help. Etiketten får innehålla & för snabbtangent.

            Funktionen exporteras inte av modulen.

        .EXAMPLE
            Invoke-DnsMenuChoice -Title 'Åtgärd' -Message 'Vad vill du göra?' -Choice @(
                @{ Label = '&Redigera'; Help = 'Ändra posten' }
                @{ Label = '&Avbryt'; Help = 'Avsluta' }
            ) -DefaultChoice 1

            Returnerar 0 för Redigera och 1 för Avbryt.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Title,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [hashtable[]]$Choice,

        [Parameter()]
        [int]$DefaultChoice = 0
    )

    $descriptions = [System.Management.Automation.Host.ChoiceDescription[]]@(
        foreach ($choiceItem in $Choice) {
            [System.Management.Automation.Host.ChoiceDescription]::new(
                [string]$choiceItem['Label'],
                [string]$choiceItem['Help']
            )
        }
    )

    return $Host.UI.PromptForChoice($Title, $Message, $descriptions, $DefaultChoice)
}

function Read-DnsIPv4Input {
    <#
        .SYNOPSIS
            Läser in en IPv4-adress från operatören med valideringsloop.

        .DESCRIPTION
            Frågar tills svaret är en giltig IPv4-adress och returnerar den
            normaliserad (till exempel '10.00.16.005' blir '10.0.16.5'). Ett
            tomt svar tolkas som avbryt och ger $null.

            Ligger i samma fil som Invoke-DnsRecordEditor och exporteras inte.

        .EXAMPLE
            $address = Read-DnsIPv4Input -Prompt 'Ny IPv4-adress'

            Returnerar adressen eller $null om användaren avbröt.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt
    )

    while ($true) {
        $answer = Read-Host -Prompt $Prompt

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $null
        }

        $answer = $answer.Trim()

        if (Test-IPv4Address -Value $answer) {
            return ([System.Net.IPAddress]::Parse($answer)).IPAddressToString
        }

        Write-Warning "'$answer' är inte en giltig IPv4-adress."
    }
}

function Get-DnsReverseZoneForAddress {
    <#
        .SYNOPSIS
            Hittar reverse-zon och nodnamn för en IPv4-adress.

        .DESCRIPTION
            Slår ihop ConvertTo-ReverseFqdn, Get-DnsZoneTable och
            Get-MatchingDnsZone till ett svar: ett objekt med ZoneName,
            NodeName och ReverseFqdn, eller $null när ingen reverse-zon på
            servern täcker adressen. Kastar aldrig — går zontabellen inte att
            läsa varnar funktionen och returnerar $null, eftersom en saknad
            reverse-zon aldrig får stoppa forward-delen av en ändring.

            Ligger i samma fil som Invoke-DnsRecordEditor och exporteras inte.

        .EXAMPLE
            $reverse = Get-DnsReverseZoneForAddress -IPAddress '10.0.16.5' -ComputerName 'dc01'

            Ger zonnamn och nodnamn för PTR-posten, eller $null.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IPAddress,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    $credentialSplat = @{}

    if ($null -ne $Credential) {
        $credentialSplat['Credential'] = $Credential
    }

    try {
        $zoneTable = Get-DnsZoneTable -ComputerName $ComputerName @credentialSplat
    }
    catch {
        Write-Warning "Kunde inte läsa zontabellen från '$ComputerName': $($_.Exception.Message)"

        return $null
    }

    $reverseFqdn = ConvertTo-ReverseFqdn -IPAddress $IPAddress
    $reverseZone = Get-MatchingDnsZone -DnsName $reverseFqdn -ZoneNames $zoneTable.ReverseZones

    if ([string]::IsNullOrWhiteSpace($reverseZone)) {
        return $null
    }

    return [PSCustomObject]@{
        ZoneName    = $reverseZone
        NodeName    = Get-RelativeRecordName -DnsName $reverseFqdn -ZoneName $reverseZone
        ReverseFqdn = $reverseFqdn
    }
}

function Invoke-DnsRecordEditor {
    <#
        .SYNOPSIS
            Interaktiv sök, redigera, skapa och ta bort för DNS-poster.

        .DESCRIPTION
            Söker upp posten med Find-DnsRecord och visar därefter en
            konsolmeny via $Host.UI.PromptForChoice (fungerar över remoting och
            på Server Core — Out-GridView används medvetet inte).

            Fler än 20 träffar: användaren ombeds förfina sökningen.
            2-20 träffar: urvalsmeny. En träff: meny med Redigera / Ta bort /
            Avbryt. Ingen träff: Skapa / Avbryt.

            Redigera använder Clone() plus Set-DnsServerResourceRecord med
            -OldInputObject/-NewInputObject. Saknas Clone (deserialiserat objekt
            i PS 7) läggs i stället en ny A-post till och den gamla tas bort via
            ett färskt objekt i pipelineform. PTR synkas: gammal matchande PTR
            tas bort och en ny läggs till om reverse-zon finns, annars varnas det.

            Ta bort delegerar till Remove-DnsHostRecord -InputObject.

            Skapa kontrollerar reverse-zonen först: finns den används
            Add-DnsServerResourceRecordA -CreatePtr (och om A skapades men PTR
            misslyckades görs ett separat Add-Ptr), annars skapas A utan PTR med
            en varning.

            Skapa erbjuds bara när Identity är ett vanligt namn. En IPv4-adress
            eller ett wildcardmönster utan träff ger bara en varning — det finns
            inget entydigt namn att skapa.

            Misslyckas ändringen av A-posten rörs PTR aldrig; ett halvfärdigt
            byte skulle annars lämna precis de föräldralösa PTR-poster modulen
            är byggd för att jaga.

            Varje steg (SetA, AddA, RemoveA, RemovePtr, AddPtr) loggas till
            JSONL-loggen, även vid -WhatIf.

        .EXAMPLE
            Invoke-DnsRecordEditor -Identity 'srv01.contoso.local' -ComputerName 'dc01'

            Öppnar den interaktiva menyn för posten.

        .EXAMPLE
            Invoke-DnsRecordEditor -Identity '10.0.16.5' -ComputerName 'dc01' -LogPath 'C:\Temp\dns.jsonl'

            Slår upp adressen och loggar till en egen fil.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingWriteHost',
        '',
        Justification = 'Funktionen är medvetet interaktiv: listningar och kvitton ska visas för operatören och aldrig hamna i pipelinen.'
    )]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [Alias('Name', 'HostName')]
        [string]$Identity,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ZoneName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    process {
        $credentialSplat = @{}

        if ($null -ne $Credential) {
            $credentialSplat['Credential'] = $Credential
        }

        $logSplat = @{}

        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            $logSplat['LogPath'] = $LogPath
        }

        # Serverparametrarna för DnsServer-cmdletarna: CimSession när
        # -Credential angetts, annars -ComputerName. Beräknas en gång här och
        # splattas in i varje skriv-/läsanrop nedan. Kan ingen CIM-session
        # upprättas när -Credential angetts kastar hjälparen direkt — vi kör
        # aldrig ändringar med fel rättigheter.
        $serverParameters = Get-DnsServerParameter -ComputerName $ComputerName -Credential $Credential

        $hasZoneName = -not [string]::IsNullOrWhiteSpace($ZoneName)
        $normalizedZone = if ($hasZoneName) { $ZoneName.TrimEnd('.') } else { $null }

        $identityIsIp = Test-IPv4Address -Value $Identity
        $identityIsWildcard = [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Identity)

        # 1. Sök. Find-DnsRecord varnar själv om inget matchar; den varningen
        #    tystas här och hanteras i stället nedan tillsammans med
        #    Skapa-erbjudandet.
        $findParameters = @{
            Identity      = $Identity
            ComputerName  = $ComputerName
            WarningAction = 'SilentlyContinue'
        }

        if ($hasZoneName) {
            $findParameters['ZoneName'] = $normalizedZone
        }

        $pairs = @(Find-DnsRecord @findParameters @credentialSplat)

        # 2. För många träffar: be om förfining i stället för att rada upp dem.
        if ($pairs.Count -gt 20) {
            Write-Warning 'Fler än 20 träffar – förfina sökningen.'
            Write-Host ("Sökningen '{0}' gav {1} träffar." -f $Identity, $pairs.Count)

            return
        }

        # 3. Ingen träff: erbjud Skapa för vanliga namn.
        if ($pairs.Count -eq 0) {
            Write-Warning "Inga poster matchade '$Identity'."

            if ($identityIsIp -or $identityIsWildcard) {
                return
            }

            $createChoice = Invoke-DnsMenuChoice `
                -Title 'Ingen träff' `
                -Message ("Ingen post matchade '{0}'. Vill du skapa den?" -f $Identity) `
                -Choice @(
                    @{ Label = '&Skapa'; Help = 'Skapa en ny A-post (och PTR om reverse-zon finns)' }
                    @{ Label = '&Avbryt'; Help = 'Avsluta utan att ändra något' }
                ) `
                -DefaultChoice 1

            if ($createChoice -ne 0) {
                Write-Host 'Avbrutet – ingen post skapades.'

                return
            }

            $targetName = ConvertTo-CanonicalDnsName -Name $Identity
            $targetZone = $null

            if ($hasZoneName) {
                $targetZone = $normalizedZone

                # Ett kort namn tillsammans med -ZoneName tolkas som relativt.
                if (
                    -not (Test-DnsNameEqual -First $targetName -Second $targetZone) -and
                    -not $targetName.EndsWith(".$targetZone", [System.StringComparison]::OrdinalIgnoreCase)
                ) {
                    $targetName = "$targetName.$targetZone"
                }
            }
            else {
                try {
                    $zoneTable = Get-DnsZoneTable -ComputerName $ComputerName @credentialSplat
                }
                catch {
                    $PSCmdlet.WriteError($_)

                    return
                }

                $targetZone = Get-MatchingDnsZone -DnsName $targetName -ZoneNames $zoneTable.ForwardZones

                if ([string]::IsNullOrWhiteSpace($targetZone)) {
                    $PSCmdlet.WriteError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.ArgumentException]::new(
                                "Ingen forward-zon på '$ComputerName' matchar '$targetName'. Ange -ZoneName."
                            ),
                            'ZoneNameRequiredForCreate',
                            [System.Management.Automation.ErrorCategory]::InvalidArgument,
                            $Identity
                        )
                    )

                    return
                }
            }

            $newAddress = Read-DnsIPv4Input -Prompt 'IPv4-adress för den nya A-posten'

            if ($null -eq $newAddress) {
                Write-Host 'Avbrutet – ingen adress angavs.'

                return
            }

            $relativeName = Get-RelativeRecordName -DnsName $targetName -ZoneName $targetZone

            # Reverse-zonen kollas före skapandet: den avgör om -CreatePtr kan
            # användas eller om posten måste skapas utan PTR.
            $createReverseZone = Get-DnsReverseZoneForAddress `
                -IPAddress $newAddress `
                -ComputerName $ComputerName `
                @credentialSplat

            if (-not $PSCmdlet.ShouldProcess("$targetName -> $newAddress", 'Skapa A-post')) {
                Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddA' `
                    -ZoneName $targetZone -RecordName $relativeName -RecordType 'A' `
                    -RecordData $newAddress -Result 'WhatIf'

                if ($null -ne $createReverseZone) {
                    Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddPtr' `
                        -ZoneName $createReverseZone.ZoneName -RecordName $createReverseZone.NodeName `
                        -RecordType 'PTR' -RecordData $targetName -Result 'WhatIf'
                }

                return
            }

            Assert-DnsServerModule

            if ($null -eq $createReverseZone) {
                Write-Warning "Ingen reverse-zon finns för $newAddress – PTR skapades inte."

                try {
                    Add-DnsServerResourceRecordA `
                        -Name $relativeName `
                        -ZoneName $targetZone `
                        @serverParameters `
                        -IPv4Address $newAddress `
                        -ErrorAction Stop

                    Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddA' `
                        -ZoneName $targetZone -RecordName $relativeName -RecordType 'A' `
                        -RecordData $newAddress -Result 'Success'

                    Write-Host ("Skapade A: {0} -> {1}" -f $targetName, $newAddress) -ForegroundColor Green
                }
                catch {
                    Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddA' `
                        -ZoneName $targetZone -RecordName $relativeName -RecordType 'A' `
                        -RecordData $newAddress -Result 'Failed' -ErrorMessage $_.Exception.Message

                    Write-Error -ErrorRecord $_
                }

                return
            }

            try {
                Add-DnsServerResourceRecordA `
                    -Name $relativeName `
                    -ZoneName $targetZone `
                    @serverParameters `
                    -IPv4Address $newAddress `
                    -CreatePtr `
                    -ErrorAction Stop

                Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddA' `
                    -ZoneName $targetZone -RecordName $relativeName -RecordType 'A' `
                    -RecordData $newAddress -Result 'Success'

                Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddPtr' `
                    -ZoneName $createReverseZone.ZoneName -RecordName $createReverseZone.NodeName `
                    -RecordType 'PTR' -RecordData $targetName -Result 'Success'

                Write-Host ("Skapade A + PTR: {0} -> {1}" -f $targetName, $newAddress) -ForegroundColor Green
            }
            catch {
                $createError = $_

                # -CreatePtr är inte atomiskt: A-posten kan ha skapats även när
                # anropet felar. Punktuppslag avgör vilket som hände.
                $createdARecords = @(
                    Get-DnsServerResourceRecord `
                        @serverParameters `
                        -ZoneName $targetZone `
                        -Name $relativeName `
                        -RRType A `
                        -ErrorAction SilentlyContinue |
                        Where-Object {
                            "$($_.RecordData.IPv4Address)" -eq $newAddress
                        }
                )

                if ($createdARecords.Count -eq 0) {
                    Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddA' `
                        -ZoneName $targetZone -RecordName $relativeName -RecordType 'A' `
                        -RecordData $newAddress -Result 'Failed' -ErrorMessage $createError.Exception.Message

                    Write-Error -ErrorRecord $createError

                    return
                }

                Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddA' `
                    -ZoneName $targetZone -RecordName $relativeName -RecordType 'A' `
                    -RecordData $newAddress -Result 'Success'

                Write-Warning ("A-posten skapades men PTR misslyckades: {0}" -f $createError.Exception.Message)

                try {
                    Add-DnsServerResourceRecordPtr `
                        -Name $createReverseZone.NodeName `
                        -ZoneName $createReverseZone.ZoneName `
                        @serverParameters `
                        -PtrDomainName $targetName `
                        -ErrorAction Stop

                    Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddPtr' `
                        -ZoneName $createReverseZone.ZoneName -RecordName $createReverseZone.NodeName `
                        -RecordType 'PTR' -RecordData $targetName -Result 'Success'

                    Write-Host ("Skapade PTR i efterhand: {0} -> {1}" -f $newAddress, $targetName) -ForegroundColor Green
                }
                catch {
                    Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddPtr' `
                        -ZoneName $createReverseZone.ZoneName -RecordName $createReverseZone.NodeName `
                        -RecordType 'PTR' -RecordData $targetName -Result 'Failed' -ErrorMessage $_.Exception.Message

                    Write-Warning ("PTR kunde inte skapas manuellt heller: {0}" -f $_.Exception.Message)
                }
            }

            return
        }

        # 4. 2-20 träffar: urvalsmeny.
        $pair = $pairs[0]

        if ($pairs.Count -gt 1) {
            Write-Host ''
            Write-Host ("{0} träffar på {1}" -f $pairs.Count, $ComputerName) -ForegroundColor Cyan
            Write-Host ('-' * 78)

            $selectionChoices = @(
                for ($index = 0; $index -lt $pairs.Count; $index++) {
                    $candidate = $pairs[$index]

                    # PromptForChoice slår upp snabbtangenten på ett tecken.
                    # Alternativ 10 och uppåt får därför ingen &-snabbtangent
                    # (den skulle krocka med 1); de väljs genom att skriva
                    # hela numret.
                    $label = if ($index -lt 9) {
                        '&{0} - {1} ({2})' -f ($index + 1), $candidate.Name, $candidate.IPv4Address
                    }
                    else {
                        '{0} - {1} ({2})' -f ($index + 1), $candidate.Name, $candidate.IPv4Address
                    }

                    @{
                        Label = $label
                        Help  = '{0} i zonen {1} [{2}]' -f $candidate.Name, $candidate.ForwardZone, $candidate.Relation
                    }
                }

                @{ Label = '&Avbryt'; Help = 'Avsluta utan att ändra något' }
            )

            $selection = Invoke-DnsMenuChoice `
                -Title 'Flera träffar' `
                -Message 'Vilken post vill du arbeta med?' `
                -Choice $selectionChoices `
                -DefaultChoice ($selectionChoices.Count - 1)

            if ($selection -lt 0 -or $selection -ge $pairs.Count) {
                Write-Host 'Avbrutet.'

                return
            }

            $pair = $pairs[$selection]
        }

        # 5. Visa posten och fråga vad som ska göras.
        $ptrDisplay = if (@($pair.PtrTargets).Count -gt 0) {
            @($pair.PtrTargets) -join ', '
        }
        else {
            '<saknas>'
        }

        Write-Host ''
        Write-Host ("DNS-post på {0}" -f $ComputerName) -ForegroundColor Cyan
        Write-Host ('-' * 78)
        Write-Host ('  Namn        : {0}' -f $pair.Name)
        Write-Host ('  A           : {0}' -f $pair.IPv4Address)
        Write-Host ('  Forward-zon : {0}' -f $pair.ForwardZone)
        Write-Host ('  Reverse-zon : {0}' -f $(if ($pair.ReverseZone) { $pair.ReverseZone } else { '<saknas>' }))
        Write-Host ('  PTR         : {0}' -f $ptrDisplay)
        Write-Host ('  Relation    : {0}' -f $pair.Relation)
        Write-Host ''

        $action = Invoke-DnsMenuChoice `
            -Title 'Åtgärd' `
            -Message ("Vad vill du göra med {0}?" -f $pair.Name) `
            -Choice @(
                @{ Label = '&Redigera'; Help = 'Ändra IP-adress (A) och synka PTR' }
                @{ Label = '&Ta bort'; Help = 'Ta bort A-posten och matchande PTR' }
                @{ Label = '&Avbryt'; Help = 'Avsluta utan att ändra något' }
            ) `
            -DefaultChoice 2

        # 6. Ta bort delegeras — Remove-DnsHostRecord har egen ShouldProcess-
        #    och ShouldContinue-grind, som medvetet inte förbigås här.
        if ($action -eq 1) {
            $removeParameters = @{
                ComputerName = $ComputerName
            }

            $pair | Remove-DnsHostRecord @removeParameters @logSplat @credentialSplat

            return
        }

        if ($action -ne 0) {
            Write-Host 'Avbrutet.'

            return
        }

        # 7. Redigera.
        $oldAddress = [string]$pair.IPv4Address
        $newAddress = Read-DnsIPv4Input -Prompt 'Ny IPv4-adress'

        if ($null -eq $newAddress) {
            Write-Host 'Avbrutet – ingen adress angavs.'

            return
        }

        if ($newAddress -eq $oldAddress) {
            Write-Warning 'Den nya adressen är samma som den gamla – ingen ändring gjordes.'

            return
        }

        $relativeName = Get-RelativeRecordName -DnsName $pair.Name -ZoneName $pair.ForwardZone
        $newReverseZone = Get-DnsReverseZoneForAddress `
            -IPAddress $newAddress `
            -ComputerName $ComputerName `
            @credentialSplat

        if (-not $PSCmdlet.ShouldProcess("$($pair.Name)  $oldAddress -> $newAddress", 'Ändra A-post')) {
            Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'SetA' `
                -ZoneName $pair.ForwardZone -RecordName $relativeName -RecordType 'A' `
                -RecordData $newAddress -Result 'WhatIf'

            foreach ($ptrRecord in @($pair.MatchingPtrRecords)) {
                Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'RemovePtr' `
                    -ZoneName $pair.ReverseZone -RecordName $pair.PtrNodeName `
                    -RecordType 'PTR' -RecordData $pair.Name -Result 'WhatIf'
            }

            if ($null -ne $newReverseZone) {
                Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddPtr' `
                    -ZoneName $newReverseZone.ZoneName -RecordName $newReverseZone.NodeName `
                    -RecordType 'PTR' -RecordData $pair.Name -Result 'WhatIf'
            }

            return
        }

        Assert-DnsServerModule

        # Clone() saknas på deserialiserade objekt (DnsServer via PS 7:s
        # kompatlager). Då byts A-posten i stället genom Add + Remove.
        $canClone = (
            $null -ne $pair.ARecord -and
            $null -ne $pair.ARecord.psobject.Methods['Clone']
        )

        if ($canClone) {
            try {
                $newRecord = $pair.ARecord.Clone()
                $newRecord.RecordData.IPv4Address = [System.Net.IPAddress]::Parse($newAddress)

                Set-DnsServerResourceRecord `
                    -ZoneName $pair.ForwardZone `
                    @serverParameters `
                    -OldInputObject $pair.ARecord `
                    -NewInputObject $newRecord `
                    -ErrorAction Stop

                Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'SetA' `
                    -ZoneName $pair.ForwardZone -RecordName $relativeName -RecordType 'A' `
                    -RecordData $newAddress -Result 'Success'

                Write-Host ("Ändrade A: {0} {1} -> {2}" -f $pair.Name, $oldAddress, $newAddress) -ForegroundColor Green
            }
            catch {
                Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'SetA' `
                    -ZoneName $pair.ForwardZone -RecordName $relativeName -RecordType 'A' `
                    -RecordData $newAddress -Result 'Failed' -ErrorMessage $_.Exception.Message

                Write-Error -ErrorRecord $_

                # PTR rörs inte när A-posten står kvar oförändrad.
                return
            }
        }
        else {
            try {
                Add-DnsServerResourceRecordA `
                    -Name $relativeName `
                    -ZoneName $pair.ForwardZone `
                    @serverParameters `
                    -IPv4Address $newAddress `
                    -ErrorAction Stop

                Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddA' `
                    -ZoneName $pair.ForwardZone -RecordName $relativeName -RecordType 'A' `
                    -RecordData $newAddress -Result 'Success'
            }
            catch {
                Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddA' `
                    -ZoneName $pair.ForwardZone -RecordName $relativeName -RecordType 'A' `
                    -RecordData $newAddress -Result 'Failed' -ErrorMessage $_.Exception.Message

                Write-Error -ErrorRecord $_

                return
            }

            try {
                # Det cachade $pair.ARecord kan vara deserialiserat och duger
                # inte som pipelineindata — hämta ett färskt objekt.
                $staleRecords = @(
                    Get-DnsServerResourceRecord `
                        @serverParameters `
                        -ZoneName $pair.ForwardZone `
                        -Name $relativeName `
                        -RRType A `
                        -ErrorAction Stop |
                        Where-Object {
                            "$($_.RecordData.IPv4Address)" -eq $oldAddress
                        }
                )

                foreach ($staleRecord in $staleRecords) {
                    $staleRecord |
                        Remove-DnsServerResourceRecord `
                            -ZoneName $pair.ForwardZone `
                            @serverParameters `
                            -Force `
                            -ErrorAction Stop
                }

                Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'RemoveA' `
                    -ZoneName $pair.ForwardZone -RecordName $relativeName -RecordType 'A' `
                    -RecordData $oldAddress -Result 'Success'

                Write-Host ("Ändrade A: {0} {1} -> {2}" -f $pair.Name, $oldAddress, $newAddress) -ForegroundColor Green
            }
            catch {
                Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'RemoveA' `
                    -ZoneName $pair.ForwardZone -RecordName $relativeName -RecordType 'A' `
                    -RecordData $oldAddress -Result 'Failed' -ErrorMessage $_.Exception.Message

                Write-Error -ErrorRecord $_

                Write-Warning ("Både {0} och {1} finns nu på {2} — rätta manuellt." -f $oldAddress, $newAddress, $pair.Name)

                return
            }
        }

        # 8. PTR-synk. Gamla matchande PTR bort först.
        foreach ($ptrRecord in @($pair.MatchingPtrRecords)) {
            try {
                $ptrRecord |
                    Remove-DnsServerResourceRecord `
                        -ZoneName $pair.ReverseZone `
                        @serverParameters `
                        -Force `
                        -ErrorAction Stop

                Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'RemovePtr' `
                    -ZoneName $pair.ReverseZone -RecordName $pair.PtrNodeName `
                    -RecordType 'PTR' -RecordData $pair.Name -Result 'Success'

                Write-Host ("Tog bort PTR: {0} -> {1}" -f $oldAddress, $pair.Name) -ForegroundColor Green
            }
            catch {
                Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'RemovePtr' `
                    -ZoneName $pair.ReverseZone -RecordName $pair.PtrNodeName `
                    -RecordType 'PTR' -RecordData $pair.Name -Result 'Failed' -ErrorMessage $_.Exception.Message

                Write-Error -ErrorRecord $_
            }
        }

        if ($null -eq $newReverseZone) {
            Write-Warning "Ingen reverse-zon finns för $newAddress – PTR skapades inte."

            return
        }

        try {
            Add-DnsServerResourceRecordPtr `
                -Name $newReverseZone.NodeName `
                -ZoneName $newReverseZone.ZoneName `
                @serverParameters `
                -PtrDomainName $pair.Name `
                -ErrorAction Stop

            Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddPtr' `
                -ZoneName $newReverseZone.ZoneName -RecordName $newReverseZone.NodeName `
                -RecordType 'PTR' -RecordData $pair.Name -Result 'Success'

            Write-Host ("Skapade PTR: {0} -> {1}" -f $newAddress, $pair.Name) -ForegroundColor Green
        }
        catch {
            Write-DnsAdminLog @logSplat -ComputerName $ComputerName -Action 'AddPtr' `
                -ZoneName $newReverseZone.ZoneName -RecordName $newReverseZone.NodeName `
                -RecordType 'PTR' -RecordData $pair.Name -Result 'Failed' -ErrorMessage $_.Exception.Message

            Write-Error -ErrorRecord $_
        }
    }
}
