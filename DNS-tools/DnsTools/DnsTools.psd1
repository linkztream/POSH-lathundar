@{
    RootModule           = 'DnsTools.psm1'
    ModuleVersion        = '1.1.0'
    GUID                 = 'a470d7fe-af54-4636-b760-f36627b1214d'
    Author               = 'Pär Lindström'
    CompanyName          = 'Unknown'
    Copyright            = '(c) Pär Lindström. All rights reserved.'
    Description          = 'Find, audit, repair, create and remove A, AAAA, PTR and CNAME records in large Microsoft DNS (Active Directory-integrated) environments. Searches run against cached zone exports, changes are verified live, and the core runs in Constrained Language Mode.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    # The DnsServer module (RSAT) is imported lazily by Import-DnsServerModule so
    # that the module can be imported, and tested with stubs, on machines without RSAT.
    FormatsToProcess     = @('DnsTools.Format.ps1xml')

    FunctionsToExport    = @('Get-DnsEntry', 'Get-DnsSnapshot', 'Update-DnsSnapshot', 'Remove-DnsEntry', 'New-DnsEntry', 'Set-DnsEntry', 'New-DnsReverseZone', 'Backup-DnsZone')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @('DNS', 'DnsServer', 'ActiveDirectory', 'PTR', 'ReverseLookup', 'Audit', 'ConstrainedLanguage', 'Windows')
            ReleaseNotes = 'Phase 2: Remove-DnsEntry, New-DnsEntry, Set-DnsEntry, New-DnsReverseZone and Backup-DnsZone with the change log. Phase 1: module foundation, zone table, zone snapshots and Get-DnsEntry.'
        }
    }
}
