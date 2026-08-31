function New-DnsRecordPairObject {
    <#
        .SYNOPSIS
            Skapar ett DnsLathund.RecordPair-objekt.

        .DESCRIPTION
            Enda tillåtna sättet att bygga RecordPair-objekt i modulen.
            Egenskapsuppsättningen är ett fryst kontrakt: Name, IPv4Address,
            ForwardZone, ARecord, ReverseZone, PtrNodeName, PtrRecords,
            MatchingPtrRecords, PtrTargets, Relation och ComputerName.

            Relation är en av strängarna '1:1',
            'Matchande PTR finns, men relationen är inte 1:1',
            'PTR pekar på annat namn' eller 'PTR saknas'.

        .EXAMPLE
            New-DnsRecordPairObject -Name 'srv01.contoso.local' -IPv4Address '10.0.16.5' -ForwardZone 'contoso.local' -Relation '1:1' -ComputerName 'dc01'

            Skapar ett minimalt RecordPair-objekt.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$IPv4Address,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ForwardZone,

        [Parameter()]
        [AllowNull()]
        [object]$ARecord,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ReverseZone,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PtrNodeName,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$PtrRecords = @(),

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$MatchingPtrRecords = @(),

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$PtrTargets = @(),

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Relation,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ComputerName
    )

    return [PSCustomObject]@{
        PSTypeName         = 'DnsLathund.RecordPair'
        Name               = $Name
        IPv4Address        = $IPv4Address
        ForwardZone        = $ForwardZone
        ARecord            = $ARecord
        ReverseZone        = $ReverseZone
        PtrNodeName        = $PtrNodeName
        PtrRecords         = $PtrRecords
        MatchingPtrRecords = $MatchingPtrRecords
        PtrTargets         = $PtrTargets
        Relation           = $Relation
        ComputerName       = $ComputerName
    }
}
