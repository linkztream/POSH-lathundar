function New-DnsRemovalResultObject {
    <#
        .SYNOPSIS
            Skapar ett DnsLathund.RemovalResult-objekt.

        .DESCRIPTION
            Enda tillåtna sättet att bygga RemovalResult-objekt i modulen.
            Egenskapsuppsättningen är ett fryst kontrakt: Name, IPAddress,
            ZoneName, RecordType, Action, Result och Error.

            Result är en av 'Success', 'Failed', 'Skipped' eller 'WhatIf'.

        .EXAMPLE
            New-DnsRemovalResultObject -Name 'srv01.contoso.local' -IPAddress '10.0.16.5' -ZoneName 'contoso.local' -RecordType 'A' -Action 'RemoveA' -Result 'Success'

            Skapar ett resultatobjekt för en lyckad A-borttagning.
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
        [string]$IPAddress,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ZoneName,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RecordType,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Action,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Result,

        # Parametern heter ErrorMessage för att inte skugga den automatiska
        # variabeln $Error. Aliaset -Error finns kvar eftersom kontraktets
        # egenskap heter Error.
        [Parameter()]
        [Alias('Error')]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ErrorMessage
    )

    return [PSCustomObject]@{
        PSTypeName = 'DnsLathund.RemovalResult'
        Name       = $Name
        IPAddress  = $IPAddress
        ZoneName   = $ZoneName
        RecordType = $RecordType
        Action     = $Action
        Result     = $Result
        Error      = $ErrorMessage
    }
}
