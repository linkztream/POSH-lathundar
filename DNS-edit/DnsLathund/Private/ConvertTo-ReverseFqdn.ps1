function ConvertTo-ReverseFqdn {
    <#
        .SYNOPSIS
            Översätter en IPv4-adress till motsvarande in-addr.arpa-namn.

        .DESCRIPTION
            Vänder oktetterna i adressen och lägger på suffixet 'in-addr.arpa'.
            Används av alla reverse-uppslag i modulen så att idiomet
            (split '\.')[3..0] bara finns på ett ställe.

        .EXAMPLE
            ConvertTo-ReverseFqdn -IPAddress '10.0.0.1'

            Returnerar '1.0.0.10.in-addr.arpa'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            $parsedAddress = $null

            if (
                [IPAddress]::TryParse($_, [ref]$parsedAddress) -and
                $parsedAddress.AddressFamily -eq
                    [System.Net.Sockets.AddressFamily]::InterNetwork
            ) {
                $true
            }
            else {
                throw "'$_' är inte en giltig IPv4-adress."
            }
        })]
        [string]$IPAddress
    )

    $normalizedAddress = ([IPAddress]$IPAddress).IPAddressToString

    return (($normalizedAddress -split '\.')[3..0] -join '.') + '.in-addr.arpa'
}
