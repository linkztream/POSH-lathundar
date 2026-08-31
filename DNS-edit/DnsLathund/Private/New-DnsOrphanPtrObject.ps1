function New-DnsOrphanPtrObject {
    <#
        .SYNOPSIS
            Skapar ett DnsLathund.OrphanPtr-objekt.

        .DESCRIPTION
            Enda tillåtna sättet att bygga OrphanPtr-objekt i modulen.
            Egenskapsuppsättningen är ett fryst kontrakt: IPAddress,
            PtrOwnerName, PtrTarget, ReverseZone, Status och ComputerName.

            Status är antingen 'NoARecord' (målnamnet saknar A-post) eller
            'IpMismatch' (A-post finns, men med en annan IP-adress).

        .EXAMPLE
            New-DnsOrphanPtrObject -IPAddress '10.0.16.90' -PtrOwnerName '90' -PtrTarget 'gammal.contoso.local' -ReverseZone '16.0.10.in-addr.arpa' -Status 'NoARecord' -ComputerName 'dc01'

            Skapar ett objekt för en PTR utan motsvarande A-post.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$IPAddress,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PtrOwnerName,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PtrTarget,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ReverseZone,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Status,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ComputerName
    )

    return [PSCustomObject]@{
        PSTypeName   = 'DnsLathund.OrphanPtr'
        IPAddress    = $IPAddress
        PtrOwnerName = $PtrOwnerName
        PtrTarget    = $PtrTarget
        ReverseZone  = $ReverseZone
        Status       = $Status
        ComputerName = $ComputerName
    }
}
