function Remove-DnsEntry {
    <#
    .SYNOPSIS
        Removes A, AAAA and CNAME entries together with their PTR records, DHCID record and CNAME aliases, after one confirmation per entry.

    .DESCRIPTION
        Remove-DnsEntry takes a host out of DNS the way an administrator would by
        hand, but checked and logged: the A and AAAA records of the name, the PTR
        records that point back at it, its DHCID record and the CNAME aliases that
        point at it. Each input item is resolved, read live from the server and
        shown in one confirmation prompt, for example

            srv01.contoso.local: remove 2 PTR, 1 A, 1 CNAME alias

        before anything is removed. Every record that is removed, skipped or
        already gone becomes one DnsTools.Result object and one line in the
        change log.

        An input item is one of:
        - An FQDN ('srv01.contoso.local'), or a bare name with -Zone ('srv01',
          '@' for the zone apex): every A, AAAA and CNAME record at that node.
        - An IPv4 or IPv6 address: every A or AAAA record that holds the address.
          They are found through the PTR records of the address and, when a
          snapshot of the server exists (any age), through the snapshot's address
          index. PTR records of the address that point at a name without such an
          A or AAAA record are orphans and are removed as well.
        - An entry from Get-DnsEntry: exactly that record, for example one of two
          A records of a node, or one CNAME record.
        - A row of a CSV file (-InputFile) with a Name column, and optionally
          Address, Target and Zone columns.

        For each item the records are handled in this order: PTR records, then
        the A/AAAA records, then the DHCID record (only when the node is left
        without any A or AAAA record), then the CNAME records (the node's own
        CNAME first, then the aliases that point at the name).

        Safety rules:
        - A name that NS, SRV or MX records point at is not removed: the whole
          item is Skipped, with one Result per record that would have been
          touched, unless -AllowReferenced is given.
        - The reference check reads a snapshot no older than -MaxSnapshotAge, or
          else asks the server live over WMI/CIM (root\MicrosoftDNS). When neither
          works, the item is Skipped; -SkipReferenceCheck removes it unchecked
          (and leaves its aliases behind, because they cannot be found either).
        - CNAME aliases are removed only when the name loses all its A, AAAA and
          CNAME records, and not with -KeepAlias. An alias that NS, SRV or MX
          records point at is Skipped on its own.
        - Records in read-only zones (secondary, stub, automatically created) are
          Skipped. A PTR record in a read-only reverse zone does not stop the
          A record from being removed.
        - When a PTR record in a writable zone cannot be removed, the A and AAAA
          records of that name are kept (Skipped), so that no orphaned PTR is
          left behind.
        - A record that is already gone counts as done (AlreadyDone); running
          the same removal twice is safe.

        What it does NOT do: it does not accept patterns ('*' or '?'; find the
        entries with Get-DnsEntry, check them and pipe them to this command), it
        does not remove other record types (MX, SRV, NS, TXT) or the records that
        point at the name, it does not follow chains of aliases (an alias of an
        alias), it does not remove the parent-zone CNAME of an RFC 2317
        delegation, it does not update the local snapshot, and it changes one
        server only (Active Directory replication carries the change to the
        other domain controllers).

    .PARAMETER Identity
        What to remove: an FQDN, a bare name (with -Zone), an IPv4 or IPv6
        address, or a DnsTools.Entry from Get-DnsEntry (also after
        Export-Clixml / Import-Clixml). Several values are processed one after
        the other. Accepts pipeline input: entries, strings (for example from
        Get-Content; blank lines are skipped) and other objects, whose Name,
        Identity, HostName, IPAddress or Address property is used (the first
        one that has a value, in that order).

    .PARAMETER InputFile
        A text file with one name or address per line ('#' comments, blank lines
        and duplicates are skipped), or a CSV file with a Name column and
        optionally Address, Target and Zone columns (comma or semicolon
        separated). With an Address the row removes only that A or AAAA record;
        with a Target only that CNAME record. Alias: FilePath.

    .PARAMETER Zone
        The zone for bare names, and a restriction for FQDNs (an FQDN must lie
        inside this zone). For an address, only the A and AAAA records in this
        zone are removed (and orphaned PTR records whose target lies in it).
        Alias: ZoneName.

    .PARAMETER KeepPtr
        Do not remove PTR records. A name is then removed even though its PTR
        records stay; no Result is written for them. Windows Server 2025 deletes
        the PTR record that points at a name together with its A or AAAA record,
        so there -KeepPtr cannot be honoured: the PTR records are read again after
        the removal, and each one that is gone gets a RemovePtr result (Success,
        with a note in Error) and the run gives one warning.

    .PARAMETER KeepAlias
        Do not remove the CNAME aliases that point at a removed name.

    .PARAMETER AllowReferenced
        Remove a name even when NS, SRV or MX records point at it (a warning is
        written). Those records are not changed and point at a missing name
        afterwards.

    .PARAMETER SkipReferenceCheck
        Do not look for NS, SRV, MX and CNAME records that point at the names.
        Referenced names are removed anyway and their aliases stay behind. Use
        it when neither a fresh snapshot nor WMI access to the server is
        available and the names are known to be unreferenced.

    .PARAMETER MaxSnapshotAge
        The oldest snapshot the reference check trusts; an older one is not used
        for it and the server is asked live instead. Default: 24 hours. Write it
        as d.hh:mm:ss ('04:00:00', '2.00:00:00') or with New-TimeSpan; a bare
        number such as 4 is read as 4 ticks, not 4 hours. Address lookups use a
        snapshot of any age (with a warning when it is older than this).

    .PARAMETER Delay
        Seconds to wait after each input item, to spread the load on the server
        and on replication. Default: 0. Not applied under -WhatIf.

    .PARAMETER Server
        The DNS server to change. Default: the logon server ($env:LOGONSERVER
        without the leading backslashes). Alias: ComputerName.

    .PARAMETER Credential
        Alternate credentials. All DnsServer calls then go through a CIM session;
        the command throws when none can be opened and never falls back to the
        logged-on user.

    .PARAMETER TimeoutSec
        Timeout in seconds for the CIM session and the WMI queries of the
        reference check. Default: 300.

    .PARAMETER LogPath
        The change-log file (JSON Lines). Default: $env:DNSTOOLS_LOGPATH, or
        %LOCALAPPDATA%\DnsTools\log\DnsTools_<yyyy-MM>.jsonl.

    .PARAMETER Force
        Remove without asking. Only the prompt is skipped; every other safety
        rule stays (references, read-only zones, orphaned PTR protection).

    .EXAMPLE
        Remove-DnsEntry srv01.contoso.local -Server dc01

        Reads srv01.contoso.local on dc01, shows what will be removed (for
        example "srv01.contoso.local: remove 1 PTR, 1 A, 1 CNAME alias") and asks
        once. Answer Y to remove, N to skip, A to remove this and every
        following entry without asking again, S to stop.

    .EXAMPLE
        Get-DnsEntry '*-old.contoso.local' -Server dc01 | Where-Object PtrStatus -ne 'NoReverseZone' | Remove-DnsEntry -Server dc01 -WhatIf

        Finds the entries in the snapshot, filters them, and shows what removing
        them would do without changing anything: one "What if" line per entry
        and one Result with Result = WhatIf per record. Each entry removes
        exactly that record. Run it again without -WhatIf to remove them.

    .EXAMPLE
        $results = @(Remove-DnsEntry -InputFile .\decommissioned.txt -Server dc01 -Force -LogPath D:\Logs\dns-changes.jsonl -Delay 2 -ErrorAction Continue)
        $results | Where-Object Result -eq 'Failed' | Export-Csv .\failed.csv -NoTypeInformation -Encoding UTF8

        For a scheduled task or another unattended script: removes every name
        and address listed in decommissioned.txt without prompting, waits two
        seconds after each entry, appends one JSON line per record to
        D:\Logs\dns-changes.jsonl and exports the failures. Without -Force an
        unattended run stops at the first entry with the error
        DnsTools.Confirm.NonInteractive and changes nothing.

    .EXAMPLE
        Remove-DnsEntry 10.0.16.88 -Server dc01 -Confirm:$false

        Removes every A record that holds 10.0.16.88, their PTR records, and PTR
        records of the address that point at names without such an A record
        (orphans). Without a snapshot of dc01, A records that have no PTR record
        cannot be found by address; a warning says so.

    .EXAMPLE
        Get-DnsEntry app01.contoso.local -Server dc01 | Where-Object Data -eq '10.0.16.21' | Remove-DnsEntry -Server dc01 -KeepAlias

        Removes only the A record 10.0.16.21 of app01 (and its PTR record) and
        keeps the other A records of the node and the aliases of the name.

    .INPUTS
        DnsTools.Entry, System.String, System.Object

        Entries from Get-DnsEntry (also deserialized), names and addresses as
        strings, and objects with a Name, Identity, HostName, IPAddress or Address
        property.

    .OUTPUTS
        DnsTools.Result

        One object per record that was removed, skipped, already gone or would
        be removed (-WhatIf), with these properties in this order:
        - Action (string): RemovePtr, RemoveA, RemoveAAAA, RemoveDhcid or RemoveCName.
        - Name (string): the owner of the record (for a PTR the reverse name, such as 20.16.0.10.in-addr.arpa); the name or address of the item when nothing was found.
        - Type (string): PTR, A, AAAA, DHCID or CNAME.
        - Data (string): the address, the target name (PTR, CNAME) or the DHCID value.
        - Result (string): Success, Failed, Skipped, WhatIf or AlreadyDone.
        - Error (string): why the record failed or was skipped; $null otherwise.
        - Zone (string): the zone that holds the record.
        - NodeName (string): the node within the zone ('@' for the apex).
        - Server (string): the DNS server that was changed.
        - Id (string): the GUID of the Result and of its change-log line.
        - BatchId (string): the GUID shared by every Result of this run.
        - Timestamp (datetime): when the Result was written.

    .NOTES
        - Dynamic records (with an aging timestamp) are removed with a warning.
          The client or the DHCP server may register them again. In an
          AD-integrated zone a removed name is kept as a tombstoned dnsNode for
          about 7 days, and that object keeps the old permissions: with secure
          dynamic updates only the previous owner can register the name again
          until the tombstone is gone. The end-of-run Verbose summary counts
          the dynamic records.
        - Reference check: a snapshot is used only when it is younger than
          -MaxSnapshotAge; records created after the snapshot are not seen. The
          live check needs WMI/CIM access to root\MicrosoftDNS on the server.
        - Address lookups without a snapshot find only the names that PTR
          records point at.
        - The batch stops with one terminating error when the server cannot be
          reached (ErrorId DnsTools.Remove-DnsEntry.ServerUnreachable, after
          the Failed Result of the record concerned) or when the session cannot
          prompt (ErrorId DnsTools.Confirm.NonInteractive; use -Force or
          -Confirm:$false in unattended runs). Other failures are
          non-terminating errors (DnsTools.Remove-DnsEntry.<Reason>) with a
          Failed Result, and the run goes on.
        - PTR records and -KeepPtr: Windows Server 2025 deletes the PTR record
          that points at a name when its A or AAAA record is removed, by any tool
          (verified on 2026-10-13); older servers keep it. Remove-DnsEntry removes
          the PTR records first anyway, so the log names each of them. With
          -KeepPtr the PTR records are read again after each removed A or AAAA
          record: one that is still there is left alone, one that the server
          deleted gets a RemovePtr result with Result Success and the Error
          "Removed by the DNS server together with the A record; -KeepPtr cannot
          be honoured on this server.", plus one warning per run. Remove-DnsEntry
          never re-creates such a PTR record.
        - Only the default zone scope is changed; a zone with more zone scopes
          gives one warning.
        - The local snapshot is not updated; run Update-DnsSnapshot afterwards
          before searching it again.
        - Change several domain controllers in one session only with care: a
          warning appears when this session already changed another server,
          because changes to the same node can be lost before replication.
        - The change log is UTF-8 (Windows PowerShell 5.1 writes a BOM when it
          creates the file, PowerShell 7 does not). -WhatIf runs are logged too.
        - PowerShell records the silenced "not found" answers of
          Get-DnsServerResourceRecord in $Error and in a caller's -ErrorVariable;
          real failures carry an ErrorId that starts with DnsTools.
        - Works in Constrained Language Mode. Needs the DnsServer module (RSAT:
          DNS Server Tools).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Identity')]
    [OutputType('DnsTools.Result')]
    param (
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'Identity')]
        [AllowNull()]
        [AllowEmptyString()]
        [object[]]$Identity,

        [Parameter(Mandatory, ParameterSetName = 'File')]
        [Alias('FilePath')]
        [ValidateNotNullOrEmpty()]
        [string]$InputFile,

        [Parameter()]
        [Alias('ZoneName')]
        [ValidateNotNullOrEmpty()]
        [string]$Zone,

        [Parameter()]
        [switch]$KeepPtr,

        [Parameter()]
        [switch]$KeepAlias,

        [Parameter()]
        [switch]$AllowReferenced,

        [Parameter()]
        [switch]$SkipReferenceCheck,

        [Parameter()]
        [timespan]$MaxSnapshotAge = (New-TimeSpan -Hours 24),

        [Parameter()]
        [ValidateRange(0, 86400)]
        [int]$Delay = 0,

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

    begin {
        $serverKey = Resolve-DnsServerName -Server $Server
        $Batch = New-DnsBatch -Server $serverKey -LogPath $LogPath -Delay $Delay -Force:$Force
        # A preview changes nothing, so it must not become the session's writer server.
        if (-not $WhatIfPreference) {
            Test-DnsWriterServer -Server $serverKey
        }

        # Throws when the server cannot be reached or the DnsServer module is
        # missing: nothing in the batch could work then.
        $zoneTable = Get-DnsZoneTable -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec
        $zoneLookup = $zoneTable.ZoneLookup
        $serverParameter = Get-DnsServerParameter -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec

        $zoneFilter = ''
        if ($Zone) {
            $zoneFilter = ConvertTo-DnsNormalizedName -Name $Zone
        }

        $actionByType = @{ A = 'RemoveA'; AAAA = 'RemoveAAAA'; CNAME = 'RemoveCName'; PTR = 'RemovePtr'; DHCID = 'RemoveDhcid' }
        $readOnlyText = "Zone '{0}' is not writable on this server ('{1}' holds it as a {2} zone). Remove the record on the server that hosts the primary zone."
        $unavailableText = "The reference check could not run (root\MicrosoftDNS on '$serverKey' is not reachable). Run Update-DnsSnapshot first, or pass -SkipReferenceCheck."
        $keepPtrText = 'Removed by the DNS server together with the A record; -KeepPtr cannot be honoured on this server.'
        $keepPtrWarned = $false
        $lookupFailedPrefix = 'DnsTools.Get-DnsLiveRecord.LookupFailed'

        # The snapshot index is loaded on the first address item only, and only
        # when a snapshot already exists: a removal must never start an export.
        $indexState = 'Unknown'
        $index = $null
        $scopeChecked = @{}
        $Batch['Counts']['DynamicRecords'] = 0
    }

    process {
        $items = $Identity
        # Progress only for -InputFile, the one case where the total is known (CONTRACTS.md 5.5).
        $progressTotal = 0
        $progressNumber = 0
        $progressShown = $false
        $progressAt = [datetime]::UtcNow.AddSeconds(-1)
        $progressActivity = "Removing the DNS entries listed in '$InputFile'"
        if ($InputFile) {
            $items = @(Read-DnsInputFile -Path $InputFile)
            $progressTotal = $items.Count
            Write-Verbose "Read $($items.Count) item(s) from '$InputFile'."
        }

        foreach ($item in @($items)) {
            if ($progressTotal -gt 1) {
                $progressNumber++
                $now = [datetime]::UtcNow
                if (($now - $progressAt).TotalMilliseconds -ge 500) {
                    Write-Progress -Id 96 -Activity $progressActivity -Status "Item $progressNumber of $progressTotal" -PercentComplete ([int](($progressNumber - 1) * 100 / $progressTotal))
                    $progressAt = $now
                    $progressShown = $true
                }
            }

            # --- What the item is. Objects other than entries, strings and CSV rows
            #     are read by property name, like ValueFromPipelineByPropertyName would:
            #     -Identity must take entries by value, so it cannot bind by name. ---
            $resolveInput = $item
            $identityText = ''
            $isEntry = $false
            $isRow = $item -is [System.Collections.IDictionary]
            if ($null -ne $item) {
                $typeNames = @($item.PSObject.TypeNames)
                $isEntry = ($typeNames -contains 'DnsTools.Entry') -or ($typeNames -contains 'Deserialized.DnsTools.Entry')
            }

            if ($null -eq $item) {
                $identityText = ''
            }
            elseif ($item -is [string]) {
                $identityText = $item.Trim()
            }
            elseif ($item -is [ipaddress]) {
                $resolveInput = $item.IPAddressToString
                $identityText = $resolveInput
            }
            elseif ($isEntry -or $isRow) {
                foreach ($propertyName in @('Name', 'Address')) {
                    $value = $null
                    if ($isRow) {
                        $value = $item[$propertyName]
                    }
                    elseif ($null -ne $item.PSObject.Properties[$propertyName]) {
                        $value = $item.PSObject.Properties[$propertyName].Value
                    }
                    if ($null -ne $value -and ([string]$value).Trim()) {
                        $identityText = ([string]$value).Trim()
                        break
                    }
                }
            }
            else {
                $resolveInput = $null
                foreach ($propertyName in @('Name', 'Identity', 'HostName', 'IPAddress', 'Address')) {
                    $property = $item.PSObject.Properties[$propertyName]
                    if ($null -eq $property -or $null -eq $property.Value) {
                        continue
                    }
                    $values = @($property.Value)
                    if ($values.Count -eq 0) {
                        continue
                    }
                    $value = $values[0]
                    if ($value -is [ipaddress]) {
                        $value = $value.IPAddressToString
                    }
                    if ($null -ne $value -and ([string]$value).Trim()) {
                        $resolveInput = ([string]$value).Trim()
                        break
                    }
                }
                if ($null -eq $resolveInput) {
                    $resolveInput = ([string]$item).Trim()
                }
                $identityText = $resolveInput
            }

            if (-not $isEntry -and -not $isRow -and -not $identityText) {
                Write-Verbose 'Skipping an empty input item.'
                continue
            }
            $itemLabel = $identityText
            if (-not $itemLabel) {
                $itemLabel = '(empty)'
            }

            # One pass: 'break' ends the item early and still reaches the -Delay below.
            do {
                # --- 1. Resolve the item to a name, an address or one CNAME record ---
                $target = $null
                try {
                    $target = Resolve-DnsChangeTarget -InputObject $resolveInput -ZoneTable $zoneTable -Zone $Zone
                }
                catch {
                    $resolveError = $_
                    $errorId = [string]$resolveError.FullyQualifiedErrorId
                    $reasonPrefix = 'DnsTools.Resolve-DnsChangeTarget.'
                    $reason = 'InvalidInput'
                    if ($errorId.StartsWith($reasonPrefix)) {
                        $reason = $errorId.Split(',')[0].Substring($reasonPrefix.Length)
                    }

                    $failedType = $null
                    $failedData = $identityText
                    if ($isEntry) {
                        foreach ($propertyName in @('Type', 'Data')) {
                            $property = $item.PSObject.Properties[$propertyName]
                            if ($null -ne $property -and $null -ne $property.Value -and $propertyName -eq 'Type') {
                                $failedType = ([string]$property.Value).ToUpperInvariant()
                            }
                            elseif ($null -ne $property -and $null -ne $property.Value) {
                                $failedData = [string]$property.Value
                            }
                        }
                    }
                    $failedAction = 'RemoveA'
                    if ($failedType -and $actionByType.ContainsKey($failedType)) {
                        $failedAction = $actionByType[$failedType]
                    }

                    Write-DnsResult -Batch $Batch -Action $failedAction -Name $itemLabel -Type $failedType -Data $failedData -Zone $null -NodeName $null -Result 'Failed' -ErrorMessage $resolveError.Exception.Message
                    Write-Error -Message $resolveError.Exception.Message -Category $resolveError.CategoryInfo.Category -ErrorId "DnsTools.Remove-DnsEntry.$reason" -TargetObject $item
                    break
                }

                $kind = $target['Kind']
                $itemName = $target['Fqdn']
                if ($kind -eq 'Address') {
                    $itemName = $target['Address']
                }

                if ($target['Server'] -and $target['Server'].Trim() -ne $serverKey) {
                    Write-Warning ("The entry '{0}' was read from '{1}', but this command changes '{2}'. It is read again and removed on '{2}'." -f $itemName, $target['Server'], $serverKey)
                }

                # Stub and forwarder zones only point elsewhere; their records are not here.
                if ($kind -ne 'Address') {
                    $targetZoneType = [string]$zoneLookup[$target['Zone']].ZoneType
                    if ($targetZoneType -eq 'Stub' -or $targetZoneType -eq 'Forwarder') {
                        $skipAction = 'RemoveA'
                        if ($target['Type'] -and $actionByType.ContainsKey($target['Type'])) {
                            $skipAction = $actionByType[$target['Type']]
                        }
                        $skipData = $target['Data']
                        if (-not $skipData) {
                            $skipData = $itemName
                        }
                        $skipText = "Zone '{0}' is a {1} zone on '{2}'; its records are not hosted there. Remove the record on the server that hosts the zone." -f $target['Zone'], $targetZoneType, $serverKey
                        Write-DnsResult -Batch $Batch -Action $skipAction -Name $itemName -Type $target['Type'] -Data $skipData -Zone $target['Zone'] -NodeName $target['NodeName'] -Result 'Skipped' -ErrorMessage $skipText
                        break
                    }
                }

                # --- Snapshot for address items: used when it exists, never created ---
                if ($kind -eq 'Address' -and $indexState -eq 'Unknown') {
                    $snapshotExists = $script:SnapshotIndexCache.ContainsKey($serverKey)
                    if (-not $snapshotExists) {
                        $serverFolder = Get-DnsSnapshotRoot -Server $serverKey
                        if (Test-Path -LiteralPath (Join-Path -Path $serverFolder -ChildPath 'meta.json') -PathType Leaf) {
                            $meta = Get-DnsSnapshotMeta -Server $serverKey
                            if ($null -ne $meta) {
                                foreach ($metaZoneName in @($meta['Zones'].Keys)) {
                                    $zoneFile = Join-Path -Path $serverFolder -ChildPath ([string]$meta['Zones'][$metaZoneName]['File'])
                                    if (Test-Path -LiteralPath $zoneFile -PathType Leaf) {
                                        $snapshotExists = $true
                                        break
                                    }
                                }
                            }
                        }
                    }

                    if ($snapshotExists) {
                        $index = Get-DnsSnapshotIndex -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec -MaxSnapshotAge $MaxSnapshotAge
                        $indexState = 'Loaded'
                    }
                    else {
                        $indexState = 'None'
                        Write-Warning "A records without a PTR cannot be found by address without a snapshot. No snapshot of '$serverKey' exists, so only the names that PTR records point at are removed; run Update-DnsSnapshot -Server $serverKey first to find the others too."
                    }
                }

                # --- 2. Read live. Two rounds: an address item needs the PTR records of
                #     the address first (their targets are the candidate names), a name
                #     item needs its node first (its addresses lead to the PTR records). ---
                $lookupFailure = $null
                $isUnreachable = $false
                $ptrsByAddress = @{}
                $pendingAddresses = @()
                $pendingOwners = @()
                if ($kind -eq 'Address') {
                    $pendingAddresses = @($target['Address'])
                }
                else {
                    $pendingOwners = @(@{ Fqdn = $target['Fqdn']; Zone = $target['Zone']; NodeName = $target['NodeName']; Type = $target['Type']; Data = $target['Data'] })
                }

                $groups = @(
                    for ($round = 1; $round -le 2; $round++) {
                        # PTR records at the address's node in every covering reverse zone:
                        # classless zones (RFC 2317) and shadowed shorter zones included.
                        foreach ($ptrAddress in $pendingAddresses) {
                            if ($ptrsByAddress.ContainsKey($ptrAddress)) {
                                continue
                            }
                            $reverse = ConvertTo-DnsReverseName -Address $ptrAddress
                            $ptrsByAddress[$ptrAddress] = @(
                                foreach ($reverseZone in @(Find-DnsZoneForName -Name $reverse['ReverseName'] -ZoneTable $zoneTable -Reverse)) {
                                    $reverseZoneInfo = $zoneLookup[$reverseZone]
                                    if ($null -eq $reverseZoneInfo -or [string]$reverseZoneInfo.ZoneType -eq 'Stub' -or [string]$reverseZoneInfo.ZoneType -eq 'Forwarder') {
                                        continue
                                    }
                                    $reverseNode = Get-DnsReverseNodeName -ReverseName $reverse['ReverseName'] -ZoneName $reverseZone -ClasslessHostLabel:($reverseZoneInfo.IsClassless -eq $true)
                                    if ($null -eq $reverseNode) {
                                        continue
                                    }

                                    # The helper's own error is kept for the item's Result; 2>$null
                                    # keeps it from being reported twice.
                                    $readErrors = $null
                                    $ptrRecords = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $reverseZone -NodeName $reverseNode -RRType 'PTR' -ErrorVariable readErrors 2>$null)
                                    foreach ($readError in @($readErrors)) {
                                        if ($null -ne $readError -and $null -ne $readError.PSObject.Properties['FullyQualifiedErrorId'] -and ([string]$readError.FullyQualifiedErrorId).StartsWith($lookupFailedPrefix)) {
                                            if ($null -eq $lookupFailure) {
                                                $lookupFailure = $readError
                                            }
                                            if (Test-DnsConnectionError -ErrorRecord $readError) {
                                                $isUnreachable = $true
                                            }
                                        }
                                    }
                                    foreach ($ptrRecord in $ptrRecords) {
                                        if ($null -ne $ptrRecord -and $ptrRecord['Data']) {
                                            $ptrRecord
                                        }
                                    }
                                }
                            )
                        }
                        $pendingAddresses = @()

                        # Address item: candidate names from the PTR targets and the snapshot.
                        if ($kind -eq 'Address' -and $round -eq 1) {
                            $address = $target['Address']
                            $addressType = 'A'
                            if ($address.IndexOf(':') -ge 0) {
                                $addressType = 'AAAA'
                            }

                            $candidateSeen = @{}
                            $candidateNames = @(
                                foreach ($ptrRecord in @($ptrsByAddress[$address])) {
                                    if ($null -ne $ptrRecord -and -not $candidateSeen.ContainsKey($ptrRecord['Data'])) {
                                        $candidateSeen[$ptrRecord['Data']] = $true
                                        $ptrRecord['Data']
                                    }
                                }
                                if ($null -ne $index) {
                                    foreach ($addressOwner in @($index['Addr'][$address])) {
                                        if ($addressOwner -and -not $candidateSeen.ContainsKey($addressOwner)) {
                                            $candidateSeen[$addressOwner] = $true
                                            $addressOwner
                                        }
                                    }
                                }
                            )

                            $pendingOwners = @(
                                foreach ($candidate in $candidateNames) {
                                    # The snapshot knows the exact zone(s); otherwise the longest
                                    # hosted forward zone of the name is the one.
                                    $candidateZones = @{}
                                    if ($null -ne $index) {
                                        foreach ($nameEntry in @($index['Name'][$candidate])) {
                                            if ($null -eq $nameEntry) {
                                                continue
                                            }
                                            # TYPE DATA TTL AGE ZONE (CONTRACTS.md section 9.3)
                                            $field = ([string]$nameEntry).Split([char]9)
                                            if ($field.Count -ge 5 -and $field[0] -eq $addressType -and $field[1] -eq $address) {
                                                $candidateZones[$field[4]] = $true
                                            }
                                        }
                                    }
                                    if ($candidateZones.Count -eq 0) {
                                        foreach ($forwardZone in @(Find-DnsZoneForName -Name $candidate -ZoneTable $zoneTable)) {
                                            $forwardZoneInfo = $zoneLookup[$forwardZone]
                                            if (-not $forwardZoneInfo.IsReverse -and [string]$forwardZoneInfo.ZoneType -ne 'Stub' -and [string]$forwardZoneInfo.ZoneType -ne 'Forwarder') {
                                                $candidateZones[$forwardZone] = $true
                                                break
                                            }
                                        }
                                    }

                                    foreach ($candidateZone in @($candidateZones.Keys | Sort-Object)) {
                                        if ($null -eq $zoneLookup[$candidateZone]) {
                                            continue
                                        }
                                        $candidateNode = '@'
                                        if ($candidate -ne $candidateZone) {
                                            $candidateNode = $candidate.Substring(0, $candidate.Length - $candidateZone.Length - 1)
                                        }
                                        @{ Fqdn = $candidate; Zone = $candidateZone; NodeName = $candidateNode; Type = $addressType; Data = $address }
                                    }
                                }
                            )
                        }

                        # Node records of every owner: what to remove, and whether the
                        # name loses everything (then its DHCID record and aliases go too).
                        $roundGroups = @(
                            foreach ($owner in $pendingOwners) {
                                $readErrors = $null
                                $nodeRecords = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $owner['Zone'] -NodeName $owner['NodeName'] -RRType 'A', 'AAAA', 'CNAME', 'DHCID' -ErrorVariable readErrors 2>$null)
                                foreach ($readError in @($readErrors)) {
                                    if ($null -ne $readError -and $null -ne $readError.PSObject.Properties['FullyQualifiedErrorId'] -and ([string]$readError.FullyQualifiedErrorId).StartsWith($lookupFailedPrefix)) {
                                        if ($null -eq $lookupFailure) {
                                            $lookupFailure = $readError
                                        }
                                        if (Test-DnsConnectionError -ErrorRecord $readError) {
                                            $isUnreachable = $true
                                        }
                                    }
                                }

                                $addressRecords = @(foreach ($nodeRecord in $nodeRecords) { if ($null -ne $nodeRecord -and ($nodeRecord['Type'] -eq 'A' -or $nodeRecord['Type'] -eq 'AAAA') -and $nodeRecord['Data']) { $nodeRecord } })
                                $cnameRecords = @(foreach ($nodeRecord in $nodeRecords) { if ($null -ne $nodeRecord -and $nodeRecord['Type'] -eq 'CNAME' -and $nodeRecord['Data']) { $nodeRecord } })
                                $dhcidRecords = @(foreach ($nodeRecord in $nodeRecords) { if ($null -ne $nodeRecord -and $nodeRecord['Type'] -eq 'DHCID' -and $nodeRecord['Data']) { $nodeRecord } })

                                # An entry, a CSV row with Address or Target, or an address
                                # names one record; a plain name means the whole node.
                                $wantedType = $owner['Type']
                                $wantedData = $owner['Data']
                                $selectedAddresses = @(foreach ($addressRecord in $addressRecords) { if (-not $wantedType -or ($addressRecord['Type'] -eq $wantedType -and $addressRecord['Data'] -eq $wantedData)) { $addressRecord } })
                                $selectedCnames = @(foreach ($cnameRecord in $cnameRecords) { if (-not $wantedType -or ($cnameRecord['Type'] -eq $wantedType -and $cnameRecord['Data'] -eq $wantedData)) { $cnameRecord } })
                                if ($selectedAddresses.Count -eq 0 -and $selectedCnames.Count -eq 0) {
                                    continue
                                }

                                $clearsAddresses = $selectedAddresses.Count -gt 0 -and $selectedAddresses.Count -eq $addressRecords.Count
                                $dhcids = @()
                                if ($clearsAddresses) {
                                    $dhcids = $dhcidRecords
                                }
                                @{
                                    Key         = $owner['Zone'] + '|' + $owner['NodeName']
                                    Fqdn        = $owner['Fqdn']
                                    Zone        = $owner['Zone']
                                    NodeName    = $owner['NodeName']
                                    ZoneInfo    = $zoneLookup[$owner['Zone']]
                                    Addresses   = $selectedAddresses
                                    Cnames      = $selectedCnames
                                    Dhcids      = $dhcids
                                    # A CNAME entry is only that record (CONTRACTS.md 13.4 step 1).
                                    RemovesName = ($kind -ne 'Cname' -and $selectedAddresses.Count -eq $addressRecords.Count -and $selectedCnames.Count -eq $cnameRecords.Count)
                                    Ptrs        = @()
                                }
                            }
                        )
                        $pendingOwners = @()
                        $roundGroups
                        $pendingAddresses = @(foreach ($roundGroup in $roundGroups) { foreach ($addressRecord in $roundGroup['Addresses']) { $addressRecord['Data'] } })
                    }
                )

                # With -Zone an address item removes only the A/AAAA records in that
                # zone; the owners elsewhere still decide which PTR records are orphans.
                $ownerNames = @{}
                foreach ($group in $groups) {
                    $ownerNames[$group['Fqdn']] = $true
                }
                if ($kind -eq 'Address' -and $zoneFilter) {
                    $groups = @(foreach ($group in $groups) { if ($group['Zone'] -eq $zoneFilter) { $group } })
                }

                # PTR records of an address that point at no name holding the address.
                $orphanPtrs = @()
                if ($kind -eq 'Address') {
                    $orphanPtrs = @(
                        foreach ($ptrRecord in @($ptrsByAddress[$target['Address']])) {
                            if ($null -eq $ptrRecord -or $ownerNames.ContainsKey($ptrRecord['Data'])) {
                                continue
                            }
                            if ($zoneFilter -and $ptrRecord['Data'] -ne $zoneFilter -and -not $ptrRecord['Data'].EndsWith('.' + $zoneFilter)) {
                                continue
                            }
                            $ptrRecord
                        }
                    )
                }

                # --- 3. PTR records that point at the names (only those) ---
                if ($KeepPtr) {
                    Write-Verbose "PTR records for '$itemName' are kept (-KeepPtr)."
                }
                else {
                    $ptrSeen = @{}
                    foreach ($group in $groups) {
                        $group['Ptrs'] = @(
                            foreach ($addressRecord in $group['Addresses']) {
                                foreach ($ptrRecord in @($ptrsByAddress[$addressRecord['Data']])) {
                                    if ($null -eq $ptrRecord -or $ptrRecord['Data'] -ne $group['Fqdn']) {
                                        continue
                                    }
                                    $ptrKey = $ptrRecord['Zone'] + '|' + $ptrRecord['NodeName'] + '|' + $ptrRecord['Data']
                                    if ($ptrSeen.ContainsKey($ptrKey)) {
                                        continue
                                    }
                                    $ptrSeen[$ptrKey] = $true
                                    $ptrRecord
                                }
                            }
                        )
                    }
                }

                # --- 4. References: NS, SRV and MX block; CNAME owners are the aliases ---
                $itemSkip = $null
                $aliasPlans = @()
                if ($null -eq $lookupFailure) {
                    $groupReferences = @{}
                    foreach ($group in $groups) {
                        if ($group['ZoneInfo'].IsReadOnly) {
                            continue
                        }
                        $groupReferences[$group['Key']] = Get-DnsReference -Name $group['Fqdn'] -ZoneTable $zoneTable -Batch $Batch -Credential $Credential -TimeoutSec $TimeoutSec -MaxSnapshotAge $MaxSnapshotAge -SkipReferenceCheck:$SkipReferenceCheck
                    }

                    $aliasSeen = @{}
                    $aliasPlans = @(
                        foreach ($group in $groups) {
                            $references = $groupReferences[$group['Key']]
                            if ($null -eq $references -or -not $group['RemovesName']) {
                                continue
                            }
                            if ($KeepAlias) {
                                if (@($references['Cname']).Count -gt 0) {
                                    Write-Verbose ("The aliases of '{0}' are kept (-KeepAlias): {1}." -f $group['Fqdn'], (@($references['Cname']) -join ', '))
                                }
                                continue
                            }

                            foreach ($aliasName in @($references['Cname'])) {
                                if (-not $aliasName -or $aliasName -eq $group['Fqdn'] -or $aliasSeen.ContainsKey($aliasName)) {
                                    continue
                                }
                                $aliasSeen[$aliasName] = $true

                                $aliasZone = $null
                                foreach ($candidateZone in @(Find-DnsZoneForName -Name $aliasName -ZoneTable $zoneTable)) {
                                    $candidateZoneInfo = $zoneLookup[$candidateZone]
                                    if (-not $candidateZoneInfo.IsReverse -and [string]$candidateZoneInfo.ZoneType -ne 'Stub' -and [string]$candidateZoneInfo.ZoneType -ne 'Forwarder') {
                                        $aliasZone = $candidateZone
                                        break
                                    }
                                }
                                if (-not $aliasZone) {
                                    Write-Verbose "The alias '$aliasName' of '$($group['Fqdn'])' is not in a zone hosted on '$serverKey'; it is left alone."
                                    continue
                                }
                                $aliasNode = '@'
                                if ($aliasName -ne $aliasZone) {
                                    $aliasNode = $aliasName.Substring(0, $aliasName.Length - $aliasZone.Length - 1)
                                }

                                $readErrors = $null
                                $aliasRecords = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $aliasZone -NodeName $aliasNode -RRType 'CNAME' -ErrorVariable readErrors 2>$null)
                                foreach ($readError in @($readErrors)) {
                                    if ($null -ne $readError -and $null -ne $readError.PSObject.Properties['FullyQualifiedErrorId'] -and ([string]$readError.FullyQualifiedErrorId).StartsWith($lookupFailedPrefix)) {
                                        if ($null -eq $lookupFailure) {
                                            $lookupFailure = $readError
                                        }
                                        if (Test-DnsConnectionError -ErrorRecord $readError) {
                                            $isUnreachable = $true
                                        }
                                    }
                                }

                                $aliasFound = $false
                                foreach ($aliasRecord in $aliasRecords) {
                                    if ($null -eq $aliasRecord -or $aliasRecord['Data'] -ne $group['Fqdn']) {
                                        continue
                                    }
                                    $aliasFound = $true
                                    @{ Group = $group; Record = $aliasRecord; ZoneInfo = $zoneLookup[$aliasZone]; References = $null; Message = $null }
                                }
                                if (-not $aliasFound) {
                                    # A snapshot can be older than the alias's last change.
                                    Write-Verbose "'$aliasName' no longer points at '$($group['Fqdn'])'; it is left alone."
                                }
                            }
                        }
                    )

                    # Each alias gets its own check: an alias that NS, SRV or MX records
                    # point at must stay even when its target goes.
                    foreach ($aliasPlan in $aliasPlans) {
                        if (-not $aliasPlan['ZoneInfo'].IsReadOnly) {
                            $aliasPlan['References'] = Get-DnsReference -Name $aliasPlan['Record']['Owner'] -ZoneTable $zoneTable -Batch $Batch -Credential $Credential -TimeoutSec $TimeoutSec -MaxSnapshotAge $MaxSnapshotAge -SkipReferenceCheck:$SkipReferenceCheck
                        }
                    }

                    # One subject for the item (all its names together) and one per alias;
                    # every subject gets the same message format (CONTRACTS.md 13.4 step 2).
                    $itemSubject = @{ Name = $itemName; Unavailable = $false; Srv = @(); Ns = @(); Mx = @(); Message = $null }
                    foreach ($listName in @('Srv', 'Ns', 'Mx')) {
                        $ownerSeen = @{}
                        $itemSubject[$listName] = @(
                            foreach ($group in $groups) {
                                $references = $groupReferences[$group['Key']]
                                if ($null -eq $references) {
                                    continue
                                }
                                if ($references['Source'] -eq 'Unavailable') {
                                    $itemSubject['Unavailable'] = $true
                                }
                                foreach ($ownerName in @($references[$listName])) {
                                    if ($ownerName -and -not $ownerSeen.ContainsKey($ownerName)) {
                                        $ownerSeen[$ownerName] = $true
                                        $ownerName
                                    }
                                }
                            }
                        )
                    }
                    $subjects = @(
                        $itemSubject
                        foreach ($aliasPlan in $aliasPlans) {
                            $references = $aliasPlan['References']
                            if ($null -eq $references) {
                                continue
                            }
                            @{ Name = $aliasPlan['Record']['Owner']; Unavailable = ($references['Source'] -eq 'Unavailable'); Srv = @($references['Srv']); Ns = @($references['Ns']); Mx = @($references['Mx']); Message = $null; Plan = $aliasPlan }
                        }
                    )

                    foreach ($subject in $subjects) {
                        if ($subject['Unavailable']) {
                            $subject['Message'] = $unavailableText
                            continue
                        }
                        $srvOwners = @($subject['Srv'])
                        $nsOwners = @($subject['Ns'])
                        $mxOwners = @($subject['Mx'])
                        $countParts = @(
                            if ($srvOwners.Count -gt 0) { '{0} SRV' -f $srvOwners.Count }
                            if ($nsOwners.Count -gt 0) { '{0} NS' -f $nsOwners.Count }
                            if ($mxOwners.Count -gt 0) { '{0} MX' -f $mxOwners.Count }
                        )
                        if ($countParts.Count -eq 0) {
                            continue
                        }

                        $countText = $countParts[0]
                        if ($countParts.Count -eq 2) {
                            $countText = '{0} and {1}' -f $countParts[0], $countParts[1]
                        }
                        elseif ($countParts.Count -eq 3) {
                            $countText = '{0}, {1} and {2}' -f $countParts[0], $countParts[1], $countParts[2]
                        }
                        $referenceOwners = @($srvOwners) + @($nsOwners) + @($mxOwners)
                        $noun = 'records'
                        if ($referenceOwners.Count -eq 1) {
                            $noun = 'record'
                        }
                        $ownerText = (@($referenceOwners | Select-Object -First 3)) -join ', '
                        if ($referenceOwners.Count -gt 3) {
                            $ownerText = '{0}, ...' -f $ownerText
                        }
                        $referenceText = 'Referenced by {0} {1} ({2}).' -f $countText, $noun, $ownerText

                        if ($AllowReferenced) {
                            Write-Warning ("'{0}': {1} It is removed anyway (-AllowReferenced); those records will point at a missing name." -f $subject['Name'], $referenceText)
                        }
                        else {
                            $subject['Message'] = $referenceText + ' Add -AllowReferenced to remove it anyway.'
                        }
                    }

                    $itemSkip = $itemSubject['Message']
                    foreach ($subject in $subjects) {
                        if ($subject.ContainsKey('Plan')) {
                            $subject['Plan']['Message'] = $subject['Message']
                        }
                    }
                }

                # --- A lookup that failed means the item cannot be judged: never guess ---
                if ($null -ne $lookupFailure) {
                    $failAction = 'RemoveA'
                    if ($target['Type'] -and $actionByType.ContainsKey($target['Type'])) {
                        $failAction = $actionByType[$target['Type']]
                    }
                    $failData = $target['Data']
                    if (-not $failData) {
                        $failData = $itemName
                    }
                    $failText = "'{0}' was not changed because a lookup failed: {1}" -f $itemName, $lookupFailure.Exception.Message
                    Write-DnsResult -Batch $Batch -Action $failAction -Name $itemName -Type $target['Type'] -Data $failData -Zone $target['Zone'] -NodeName $target['NodeName'] -Result 'Failed' -ErrorMessage $failText
                    if ($isUnreachable) {
                        Write-Error -Message ("The DNS server '{0}' cannot be reached: {1} The run was stopped; the remaining input was not processed. Check the server and run the command again." -f $serverKey, $lookupFailure.Exception.Message) -Category ConnectionError -ErrorId 'DnsTools.Remove-DnsEntry.ServerUnreachable' -TargetObject $serverKey -ErrorAction Stop
                    }
                    Write-Error -Message $failText -Category $lookupFailure.CategoryInfo.Category -ErrorId 'DnsTools.Remove-DnsEntry.LookupFailed' -TargetObject $item
                    break
                }

                # --- 5. The sub-operations, in the order of CONTRACTS.md 13.4 step 4 ---
                $ops = @(
                    foreach ($group in $groups) {
                        foreach ($ptrRecord in $group['Ptrs']) {
                            @{ Phase = 'Ptr'; Group = $group['Key']; GroupZoneInfo = $group['ZoneInfo']; Record = $ptrRecord; ZoneInfo = $zoneLookup[$ptrRecord['Zone']]; PreError = $null }
                        }
                    }
                    if (-not $KeepPtr) {
                        foreach ($ptrRecord in $orphanPtrs) {
                            @{ Phase = 'Ptr'; Group = $null; GroupZoneInfo = $null; Record = $ptrRecord; ZoneInfo = $zoneLookup[$ptrRecord['Zone']]; PreError = $null }
                        }
                    }
                    foreach ($group in $groups) {
                        foreach ($addressRecord in $group['Addresses']) {
                            @{ Phase = 'Address'; Group = $group['Key']; GroupZoneInfo = $group['ZoneInfo']; Record = $addressRecord; ZoneInfo = $group['ZoneInfo']; PreError = $null }
                        }
                    }
                    foreach ($group in $groups) {
                        foreach ($dhcidRecord in $group['Dhcids']) {
                            @{ Phase = 'Dhcid'; Group = $group['Key']; GroupZoneInfo = $group['ZoneInfo']; Record = $dhcidRecord; ZoneInfo = $group['ZoneInfo']; PreError = $null }
                        }
                    }
                    foreach ($group in $groups) {
                        foreach ($cnameRecord in $group['Cnames']) {
                            @{ Phase = 'Cname'; Group = $group['Key']; GroupZoneInfo = $group['ZoneInfo']; Record = $cnameRecord; ZoneInfo = $group['ZoneInfo']; PreError = $null }
                        }
                    }
                    foreach ($aliasPlan in $aliasPlans) {
                        @{ Phase = 'Alias'; Group = $aliasPlan['Group']['Key']; GroupZoneInfo = $aliasPlan['Group']['ZoneInfo']; Record = $aliasPlan['Record']; ZoneInfo = $aliasPlan['ZoneInfo']; PreError = $aliasPlan['Message'] }
                    }
                )

                if ($ops.Count -eq 0) {
                    if ($groups.Count -gt 0 -or $orphanPtrs.Count -gt 0) {
                        Write-Verbose "Nothing to remove for '$itemName': its PTR records are kept (-KeepPtr)."
                    }
                    else {
                        $doneType = $target['Type']
                        $doneData = $target['Data']
                        if ($kind -eq 'Address') {
                            $doneType = 'A'
                            if ($target['Address'].IndexOf(':') -ge 0) {
                                $doneType = 'AAAA'
                            }
                            $doneData = $target['Address']
                        }
                        elseif (-not $doneData) {
                            $doneData = $target['Fqdn']
                        }
                        $doneAction = 'RemoveA'
                        if ($doneType -and $actionByType.ContainsKey($doneType)) {
                            $doneAction = $actionByType[$doneType]
                        }
                        Write-Verbose "Nothing to remove for '$itemName' on '$serverKey'; it is already gone."
                        Write-DnsResult -Batch $Batch -Action $doneAction -Name $itemName -Type $doneType -Data $doneData -Zone $target['Zone'] -NodeName $target['NodeName'] -Result 'AlreadyDone'
                    }
                    break
                }

                # Reasons that are known before the prompt: read-only zones first, then
                # a referenced item, then a referenced alias.
                foreach ($op in $ops) {
                    $reason = $null
                    if ($null -ne $op['GroupZoneInfo'] -and $op['GroupZoneInfo'].IsReadOnly) {
                        $readOnlyInfo = $op['GroupZoneInfo']
                    }
                    elseif ($op['ZoneInfo'].IsReadOnly) {
                        $readOnlyInfo = $op['ZoneInfo']
                    }
                    else {
                        $readOnlyInfo = $null
                    }

                    if ($null -ne $readOnlyInfo) {
                        $holding = [string]$readOnlyInfo.ZoneType
                        if ($readOnlyInfo.IsAutoCreated) {
                            $holding = 'automatically created'
                        }
                        $reason = $readOnlyText -f $readOnlyInfo.ZoneName, $serverKey, $holding
                    }
                    elseif ($itemSkip) {
                        $reason = $itemSkip
                    }
                    elseif ($op['PreError']) {
                        $reason = $op['PreError']
                    }
                    $op['PreError'] = $reason
                }

                # Zone scopes: this command changes the default scope only (one warning per zone).
                foreach ($op in $ops) {
                    $scopeZone = $op['Record']['Zone']
                    if ($op['PreError'] -or $scopeChecked.ContainsKey($scopeZone)) {
                        continue
                    }
                    $scopeChecked[$scopeZone] = $true
                    $scopeErrors = $null
                    $scopes = @()
                    try {
                        $scopes = @(Get-DnsServerZoneScope @serverParameter -ZoneName $scopeZone -ErrorAction SilentlyContinue -ErrorVariable scopeErrors)
                    }
                    catch {
                        Write-Verbose "The zone scopes of '$scopeZone' could not be read: $($_.Exception.Message)"
                    }
                    foreach ($scopeError in @($scopeErrors)) {
                        if ($null -ne $scopeError) {
                            Write-Verbose "The zone scopes of '$scopeZone' could not be read: $scopeError"
                        }
                    }
                    $extraScopes = @(
                        foreach ($scope in $scopes) {
                            if ($null -eq $scope -or $null -eq $scope.PSObject.Properties['ZoneScope']) {
                                continue
                            }
                            $scopeName = [string]$scope.PSObject.Properties['ZoneScope'].Value
                            if ($scopeName -and $scopeName -ne $scopeZone) {
                                $scopeName
                            }
                        }
                    )
                    if ($extraScopes.Count -gt 0) {
                        Write-Warning ("Zone '{0}' on '{1}' has zone scopes besides the default ({2}). Remove-DnsEntry changes the default scope only; records in the other scopes stay." -f $scopeZone, $serverKey, ($extraScopes -join ', '))
                    }
                }

                # --- 6. One gate per item ---
                $pendingCounts = @{}
                foreach ($op in $ops) {
                    if ($op['PreError']) {
                        continue
                    }
                    $label = $op['Record']['Type']
                    if ($op['Phase'] -eq 'Alias') {
                        $label = 'CNAME alias'
                    }
                    $pendingCounts[$label] = 1 + [int]$pendingCounts[$label]
                }

                $decision = 'Approved'
                if ($pendingCounts.Count -gt 0) {
                    $countParts = @(
                        foreach ($label in @('PTR', 'A', 'AAAA', 'DHCID', 'CNAME', 'CNAME alias')) {
                            $count = [int]$pendingCounts[$label]
                            if ($count -eq 0) {
                                continue
                            }
                            if ($label -eq 'CNAME alias' -and $count -gt 1) {
                                '{0} CNAME aliases' -f $count
                            }
                            else {
                                '{0} {1}' -f $count, $label
                            }
                        }
                    )
                    $gateTarget = '{0}: remove {1}' -f $itemName, ($countParts -join ', ')

                    # 2>$null: a non-interactive session becomes the one terminating error
                    # below instead of a second, non-terminating copy (CONTRACTS.md 5.8).
                    $confirmErrors = $null
                    $isApproved = Confirm-DnsAction -Target $gateTarget -Action 'Remove DNS records' -Impact 'High' -State $Batch['Confirm'] -Force:$Batch['Force'] -ErrorVariable confirmErrors 2>$null
                    if (-not $isApproved) {
                        foreach ($confirmError in @($confirmErrors)) {
                            # -ErrorVariable also collects the caught exception of the failed
                            # Read-Host, which is not an ErrorRecord.
                            if ($null -ne $confirmError -and $null -ne $confirmError.PSObject.Properties['FullyQualifiedErrorId'] -and ([string]$confirmError.FullyQualifiedErrorId).StartsWith('DnsTools.Confirm.NonInteractive')) {
                                Write-Error -Message $confirmError.Exception.Message -Category InvalidOperation -ErrorId 'DnsTools.Confirm.NonInteractive' -TargetObject $gateTarget -ErrorAction Stop
                            }
                        }
                        $decision = 'Declined'
                        if ($WhatIfPreference) {
                            $decision = 'WhatIf'
                        }
                    }
                }

                # --- 7. Execute, one Result per sub-operation ---
                $keepPtrChecked = @{}
                $groupState = @{}
                foreach ($group in $groups) {
                    $groupState[$group['Key']] = @{ Fqdn = $group['Fqdn']; PtrFailed = $false; AddressKept = $false; NameKept = $false }
                }

                foreach ($op in $ops) {
                    $record = $op['Record']
                    $phase = $op['Phase']
                    $state = $null
                    if ($op['Group']) {
                        $state = $groupState[$op['Group']]
                    }
                    $resultValue = $null
                    $errorText = $null
                    $before = $null
                    $failure = $null

                    if ($op['PreError']) {
                        $resultValue = 'Skipped'
                        $errorText = $op['PreError']
                    }
                    elseif ($decision -eq 'WhatIf') {
                        $resultValue = 'WhatIf'
                    }
                    elseif ($decision -eq 'Declined') {
                        $resultValue = 'Skipped'
                        $errorText = 'Declined at the confirmation prompt.'
                    }
                    elseif ($phase -eq 'Address' -and $null -ne $state -and $state['PtrFailed']) {
                        $resultValue = 'Skipped'
                        $errorText = "Kept to avoid an orphaned PTR: a PTR record that points at '$($state['Fqdn'])' could not be removed."
                    }
                    elseif ($phase -eq 'Dhcid' -and $null -ne $state -and $state['AddressKept']) {
                        $resultValue = 'Skipped'
                        $errorText = "Kept because '$($state['Fqdn'])' still has an A or AAAA record."
                    }
                    elseif ($phase -eq 'Alias' -and $null -ne $state -and $state['NameKept']) {
                        $resultValue = 'Skipped'
                        $errorText = "Kept because '$($state['Fqdn'])' was not removed."
                    }
                    else {
                        $outcome = Remove-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $record['Zone'] -NodeName $record['NodeName'] -RRType $record['Type'] -Data $record['Data']
                        if ($outcome['Removed']) {
                            $resultValue = 'Success'
                            $before = $record
                        }
                        elseif ($outcome['AlreadyGone']) {
                            $resultValue = 'AlreadyDone'
                        }
                        elseif ([string]$outcome['ErrorId'] -like '*9712*') {
                            # WIN32 9712: the zone became read-only (secondary) since the zone table was read.
                            $resultValue = 'Skipped'
                            $errorText = $readOnlyText -f $record['Zone'], $serverKey, 'read-only'
                        }
                        else {
                            $resultValue = 'Failed'
                            $errorText = $outcome['Error']
                            $failure = $outcome
                        }
                    }

                    if ($null -ne $record['Timestamp'] -and ($resultValue -eq 'Success' -or $resultValue -eq 'WhatIf')) {
                        $Batch['Counts']['DynamicRecords'] = 1 + [int]$Batch['Counts']['DynamicRecords']
                        Write-Warning ("'{0}' ({1} {2}) is a dynamic record. The client or the DHCP server may register it again; see the notes in Get-Help Remove-DnsEntry -Full." -f $record['Owner'], $record['Type'], $record['Data'])
                    }

                    # What the later sub-operations of the same name depend on.
                    if ($null -ne $state -and $resultValue -ne 'Success' -and $resultValue -ne 'AlreadyDone' -and $resultValue -ne 'WhatIf') {
                        if ($phase -eq 'Ptr' -and $resultValue -eq 'Failed') {
                            $state['PtrFailed'] = $true
                        }
                        elseif ($phase -eq 'Address') {
                            $state['AddressKept'] = $true
                            $state['NameKept'] = $true
                        }
                        elseif ($phase -eq 'Cname') {
                            $state['NameKept'] = $true
                        }
                    }

                    Write-DnsResult -Batch $Batch -Action $actionByType[$record['Type']] -Name $record['Owner'] -Type $record['Type'] -Data $record['Data'] -Zone $record['Zone'] -NodeName $record['NodeName'] -Result $resultValue -ErrorMessage $errorText -Before $before

                    # -KeepPtr: Windows Server 2025 deletes the PTR that points at the
                    # name together with the A/AAAA record, older servers keep it. Read
                    # the PTR records found before the removal again and report the ones
                    # that are gone (CONTRACTS.md 13.4); never assume either way.
                    if ($KeepPtr -and $phase -eq 'Address' -and $resultValue -eq 'Success') {
                        foreach ($ptrRecord in @($ptrsByAddress[$record['Data']])) {
                            if ($null -eq $ptrRecord -or $ptrRecord['Data'] -ne $record['Owner']) {
                                continue
                            }
                            $ptrKey = $ptrRecord['Zone'] + '|' + $ptrRecord['NodeName'] + '|' + $ptrRecord['Data']
                            if ($keepPtrChecked.ContainsKey($ptrKey)) {
                                continue
                            }
                            $keepPtrChecked[$ptrKey] = $true

                            $readErrors = $null
                            $ptrsNow = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $ptrRecord['Zone'] -NodeName $ptrRecord['NodeName'] -RRType 'PTR' -ErrorVariable readErrors 2>$null)
                            $readFailed = $false
                            foreach ($readError in @($readErrors)) {
                                if ($null -ne $readError -and $null -ne $readError.PSObject.Properties['FullyQualifiedErrorId'] -and ([string]$readError.FullyQualifiedErrorId).StartsWith($lookupFailedPrefix)) {
                                    $readFailed = $true
                                }
                            }
                            if ($readFailed) {
                                Write-Verbose "The PTR record $($ptrRecord['Owner']) could not be read again after the removal of '$($record['Owner'])' ($($record['Data']))."
                                continue
                            }
                            $isStillThere = $false
                            foreach ($ptrNow in $ptrsNow) {
                                if ($null -ne $ptrNow -and $ptrNow['Data'] -eq $ptrRecord['Data']) {
                                    $isStillThere = $true
                                }
                            }
                            if ($isStillThere) {
                                Write-Verbose "The PTR record $($ptrRecord['Owner']) -> $($ptrRecord['Data']) is kept (-KeepPtr)."
                                continue
                            }

                            Write-DnsResult -Batch $Batch -Action 'RemovePtr' -Name $ptrRecord['Owner'] -Type 'PTR' -Data $ptrRecord['Data'] -Zone $ptrRecord['Zone'] -NodeName $ptrRecord['NodeName'] -Result 'Success' -ErrorMessage $keepPtrText -Before $ptrRecord
                            if (-not $keepPtrWarned) {
                                $keepPtrWarned = $true
                                Write-Warning $keepPtrText
                            }
                        }
                    }

                    if ($null -ne $failure) {
                        if ($failure['Unreachable']) {
                            Write-Error -Message ("The DNS server '{0}' cannot be reached: {1} The run was stopped; the remaining input was not processed. Check the server and run the command again." -f $serverKey, $failure['Error']) -Category ConnectionError -ErrorId 'DnsTools.Remove-DnsEntry.ServerUnreachable' -TargetObject $serverKey -ErrorAction Stop
                        }
                        $failureCategory = 'WriteError'
                        if ([string]$failure['ErrorId'] -like 'WIN32 5,*') {
                            $failureCategory = 'PermissionDenied'
                        }
                        Write-Error -Message $errorText -Category $failureCategory -ErrorId 'DnsTools.Remove-DnsEntry.RemoveFailed' -TargetObject $record['Owner']
                    }
                }
            } while ($false)

            if ($Delay -gt 0 -and -not $WhatIfPreference) {
                Write-Verbose "Waiting $Delay second(s) before the next item (-Delay)."
                Start-Sleep -Seconds $Delay
            }
        }

        if ($progressShown) {
            Write-Progress -Id 96 -Activity $progressActivity -Completed
        }
    }

    end {
        $summaryParts = @(
            foreach ($resultName in @('Success', 'AlreadyDone', 'WhatIf', 'Skipped', 'Failed')) {
                $count = [int]$Batch['Counts'][$resultName]
                if ($count -gt 0) {
                    '{0} {1}' -f $count, $resultName
                }
            }
        )
        if ($summaryParts.Count -eq 0) {
            $summaryParts = @('no records')
        }
        Write-Verbose ("Remove-DnsEntry on '{0}' (batch {1}): {2}; {3} dynamic record(s)." -f $serverKey, $Batch['BatchId'], ($summaryParts -join ', '), [int]$Batch['Counts']['DynamicRecords'])

        # The snapshot index is not patched after writes (CONTRACTS.md 13.9).
        if ([int]$Batch['Counts']['Success'] -gt 0) {
            Write-Verbose "The local snapshot of '$serverKey' does not include these changes; run Update-DnsSnapshot -Server $serverKey before searching it again."
        }
    }
}
