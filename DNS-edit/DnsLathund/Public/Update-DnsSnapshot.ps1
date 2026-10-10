function Update-DnsSnapshot {
    <#
    .SYNOPSIS
        Exports DNS zones from a server into the local snapshot and rebuilds the search index.

    .DESCRIPTION
        Update-DnsSnapshot exports every exportable zone of a DNS server (or only
        the zones named with -Zone) with Export-DnsServerZone, copies the export
        files to the local snapshot folder, records when each zone was exported in
        meta.json, rebuilds the in-memory search index that Get-DnsEntry uses, and
        returns one DnsLathund.Snapshot object per zone in the snapshot.

        Use it before searching a large environment, after bulk changes, and
        whenever a command warns that the snapshot is older than you accept. On a
        zone with hundreds of thousands of records an export takes minutes; the
        snapshot exists so that searches do not have to ask the server for whole
        zones (the DNS Manager console times out on such zones).

        Exportable zones are primary zones that were not created automatically by
        the server, except TrustAnchors. Secondary, stub and conditional forwarder
        zones are never exported.

        Snapshot location: %LOCALAPPDATA%\DnsLathund\snapshot\<server>\ (or the
        folder in the environment variable DNSLATHUND_SNAPSHOTPATH), one
        <zone>.txt per zone plus meta.json. Each zone is exported to a temporary
        file first and only replaces the previous file when the export succeeded,
        so a failed export never destroys the last good snapshot of that zone. A
        full update (no -Zone) also removes zones from the snapshot that are no
        longer exportable on the server.

        The export as a whole is confirmed once (impact Low), not once per zone.
        With the default $ConfirmPreference there is no prompt; -Confirm asks,
        -Force never asks, and -WhatIf lists the zones (with -Verbose) and changes
        nothing.

        A zone that fails to export writes a non-terminating error and the other
        zones continue; the previous snapshot of that zone, if any, is kept. A
        -Zone name that is not hosted on the server, or is not exportable, is a
        non-terminating error too.

        What it does NOT do: it changes nothing in DNS (the server-side export
        file is removed again), it never runs on its own (other commands only
        create a snapshot automatically when none exists), and it does not keep a
        history of earlier snapshots.

    .PARAMETER Server
        The DNS server to export from. Default: the logon server
        ($env:LOGONSERVER without the leading backslashes).

    .PARAMETER Zone
        Export only these zones. The other zones already in the snapshot are kept
        as they are. Default: every exportable zone on the server.

    .PARAMETER Credential
        Alternate credentials. The DnsServer cmdlets then run through a CIM
        session, and the export file is copied over WinRM (Invoke-Command) because
        the admin$ share cannot use alternate credentials. Throws when no CIM
        session can be opened; it never falls back to the logged-on user.

    .PARAMETER TimeoutSec
        Timeout in seconds for the CIM session and for remoting operations.
        Default: 300.

    .PARAMETER Force
        Export without asking, also when -Confirm is given.

    .PARAMETER WhatIf
        Show which zones would be exported (use -Verbose for the list) without
        exporting anything or writing any file.

    .PARAMETER Confirm
        Ask once before the export starts.

    .EXAMPLE
        Update-DnsSnapshot -Server dc01

        Exports every exportable zone on dc01 into the local snapshot and lists
        one object per zone with its export time, age and file size.

    .EXAMPLE
        Update-DnsSnapshot -Server dc01 -Zone contoso.local, 16.0.10.in-addr.arpa | Format-Table Zone, ExportedAt, FileSizeBytes

        Refreshes only two zones and shows a compact table. The other zones in
        the snapshot keep their earlier export time; the output still lists every
        zone in the snapshot.

    .EXAMPLE
        Update-DnsSnapshot -Server dc01 -Force -ErrorAction Stop | Out-Null

        For a scheduled task or another unattended script: never prompts, and
        stops with a terminating error at the first zone that cannot be
        exported. Without -ErrorAction Stop a failed zone is reported and the
        others are still exported.

    .EXAMPLE
        Update-DnsSnapshot -Server dc01 -WhatIf -Verbose

        Lists the zones that would be exported and where each file would go,
        without contacting the server for anything but the zone list.

    .INPUTS
        None. Update-DnsSnapshot does not accept pipeline input.

    .OUTPUTS
        DnsLathund.Snapshot

        One object per zone in the snapshot after the update (including zones
        that were not exported this time), sorted by zone name, with these
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
        - AgingEnabled (bool): aging/scavenging is enabled for the zone.
        - FileSizeBytes (long): size of the local export file.
        - Path (string): full path of the local export file.

    .NOTES
        - Works in Constrained Language Mode.
        - Needs the DnsServer module (RSAT: DNS Server Tools) and an account that
          may export zones on the server (DnsAdmins or Administrators), plus
          access to \\<server>\admin$ or WinRM to copy the export file.
        - Only the module's own search index uses the snapshot. Commands that
          change DNS always read the record live first.
        - A snapshot is a point in time. The age of a snapshot is reported by
          Get-DnsSnapshot; other commands warn when the snapshot they use is
          older than their -MaxSnapshotAge (default 24 hours).
        - Aging timestamps are part of the export ([AGE:n]); records changed
          after the export are not in the snapshot.
        - On Windows PowerShell 5.1 meta.json and files copied over WinRM are
          written with a UTF-8 BOM; PowerShell 7 writes no BOM. Both read the
          same.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('DnsLathund.Snapshot')]
    param (
        [Parameter()]
        [Alias('ComputerName')]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]]$Zone,

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.Credential()]
        [pscredential]$Credential,

        [Parameter()]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSec = 300,

        [Parameter()]
        [switch]$Force
    )

    $state = @{ All = $false }
    $serverKey = Resolve-DnsServerName -Server $Server

    # A fresh zone list, so that zones created or removed since the module
    # cached the table are exported or dropped.
    $zoneTable = Get-DnsZoneTable -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec -Refresh

    # --- Which zones ---
    $isFullUpdate = -not $Zone
    if ($isFullUpdate) {
        $targets = @(foreach ($zoneInfo in @($zoneTable.Zones)) { if ($zoneInfo.IsExportable) { $zoneInfo } })
    }
    else {
        $seen = @{}
        $targets = @(
            foreach ($zoneEntry in $Zone) {
                $zoneName = ConvertTo-DnsNormalizedName -Name $zoneEntry
                if (-not $zoneName -or $seen.ContainsKey($zoneName)) {
                    continue
                }
                $seen[$zoneName] = $true

                $zoneInfo = $zoneTable.ZoneLookup[$zoneName]
                if ($null -eq $zoneInfo) {
                    Write-Error -Message "Zone '$zoneEntry' is not hosted on '$serverKey'. Check the name, or list the zones with Get-DnsServerZone -ComputerName $serverKey." -Category ObjectNotFound -ErrorId 'DnsLathund.Update-DnsSnapshot.ZoneNotFound' -TargetObject $zoneEntry
                    continue
                }
                if (-not $zoneInfo.IsExportable) {
                    if ($zoneInfo.ZoneType -ne 'Primary') {
                        $reason = "it is a $($zoneInfo.ZoneType) zone"
                    }
                    elseif ($zoneInfo.IsAutoCreated) {
                        $reason = 'it was created automatically by the DNS server'
                    }
                    else {
                        $reason = 'it holds DNSSEC trust anchors'
                    }
                    Write-Error -Message "Zone '$zoneName' on '$serverKey' cannot be exported because $reason. Only primary zones are exported; export it on the server that hosts the primary copy." -Category InvalidOperation -ErrorId 'DnsLathund.Update-DnsSnapshot.ZoneNotExportable' -TargetObject $zoneEntry
                    continue
                }
                $zoneInfo
            }
        )
    }

    if ($targets.Count -eq 0) {
        if ($isFullUpdate) {
            Write-Warning "'$serverKey' hosts no exportable zones (only secondary, stub, forwarder or automatically created zones). Nothing was exported."
        }
        return
    }

    $serverFolder = Get-DnsSnapshotRoot -Server $serverKey
    $plan = @(
        foreach ($zoneInfo in $targets) {
            $fileName = ($zoneInfo.ZoneName -replace '[^A-Za-z0-9._-]', '_') + '.txt'
            Write-Verbose "Zone to export: '$($zoneInfo.ZoneName)' -> '$(Join-Path -Path $serverFolder -ChildPath $fileName)'."
            @{ ZoneInfo = $zoneInfo; FileName = $fileName }
        }
    )

    # One decision for the whole export; nothing below this line runs under -WhatIf.
    $confirmTarget = "$($plan.Count) zone(s) on $serverKey"
    if (-not (Confirm-DnsAction -Target $confirmTarget -Action 'Export DNS zones to local snapshot' -Impact Low -State $state -Force:$Force)) {
        return
    }

    if (-not (Test-Path -LiteralPath $serverFolder -PathType Container)) {
        $null = New-Item -Path $serverFolder -ItemType Directory -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
    }

    $meta = $null
    if (Test-Path -LiteralPath (Join-Path -Path $serverFolder -ChildPath 'meta.json') -PathType Leaf) {
        $meta = Get-DnsSnapshotMeta -Server $serverKey
    }
    if ($null -eq $meta) {
        $meta = @{ Server = $serverKey; SchemaVersion = 1; Zones = @{} }
    }
    $metaZones = $meta['Zones']

    # --- Export and parse, zone by zone ---
    $progressId = 94
    $progressActivity = "Updating the DNS snapshot of '$serverKey'"
    $parsedZones = @{}
    $exportedCount = 0
    $zoneNumber = 0
    foreach ($item in $plan) {
        $zoneInfo = $item['ZoneInfo']
        $zoneName = $zoneInfo.ZoneName
        $zoneNumber++
        $percent = [int](($zoneNumber - 1) * 100 / $plan.Count)
        Write-Progress -Id $progressId -Activity $progressActivity -Status "Exporting zone $zoneNumber of $($plan.Count): $zoneName" -PercentComplete $percent

        $finalPath = Join-Path -Path $serverFolder -ChildPath $item['FileName']
        # Same folder as the final file, so the move below is a rename on one volume.
        $tempPath = Join-Path -Path $serverFolder -ChildPath ('{0}.{1}.tmp' -f $item['FileName'], [guid]::NewGuid().ToString('N'))
        $exportStartedAt = Get-Date
        try {
            $null = Export-DnsZoneFile -ZoneName $zoneName -Server $serverKey -DestinationPath $tempPath -Credential $Credential -TimeoutSec $TimeoutSec -ErrorAction Stop
            Move-Item -LiteralPath $tempPath -Destination $finalPath -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
        }
        catch {
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
            }
            $keptNote = ''
            if ($metaZones.ContainsKey($zoneName)) {
                $keptNote = ' The previous snapshot of this zone is kept.'
            }
            Write-Error -Message "Zone '$zoneName' on '$serverKey' could not be exported: $($_.Exception.Message)$keptNote" -Category InvalidOperation -ErrorId 'DnsLathund.Update-DnsSnapshot.ExportFailed' -TargetObject $zoneName
            continue
        }

        $fileSize = $null
        try {
            $fileSize = [long](Get-Item -LiteralPath $finalPath -ErrorAction Stop).Length
        }
        catch {
            Write-Verbose "Could not read the size of '$finalPath': $($_.Exception.Message)"
        }

        # The ZoneInfo is the source of truth for the zone settings at export time.
        $metaZones[$zoneName] = @{
            File                   = $item['FileName']
            ExportedAt             = $exportStartedAt
            IsReverse              = [bool]$zoneInfo.IsReverse
            ZoneType               = $zoneInfo.ZoneType
            ReplicationScope       = $zoneInfo.ReplicationScope
            DirectoryPartitionName = $zoneInfo.DirectoryPartitionName
            DynamicUpdate          = $zoneInfo.DynamicUpdate
            AgingEnabled           = $zoneInfo.AgingEnabled
            FileSizeBytes          = $fileSize
        }
        $exportedCount++

        # Parsed now, while the export is fresh, so the index build below does not
        # read the file a second time.
        Write-Progress -Id $progressId -Activity $progressActivity -Status "Parsing zone $zoneNumber of $($plan.Count): $zoneName" -PercentComplete $percent
        try {
            $parsed = ConvertFrom-DnsZoneFile -Path $finalPath -ZoneName $zoneName -ZoneInfo $zoneInfo
            $parsed['ExportedAt'] = $exportStartedAt
            foreach ($parseWarning in @($parsed['Warnings'])) {
                if ($parseWarning) {
                    Write-Warning "Zone '$zoneName': $parseWarning"
                }
            }
            $parsedZones[$zoneName] = $parsed
        }
        catch {
            Write-Warning "Zone '$zoneName' was exported to '$finalPath' but could not be parsed: $($_.Exception.Message) It is left out of the search index."
        }
    }

    # --- Zones that are gone from the server leave the snapshot (full update only) ---
    $prunedCount = 0
    if ($isFullUpdate) {
        $targetNames = @{}
        foreach ($zoneInfo in $targets) {
            $targetNames[$zoneInfo.ZoneName] = $true
        }
        foreach ($oldZoneName in @($metaZones.Keys)) {
            if ($targetNames.ContainsKey($oldZoneName)) {
                continue
            }
            $oldPath = Join-Path -Path $serverFolder -ChildPath ([string]$metaZones[$oldZoneName]['File'])
            Write-Verbose "Zone '$oldZoneName' is no longer an exportable zone on '$serverKey'; removing it from the snapshot."
            $metaZones.Remove($oldZoneName)
            $prunedCount++
            if (Test-Path -LiteralPath $oldPath -PathType Leaf) {
                try {
                    Remove-Item -LiteralPath $oldPath -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
                }
                catch {
                    Write-Warning "Could not remove the snapshot file '$oldPath' of zone '$oldZoneName', which is no longer on '$serverKey': $($_.Exception.Message)"
                }
            }
        }
    }

    if ($exportedCount -gt 0 -or $prunedCount -gt 0) {
        try {
            Save-DnsSnapshotMeta -Server $serverKey -Meta $meta
        }
        catch {
            Write-Progress -Id $progressId -Activity $progressActivity -Completed
            throw "Could not write the snapshot metadata of '$serverKey' to '$serverFolder': $($_.Exception.Message) Check that the folder is writable and run Update-DnsSnapshot again."
        }
    }

    # --- Rebuild and cache the index from every zone in the snapshot ---
    $metaZoneNames = @($metaZones.Keys | Sort-Object)
    if ($metaZoneNames.Count -eq 0) {
        $script:SnapshotIndexCache.Remove($serverKey)
    }
    elseif ($exportedCount -gt 0 -or $prunedCount -gt 0 -or -not $script:SnapshotIndexCache.ContainsKey($serverKey)) {
        $parseResults = @(
            foreach ($zoneName in $metaZoneNames) {
                if ($parsedZones.ContainsKey($zoneName)) {
                    $parsedZones[$zoneName]
                    continue
                }

                # Not exported in this run (a -Zone subset or a failed export): the
                # previous file is still part of the snapshot.
                $entry = $metaZones[$zoneName]
                $zonePath = Join-Path -Path $serverFolder -ChildPath ([string]$entry['File'])
                Write-Progress -Id $progressId -Activity $progressActivity -Status "Reading the snapshot of zone $zoneName"
                try {
                    $parsed = ConvertFrom-DnsZoneFile -Path $zonePath -ZoneName $zoneName -ZoneInfo $zoneTable.ZoneLookup[$zoneName]
                    $parsed['ExportedAt'] = $entry['ExportedAt']
                    foreach ($parseWarning in @($parsed['Warnings'])) {
                        if ($parseWarning) {
                            Write-Warning "Zone '$zoneName': $parseWarning"
                        }
                    }
                    $parsed
                }
                catch {
                    Write-Warning "The snapshot file of zone '$zoneName' could not be read: $($_.Exception.Message) It is left out of the search index; run Update-DnsSnapshot -Server $serverKey -Zone $zoneName."
                }
            }
        )
        $parsedZones = $null

        $index = New-DnsSnapshotIndex -Server $serverKey -ParseResult $parseResults -ZoneTable $zoneTable
        $parseResults = $null
        $script:SnapshotIndexCache[$serverKey] = $index
        Write-Verbose "Snapshot index of '$serverKey' rebuilt from $($metaZoneNames.Count) zone(s)."
    }
    Write-Progress -Id $progressId -Activity $progressActivity -Completed

    # --- One object per zone in the snapshot ---
    $now = Get-Date
    foreach ($zoneName in $metaZoneNames) {
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
