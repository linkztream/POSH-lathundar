function Get-DnsServerParameter {
    <#
        .SYNOPSIS
            Bygger serverparametrarna (CimSession eller ComputerName) för
            DnsServer-cmdletarna.

        .DESCRIPTION
            DnsServer-cmdletarna saknar -Credential. Enda sättet att köra dem
            som någon annan än den inloggade användaren är en CIM-session.

            Modulens regel: anges -Credential MÅSTE anropet gå via en
            CIM-session. Går den inte att upprätta kastas ett fel — vi faller
            aldrig tillbaka på -ComputerName, eftersom det tyst hade kört med
            den inloggade användarens rättigheter i stället för de angivna.
            Vid borttagning av poster vore en sådan tyst nedgradering direkt
            farlig.

            Utan -Credential returneras @{ ComputerName = <server> }.

            Resultatet är avsett att splattas in i DnsServer-cmdletarna:
            Get-DnsServerResourceRecord @serverParameters -ZoneName ...

        .EXAMPLE
            $serverParameters = Get-DnsServerParameter -ComputerName 'dc01'

            Ger @{ ComputerName = 'dc01' }.

        .EXAMPLE
            $serverParameters = Get-DnsServerParameter -ComputerName 'dc01' -Credential $credential

            Ger @{ CimSession = <CimSession> } eller kastar om ingen session
            kunde upprättas.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    if ($null -eq $Credential) {
        return @{ ComputerName = $ComputerName }
    }

    $cimSession = Get-DnsCimSession -ComputerName $ComputerName -Credential $Credential

    if ($null -eq $cimSession) {
        throw "Ingen CIM-session kunde upprättas mot '$ComputerName', vilket krävs när -Credential anges."
    }

    return @{ CimSession = $cimSession }
}
