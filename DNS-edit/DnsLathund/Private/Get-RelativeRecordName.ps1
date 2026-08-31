function Get-RelativeRecordName {
    <#
        .SYNOPSIS
            Räknar ut nodnamnet relativt en zon.

        .DESCRIPTION
            Tar bort zonsuffixet från ett fullständigt DNS-namn så att
            resultatet kan användas som -Name mot DnsServer-cmdletarna.
            Om namnet är zonens apex returneras '@'.

        .EXAMPLE
            Get-RelativeRecordName -DnsName 'srv01.contoso.local' -ZoneName 'contoso.local'

            Returnerar 'srv01'.

        .EXAMPLE
            Get-RelativeRecordName -DnsName 'contoso.local.' -ZoneName 'contoso.local'

            Returnerar '@'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string]$DnsName,

        [Parameter(Mandatory)]
        [string]$ZoneName
    )

    $normalizedName = $DnsName.TrimEnd('.')
    $normalizedZone = $ZoneName.TrimEnd('.')

    if ($normalizedName -ieq $normalizedZone) {
        return '@'
    }

    return $normalizedName.Substring(
        0,
        $normalizedName.Length - $normalizedZone.Length - 1
    )
}
