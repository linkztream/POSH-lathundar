@{
    RootModule            = 'DnsLathund.psm1'
    ModuleVersion         = '0.1.0'
    GUID                  = 'a470d7fe-af54-4636-b760-f36627b1214d'
    Author                = 'Pär Lindström'
    CompanyName           = 'Unknown'
    Copyright             = '(c) Pär Lindström. Alla rättigheter förbehållna.'
    Description           = 'Verktyg för DNS-administration i mycket stora Microsoft DNS-miljöer: sökning, orphan-PTR-jakt och säker borttagning av A- och PTR-poster.'

    PowerShellVersion     = '5.1'
    CompatiblePSEditions  = @('Desktop', 'Core')

    # DnsServer (RSAT) listas medvetet INTE här. Modulen ska kunna importeras
    # på en dev-maskin utan RSAT; Assert-DnsServerModule kontrollerar i stället
    # vid anrop av de funktioner som faktiskt behöver DnsServer-cmdletarna.
    RequiredModules       = @()

    FunctionsToExport     = @(
        'Find-DnsRecord'
        'Get-DnsOrphanPtr'
        'Remove-DnsHostRecord'
        'Remove-DnsPtrRecord'
        'Invoke-DnsRecordEditor'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()

    PrivateData           = @{
        PSData = @{
            Tags         = @('DNS', 'DnsServer', 'PTR', 'Windows', 'RSAT')
            ReleaseNotes = 'Fas 0: modulställning, privata hjälpare och objektkontrakt.'
        }
    }
}
