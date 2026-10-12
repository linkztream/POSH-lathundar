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

    # --- Phase 2 scenarios (CONTRACTS §16) ---
    # The change commands under -WhatIf against the same stub data: nothing may
    # be written to the stub store, every Result must say WhatIf, and every
    # Result must be one line in a change log inside the scenario root, so the
    # operator's real log is never touched.
    $scenarioLog = Join-Path -Path $scenarioRoot -ChildPath 'changes.jsonl'
    $backupRoot = Join-Path -Path $scenarioRoot -ChildPath 'backup'

    $previews = @(
        @{ Label = 'Remove-DnsEntry'; Results = @(Remove-DnsEntry -Identity 'srv02.contoso.local' -Server $scenarioServer -LogPath $scenarioLog -WhatIf) }
        @{ Label = 'New-DnsEntry'; Results = @(New-DnsEntry -Name 'new01.contoso.local' -Address '10.0.16.30' -Server $scenarioServer -LogPath $scenarioLog -WhatIf) }
        @{ Label = 'Set-DnsEntry'; Results = @(Set-DnsEntry -Identity 'srv02.contoso.local' -TTL 300 -Server $scenarioServer -LogPath $scenarioLog -WhatIf) }
        @{ Label = 'Backup-DnsZone'; Results = @(Backup-DnsZone -Server $scenarioServer -Path $backupRoot -LogPath $scenarioLog -WhatIf) }
    )
    $expectedLines = 0
    foreach ($preview in $previews) {
        $results = @($preview['Results'])
        if ($results.Count -lt 1) {
            throw ('{0} -WhatIf returned no Result.' -f $preview['Label'])
        }
        foreach ($result in $results) {
            if ($result.Result -ne 'WhatIf') {
                throw ('{0} -WhatIf returned Result {1} for {2} {3}; expected WhatIf.' -f $preview['Label'], $result.Result, $result.Action, $result.Name)
            }
            if (-not $result.BatchId -or -not $result.Name) {
                throw ('{0} -WhatIf returned a Result without BatchId or Name.' -f $preview['Label'])
            }
            Write-Output ('Scenario: {0} -WhatIf -> {1} {2} {3} {4}' -f $preview['Label'], $result.Action, $result.Name, $result.Data, $result.Result)
        }
        $expectedLines = $expectedLines + $results.Count
    }
    if (@($previews[3]['Results']).Count -ne 2) {
        throw ('Backup-DnsZone -WhatIf returned {0} Result(s); expected one per exportable zone (2).' -f @($previews[3]['Results']).Count)
    }

    # Nothing may have changed, and every Result must be exactly one log line.
    $srv02After = @(Get-DnsEntry -Find 'srv02.contoso.local' -Server $scenarioServer)
    if ($srv02After.Count -ne 1 -or $srv02After[0].Data -ne '10.0.16.20') {
        throw 'srv02.contoso.local changed under -WhatIf.'
    }
    $new01After = @(Get-DnsEntry -Find 'new01.contoso.local' -Server $scenarioServer)
    if ($new01After.Count -ne 0) {
        throw 'new01.contoso.local was created under -WhatIf.'
    }
    if (Test-Path -LiteralPath $backupRoot) {
        throw 'Backup-DnsZone -WhatIf created the backup folder.'
    }
    if (-not (Test-Path -LiteralPath $scenarioLog -PathType Leaf)) {
        throw 'The -WhatIf runs wrote no change log.'
    }
    $logLines = @(Get-Content -LiteralPath $scenarioLog -Encoding UTF8)
    if ($logLines.Count -ne $expectedLines) {
        throw ('The change log has {0} line(s); expected {1} (one per Result).' -f $logLines.Count, $expectedLines)
    }
    foreach ($line in $logLines) {
        $entry = ConvertFrom-Json -InputObject $line
        if ($entry.Result -ne 'WhatIf' -or -not $entry.Name -or -not $entry.BatchId -or -not $entry.Action) {
            throw ('Unexpected change-log line: {0}' -f $line)
        }
    }
    Write-Output ('Scenario: phase 2 -WhatIf checks passed ({0} Result(s), {0} log line(s)).' -f $expectedLines)
    # --- End of phase 2 scenarios ---
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
