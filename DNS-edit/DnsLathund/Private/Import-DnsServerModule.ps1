function Import-DnsServerModule {
    <#
    .SYNOPSIS
        Makes sure the DnsServer cmdlets are available.

    .DESCRIPTION
        The DnsServer module (RSAT: DNS Server Tools) is not a RequiredModule so that
        DnsLathund can be imported, and tested with stubs, on machines without RSAT.
        This helper is called before the first DnsServer cmdlet call instead.

        If Get-DnsServerResourceRecord is already resolvable (the real module is
        loaded or auto-loadable, or test stubs are present in the module scope),
        nothing is imported. Otherwise the DnsServer module is imported, and a
        missing module throws with installation instructions. A success is
        remembered in $script:DnsServerModuleChecked so later calls are free.

    .EXAMPLE
        Import-DnsServerModule

        Returns nothing when the DnsServer cmdlets are available; throws with an
        install hint when they are not.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param ()

    if ($script:DnsServerModuleChecked) {
        return
    }

    if (Get-Command -Name 'Get-DnsServerResourceRecord' -ErrorAction SilentlyContinue) {
        $script:DnsServerModuleChecked = $true
        return
    }

    try {
        Write-Verbose 'Importing the DnsServer module.'
        Import-Module -Name 'DnsServer' -ErrorAction Stop -Verbose:$false
    }
    catch {
        throw 'The DnsServer PowerShell module (RSAT: DNS Server Tools) is not available. Install it with: Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0 (Windows 10/11) or Install-WindowsFeature RSAT-DNS-Server (Windows Server).'
    }

    $script:DnsServerModuleChecked = $true
}
