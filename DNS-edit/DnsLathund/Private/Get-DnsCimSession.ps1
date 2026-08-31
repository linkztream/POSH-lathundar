function Get-DnsCimSession {
    <#
        .SYNOPSIS
            Hämtar (och cachar) en verifierad CIM-session mot en DNS-server.

        .DESCRIPTION
            Försöker först med WSMan och verifierar sessionen genom att läsa
            MicrosoftDNS_Server i namnrymden root\MicrosoftDNS med 15 sekunders
            timeout. Misslyckas det görs ett omförsök över DCOM. Fungerar inte
            heller det cachas markören 'Unavailable' för servern och $null
            returneras — anroparen får då falla tillbaka på zonexportvägen.

            Funktionen kastar aldrig. Sessioner cachas per server (gemener) i
            $script:DnsCimSessionCache och stängs när modulen tas bort.

        .EXAMPLE
            $session = Get-DnsCimSession -ComputerName 'dc01'

            Returnerar en CimSession eller $null om CIM inte är nåbart.

        .EXAMPLE
            $session = Get-DnsCimSession -ComputerName 'dc01' -Credential (Get-Credential)

            Öppnar sessionen med andra uppgifter.
    #>
    [CmdletBinding()]
    [OutputType([Microsoft.Management.Infrastructure.CimSession])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    $cacheKey = $ComputerName.ToLowerInvariant()

    if ($script:DnsCimSessionCache.ContainsKey($cacheKey)) {
        $cached = $script:DnsCimSessionCache[$cacheKey]

        if ($cached -is [string] -and $cached -eq 'Unavailable') {
            return $null
        }

        if ($cached -is [Microsoft.Management.Infrastructure.CimSession]) {
            return $cached
        }
    }

    $commonParameters = @{
        ComputerName = $ComputerName
        ErrorAction  = 'Stop'
    }

    if ($null -ne $Credential) {
        $commonParameters['Credential'] = $Credential
    }

    $lastError = $null

    # Försök 1: WSMan (standardprotokollet).
    $session = $null

    try {
        $session = New-CimSession @commonParameters

        $null = Get-CimInstance `
            -CimSession $session `
            -Namespace 'root\MicrosoftDNS' `
            -ClassName 'MicrosoftDNS_Server' `
            -OperationTimeoutSec 15 `
            -ErrorAction Stop

        $script:DnsCimSessionCache[$cacheKey] = $session

        return $session
    }
    catch {
        $lastError = $_.Exception.Message

        if ($null -ne $session) {
            try {
                Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
            }
            catch {
                # Ignoreras medvetet.
            }

            $session = $null
        }
    }

    # Försök 2: DCOM.
    try {
        $dcomOption = New-CimSessionOption -Protocol Dcom

        $session = New-CimSession @commonParameters -SessionOption $dcomOption

        $null = Get-CimInstance `
            -CimSession $session `
            -Namespace 'root\MicrosoftDNS' `
            -ClassName 'MicrosoftDNS_Server' `
            -OperationTimeoutSec 15 `
            -ErrorAction Stop

        $script:DnsCimSessionCache[$cacheKey] = $session

        return $session
    }
    catch {
        $lastError = $_.Exception.Message

        if ($null -ne $session) {
            try {
                Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
            }
            catch {
                # Ignoreras medvetet.
            }
        }
    }

    $script:DnsCimSessionCache[$cacheKey] = 'Unavailable'

    Write-Verbose "CIM är inte nåbart mot '$ComputerName' (varken WSMan eller DCOM): $lastError"

    return $null
}
