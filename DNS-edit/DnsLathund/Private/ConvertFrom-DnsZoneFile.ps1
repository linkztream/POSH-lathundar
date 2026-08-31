function ConvertFrom-DnsZoneFile {
    <#
        .SYNOPSIS
            Tolkar en exporterad DNS-zonfil (BIND-format).

        .DESCRIPTION
            Radgrammatik: [ägare] [TTL] [klass] typ rdata. Rader som börjar med
            whitespace ärver föregående ägare, $ORIGIN växlar origin, '@' blir
            origin, [AGE:nnnn]-tokens hoppas över och namn med slutpunkt är
            absoluta. Kommentarer, WINS och övriga typer filtreras bort per
            typtoken. Ogiltiga rader räknas och rapporteras med Write-Verbose —
            parsern kastar aldrig.

            Ogiltig rad = en rad vars typtoken efterfrågas men vars rdata saknas
            eller inte går att tolka (till exempel en A-post utan giltig
            IPv4-adress). Rader med andra typtoken, fortsättningsrader i
            flerradiga poster (SOA), kommentarer och tomma rader räknas inte
            som ogiltiga. Antalet kan även hämtas via -SkippedLineCount.

            Utan -AsIndex returneras ett objekt per post med egenskaperna
            OwnerFqdn (kanoniskt FQDN utan slutpunkt), RecordType och
            RecordData (kanoniskt FQDN för PTR, IP-sträng för A). Med -AsIndex
            byggs i stället en Dictionary[string, List[string]]
            (OrdinalIgnoreCase) från FQDN till IP-adresser, vilket är
            minnessnålt nog för zoner med hundratusentals poster. -AsIndex
            innebär alltid RecordType A — PTR-poster indexeras inte.

        .EXAMPLE
            ConvertFrom-DnsZoneFile -Path 'C:\Temp\contoso.local.dns' -ZoneName 'contoso.local' -RecordType A

            Returnerar alla A-poster i zonfilen.

        .EXAMPLE
            ConvertFrom-DnsZoneFile -Path 'C:\Temp\contoso.local.dns' -ZoneName 'contoso.local' -AsIndex

            Bygger ett uppslagsindex FQDN -> IP-adresser.

        .EXAMPLE
            $skipped = 0
            ConvertFrom-DnsZoneFile -Path $file -ZoneName '16.0.10.in-addr.arpa' -RecordType PTR -SkippedLineCount ([ref]$skipped)

            Tolkar PTR-posterna och rapporterar antalet ogiltiga rader i $skipped.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        # Zonens namn används som initialt $ORIGIN.
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$ZoneName,

        [Parameter()]
        [ValidateSet('A', 'PTR')]
        [string[]]$RecordType = @('A', 'PTR'),

        [Parameter()]
        [switch]$AsIndex,

        # Fylls med antalet ogiltiga rader när tolkningen är klar.
        [Parameter()]
        [AllowNull()]
        [ref]$SkippedLineCount
    )

    process {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::new(
                "Zonfilen '$Path' hittades inte.",
                $Path
            )
        }

        # -AsIndex bygger alltid ett A-index.
        $wantedTypes = if ($AsIndex) { @('A') } else { @($RecordType) }

        $wantA = $wantedTypes -contains 'A'
        $wantPtr = $wantedTypes -contains 'PTR'

        $index = $null

        if ($AsIndex) {
            $index = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
        }

        $currentOrigin = $ZoneName.TrimEnd('.')
        $currentOwner = $currentOrigin
        $skippedLines = 0
        $lineNumber = 0

        foreach ($rawLine in [System.IO.File]::ReadLines($Path)) {
            $lineNumber++

            if ([string]::IsNullOrWhiteSpace($rawLine)) {
                continue
            }

            # Kommentar: allt från första semikolon. Modulen tolkar bara A och
            # PTR, vars rdata aldrig innehåller citerade semikolon.
            $line = $rawLine
            $commentIndex = $line.IndexOf(';')

            if ($commentIndex -ge 0) {
                $line = $line.Substring(0, $commentIndex)
            }

            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            # Radens första tecken avgör om ägaren ärvs från föregående post.
            $ownerIsInherited = [char]::IsWhiteSpace($line[0])

            # Ledande whitespace ger ett tomt första token — det är signalen
            # för ärvd ägare. Avslutande whitespace kan ge ett tomt sista token.
            $tokens = $line -split '\s+'
            $tokenCount = $tokens.Length

            $startIndex = 0

            if (-not $ownerIsInherited) {
                $firstToken = $tokens[0]

                # Direktiv: $ORIGIN växlar origin, övriga ($TTL, $INCLUDE ...)
                # saknar betydelse för A/PTR-tolkningen.
                if ($firstToken.Length -gt 0 -and $firstToken[0] -eq '$') {
                    if ([string]::Equals($firstToken, '$ORIGIN', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $originValue = $null

                        for ($i = 1; $i -lt $tokenCount; $i++) {
                            if ($tokens[$i].Length -gt 0) {
                                $originValue = $tokens[$i]
                                break
                            }
                        }

                        if ([string]::IsNullOrEmpty($originValue)) {
                            $skippedLines++
                            Write-Verbose "Rad ${lineNumber}: `$ORIGIN utan värde — hoppas över."
                        }
                        else {
                            $currentOrigin = $originValue.TrimEnd('.')
                            $currentOwner = $currentOrigin
                        }
                    }

                    continue
                }

                if ($firstToken -eq '@') {
                    $currentOwner = $currentOrigin
                }
                elseif ($firstToken.EndsWith('.')) {
                    $currentOwner = $firstToken.TrimEnd('.')
                }
                else {
                    $currentOwner = $firstToken + '.' + $currentOrigin
                }

                $startIndex = 1
            }
            else {
                $startIndex = 1
            }

            # Hoppa över valfria token före typtoken: [AGE:nnnn], TTL och klass.
            $typeIndex = -1

            for ($i = $startIndex; $i -lt $tokenCount; $i++) {
                $token = $tokens[$i]

                if ($token.Length -eq 0) {
                    continue
                }

                if ($token[0] -eq '[' -and $token -match '^\[AGE:\d+\]$') {
                    continue
                }

                if ($token -match '^\d+$') {
                    continue
                }

                if ([string]::Equals($token, 'IN', [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                $typeIndex = $i
                break
            }

            if ($typeIndex -lt 0) {
                # Ingen typtoken — fortsättningsrad i en flerradig post
                # (SOA-parenteser) eller en ren TTL-rad. Inte ett fel.
                continue
            }

            $recordTypeToken = $tokens[$typeIndex]

            $isA = $wantA -and [string]::Equals($recordTypeToken, 'A', [System.StringComparison]::OrdinalIgnoreCase)
            $isPtr = $false

            if (-not $isA) {
                $isPtr = $wantPtr -and [string]::Equals($recordTypeToken, 'PTR', [System.StringComparison]::OrdinalIgnoreCase)
            }

            if (-not $isA -and -not $isPtr) {
                # WINS, WINSR, NS, SOA, CNAME, MX ... eller en typ som inte
                # efterfrågades. Hoppas över tyst.
                continue
            }

            # Första icke-tomma token efter typtoken är rdata.
            $recordData = $null

            for ($i = $typeIndex + 1; $i -lt $tokenCount; $i++) {
                if ($tokens[$i].Length -gt 0) {
                    $recordData = $tokens[$i]
                    break
                }
            }

            if ([string]::IsNullOrEmpty($recordData)) {
                $skippedLines++
                Write-Verbose "Rad ${lineNumber}: $recordTypeToken-post utan rdata — hoppas över."
                continue
            }

            if ($isA) {
                $parsedAddress = $null

                if (
                    -not [System.Net.IPAddress]::TryParse($recordData, [ref]$parsedAddress) -or
                    $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork
                ) {
                    $skippedLines++
                    Write-Verbose "Rad ${lineNumber}: '$recordData' är ingen giltig IPv4-adress — hoppas över."
                    continue
                }

                $addressText = $parsedAddress.IPAddressToString

                if ($AsIndex) {
                    if ($index.ContainsKey($currentOwner)) {
                        $index[$currentOwner].Add($addressText)
                    }
                    else {
                        $addressList = [System.Collections.Generic.List[string]]::new()
                        $addressList.Add($addressText)
                        $index.Add($currentOwner, $addressList)
                    }
                }
                else {
                    [PSCustomObject]@{
                        OwnerFqdn  = $currentOwner
                        RecordType = 'A'
                        RecordData = $addressText
                    }
                }

                continue
            }

            # PTR: målnamnet kanoniseras mot aktuellt origin.
            if ($recordData -eq '@') {
                $ptrTarget = $currentOrigin
            }
            elseif ($recordData.EndsWith('.')) {
                $ptrTarget = $recordData.TrimEnd('.')
            }
            else {
                $ptrTarget = $recordData + '.' + $currentOrigin
            }

            [PSCustomObject]@{
                OwnerFqdn  = $currentOwner
                RecordType = 'PTR'
                RecordData = $ptrTarget
            }
        }

        if ($null -ne $SkippedLineCount) {
            $SkippedLineCount.Value = $skippedLines
        }

        if ($skippedLines -gt 0) {
            Write-Verbose "$skippedLines ogiltiga rader hoppades över i '$Path'."
        }
        else {
            Write-Verbose "Inga ogiltiga rader i '$Path' ($lineNumber rader lästa)."
        }

        if ($AsIndex) {
            # Dictionary räknas inte som uppräkningsbar av pipelinen, så
            # indexet returneras som ett enda objekt.
            return $index
        }
    }
}
