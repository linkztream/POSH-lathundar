function New-DnsWqlFilter {
    <#
        .SYNOPSIS
            Översätter ett PowerShell-wildcardmönster till ett WQL-filteruttryck.

        .DESCRIPTION
            Ren funktion utan sidoeffekter. Escapear värdet för WQL (enkla
            citattecken dubbleras, literala [, % och _ hakparentes-escapeas) och
            översätter därefter wildcard: * blir % och ? blir _.

            Saknar mönstret wildcardtecken returneras ett likhetsuttryck
            ("<Property> = '<värde>'") i stället för LIKE, vilket är betydligt
            billigare för DNS-providern i mycket stora zoner.

        .EXAMPLE
            New-DnsWqlFilter -Pattern 'web*'

            Returnerar "OwnerName LIKE 'web%'".

        .EXAMPLE
            New-DnsWqlFilter -Pattern 'srv01.contoso.local' -Property 'PTRDomainName'

            Returnerar "PTRDomainName = 'srv01.contoso.local'".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Pattern,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$Property = 'OwnerName'
    )

    $hasWildcard = [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Pattern)

    # 1. WQL-strängescape: enkelt citattecken dubbleras.
    $escaped = $Pattern.Replace("'", "''")

    if (-not $hasWildcard) {
        return "$Property = '$escaped'"
    }

    # 2. Literala LIKE-metatecken skyddas med hakparenteser. [ först, annars
    #    skulle de hakparenteser vi själva lägger till bli dubbelescapeade.
    $escaped = $escaped.Replace('[', '[[]')
    $escaped = $escaped.Replace('%', '[%]')
    $escaped = $escaped.Replace('_', '[_]')

    # 3. PowerShell-wildcard översätts till WQL-wildcard.
    $escaped = $escaped.Replace('*', '%')
    $escaped = $escaped.Replace('?', '_')

    return "$Property LIKE '$escaped'"
}
