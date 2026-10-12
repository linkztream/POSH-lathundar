function Backup-DnsZone {
    <#
    .SYNOPSIS
        Saves DNS zones from a server as zone files in a new, time-stamped backup folder.

    .DESCRIPTION
        Backup-DnsZone exports every exportable zone of a DNS server (or only the
        zones named with -Zone) with Export-DnsServerZone, copies each export to a
        new folder on this computer, and writes a RESTORE.md into that folder that
        explains how to put a single record or a whole zone back. It returns one
        DnsLathund.Result object per zone.

        Use it before a risky clean-up or a bulk change (Remove-DnsEntry,
        Set-DnsEntry, scavenging), and on a schedule if you want a history of your
        zones that does not depend on Active Directory backups.

        Layout, below -Path:

            <server>-<yyyyMMdd-HHmmss>\
                backup_<zone>_<yyyyMMdd-HHmmss>.txt     one file per zone
                RESTORE.md                              how to restore, with the file list

        The files are complete zone exports in the zone file format of Windows
        DNS, readable in any text editor. In file names every character other than
        letters, digits, '.', '_' and '-' becomes '_' (the classless zone
        0/25.16.0.10.in-addr.arpa is saved as backup_0_25.16.0.10.in-addr.arpa_...).
        RESTORE.md is written once per run, after the exports, and lists only the
        files that were really created.

        Exportable zones are primary zones that were not created automatically by
        the server, except TrustAnchors. Secondary, stub and conditional forwarder
        zones are never exported; back them up on the server that hosts the
        primary copy. A -Zone name that is not hosted on the server, or is not
        exportable, writes a non-terminating error and a Failed result for that
        name, and the other zones continue. These results come first, before the
        results of the zones that were exported.

        The backup as a whole is confirmed once (impact Low), not once per zone.
        With the default $ConfirmPreference there is no prompt; -Confirm asks,
        -Force never asks, and -WhatIf creates no folder and no file and returns
        one WhatIf result per zone with the file that would be written.

        Every result is also written to the change log (see -LogPath), so a
        scheduled backup leaves a trail of what was saved where.

        What it does NOT do: it changes nothing in DNS (the export file on the
        server is removed again), it does not touch the local snapshot that
        Get-DnsEntry searches (use Update-DnsSnapshot for that), it does not save
        zone settings that are not part of a zone file (replication scope, dynamic
        update, security, aging and scavenging settings), it does not delete old
        backups, and it does not restore anything. RESTORE.md describes the
        restore steps.

    .PARAMETER Zone
        Back up only these zones. Default: every exportable zone on the server.
        Names are matched without regard to case and a trailing dot.

    .PARAMETER Path
        The folder in which the backup folder is created. Default:
        %LOCALAPPDATA%\DnsLathund\backup. The folder is created when it does not
        exist; a relative path is relative to the current location. A new
        <server>-<yyyyMMdd-HHmmss> folder is created below it for every run, so
        earlier backups are never overwritten. Alias: BackupPath.

    .PARAMETER Server
        The DNS server to export from. Default: the logon server
        ($env:LOGONSERVER without the leading backslashes).

    .PARAMETER Credential
        Alternate credentials. The DnsServer cmdlets then run through a CIM
        session, and the export file is copied over WinRM (Invoke-Command) because
        the admin$ share cannot use alternate credentials. Throws when no CIM
        session can be opened; it never falls back to the logged-on user.

    .PARAMETER TimeoutSec
        Timeout in seconds for the CIM session and for remoting operations.
        Default: 300.

    .PARAMETER LogPath
        The change-log file. Default: the environment variable DNSLATHUND_LOGPATH,
        else %LOCALAPPDATA%\DnsLathund\log\DnsLathund_<yyyy-MM>.jsonl. One JSON
        line is written per result, also under -WhatIf.

    .PARAMETER Force
        Back up without asking, also when -Confirm is given.

    .PARAMETER WhatIf
        Show what would be done without creating the backup folder or any file.
        Prints one "What if" line for the run and returns one WhatIf result per
        zone; Data is the file that would be written.

    .PARAMETER Confirm
        Ask once before the backup starts.

    .EXAMPLE
        Backup-DnsZone -Server dc01

        Saves every exportable zone of dc01 below %LOCALAPPDATA%\DnsLathund\backup\dc01-<date>-<time>\
        and returns one result per zone. The Data property of each result is the
        file that was written; RESTORE.md in the same folder says how to restore.

    .EXAMPLE
        Backup-DnsZone -Server dc01 -Zone contoso.local, 16.0.10.in-addr.arpa -Path D:\DNS-Backup | Where-Object Result -ne 'Success'

        Backs up two zones to D:\DNS-Backup and shows only the zones that could
        not be saved. An empty result means every file was written.

    .EXAMPLE
        Backup-DnsZone -Server dc01 -Force -LogPath D:\Logs\dns-backup.jsonl -ErrorAction Stop | Out-Null

        For a scheduled task or another unattended script: never prompts, writes
        every result to D:\Logs\dns-backup.jsonl, and stops with a terminating
        error at the first zone that cannot be saved. The result of that zone is
        logged first, and RESTORE.md still lists the files that were already
        written. Without -ErrorAction Stop a failed zone is reported and the other
        zones are still saved.

    .EXAMPLE
        Backup-DnsZone -Server dc01 -WhatIf

        Lists the zones that would be saved and the files they would be saved to,
        without creating anything.

    .INPUTS
        None. Backup-DnsZone does not accept pipeline input.

    .OUTPUTS
        DnsLathund.Result

        One object per zone, with these properties in this order:
        - Action (string): Backup.
        - Name (string): the zone name, lower case.
        - Type (string): Zone.
        - Data (string): the full path of the backup file. For WhatIf and Failed
          it is the file that would be, or was meant to be, written (it does not
          exist); $null for a requested zone that is not hosted or not exportable.
        - Result (string): Success, Failed or WhatIf.
        - Error (string): why the zone could not be saved; $null otherwise.
        - Zone (string): the zone name again.
        - NodeName (string): @ (the zone itself).
        - Server (string): the DNS server, lower case.
        - Id (string): a GUID that identifies the result and its log line.
        - BatchId (string): a GUID shared by every result of the run.
        - Timestamp (datetime): when the result was created.

    .NOTES
        - Works in Constrained Language Mode.
        - Needs the DnsServer module (RSAT: DNS Server Tools) and an account that
          may export zones on the server (DnsAdmins or Administrators), plus
          access to \\<server>\admin$ or WinRM to copy the export files.
        - A backup is a point in time. The SOA serial number and the aging
          timestamps of the records are not restored exactly, and zone settings
          (dynamic update, aging, replication scope, security) are not in a zone
          file; check them after a restore. The data of the records is what is
          saved.
        - The backup files are plain text and list every name and address of the
          zone. Keep the folder as protected as the zone itself.
        - If the server cannot be reached when the run starts, the command stops
          with a terminating error. If it becomes unreachable half way, each
          remaining zone is reported as Failed.
        - If no zone could be saved, the empty backup folder is removed again and
          no RESTORE.md is written.
        - On Windows PowerShell 5.1 RESTORE.md, and files copied over WinRM, are
          written with a UTF-8 BOM; PowerShell 7 writes no BOM. Both read the
          same.
        - Old backups are not removed; delete folders you no longer need.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('DnsLathund.Result')]
    param (
        [Parameter()]
        [Alias('ZoneName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Zone,

        [Parameter()]
        [Alias('BackupPath')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [Alias('ComputerName')]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.Credential()]
        [pscredential]$Credential,

        [Parameter()]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSec = 300,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [Parameter()]
        [switch]$Force
    )

    $serverKey = Resolve-DnsServerName -Server $Server

    # A missing default location is a precondition, not a per-zone failure.
    if ($Path) {
        $backupRoot = $Path
    }
    elseif ($env:LOCALAPPDATA) {
        $backupRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'DnsLathund\backup'
    }
    else {
        throw 'No -Path given and LOCALAPPDATA is not set, so there is no default backup location. Specify -Path.'
    }
    if (-not (Split-Path -Path $backupRoot -IsAbsolute)) {
        $backupRoot = Join-Path -Path $PWD.Path -ChildPath $backupRoot
    }
    Write-Verbose "Backup location: '$backupRoot'."

    $batch = New-DnsBatch -Server $serverKey -LogPath $LogPath -Force:$Force

    # A fresh zone list, so that zones created or removed since the module
    # cached the table are backed up or reported. This also stops the command at
    # once when the server cannot be reached, before anything is created.
    $zoneTable = Get-DnsZoneTable -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec -Refresh

    # --- Which zones ---
    $isFullBackup = -not $Zone
    if ($isFullBackup) {
        $targets = @(foreach ($zoneInfo in @($zoneTable.Zones)) { if ($zoneInfo.IsExportable) { $zoneInfo } })
    }
    else {
        # Checked first and reported afterwards: Write-DnsResult emits its object, which
        # would end up in the array if it were called inside this subexpression.
        $seen = @{}
        $checks = @(
            foreach ($zoneEntry in $Zone) {
                $requestedName = ([string]$zoneEntry).Trim()
                if (-not $requestedName) {
                    Write-Verbose 'Skipping an empty -Zone value.'
                    continue
                }

                # The root zone normalises to an empty name; the zone table calls it '.'.
                $zoneName = ConvertTo-DnsNormalizedName -Name $requestedName
                if (-not $zoneName) {
                    $zoneName = '.'
                }
                if ($seen.ContainsKey($zoneName)) {
                    continue
                }
                $seen[$zoneName] = $true

                $zoneInfo = $zoneTable.ZoneLookup[$zoneName]
                $check = @{ Entry = $zoneEntry; ZoneName = $zoneName; ZoneInfo = $zoneInfo; Message = $null; ErrorId = $null; Category = $null }
                if ($null -eq $zoneInfo) {
                    $check['Message'] = "Zone '$zoneEntry' is not hosted on '$serverKey'. Check the name, or list the zones with Get-DnsServerZone -ComputerName $serverKey."
                    $check['ErrorId'] = 'DnsLathund.Backup-DnsZone.ZoneNotFound'
                    $check['Category'] = 'ObjectNotFound'
                }
                elseif (-not $zoneInfo.IsExportable) {
                    if ($zoneInfo.ZoneType -ne 'Primary') {
                        $reason = "it is a $($zoneInfo.ZoneType) zone"
                    }
                    elseif ($zoneInfo.IsAutoCreated) {
                        $reason = 'it was created automatically by the DNS server'
                    }
                    else {
                        $reason = 'it holds DNSSEC trust anchors'
                    }
                    $check['Message'] = "Zone '$zoneName' on '$serverKey' cannot be exported because $reason. Only primary zones are exported; export it on the server that hosts the primary copy."
                    $check['ErrorId'] = 'DnsLathund.Backup-DnsZone.ZoneNotExportable'
                    $check['Category'] = 'InvalidOperation'
                }
                $check
            }
        )

        # The result comes first: with -ErrorAction Stop the error below ends the
        # command, and the log must still show that this zone was asked for.
        foreach ($check in $checks) {
            if ($null -eq $check['Message']) {
                continue
            }
            Write-DnsResult -Batch $batch -Action 'Backup' -Name $check['ZoneName'] -Type 'Zone' -Data $null -Zone $check['ZoneName'] -NodeName '@' -Result 'Failed' -ErrorMessage $check['Message']
            Write-Error -Message $check['Message'] -Category $check['Category'] -ErrorId $check['ErrorId'] -TargetObject $check['Entry']
        }
        $targets = @(foreach ($check in $checks) { if ($null -eq $check['Message']) { $check['ZoneInfo'] } })
    }

    if ($targets.Count -eq 0) {
        if ($isFullBackup) {
            Write-Warning "'$serverKey' hosts no exportable zones (only secondary, stub, forwarder or automatically created zones). Nothing was backed up."
        }
        return
    }

    # One decision for the whole run. -ErrorAction Stop turns the non-interactive
    # error of Confirm-DnsAction into the terminating error of CONTRACTS.md 5.8.
    $gateTarget = "$($targets.Count) zone(s) on $serverKey"
    $isApproved = Confirm-DnsAction -Target $gateTarget -Action 'Back up DNS zones' -Impact Low -State $batch['Confirm'] -Force:$Force -ErrorAction Stop
    if (-not $isApproved -and -not $WhatIfPreference) {
        return
    }

    # The time is taken after the gate: an operator who needed two minutes to
    # answer a prompt should find the time of the export, not of the prompt, in
    # the names.
    $startedAt = Get-Date
    $stamp = $startedAt.ToString('yyyyMMdd-HHmmss')
    $serverFolderName = $serverKey -replace '[^a-z0-9._-]', '_'
    try {
        $folderPath = Join-Path -Path $backupRoot -ChildPath ('{0}-{1}' -f $serverFolderName, $stamp) -ErrorAction Stop
    }
    catch {
        throw "The backup location '$backupRoot' is not valid: $($_.Exception.Message) Specify another -Path."
    }
    Write-Verbose "Backup folder: '$folderPath'."

    $plan = @(
        foreach ($zoneInfo in $targets) {
            $fileName = 'backup_{0}_{1}.txt' -f ($zoneInfo.ZoneName -replace '[^A-Za-z0-9._-]', '_'), $stamp
            $filePath = Join-Path -Path $folderPath -ChildPath $fileName
            Write-Verbose "Zone to back up: '$($zoneInfo.ZoneName)' -> '$filePath'."
            @{ ZoneName = $zoneInfo.ZoneName; FileName = $fileName; Path = $filePath }
        }
    )

    if (-not $isApproved) {
        # Only -WhatIf gets here (the gate printed its line already): nothing is created.
        foreach ($item in $plan) {
            Write-DnsResult -Batch $batch -Action 'Backup' -Name $item['ZoneName'] -Type 'Zone' -Data $item['Path'] -Zone $item['ZoneName'] -NodeName '@' -Result 'WhatIf'
        }
        return
    }

    if (Test-Path -LiteralPath $folderPath) {
        throw "The backup folder '$folderPath' already exists and is never reused, so that an earlier backup is not overwritten. Wait a second and run the command again, or specify another -Path."
    }
    $createError = $null
    try {
        $null = New-Item -Path $folderPath -ItemType Directory -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
    }
    catch {
        $createError = $_.Exception.Message
    }
    if ($null -eq $createError -and -not (Test-Path -LiteralPath $folderPath -PathType Container)) {
        # New-Item -Force returns silently, with no folder, when a file blocks the path.
        $createError = 'A file or another obstacle blocks the path.'
    }
    if ($null -ne $createError) {
        throw "Could not create the backup folder '$folderPath': $createError Check that the location is writable, or specify another -Path."
    }

    # --- Export, zone by zone ---
    $progressId = 93
    $progressActivity = "Backing up DNS zones from '$serverKey'"
    $backedUp = @{}
    $zoneNumber = 0
    try {
        foreach ($item in $plan) {
            $zoneName = $item['ZoneName']
            $zoneNumber++
            $percent = [int](($zoneNumber - 1) * 100 / $plan.Count)
            Write-Progress -Id $progressId -Activity $progressActivity -Status "Exporting zone $zoneNumber of $($plan.Count): $zoneName" -PercentComplete $percent

            $exportedPath = $null
            $exportError = $null
            try {
                $exportedPath = Export-DnsZoneFile -ZoneName $zoneName -Server $serverKey -DestinationPath $item['Path'] -Credential $Credential -TimeoutSec $TimeoutSec -ErrorAction Stop
            }
            catch {
                $exportError = $_.Exception.Message
            }

            if ($null -eq $exportError) {
                $backedUp[$zoneName] = $item['FileName']
                Write-DnsResult -Batch $batch -Action 'Backup' -Name $zoneName -Type 'Zone' -Data ([string]$exportedPath) -Zone $zoneName -NodeName '@' -Result 'Success'
                continue
            }

            $failureMessage = "Zone '$zoneName' on '$serverKey' could not be backed up: $exportError"
            Write-DnsResult -Batch $batch -Action 'Backup' -Name $zoneName -Type 'Zone' -Data $item['Path'] -Zone $zoneName -NodeName '@' -Result 'Failed' -ErrorMessage $failureMessage
            Write-Error -Message $failureMessage -Category InvalidOperation -ErrorId 'DnsLathund.Backup-DnsZone.ExportFailed' -TargetObject $zoneName
        }
    }
    finally {
        # In finally so that a stop (-ErrorAction Stop, Ctrl+C) after some zones were
        # saved still leaves the instructions next to the files that exist.
        Write-Progress -Id $progressId -Activity $progressActivity -Completed

        if ($backedUp.Count -gt 0) {
            $fileRows = @(
                foreach ($item in $plan) {
                    if ($backedUp.ContainsKey($item['ZoneName'])) {
                        '| {0} | {1} |' -f $item['ZoneName'], $item['FileName']
                    }
                }
            )
            $restoreLines = @(
                ('# Restore DNS zones (backup taken {0} from {1})' -f $startedAt.ToString('yyyy-MM-dd HH:mm:ss'), $serverKey)
                ''
                'This folder was made by Backup-DnsZone (DnsLathund module). Every file is a'
                'complete zone export in the zone file format of Windows DNS, made with'
                ('Export-DnsServerZone on {0}. The copy on the server was deleted after the file' -f $serverKey)
                'had been copied here, so this folder holds the only copy.'
                ''
                ('- Server: {0}' -f $serverKey)
                ('- Taken: {0}' -f $startedAt.ToString('yyyy-MM-dd HH:mm:ss'))
                ('- Folder: {0}' -f $folderPath)
                ''
                '## Files'
                ''
                '| Zone | File |'
                '|---|---|'
                $fileRows
                ''
                'In file names every character other than letters, digits, ".", "_" and "-" is'
                'replaced by "_" (the zone 0/25.16.0.10.in-addr.arpa is saved as'
                '0_25.16.0.10.in-addr.arpa). Use the zone name from the table, not the file'
                'name, in the commands below.'
                ''
                '## Restore a single record'
                ''
                'Open the backup file of the zone and find the line of the record. The first'
                'column is the owner name relative to the zone (a line that starts with a blank'
                'belongs to the owner above it, and @ is the zone itself); then come an optional'
                '[AGE:n] (the record is dynamic), an optional TTL, the record type and the data.'
                'Create the record again with New-DnsEntry:'
                ''
                '```powershell'
                '# Host record (A or AAAA) with its PTR record'
                ('New-DnsEntry -Name srv01.contoso.local -Address 10.0.16.20 -Server {0}' -f $serverKey)
                '# Alias (CNAME)'
                ('New-DnsEntry -Name gw.contoso.local -Target srv01.contoso.local -Server {0}' -f $serverKey)
                '```'
                ''
                'New-DnsEntry creates static records; add -TTL to keep the original TTL, -NoPtr'
                'when the PTR record must not be created, and -WhatIf to preview. Record types'
                'that New-DnsEntry does not handle (MX, SRV, TXT, NS and others) are created'
                'with the Add-DnsServerResourceRecord* cmdlets of the DnsServer module.'
                ''
                '## Restore a whole AD-integrated zone (disaster recovery)'
                ''
                ('1. Copy the backup file to `%windir%\System32\dns\` on {0} (`dnscmd /load` reads zone files only from that folder).' -f $serverKey)
                ('2. Remove the broken zone: `Remove-DnsServerZone -Name <zone> -ComputerName {0}`' -f $serverKey)
                ('3. Create the zone from the file: `dnscmd {0} /zoneadd <zone> /primary /file <backup file> /load`' -f $serverKey)
                ('4. Make it Active Directory-integrated again: `ConvertTo-DnsServerPrimaryZone -Name <zone> -ReplicationScope Domain -ComputerName {0} -Force`' -f $serverKey)
                '   Use the replication scope the zone had (Domain, Forest or Legacy; Custom also needs -DirectoryPartitionName).'
                '5. Let Active Directory replicate the zone to the other domain controllers: `repadmin /syncall /AdeP`'
                ''
                'Note: the SOA serial number and the aging timestamps are not restored exactly;'
                'it is the data of the records that is saved. Zone settings that are not part of'
                'a zone file (dynamic update, aging and scavenging, security) must be checked'
                'after the restore, for example with Get-DnsServerZone and Get-DnsServerZoneAging.'
            )
            $restorePath = Join-Path -Path $folderPath -ChildPath 'RESTORE.md'
            try {
                Set-Content -LiteralPath $restorePath -Value $restoreLines -Encoding UTF8 -ErrorAction Stop -WhatIf:$false -Confirm:$false
            }
            catch {
                Write-Warning "The zone files were saved, but RESTORE.md could not be written to '$restorePath': $($_.Exception.Message)"
            }
            Write-Verbose "Backed up $($backedUp.Count) of $($plan.Count) zone(s) from '$serverKey' to '$folderPath'."
        }
        else {
            # Nothing was saved, so there is nothing to restore; do not leave an empty folder that looks like a backup.
            if (@(Get-ChildItem -LiteralPath $folderPath -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item -LiteralPath $folderPath -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
            }
            Write-Verbose "No zone of '$serverKey' could be backed up."
        }
    }
}
