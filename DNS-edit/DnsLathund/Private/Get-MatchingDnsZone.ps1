function Get-MatchingDnsZone {
    <#
        .SYNOPSIS
            Hittar den zon som bäst matchar ett DNS-namn (longest suffix match).

        .DESCRIPTION
            Jämför namnet mot en lista med zonnamn och returnerar det längsta
            zonnamn som antingen är identiskt med namnet eller är ett suffix
            till namnet. Jämförelsen är skiftlägesokänslig och slutpunkt
            ignoreras. Returnerar $null om ingen zon matchar.

        .EXAMPLE
            Get-MatchingDnsZone -DnsName 'srv01.lab.contoso.local' -ZoneNames @('contoso.local','lab.contoso.local')

            Returnerar 'lab.contoso.local'.

        .EXAMPLE
            Get-MatchingDnsZone -DnsName '5.16.0.10.in-addr.arpa' -ZoneNames @('16.0.10.in-addr.arpa')

            Returnerar '16.0.10.in-addr.arpa'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string]$DnsName,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ZoneNames
    )

    $normalizedName = $DnsName.TrimEnd('.')

    return $ZoneNames |
        Where-Object {
            $normalizedName -ieq $_ -or
            $normalizedName.EndsWith(
                ".$_",
                [StringComparison]::OrdinalIgnoreCase
            )
        } |
        Sort-Object Length -Descending |
        Select-Object -First 1
}
