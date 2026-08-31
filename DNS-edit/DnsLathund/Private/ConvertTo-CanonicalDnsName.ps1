function ConvertTo-CanonicalDnsName {
    <#
        .SYNOPSIS
            Normaliserar ett DNS-namn genom att ta bort avslutande punkt.

        .DESCRIPTION
            DnsServer-cmdletarna returnerar absoluta namn med slutpunkt i
            exempelvis PtrDomainName, medan indata från användaren sällan har
            det. Alla namnjämförelser i modulen ska gå via den här hjälparen
            (eller Test-DnsNameEqual) så att slutpunkten aldrig ställer till det.

        .EXAMPLE
            ConvertTo-CanonicalDnsName -Name 'srv01.contoso.local.'

            Returnerar 'srv01.contoso.local'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrEmpty($Name)) {
        return $Name
    }

    return $Name.TrimEnd('.')
}
