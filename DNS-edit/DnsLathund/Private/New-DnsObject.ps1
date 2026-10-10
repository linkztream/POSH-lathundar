function New-DnsObject {
    <#
    .SYNOPSIS
        Creates a typed DnsLathund output object.

    .DESCRIPTION
        Builds one PSObject whose properties are exactly the entries of the given
        dictionary, in dictionary order, and whose first type name is
        "DnsLathund.<TypeName>". This is the only way module code creates output
        objects: the [PSCustomObject] cast is blocked in Constrained Language Mode,
        while New-Object PSObject and Add-Member -TypeName are allowed.

        Pass an [ordered] dictionary; with a plain hashtable the property order is
        undefined, and property order is part of the output contract.

    .PARAMETER TypeName
        The type name without the "DnsLathund." prefix, for example "Entry".

    .PARAMETER Property
        The properties of the new object. Use [ordered]@{} to keep the order.

    .EXAMPLE
        New-DnsObject -TypeName 'Result' -Property ([ordered]@{ Action = 'RemoveA'; Result = 'Success' })

        Returns an object with the type name DnsLathund.Result and the properties
        Action and Result, in that order.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TypeName,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Property
    )

    $dnsObject = New-Object -TypeName PSObject -Property $Property
    Add-Member -InputObject $dnsObject -TypeName "DnsLathund.$TypeName"
    $dnsObject
}
