function Test-IPv4Address {
    <#
        .SYNOPSIS
            Avgör om en sträng är en giltig IPv4-adress.

        .DESCRIPTION
            Försöker tolka värdet som en IP-adress och kontrollerar att
            adressfamiljen är InterNetwork (IPv4). Returnerar $true eller
            $false och kastar aldrig.

        .EXAMPLE
            Test-IPv4Address -Value '10.0.16.5'

            Returnerar $true.

        .EXAMPLE
            Test-IPv4Address -Value 'srv01.contoso.local'

            Returnerar $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $parsedAddress = $null

    return (
        [IPAddress]::TryParse($Value, [ref]$parsedAddress) -and
        $parsedAddress.AddressFamily -eq
            [System.Net.Sockets.AddressFamily]::InterNetwork
    )
}
