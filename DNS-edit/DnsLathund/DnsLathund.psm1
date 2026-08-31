#Requires -Version 5.1

<#
    DnsLathund — modulladdare.

    Laddar alla .ps1-filer under Private\ och därefter Public\, exporterar de
    publika funktionerna och initierar de script-scope-cachar som de privata
    hjälparna använder.
#>

$script:ModuleRoot = $PSScriptRoot

# Script-scope-cachar. Nycklas på gemener av ComputerName.
$script:DnsZoneCache = @{}
$script:DnsCimSessionCache = @{}

# Cache för Assert-DnsServerModule (sätts av hjälparen vid första lyckade koll).
$script:DnsServerModuleVerified = $false

foreach ($folder in @('Private', 'Public')) {
    $folderPath = Join-Path -Path $PSScriptRoot -ChildPath $folder

    if (-not (Test-Path -LiteralPath $folderPath)) {
        continue
    }

    $scriptFiles = @(
        Get-ChildItem -LiteralPath $folderPath -Filter '*.ps1' -File -ErrorAction Stop |
            Sort-Object -Property Name
    )

    foreach ($scriptFile in $scriptFiles) {
        try {
            . $scriptFile.FullName
        }
        catch {
            throw "Kunde inte ladda modulfilen '$($scriptFile.Name)': $($_.Exception.Message)"
        }
    }
}

$publicFunctions = @(
    'Find-DnsRecord'
    'Get-DnsOrphanPtr'
    'Remove-DnsHostRecord'
    'Remove-DnsPtrRecord'
    'Invoke-DnsRecordEditor'
)

Export-ModuleMember -Function $publicFunctions

# Städa upp eventuella CIM-sessioner när modulen tas bort. Får aldrig kasta.
$ExecutionContext.SessionState.Module.OnRemove = {
    try {
        if ($script:DnsCimSessionCache) {
            foreach ($cachedSession in @($script:DnsCimSessionCache.Values)) {
                try {
                    if ($cachedSession -is [Microsoft.Management.Infrastructure.CimSession]) {
                        Remove-CimSession -CimSession $cachedSession -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    # Ignoreras medvetet — modulen tas bort ändå.
                }
            }

            $script:DnsCimSessionCache.Clear()
        }
    }
    catch {
        # Ignoreras medvetet.
    }
}
