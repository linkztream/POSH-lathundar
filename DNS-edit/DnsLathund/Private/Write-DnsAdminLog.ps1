function Write-DnsAdminLog {
    <#
        .SYNOPSIS
            Skriver en rad till modulens JSONL-granskningslogg.

        .DESCRIPTION
            Varje DNS-operation (inklusive WhatIf-körningar) loggas som exakt
            en komprimerad JSON-rad. Sökvägen väljs i ordningen -LogPath,
            miljövariabeln DNSLATHUND_LOGPATH och sist
            "$env:LOCALAPPDATA\DnsLathund\DnsLathund_<yyyy-MM>.jsonl".
            Katalogen skapas vid behov.

            Loggning får aldrig avbryta DNS-flödet: alla fel rapporteras med
            Write-Warning och funktionen kastar aldrig. Vid IOException görs
            ett omförsök efter 200 ms (samtidiga skrivningar).

        .EXAMPLE
            Write-DnsAdminLog -ComputerName 'dc01' -Action RemoveA -ZoneName 'contoso.local' -RecordName 'srv01' -RecordType 'A' -RecordData '10.0.16.5' -Result Success

            Loggar en lyckad borttagning av en A-post.

        .EXAMPLE
            Write-DnsAdminLog -LogPath 'C:\Temp\dns.jsonl' -ComputerName 'dc01' -Action RemovePtr -ZoneName '16.0.10.in-addr.arpa' -RecordName '5' -RecordType 'PTR' -RecordData 'srv01.contoso.local.' -Result WhatIf

            Loggar en simulerad PTR-borttagning till en egen fil.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [ValidateSet('RemoveA', 'RemovePtr', 'SetA', 'AddA', 'AddPtr')]
        [string]$Action,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ZoneName,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RecordName,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RecordType,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RecordData,

        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Failed', 'Skipped', 'WhatIf')]
        [string]$Result,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ErrorMessage
    )

    try {
        $resolvedPath = $LogPath

        if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
            $resolvedPath = $env:DNSLATHUND_LOGPATH
        }

        if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
            $fileName = 'DnsLathund_{0}.jsonl' -f (Get-Date -Format 'yyyy-MM')

            $resolvedPath = Join-Path -Path (
                Join-Path -Path $env:LOCALAPPDATA -ChildPath 'DnsLathund'
            ) -ChildPath $fileName
        }

        # Gör sökvägen absolut. .NET-anropet nedan utgår från processens
        # arbetskatalog, inte PowerShells, så relativa sökvägar och
        # PSDrive-sökvägar (till exempel TestDrive:) måste översättas här.
        $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($resolvedPath)

        $logDirectory = Split-Path -Path $resolvedPath -Parent

        if (
            -not [string]::IsNullOrWhiteSpace($logDirectory) -and
            -not (Test-Path -LiteralPath $logDirectory -ErrorAction Stop)
        ) {
            $null = New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop
        }

        $entry = [PSCustomObject]@{
            Timestamp    = Get-Date -Format o
            Operator     = "$env:USERDOMAIN\$env:USERNAME"
            ComputerName = $ComputerName
            Action       = $Action
            ZoneName     = $ZoneName
            RecordName   = $RecordName
            RecordType   = $RecordType
            RecordData   = $RecordData
            Result       = $Result
            Error        = $ErrorMessage
        }

        $line = ($entry | ConvertTo-Json -Compress -Depth 3) + [System.Environment]::NewLine

        # Skrivningen görs med .NET i stället för Add-Content -Encoding utf8:
        # i Windows PowerShell 5.1 betyder "utf8" UTF-8 MED BOM, och en BOM
        # först i en JSONL-fil är ett interoperabilitetsproblem. UTF8Encoding
        # med $false ger samma BOM-lösa resultat på både 5.1 och 7.
        # Ett omförsök efter 200 ms täcker samtidiga skrivare (fillåsning).
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        try {
            [System.IO.File]::AppendAllText($resolvedPath, $line, $utf8NoBom)
        }
        catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 200
            [System.IO.File]::AppendAllText($resolvedPath, $line, $utf8NoBom)
        }
    }
    catch {
        Write-Warning "Kunde inte skriva till DnsLathund-loggen: $($_.Exception.Message)"
    }
}
