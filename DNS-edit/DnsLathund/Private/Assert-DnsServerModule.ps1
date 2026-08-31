function Assert-DnsServerModule {
    <#
        .SYNOPSIS
            Säkerställer att DnsServer-modulen (RSAT) finns och är laddad.

        .DESCRIPTION
            DnsServer listas medvetet inte i psd1-filens RequiredModules, så att
            modulen går att importera på en maskin utan RSAT. De funktioner som
            faktiskt behöver DnsServer-cmdletarna anropar den här hjälparen
            först. Resultatet cachas i script-scope så att upprepade anrop är
            billiga.

        .EXAMPLE
            Assert-DnsServerModule

            Importerar DnsServer eller kastar ett svenskt felmeddelande om RSAT saknas.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param ()

    if ($script:DnsServerModuleVerified) {
        return
    }

    $availableModule = @(Get-Module -ListAvailable -Name DnsServer -ErrorAction SilentlyContinue)

    if ($availableModule.Count -eq 0) {
        throw 'DnsServer-modulen (RSAT) saknas på den här datorn. Installera RSAT: DNS Server Tools och försök igen.'
    }

    Import-Module -Name DnsServer -ErrorAction Stop

    $script:DnsServerModuleVerified = $true
}
