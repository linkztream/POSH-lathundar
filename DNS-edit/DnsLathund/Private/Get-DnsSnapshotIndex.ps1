function Get-DnsSnapshotIndex {
    <#
    .SYNOPSIS
        Returns the search index of a server's snapshot, loading or creating it when needed.

    .DESCRIPTION
        Returns the index hashtable of CONTRACTS.md section 9.3 for one server
        (section 9.4), from the first source that has it:

        1. $script:SnapshotIndexCache (built earlier in this session, by this
           function or by Update-DnsSnapshot);
        2. the snapshot on disk: every zone file listed in meta.json is parsed
           with ConvertFrom-DnsZoneFile and the index is built with
           New-DnsSnapshotIndex, then cached;
        3. nothing on disk: a warning announces the export and Update-DnsSnapshot
           creates the snapshot (and caches the index). This is the only place
           where a snapshot is created without being asked for, because a search
           cannot work without one.

        Reading an existing snapshot does not require the server: the zone table
        (Get-DnsZoneTable) supplies the zone details the parser uses for RFC 2317
        zones when the server answers; when it does not, or the DnsServer module
        is missing, a warning is written and the details are inferred from the
        zone names.

        A snapshot older than -MaxSnapshotAge is used anyway, with a warning that
        names its age and Update-DnsSnapshot; it is never refreshed
        automatically. The age is that of the oldest zone export in the index.

        A zone whose file is missing or unreadable is left out with a warning.
        When no zone at all can be read, the snapshot counts as missing.

    .PARAMETER Server
        The DNS server.

    .PARAMETER Credential
        Alternate credentials for the zone table and for an automatic export.

    .PARAMETER TimeoutSec
        Timeout for server calls. Default: 300.

    .PARAMETER MaxSnapshotAge
        Warn when the oldest zone export in the snapshot is older than this.
        Default: 24 hours.

    .EXAMPLE
        $index = Get-DnsSnapshotIndex -Server 'dc01'
        $index.Addr['10.0.16.5']

        Returns the names that have an A record for 10.0.16.5 in the snapshot.

    .EXAMPLE
        Get-DnsSnapshotIndex -Server 'dc01' -MaxSnapshotAge (New-TimeSpan -Hours 4)

        Returns the index and warns when any zone export is older than 4 hours.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter()]
        [AllowNull()]
        [pscredential]$Credential,

        [Parameter()]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSec = 300,

        [Parameter()]
        [timespan]$MaxSnapshotAge = (New-TimeSpan -Hours 24)
    )

    $serverKey = $Server.Trim().ToLowerInvariant()
    $index = $null

    if ($script:SnapshotIndexCache.ContainsKey($serverKey)) {
        Write-Verbose "Using the cached snapshot index of '$serverKey'."
        $index = $script:SnapshotIndexCache[$serverKey]
    }

    # --- Load the snapshot from disk ---
    if ($null -eq $index) {
        $serverFolder = Get-DnsSnapshotRoot -Server $serverKey
        $meta = $null
        if (Test-Path -LiteralPath (Join-Path -Path $serverFolder -ChildPath 'meta.json') -PathType Leaf) {
            $meta = Get-DnsSnapshotMeta -Server $serverKey
        }

        $zoneNames = @()
        if ($null -ne $meta) {
            $zoneNames = @($meta['Zones'].Keys | Sort-Object)
        }

        if ($zoneNames.Count -gt 0) {
            # The zone table only refines the parse (classless zones); a snapshot
            # must stay readable when the server or RSAT is not available.
            $zoneTable = $null
            try {
                $zoneTable = Get-DnsZoneTable -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec
            }
            catch {
                Write-Warning "Could not read the zone list of '$serverKey' ($($_.Exception.Message)); the snapshot is read without it and zone details are inferred from the zone names."
            }
            $zoneLookup = @{}
            if ($null -ne $zoneTable) {
                $zoneLookup = $zoneTable.ZoneLookup
            }

            $progressId = 94
            $progressActivity = "Reading the DNS snapshot of '$serverKey'"
            $zoneNumber = 0
            $parseResults = @(
                foreach ($zoneName in $zoneNames) {
                    $zoneNumber++
                    $entry = $meta['Zones'][$zoneName]
                    $zonePath = Join-Path -Path $serverFolder -ChildPath ([string]$entry['File'])
                    Write-Progress -Id $progressId -Activity $progressActivity -Status "Parsing zone $zoneNumber of $($zoneNames.Count): $zoneName" -PercentComplete ([int](($zoneNumber - 1) * 100 / $zoneNames.Count))

                    if (-not (Test-Path -LiteralPath $zonePath -PathType Leaf)) {
                        Write-Warning "The snapshot file '$zonePath' of zone '$zoneName' is missing; the zone is left out. Run Update-DnsSnapshot -Server $serverKey -Zone $zoneName."
                        continue
                    }

                    try {
                        $parsed = ConvertFrom-DnsZoneFile -Path $zonePath -ZoneName $zoneName -ZoneInfo $zoneLookup[$zoneName]
                    }
                    catch {
                        Write-Warning "The snapshot file '$zonePath' of zone '$zoneName' could not be read: $($_.Exception.Message) The zone is left out; run Update-DnsSnapshot -Server $serverKey -Zone $zoneName."
                        continue
                    }
                    $parsed['ExportedAt'] = $entry['ExportedAt']
                    foreach ($parseWarning in @($parsed['Warnings'])) {
                        if ($parseWarning) {
                            Write-Warning "Zone '$zoneName': $parseWarning"
                        }
                    }
                    $parsed
                }
            )
            Write-Progress -Id $progressId -Activity $progressActivity -Completed

            if ($parseResults.Count -gt 0) {
                if ($null -eq $zoneTable) {
                    # New-DnsSnapshotIndex accepts any object with a ZoneLookup; an
                    # empty one makes it infer IsReverse and treat every NS owner
                    # below a zone apex as a delegation.
                    $zoneTable = @{ ZoneLookup = @{} }
                }
                Write-Verbose "Building the snapshot index of '$serverKey' from $($parseResults.Count) zone file(s) in '$serverFolder'."
                $index = New-DnsSnapshotIndex -Server $serverKey -ParseResult $parseResults -ZoneTable $zoneTable
                $parseResults = $null
                $script:SnapshotIndexCache[$serverKey] = $index
            }
        }
    }

    # --- No snapshot at all: create one ---
    if ($null -eq $index) {
        $zoneTable = Get-DnsZoneTable -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec
        $exportableCount = @(foreach ($zoneInfo in @($zoneTable.Zones)) { if ($zoneInfo.IsExportable) { $zoneInfo } }).Count
        Write-Warning "No snapshot exists for '$serverKey'. Exporting $exportableCount zone(s) now; this can take several minutes on large zones."

        # -Force and -WhatIf:$false: the export was just announced, and a search
        # run under a caller's -WhatIf must still be able to read data.
        $null = Update-DnsSnapshot -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec -Force -WhatIf:$false -Confirm:$false

        if ($script:SnapshotIndexCache.ContainsKey($serverKey)) {
            $index = $script:SnapshotIndexCache[$serverKey]
        }
        if ($null -eq $index) {
            throw "Could not create a snapshot for '$serverKey'; no zone could be exported (see the errors above). Fix the cause and run Update-DnsSnapshot -Server $serverKey."
        }
        return $index
    }

    # --- Stale, but used ---
    $oldestExportedAt = $index['OldestExportedAt']
    if ($null -ne $oldestExportedAt) {
        $age = (Get-Date) - [datetime]$oldestExportedAt
        if ($age -gt $MaxSnapshotAge) {
            $ageText = '{0}d {1}h {2}m' -f $age.Days, $age.Hours, $age.Minutes
            $maxText = '{0}d {1}h {2}m' -f $MaxSnapshotAge.Days, $MaxSnapshotAge.Hours, $MaxSnapshotAge.Minutes
            Write-Warning "The snapshot of '$serverKey' is $ageText old (oldest zone export, exported $($oldestExportedAt.ToString('yyyy-MM-dd HH:mm'))), older than the accepted $maxText. It is used anyway; run Update-DnsSnapshot -Server $serverKey to refresh it."
        }
    }

    $index
}
