@{
    RootModule           = 'DnsLathund.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'a470d7fe-af54-4636-b760-f36627b1214d'
    Author               = 'Pär Lindström'
    CompanyName          = 'Unknown'
    Copyright            = '(c) Pär Lindström. All rights reserved.'
    Description          = 'Find, audit, repair, create and remove A, AAAA, PTR and CNAME records in large Microsoft DNS (Active Directory-integrated) environments. Searches run against cached zone exports, changes are verified live, and the core runs in Constrained Language Mode.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    # The DnsServer module (RSAT) is imported lazily by Import-DnsServerModule so
    # that the module can be imported, and tested with stubs, on machines without RSAT.
    FormatsToProcess     = @('DnsLathund.Format.ps1xml')

    FunctionsToExport    = @('Get-DnsEntry', 'Get-DnsSnapshot', 'Update-DnsSnapshot')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @('DNS', 'DnsServer', 'ActiveDirectory', 'PTR', 'ReverseLookup', 'Audit', 'ConstrainedLanguage', 'Windows')
            ReleaseNotes = 'Phase 1: module foundation, zone table, zone snapshots and Get-DnsEntry.'
        }
    }
}
