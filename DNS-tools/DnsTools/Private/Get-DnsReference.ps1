function Get-DnsReference {
    <#
    .SYNOPSIS
        Finds the CNAME, SRV, NS and MX records that point at a name.

    .DESCRIPTION
        Change commands must not silently remove a name that domain controllers
        (SRV), delegations (NS) or mail (MX) depend on, and they remove the CNAME
        aliases of a name together with it. This helper answers "who points at this
        name" from the cheapest source that is trustworthy (CONTRACTS.md section 7.5):

        1. A snapshot index no older than -MaxSnapshotAge: the cached index of the
           batch's server, or, when nothing is cached, the snapshot on disk if the
           oldest zone export listed in its meta.json (counting only zone files
           that exist) is young enough. Only then is the index loaded with
           Get-DnsSnapshotIndex, so this path never triggers the automatic export.
           The answer comes from the index's RefBy table. The age limit applies to
           a cached index as well: a reference check must not trust data older than
           the caller accepted.
        2. Otherwise WQL: one CIM session per batch (Get-DnsCimSession, kept in
           $Batch.CimSession) and Get-DnsReferenceTable for every hosted forward
           zone, because an SRV, NS or MX record may live in another zone than the
           name. Each zone's table is cached in $Batch.References, so a batch queries
           each zone once. No session, or any zone whose table cannot be read, gives
           Source 'Unavailable': a check that saw only some zones is no check.
        3. -SkipReferenceCheck: nothing is looked up; Source 'Skipped' with one
           warning per batch (counted in $Batch.Counts['ReferenceCheckSkipped']).

        Returns @{ Cname; Srv; Ns; Mx; Source; Age }. The four lists are [string[]]
        of distinct owner FQDNs (normalised, in the order found) and are empty when
        nothing points at the name, and also for 'Skipped' and 'Unavailable'. Source
        is 'Snapshot', 'Wql', 'Skipped' or 'Unavailable'; Age is the snapshot's age
        for 'Snapshot' and $null otherwise. The caller decides what a reference means
        (CONTRACTS.md section 13.4).

    .PARAMETER Name
        The FQDN to look up, with or without the trailing dot.

    .PARAMETER ZoneTable
        The server's zone table (Get-DnsZoneTable); its ForwardZones are queried
        on the WQL path.

    .PARAMETER Batch
        The batch from New-DnsBatch; supplies the server and caches the CIM session
        and the reference tables.

    .PARAMETER Credential
        Alternate credentials for the CIM session and for loading the snapshot.

    .PARAMETER TimeoutSec
        Timeout for the CIM session and each WQL query. Default: 300.

    .PARAMETER MaxSnapshotAge
        The oldest snapshot that may answer, in d.hh:mm:ss form. Default: 24 hours.

    .PARAMETER SkipReferenceCheck
        Look nothing up; report Source 'Skipped'.

    .OUTPUTS
        System.Collections.Hashtable

    .EXAMPLE
        $references = Get-DnsReference -Name 'dc01.contoso.local' -ZoneTable $zoneTable -Batch $batch
        if (@($references['Srv']).Count -gt 0) { 'dc01 is referenced by SRV records' }

        Checks whether SRV records point at dc01.contoso.local.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$ZoneTable,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Batch,

        [Parameter()]
        [AllowNull()]
        [pscredential]$Credential,

        [Parameter()]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSec = 300,

        [Parameter()]
        [timespan]$MaxSnapshotAge = (New-TimeSpan -Hours 24),

        [Parameter()]
        [switch]$SkipReferenceCheck
    )

    $target = ConvertTo-DnsNormalizedName -Name $Name
    $serverKey = ([string]$Batch['Server']).Trim().ToLowerInvariant()
    $kinds = @('Cname', 'Srv', 'Ns', 'Mx')
    $references = @{ Cname = [string[]]@(); Srv = [string[]]@(); Ns = [string[]]@(); Mx = [string[]]@(); Source = 'Unavailable'; Age = $null }

    # --- 3. Skipped on request ---
    if ($SkipReferenceCheck) {
        if ($Batch['Counts'] -isnot [hashtable]) {
            $Batch['Counts'] = @{}
        }
        $skippedBefore = [int]$Batch['Counts']['ReferenceCheckSkipped']
        $Batch['Counts']['ReferenceCheckSkipped'] = $skippedBefore + 1
        if ($skippedBefore -eq 0) {
            Write-Warning "-SkipReferenceCheck: SRV, NS, MX and CNAME records that point at the names in this run are not looked for on '$serverKey'. Referenced names are changed anyway and their CNAME aliases stay behind."
        }
        $references['Source'] = 'Skipped'
        return $references
    }

    # --- 1. A snapshot that is young enough ---
    $index = $null
    $snapshotAge = $null
    if ($script:SnapshotIndexCache.ContainsKey($serverKey)) {
        $cachedIndex = $script:SnapshotIndexCache[$serverKey]
        if ($null -ne $cachedIndex -and $null -ne $cachedIndex['OldestExportedAt']) {
            $cachedAge = (Get-Date) - [datetime]$cachedIndex['OldestExportedAt']
            if ($cachedAge -le $MaxSnapshotAge) {
                $index = $cachedIndex
                $snapshotAge = $cachedAge
            }
            else {
                Write-Verbose "The cached snapshot index of '$serverKey' is older than $MaxSnapshotAge; references are not read from it."
            }
        }
    }

    # Get-DnsSnapshotIndex answers from its cache first, so with a cached (but too
    # old) index the disk is not worth reading.
    if ($null -eq $index -and -not $script:SnapshotIndexCache.ContainsKey($serverKey)) {
        $serverFolder = Get-DnsSnapshotRoot -Server $serverKey
        # Probe for the file first: Get-DnsSnapshotMeta warns about a missing one, and
        # a snapshot that was never made is not worth a warning here.
        if (Test-Path -LiteralPath (Join-Path -Path $serverFolder -ChildPath 'meta.json') -PathType Leaf) {
            $meta = Get-DnsSnapshotMeta -Server $serverKey
            $oldestExportedAt = $null
            if ($null -ne $meta) {
                foreach ($zoneName in @($meta['Zones'].Keys)) {
                    $zoneEntry = $meta['Zones'][$zoneName]
                    if (-not (Test-Path -LiteralPath (Join-Path -Path $serverFolder -ChildPath ([string]$zoneEntry['File'])) -PathType Leaf)) {
                        continue
                    }
                    if ($null -eq $oldestExportedAt -or $zoneEntry['ExportedAt'] -lt $oldestExportedAt) {
                        $oldestExportedAt = $zoneEntry['ExportedAt']
                    }
                }
            }

            if ($null -ne $oldestExportedAt -and ((Get-Date) - $oldestExportedAt) -le $MaxSnapshotAge) {
                $loadedIndex = Get-DnsSnapshotIndex -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec -MaxSnapshotAge $MaxSnapshotAge
                # The loader prefers its cache; re-check the age of what it returned.
                if ($null -ne $loadedIndex -and $null -ne $loadedIndex['OldestExportedAt']) {
                    $loadedAge = (Get-Date) - [datetime]$loadedIndex['OldestExportedAt']
                    if ($loadedAge -le $MaxSnapshotAge) {
                        $index = $loadedIndex
                        $snapshotAge = $loadedAge
                    }
                }
            }
            elseif ($null -ne $oldestExportedAt) {
                Write-Verbose "The snapshot of '$serverKey' on disk is older than $MaxSnapshotAge; references are read live with WQL."
            }
        }
    }

    if ($null -ne $index) {
        Write-Verbose "References to '$target' come from the snapshot of '$serverKey' ($snapshotAge old)."
        $rows = @($index['RefBy'][$target])
        foreach ($kind in $kinds) {
            $recordType = $kind.ToUpperInvariant()
            $seen = @{}
            $owners = @(
                foreach ($row in $rows) {
                    if ($null -eq $row) {
                        continue
                    }
                    # RefBy rows are "TYPE`tOWNER`tZONE" (CONTRACTS.md section 9.3).
                    $fields = ([string]$row).Split("`t")
                    if ($fields.Count -lt 2 -or $fields[0] -ne $recordType -or $seen.ContainsKey($fields[1])) {
                        continue
                    }
                    $seen[$fields[1]] = $true
                    $fields[1]
                }
            )
            $references[$kind] = [string[]]$owners
        }
        $references['Source'] = 'Snapshot'
        $references['Age'] = $snapshotAge
        return $references
    }

    # --- 2. Live, with WQL ---
    $session = $Batch['CimSession']
    if ($null -eq $session) {
        $session = Get-DnsCimSession -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec
        $Batch['CimSession'] = $session
    }
    if ($null -eq $session) {
        Write-Verbose "References to '$target' cannot be checked: no CIM session to '$serverKey'."
        return $references
    }

    if ($Batch['References'] -isnot [hashtable]) {
        $Batch['References'] = @{}
    }
    $tableCache = $Batch['References']

    $isComplete = $true
    $tables = @(
        foreach ($zoneName in @($ZoneTable.ForwardZones)) {
            if (-not $zoneName) {
                continue
            }
            if (-not $tableCache.ContainsKey($zoneName)) {
                # A failed zone is cached as $null too, so the rest of the batch does
                # not wait for the same timeouts again.
                $tableCache[$zoneName] = Get-DnsReferenceTable -Zone $zoneName -CimSession $session -TimeoutSec $TimeoutSec
            }
            $zoneTableEntry = $tableCache[$zoneName]
            if ($null -eq $zoneTableEntry) {
                $isComplete = $false
                break
            }
            $zoneTableEntry
        }
    )

    if (-not $isComplete) {
        Write-Verbose "References to '$target' cannot be checked: root\MicrosoftDNS on '$serverKey' did not answer for every zone."
        return $references
    }

    foreach ($kind in $kinds) {
        $seen = @{}
        $owners = @(
            foreach ($table in $tables) {
                foreach ($owner in @($table[$kind][$target])) {
                    if ($null -eq $owner -or $seen.ContainsKey($owner)) {
                        continue
                    }
                    $seen[$owner] = $true
                    $owner
                }
            }
        )
        $references[$kind] = [string[]]$owners
    }
    $references['Source'] = 'Wql'
    Write-Verbose "References to '$target' were read live from '$serverKey' with WQL ($($tables.Count) zone(s))."
    $references
}
