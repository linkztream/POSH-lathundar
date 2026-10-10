<#
.SYNOPSIS
    Smoke scenario that Invoke-ClmSmokeTest.ps1 dot-sources in a Constrained Language runspace.

.DESCRIPTION
    Runs in Constrained Language Mode, so everything in this file must obey
    CONTRACTS §4.1 as strictly as module code does. Throw on a failed
    expectation; any error record or exception fails the smoke run.

    When this file runs, the runner has already imported DnsLathund and
    dot-sourced the DnsServer stubs into the module scope. The stub helpers
    (Reset-DnsStubStore and friends) therefore live in the module scope and
    are reached with '& $dnsLathund { ... }', not called directly.
#>

if ([string]$ExecutionContext.SessionState.LanguageMode -ne 'ConstrainedLanguage') {
    throw ('The scenario must run in ConstrainedLanguage mode, but the language mode is {0}.' -f $ExecutionContext.SessionState.LanguageMode)
}

$dnsLathund = Get-Module -Name DnsLathund
if ($null -eq $dnsLathund) {
    throw 'The DnsLathund module is not loaded.'
}
Write-Output ('Scenario: DnsLathund {0} is loaded in {1} mode.' -f $dnsLathund.Version, $ExecutionContext.SessionState.LanguageMode)

# The stub file is written in parallel with this scenario; until it exists
# the reset is skipped rather than failed.
$stubStoreAvailable = & $dnsLathund { [bool](Get-Command -Name Reset-DnsStubStore -ErrorAction SilentlyContinue) }
if ($stubStoreAvailable) {
    & $dnsLathund { Reset-DnsStubStore }
    Write-Output 'Scenario: stub store reset.'
}
else {
    Write-Output 'Scenario: Reset-DnsStubStore is not available; stub reset skipped.'
}

# --- Phase 1 scenarios (filled by the Get-DnsEntry implementer) ---
# Get-DnsSnapshot, Update-DnsSnapshot (-WhatIf and for real) and Get-DnsEntry for
# each kind of -Find value, against stub data (CONTRACTS §16). The snapshot and
# the stub's server-side export folder live in a temporary folder that is removed
# at the end; the module variables are set inside the module scope, the same way
# the runner loads the stubs.
if (-not $stubStoreAvailable) {
    throw 'The phase 1 scenario needs the DnsServer stubs (Tests\Stubs\DnsServerStubs.ps1).'
}

$scenarioServer = $env:COMPUTERNAME.ToLowerInvariant()
$scenarioRoot = Join-Path -Path $env:TEMP -ChildPath ('DnsLathundClm-' + [guid]::NewGuid().ToString('N'))

& $dnsLathund {
    param ($Root)

    $script:SnapshotRoot = Join-Path -Path $Root -ChildPath 'snapshot'
    $script:DnsServerExportRoot = Join-Path -Path $Root -ChildPath 'server-dns'
    Reset-DnsStubStore -ExportRoot $script:DnsServerExportRoot
    $script:ZoneTableCache = @{}
    $script:SnapshotIndexCache = @{}

    Add-DnsStubZone -Name 'contoso.local'
    Add-DnsStubZone -Name '16.0.10.in-addr.arpa'
    Add-DnsStubRecord -ZoneName 'contoso.local' -Name '@' -RRType NS -Data 'dc01.contoso.local'
    Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'dc01' -RRType A -Data '10.0.16.10'
    Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'srv01' -RRType A -Data '10.0.16.20' -AgeHours 3636304
    Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'srv02' -RRType A -Data '10.0.16.20'
    Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'gw' -RRType CNAME -Data 'srv01.contoso.local'
    Add-DnsStubRecord -ZoneName 'contoso.local' -Name '_ldap._tcp' -RRType SRV -Data 'dc01.contoso.local'
    Add-DnsStubRecord -ZoneName '16.0.10.in-addr.arpa' -Name '10' -RRType PTR -Data 'dc01.contoso.local'
    Add-DnsStubRecord -ZoneName '16.0.10.in-addr.arpa' -Name '20' -RRType PTR -Data 'srv01.contoso.local'
} $scenarioRoot
Write-Output ("Scenario: stub data seeded; snapshot root '{0}'." -f $scenarioRoot)

try {
    $before = @(Get-DnsSnapshot -Server $scenarioServer -WarningAction SilentlyContinue)
    if ($before.Count -ne 0) {
        throw ('Get-DnsSnapshot returned {0} zone(s) before any export.' -f $before.Count)
    }

    $whatIf = @(Update-DnsSnapshot -Server $scenarioServer -WhatIf)
    if ($whatIf.Count -ne 0) {
        throw 'Update-DnsSnapshot -WhatIf returned output.'
    }

    $updated = @(Update-DnsSnapshot -Server $scenarioServer -Confirm:$false)
    if ($updated.Count -ne 2) {
        throw ('Update-DnsSnapshot returned {0} zone(s); expected 2.' -f $updated.Count)
    }

    $snapshots = @(Get-DnsSnapshot -Server $scenarioServer)
    if ($snapshots.Count -ne 2) {
        throw ('Get-DnsSnapshot returned {0} zone(s); expected 2.' -f $snapshots.Count)
    }
    foreach ($snapshot in $snapshots) {
        Write-Output ('Scenario: snapshot zone {0}, {1} bytes.' -f $snapshot.Zone, $snapshot.FileSizeBytes)
    }

    $lookups = @(
        @{ Label = 'FQDN'; Find = 'srv01.contoso.local'; Zone = ''; Source = 'Live' }
        @{ Label = 'IP'; Find = '10.0.16.20'; Zone = ''; Source = 'Live' }
        @{ Label = 'wildcard'; Find = '*.contoso.local'; Zone = ''; Source = 'Snapshot' }
        @{ Label = 'bare label'; Find = 'srv0'; Zone = ''; Source = 'Snapshot' }
        @{ Label = 'bare label with -Zone'; Find = 'dc01'; Zone = 'contoso.local'; Source = 'Live' }
    )
    foreach ($lookup in $lookups) {
        if ($lookup['Zone']) {
            $entries = @(Get-DnsEntry -Find $lookup['Find'] -Zone $lookup['Zone'] -Server $scenarioServer)
        }
        else {
            $entries = @(Get-DnsEntry -Find $lookup['Find'] -Server $scenarioServer)
        }

        if ($entries.Count -eq 0) {
            throw ("Get-DnsEntry returned nothing for the {0} '{1}'." -f $lookup['Label'], $lookup['Find'])
        }
        foreach ($entry in $entries) {
            if (-not $entry.PtrStatus) {
                throw ("Get-DnsEntry returned an entry without PtrStatus for the {0} '{1}': {2}." -f $lookup['Label'], $lookup['Find'], $entry.Name)
            }
            if ($entry.Source -ne $lookup['Source']) {
                throw ("Get-DnsEntry returned Source '{0}' for the {1} '{2}'; expected '{3}'." -f $entry.Source, $lookup['Label'], $lookup['Find'], $lookup['Source'])
            }
            Write-Output ('Scenario: {0} {1} -> {2} {3} {4} PtrStatus={5} Source={6}' -f $lookup['Label'], $lookup['Find'], $entry.Name, $entry.Type, $entry.Data, $entry.PtrStatus, $entry.Source)
        }
    }

    # Expected values, so that a silently wrong CLM code path cannot pass.
    $srv01 = @(Get-DnsEntry -Find 'srv01.contoso.local' -Server $scenarioServer)
    if ($srv01[0].PtrStatus -ne 'Ok' -or $srv01[0].IsStatic -or $null -eq $srv01[0].SnapshotAge) {
        throw ('srv01.contoso.local: PtrStatus {0}, IsStatic {1}; expected Ok, dynamic and a SnapshotAge.' -f $srv01[0].PtrStatus, $srv01[0].IsStatic)
    }
    if (@($srv01[0].Aliases).Count -ne 1 -or @($srv01[0].SharedWith).Count -ne 1) {
        throw 'srv01.contoso.local: expected one alias (gw) and one SharedWith name (srv02).'
    }
    $byAddress = @(Get-DnsEntry -Find '10.0.16.20' -Server $scenarioServer)
    if ($byAddress.Count -ne 2) {
        throw ('10.0.16.20: expected 2 entries (srv01 and srv02), got {0}.' -f $byAddress.Count)
    }
    $dc01 = @(Get-DnsEntry -Find 'dc01.contoso.local' -Server $scenarioServer)
    if (@($dc01[0].ReferencedBy) -notcontains 'SRV:_ldap._tcp.contoso.local') {
        throw 'dc01.contoso.local: ReferencedBy lacks SRV:_ldap._tcp.contoso.local.'
    }
    Write-Output 'Scenario: Get-DnsEntry checks passed.'
}
finally {
    & $dnsLathund {
        $script:SnapshotRoot = $null
        $script:DnsServerExportRoot = Join-Path -Path $env:windir -ChildPath 'System32\dns'
        $script:SnapshotIndexCache = @{}
        $script:ZoneTableCache = @{}
    }
    if (Test-Path -LiteralPath $scenarioRoot) {
        Remove-Item -LiteralPath $scenarioRoot -Recurse -Force
    }
}

# --- End of phase 1 scenarios ---
