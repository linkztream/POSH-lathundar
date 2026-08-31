function Test-DnsNameEqual {
    <#
        .SYNOPSIS
            Jämför två DNS-namn skiftlägesokänsligt och slutpunktstolerant.

        .DESCRIPTION
            Normaliserar båda namnen med TrimEnd('.') och jämför med
            OrdinalIgnoreCase. Hanterar $null och tom sträng: två tomma värden
            anses lika, ett tomt och ett ifyllt anses olika.

        .EXAMPLE
            Test-DnsNameEqual -First 'srv01.contoso.local.' -Second 'SRV01.Contoso.Local'

            Returnerar $true.

        .EXAMPLE
            Test-DnsNameEqual -First 'srv01.contoso.local' -Second 'srv02.contoso.local'

            Returnerar $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$First,

        [Parameter(Position = 1)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Second
    )

    $firstIsEmpty = [string]::IsNullOrEmpty($First)
    $secondIsEmpty = [string]::IsNullOrEmpty($Second)

    if ($firstIsEmpty -and $secondIsEmpty) {
        return $true
    }

    if ($firstIsEmpty -or $secondIsEmpty) {
        return $false
    }

    return [string]::Equals(
        $First.TrimEnd('.'),
        $Second.TrimEnd('.'),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}
