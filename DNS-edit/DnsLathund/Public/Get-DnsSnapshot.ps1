function Get-DnsSnapshot {
    <#
    .SYNOPSIS
        Lists the zones in the local DNS snapshot, with their export time and age.

    .DESCRIPTION
        Get-DnsSnapshot reads the meta.json of the local snapshot of one or more
        DNS servers and returns one DnsLathund.Snapshot object per zone: when the
        zone was exported, how old that export is, the zone settings at export
        time, and the local file.

        Use it to see how fresh the data behind snapshot searches is, to decide
        whether to run Update-DnsSnapshot, or to find the zone export files for
        your own processing.

        The snapshot lives in %LOCALAPPDATA%\DnsLathund\snapshot\<server>\ (or in
        the folder named by the environment variable DNSLATHUND_SNAPSHOTPATH).

        What it does NOT do: it never contacts a DNS server and needs neither the
        DnsServer module nor network access. It does not create or refresh a
        snapshot (Update-DnsSnapshot does) and it does not read the zone files
        themselves. A server without a snapshot gives a warning and no output,
        not an error.

    .PARAMETER Server
        The DNS server(s) whose snapshot is listed. Default: the logon server
        ($env:LOGONSERVER without the leading backslashes). Accepts pipeline input.

    .PARAMETER Zone
        List only these zones. Wildcards (* and ?) are allowed. A name without
        wildcards that is not in the snapshot gives a warning.

    .EXAMPLE
        Get-DnsSnapshot -Server dc01

        Lists every zone in the snapshot of dc01 with its export time and age.

    .EXAMPLE
        'dc01', 'dc02' | Get-DnsSnapshot | Where-Object { $_.Age -gt (New-TimeSpan -Hours 24) } | Select-Object Server, Zone, Age

        Shows the zones on two servers whose snapshot is more than a day old,
        which are the ones to refresh with Update-DnsSnapshot.

    .EXAMPLE
        $snapshot = @(Get-DnsSnapshot -Server dc01 -WarningAction SilentlyContinue)
        if ($snapshot.Count -eq 0 -or @($snapshot | Where-Object { $_.Age.TotalHours -gt 24 }).Count -gt 0) {
            Update-DnsSnapshot -Server dc01 -Force | Out-Null
        }

        For a scheduled task: refreshes the snapshot of dc01 only when it is
        missing or a zone in it is older than 24 hours, and never prompts.

    .EXAMPLE
        Get-DnsSnapshot -Server dc01 -Zone '*.in-addr.arpa' | Measure-Object -Property FileSizeBytes -Sum

        Sums the size of all IPv4 reverse zone exports in the snapshot.

    .INPUTS
        System.String

        Server names can be piped to Get-DnsSnapshot.

    .OUTPUTS
        DnsLathund.Snapshot

        One object per zone, sorted by zone name within each server, with these
        properties:
        - Server (string): the DNS server, lower case.
        - Zone (string): the zone name, lower case.
        - ExportedAt (datetime): when the export of the zone started.
        - Age (timespan): time since ExportedAt when the object was created.
        - IsReverse (bool): the zone is a reverse lookup zone.
        - ZoneType (string): Primary.
        - ReplicationScope (string): Domain, Forest, Legacy or Custom; empty for
          file-backed zones.
        - DirectoryPartitionName (string): the AD partition of the zone.
        - DynamicUpdate (string): None, Secure or NonsecureAndSecure.
        - AgingEnabled (bool): aging/scavenging was enabled for the zone.
        - FileSizeBytes (long): size of the local export file.
        - Path (string): full path of the local export file.

    .NOTES
        - Works in Constrained Language Mode and without the DnsServer module.
        - The values describe the zone at export time, not now. Age grows until
          the next Update-DnsSnapshot; nothing refreshes a snapshot by itself.
        - Other commands warn when the snapshot they use is older than their
          -MaxSnapshotAge (default 24 hours).
        - Aging timestamps in the export files are as old as ExportedAt.
        - meta.json is UTF-8; Windows PowerShell 5.1 writes it with a BOM,
          PowerShell 7 without. Both read the same.
    #>
    [CmdletBinding()]
    [OutputType('DnsLathund.Snapshot')]
    param (
        [Parameter(ValueFromPipeline)]
        [Alias('ComputerName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Server,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]]$Zone
    )

    begin {
        # Normalised once; a pattern without wildcards must match a zone exactly.
        $zoneFilters = @(
            foreach ($zoneEntry in @($Zone)) {
                if ($null -eq $zoneEntry) {
                    continue
                }
                $pattern = $zoneEntry.Trim().TrimEnd('.').ToLowerInvariant()
                if ($pattern) {
                    @{ Pattern = $pattern; IsWildcard = [WildcardPattern]::ContainsWildcardCharacters($pattern); Display = $zoneEntry }
                }
            }
        )
    }

    process {
        $serverNames = @($Server)
        if (-not $Server) {
            # An empty name makes Resolve-DnsServerName use the logon server.
            $serverNames = @('')
        }

        foreach ($serverName in $serverNames) {
            $serverKey = Resolve-DnsServerName -Server $serverName
            $serverFolder = Get-DnsSnapshotRoot -Server $serverKey

            if (-not (Test-Path -LiteralPath $serverFolder -PathType Container)) {
                Write-Warning "No snapshot exists for '$serverKey' ('$serverFolder'). Run Update-DnsSnapshot -Server $serverKey to create one."
                continue
            }

            $meta = Get-DnsSnapshotMeta -Server $serverKey
            if ($null -eq $meta) {
                continue
            }
            $metaZones = $meta['Zones']

            $zoneNames = @($metaZones.Keys | Sort-Object)
            if ($zoneFilters.Count -gt 0) {
                $zoneNames = @(
                    foreach ($zoneName in $zoneNames) {
                        foreach ($zoneFilter in $zoneFilters) {
                            if ($zoneName -like $zoneFilter['Pattern']) {
                                $zoneName
                                break
                            }
                        }
                    }
                )
                foreach ($zoneFilter in $zoneFilters) {
                    if (-not $zoneFilter['IsWildcard'] -and -not $metaZones.ContainsKey($zoneFilter['Pattern'])) {
                        Write-Warning "Zone '$($zoneFilter['Display'])' is not in the snapshot of '$serverKey'. Run Update-DnsSnapshot -Server $serverKey -Zone $($zoneFilter['Pattern']) to add it."
                    }
                }
            }

            $now = Get-Date
            foreach ($zoneName in $zoneNames) {
                $entry = $metaZones[$zoneName]
                New-DnsObject -TypeName 'Snapshot' -Property ([ordered]@{
                        Server                 = $serverKey
                        Zone                   = $zoneName
                        ExportedAt             = $entry['ExportedAt']
                        Age                    = $now - $entry['ExportedAt']
                        IsReverse              = $entry['IsReverse']
                        ZoneType               = $entry['ZoneType']
                        ReplicationScope       = $entry['ReplicationScope']
                        DirectoryPartitionName = $entry['DirectoryPartitionName']
                        DynamicUpdate          = $entry['DynamicUpdate']
                        AgingEnabled           = $entry['AgingEnabled']
                        FileSizeBytes          = $entry['FileSizeBytes']
                        Path                   = Join-Path -Path $serverFolder -ChildPath ([string]$entry['File'])
                    })
            }
        }
    }
}
