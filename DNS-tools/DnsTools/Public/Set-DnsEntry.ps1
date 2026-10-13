function Set-DnsEntry {
    <#
    .SYNOPSIS
        Changes the TTL, the address, the PTR target or the alias target of existing DNS records in place.

    .DESCRIPTION
        Set-DnsEntry changes existing A, AAAA, CNAME and PTR records on one
        Microsoft DNS server without deleting and re-creating them. Every change of
        a value goes through Set-DnsServerResourceRecord with the record as it is
        and as it should be, so the record keeps its node, its AD object and its
        permissions. Only the PTR records that follow an address change are
        removed and added.

        What to change (at least one; -Address, -PtrTarget and -Target exclude each
        other, -TTL can be combined with any of them):

        - -TTL: the TTL of every A, AAAA and CNAME record at the node (only the
          exact record when an entry from Get-DnsEntry is piped in) and of every PTR
          record that points at the name, in every hosted reverse zone that covers
          the address. For an IP address: the TTL of the PTR record(s) of that
          address in its reverse zone. Together with -PtrTarget: the TTL of that
          PTR record only.
        - -Address: moves one A or AAAA record to a new address of the same
          family. Exactly one record must be named: an entry piped from
          Get-DnsEntry, or a name that has a single A/AAAA record (a name with
          several gives the error Ambiguous). The PTR records follow: the PTR of
          the old address that points at the name is removed, and a PTR for the
          new address is added in its reverse zone. When no reverse zone covers the
          new address the PTR step is skipped with a warning; when the new address
          already has a PTR that points at another name it is skipped too, unless
          -ReplacePtr is given.
        - -PtrTarget: the target of the PTR record of an IP address (or of the
          address of a piped A/AAAA entry), in the reverse zone that is expected to
          hold it (the longest hosted one). When the address has no PTR record
          there, one is added.
        - -Target: the target of an alias (CNAME).

        Each change is one sub-operation with its own Result object: SetTtl,
        SetAddress, SetPtrTarget, SetTarget, RemovePtr or AddPtr. A value that is
        already as requested gives AlreadyDone and is not written, so the command
        can be run again safely.

        Safety rules: every input item is confirmed once (impact High with
        -Address, Medium otherwise; [A] Yes to all applies to the rest of the run
        at that impact). -WhatIf prints the change per item and returns WhatIf
        results without changing anything. -Force never prompts. Dynamic records
        (A, AAAA or PTR with an aging timestamp) are skipped unless
        -IncludeDynamic is given. Records in zones that are not writable on the
        server (secondary, stub or server-created zones) are skipped. Every
        sub-operation, including WhatIf and Skipped ones, is written to the change
        log.

        What it does NOT do: it does not create or remove host records (use
        New-DnsEntry and Remove-DnsEntry), it does not change the type of a
        record (A to AAAA or a host into an alias), it changes no other record
        types, it accepts no wildcard patterns, and it does not update the local
        snapshot (run Update-DnsSnapshot afterwards before you search it again).

    .PARAMETER Identity
        What to change: an FQDN ('srv01.contoso.local'), a bare name together with
        -Zone, an IPv4 or IPv6 address (for -PtrTarget and -TTL on the PTR
        record), or an entry from Get-DnsEntry, which names one exact record.
        Accepts pipeline input: strings (for example from Get-Content), entries
        from Get-DnsEntry (also after Export-Clixml and Import-Clixml), and
        objects with an Identity, Name, HostName, IPAddress or Address property
        (the first one that has a value is used, so Import-Csv rows work).
        Wildcards are rejected per item; find the records with Get-DnsEntry first.

    .PARAMETER Zone
        The zone of bare names ('srv01' with -Zone contoso.local is
        srv01.contoso.local; '@' is the zone apex). An FQDN must lie inside this
        zone. Ignored for entries from Get-DnsEntry, which carry their zone.

    .PARAMETER TTL
        The new time to live in seconds (0 to 2147483647). Alias: TimeToLive.

    .PARAMETER Address
        The new IPv4 or IPv6 address of one A or AAAA record. IPv4 must be a
        dotted quad. The family must match the record (an A record stays IPv4).

    .PARAMETER PtrTarget
        The new target of the PTR record of the address given as -Identity, as a
        fully qualified name ('srv01.contoso.local').

    .PARAMETER Target
        The new target of the alias (CNAME) given as -Identity, as a fully
        qualified name ('web02.contoso.local').

    .PARAMETER ReplacePtr
        With -Address: when the new address already has a PTR record that points
        at another name, remove that PTR and add the one for this name. Without
        it that PTR is left alone and the PTR step is Skipped.

    .PARAMETER IncludeDynamic
        Change dynamic records too (A, AAAA or PTR with an aging timestamp, as
        registered by clients or the DHCP server). Each one gives a warning,
        because the client or the DHCP server may register the old value again.
        Without it such records are Skipped.

    .PARAMETER Delay
        Seconds to wait after each input item (after all of its changes), to
        spread the load on the server and on AD replication. Default: 0.

    .PARAMETER Server
        The DNS server to change. Default: the logon server ($env:LOGONSERVER
        without the leading backslashes). Alias: ComputerName.

    .PARAMETER Credential
        Alternate credentials. All DnsServer calls then go through a CIM session;
        the command throws when none can be opened and never falls back to the
        logged-on user.

    .PARAMETER TimeoutSec
        Timeout in seconds for the CIM session and remote operations. Default: 300.

    .PARAMETER LogPath
        The change log file (one JSON line per sub-operation). Default: the
        DNSTOOLS_LOGPATH environment variable, else
        %LOCALAPPDATA%\DnsTools\log\DnsTools_<yyyy-MM>.jsonl.

    .PARAMETER Force
        Never prompt: every change is confirmed. It overrides nothing else;
        dynamic records still need -IncludeDynamic and foreign PTR records still
        need -ReplacePtr.

    .EXAMPLE
        Set-DnsEntry srv01.contoso.local -TTL 300 -Server dc01

        Lowers the TTL of every A, AAAA and CNAME record of srv01.contoso.local and
        of the PTR records that point at it to five minutes, for example before
        the server moves. Records that already have a TTL of 300 are reported as
        AlreadyDone.

    .EXAMPLE
        Get-DnsEntry srv01.contoso.local -Server dc01 | Where-Object Data -eq '10.0.16.20' | Set-DnsEntry -Address 10.0.16.25 -Server dc01

        Moves the A record 10.0.16.20 of srv01 to 10.0.16.25, even when srv01 has
        other A records: the piped entry names exactly one record. The PTR record
        20.16.0.10.in-addr.arpa that points at srv01 is removed and
        25.16.0.10.in-addr.arpa -> srv01.contoso.local is added. The command asks
        once before it changes anything (impact High).

    .EXAMPLE
        $results = @(Get-Content .\hosts.txt | Set-DnsEntry -TTL 600 -Server dc01 -Force -LogPath 'D:\Logs\dns-changes.jsonl' -Delay 2)
        if (@($results | Where-Object Result -eq 'Failed').Count -gt 0) { exit 1 }

        For a scheduled task or another unattended script: sets the TTL of every
        name in hosts.txt without prompting, waits two seconds after each name,
        writes every sub-operation to D:\Logs\dns-changes.jsonl and ends with exit
        code 1 when any change failed. Per-item failures are non-terminating
        errors as well; add -ErrorAction Stop to end at the first one. An
        unreachable server ends the run with one terminating error.

    .EXAMPLE
        Set-DnsEntry 10.0.16.25 -PtrTarget srv01.contoso.local -Server dc01 -WhatIf

        Shows what would happen to the PTR record of 10.0.16.25: its target would
        be changed in place, or a PTR record would be added when there is none.
        Nothing is changed; the WhatIf results are still written to the log.

    .EXAMPLE
        Set-DnsEntry www.contoso.local -Target web02.contoso.local -Server dc01 -Confirm:$false

        Points the alias www at web02.contoso.local without prompting. A target that
        would make the alias point at itself is refused by the server (Failed).

    .INPUTS
        System.String

        Names and addresses can be piped to Set-DnsEntry, one per line.

        DnsTools.Entry

        Entries from Get-DnsEntry, also as Deserialized.DnsTools.Entry after
        Export-Clixml and Import-Clixml. Each names one exact record.

        System.Management.Automation.PSObject

        Any object with an Identity, Name, HostName, IPAddress or Address property,
        for example an Import-Csv row.

    .OUTPUTS
        DnsTools.Result

        One object per sub-operation, emitted as soon as it is done, with these
        properties in this order:
        - Action (string): SetTtl, SetAddress, SetPtrTarget, SetTarget, RemovePtr or AddPtr.
        - Name (string): the owner FQDN of the record ('srv01.contoso.local', or '20.16.0.10.in-addr.arpa' for a PTR record); the input as given when it could not be resolved.
        - Type (string): A, AAAA, CNAME or PTR.
        - Data (string): the address or target the sub-operation is about: the new value for SetAddress, SetPtrTarget and SetTarget, the record's data for SetTtl, the PTR target for RemovePtr and AddPtr.
        - Result (string): Success, Failed, Skipped, WhatIf or AlreadyDone.
        - Error (string): why the sub-operation failed or was skipped; $null otherwise.
        - Zone (string): the zone that holds the record.
        - NodeName (string): the node within the zone ('@' for the apex).
        - Server (string): the DNS server, lower case.
        - Id (string): a GUID that identifies the matching change-log line.
        - BatchId (string): a GUID shared by every result and log line of one call.
        - Timestamp (datetime): when the sub-operation was finished.

    .NOTES
        - Changes are made in place with Set-DnsServerResourceRecord (the record is
          read twice, the second copy is changed). Records are never deleted and
          re-created for a value change; only PTR records are removed and added
          when an address moves.
        - Aging timestamps: after every change the record is read again, and the
          change log holds its timestamp before and after the change
          (Before.Timestamp, After.Timestamp), so the log shows what the server
          did to it. Verified in the live test: [LIVE TEST RESULT PENDING - the
          lead fills in whether Set-DnsServerResourceRecord keeps, clears or
          renews the timestamp of a dynamic record.]
        - Dynamic records belong to the client or the DHCP server, which may
          register the old value again. They are skipped unless -IncludeDynamic
          is given.
        - Batch stop: an unreachable server, a session that cannot prompt (use
          -Force or -WhatIf in unattended scripts) and the answer [S] Stop end the
          whole run with one terminating error. Everything else fails per item:
          a non-terminating error plus a Result with Result = Failed.
        - The local snapshot is not updated; Get-DnsEntry searches show the old
          values until Update-DnsSnapshot runs again.
        - AD replication: other domain controllers see a change only after
          replication. Changing the same names on two servers in one session gives
          a warning, because one change may overwrite the other.
        - The change log is UTF-8 JSON, one line per sub-operation; Windows
          PowerShell 5.1 writes a BOM when it creates the file, PowerShell 7 does
          not. Read it with Get-Content -Encoding UTF8 | ConvertFrom-Json.
        - Works in Constrained Language Mode. Needs the DnsServer module (RSAT:
          DNS Server Tools).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('DnsTools.Result')]
    param (
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyString()]
        [object[]]$Identity,

        [Parameter()]
        [Alias('ZoneName')]
        [ValidateNotNullOrEmpty()]
        [string]$Zone,

        [Parameter()]
        [Alias('TimeToLive')]
        [ValidateRange(0, 2147483647)]
        [int]$TTL,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Address,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$PtrTarget,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Target,

        [Parameter()]
        [switch]$ReplacePtr,

        [Parameter()]
        [switch]$IncludeDynamic,

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
        # --- The requested change, checked before any server round-trip (CONTRACTS.md 5.1, 13.6) ---
        $hasTtl = $PSBoundParameters.Keys -contains 'TTL'
        $hasAddress = $PSBoundParameters.Keys -contains 'Address'
        $hasPtrTarget = $PSBoundParameters.Keys -contains 'PtrTarget'
        $hasTarget = $PSBoundParameters.Keys -contains 'Target'

        if (-not ($hasTtl -or $hasAddress -or $hasPtrTarget -or $hasTarget)) {
            Write-Error -Message 'Nothing to change. Specify at least one of -TTL, -Address, -PtrTarget or -Target.' -Category InvalidArgument -ErrorId 'DnsTools.Set-DnsEntry.NoChangeRequested' -ErrorAction Stop
        }

        $valueChangeCount = 0
        foreach ($isGiven in @($hasAddress, $hasPtrTarget, $hasTarget)) {
            if ($isGiven) {
                $valueChangeCount++
            }
        }
        if ($valueChangeCount -gt 1) {
            Write-Error -Message '-Address, -PtrTarget and -Target change different records. Give only one of them per call; -TTL can be combined with any of them.' -Category InvalidArgument -ErrorId 'DnsTools.Set-DnsEntry.ConflictingChanges' -ErrorAction Stop
        }

        $newAddress = $null
        if ($hasAddress) {
            $newAddress = ConvertTo-DnsNormalizedAddress -Address $Address
            if ($null -eq $newAddress) {
                Write-Error -Message "-Address '$Address' is not an IPv4 or IPv6 address. Write IPv4 as a dotted quad, for example 10.0.16.25." -Category InvalidArgument -ErrorId 'DnsTools.Set-DnsEntry.InvalidAddress' -ErrorAction Stop
            }
        }

        # A PTR or CNAME target without a dot would be stored as a single-label
        # name ('srv01.'), which no client resolves; wildcards are never targets.
        $newTargetName = $null
        foreach ($nameParameter in @('PtrTarget', 'Target')) {
            if ($PSBoundParameters.Keys -notcontains $nameParameter) {
                continue
            }
            $rawName = $PtrTarget
            if ($nameParameter -eq 'Target') {
                $rawName = $Target
            }
            $newTargetName = ConvertTo-DnsNormalizedName -Name $rawName
            if ($newTargetName.IndexOf('.') -lt 0 -or $newTargetName.IndexOf('*') -ge 0 -or $newTargetName.IndexOf('?') -ge 0) {
                Write-Error -Message "-$nameParameter '$rawName' is not a fully qualified name. Give the full name, for example srv01.contoso.local." -Category InvalidArgument -ErrorId 'DnsTools.Set-DnsEntry.InvalidName' -ErrorAction Stop
            }
        }

        # The action a per-item failure is reported under when no record was reached.
        $primaryAction = 'SetTtl'
        $requestedValue = $null
        if ($hasAddress) {
            $primaryAction = 'SetAddress'
            $requestedValue = $newAddress
        }
        elseif ($hasPtrTarget) {
            $primaryAction = 'SetPtrTarget'
            $requestedValue = $newTargetName
        }
        elseif ($hasTarget) {
            $primaryAction = 'SetTarget'
            $requestedValue = $newTargetName
        }

        $impact = 'Medium'
        if ($hasAddress) {
            $impact = 'High'
        }

        $dynamicText = 'Dynamic record, owned by the client or the DHCP server; re-register it instead, or pass -IncludeDynamic.'
        $identityProperties = @('Identity', 'Name', 'HostName', 'IPAddress', 'Address')

        # --- Server context ---
        $serverKey = Resolve-DnsServerName -Server $Server
        $batch = New-DnsBatch -Server $serverKey -LogPath $LogPath -Delay $Delay -Force:$Force
        # A preview changes nothing, so it must not become the session's writer server.
        if (-not $WhatIfPreference) {
            Test-DnsWriterServer -Server $serverKey
        }
        $zoneTable = Get-DnsZoneTable -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec
        $zoneLookup = $zoneTable.ZoneLookup
        $serverParameter = Get-DnsServerParameter -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec

        $itemCount = 0
        $sleepPending = $false
    }

    process {
        foreach ($item in @($Identity)) {
            # -Delay sleeps once per item after its sub-operations. The sleep for
            # the previous item happens here and the one for the last item in
            # end {}, so that every early 'continue' below still gets its sleep.
            if ($sleepPending) {
                Start-Sleep -Seconds $Delay
            }
            # Never under -WhatIf: a preview of 600 lines must not take 20 minutes.
            $sleepPending = $Delay -gt 0 -and -not $WhatIfPreference
            $itemCount++

            # --- What the item names: an entry, a string, or an object with an identity property ---
            $identityValue = $item
            if ($item -is [ipaddress]) {
                $identityValue = $item.IPAddressToString
            }
            elseif ($null -ne $item -and $item -isnot [string] -and $item -isnot [System.Collections.IDictionary]) {
                $typeNames = @($item.PSObject.TypeNames)
                if ($typeNames -notcontains 'DnsTools.Entry' -and $typeNames -notcontains 'Deserialized.DnsTools.Entry') {
                    $identityValue = [string]$item
                    foreach ($propertyName in $identityProperties) {
                        $property = $item.PSObject.Properties[$propertyName]
                        if ($null -ne $property -and $null -ne $property.Value -and ([string]$property.Value).Trim()) {
                            $identityValue = [string]$property.Value
                            break
                        }
                    }
                }
            }

            # The name in messages and in a Failed result when the item cannot be resolved.
            $displayName = ([string]$identityValue).Trim()
            if ($null -ne $identityValue -and $identityValue -isnot [string]) {
                foreach ($propertyName in @('Name', 'Address')) {
                    $value = $null
                    if ($identityValue -is [System.Collections.IDictionary]) {
                        $value = $identityValue[$propertyName]
                    }
                    elseif ($null -ne $identityValue.PSObject.Properties[$propertyName]) {
                        $value = $identityValue.PSObject.Properties[$propertyName].Value
                    }
                    if ($null -ne $value -and ([string]$value).Trim()) {
                        $displayName = ([string]$value).Trim()
                        break
                    }
                }
            }
            if (-not $displayName) {
                $displayName = '(empty)'
            }

            # One per-item failure ends the planning: @{ Reason; Message; Category;
            # Report (write the error here); Unreachable (end the batch) }.
            $itemError = $null
            $resolved = @{}
            try {
                $resolved = Resolve-DnsChangeTarget -InputObject $identityValue -ZoneTable $zoneTable -Zone $Zone
            }
            catch {
                $reason = (([string]$_.FullyQualifiedErrorId).Split(',')[0]).Split('.')[-1]
                $itemError = @{ Reason = $reason; Message = $_.Exception.Message; Category = [string]$_.CategoryInfo.Category; Report = $true; Unreachable = $false }
            }

            $isAddressKind = $resolved['Kind'] -eq 'Address'
            $isExactRecord = $null -ne $resolved['Type'] -and $null -ne $resolved['Data']
            $isHostRecord = $isExactRecord -and ($resolved['Type'] -eq 'A' -or $resolved['Type'] -eq 'AAAA')
            $isCnameRecord = $isExactRecord -and $resolved['Type'] -eq 'CNAME'

            if ($null -eq $itemError) {
                if ($resolved['Fqdn']) {
                    $displayName = $resolved['Fqdn']
                }
                elseif ($resolved['Address']) {
                    $displayName = $resolved['Address']
                }
                if ($resolved['Server'] -and $resolved['Server'].Trim().ToLowerInvariant() -ne $serverKey) {
                    Write-Warning "The entry '$displayName' was read from '$($resolved['Server'])' but is changed on '$serverKey'."
                }
            }

            # --- Does the identity fit the change? Decided before any read ---
            $subjectAddress = $null
            if ($null -eq $itemError) {
                if ($hasPtrTarget) {
                    if ($isAddressKind) {
                        $subjectAddress = $resolved['Address']
                    }
                    elseif ($isHostRecord) {
                        $subjectAddress = $resolved['Data']
                    }
                    else {
                        $itemError = @{ Reason = 'NotAnAddress'; Message = "-PtrTarget changes the PTR record of an address, but '$displayName' is a name. Give the IP address, or pipe the A/AAAA entry from Get-DnsEntry."; Category = 'InvalidArgument'; Report = $true; Unreachable = $false }
                    }
                }
                elseif ($hasTarget) {
                    if ($isAddressKind -or $isHostRecord) {
                        $itemError = @{ Reason = 'NotACname'; Message = "-Target changes the target of an alias (CNAME), but '$displayName' is an address or an A/AAAA record. Give the alias name, or pipe the CNAME entry from Get-DnsEntry."; Category = 'InvalidArgument'; Report = $true; Unreachable = $false }
                    }
                }
                elseif ($hasAddress) {
                    if ($isAddressKind) {
                        $itemError = @{ Reason = 'NotAHost'; Message = "-Address changes the address of an A or AAAA record, but '$displayName' is an address. Give the host name, or pipe the entry from Get-DnsEntry '$displayName'."; Category = 'InvalidArgument'; Report = $true; Unreachable = $false }
                    }
                    elseif ($isCnameRecord) {
                        $itemError = @{ Reason = 'NotAHost'; Message = "-Address changes the address of an A or AAAA record, but '$displayName' is an alias (CNAME). Change an alias with -Target."; Category = 'InvalidArgument'; Report = $true; Unreachable = $false }
                    }
                }
                elseif ($isAddressKind) {
                    # -TTL alone on an address: the address names its PTR record(s).
                    $subjectAddress = $resolved['Address']
                }
            }

            # --- Live read of the forward record(s) the change is about ---
            $lookupFailure = $null
            $forwardRecords = @()
            if ($null -eq $itemError -and -not $isAddressKind -and -not $hasPtrTarget) {
                $forwardTypes = @('A', 'AAAA', 'CNAME')
                if ($isExactRecord) {
                    $forwardTypes = @($resolved['Type'])
                }
                $lookupErrors = $null
                $forwardRecords = @(
                    foreach ($record in @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $resolved['Zone'] -NodeName $resolved['NodeName'] -RRType $forwardTypes -ErrorVariable lookupErrors)) {
                        if ($null -eq $record) {
                            continue
                        }
                        # An entry names one record; the node may hold others.
                        if ($isExactRecord -and $record['Data'] -ne $resolved['Data']) {
                            continue
                        }
                        $record
                    }
                )
                # Only the helper's own error counts: the silenced "not found" answers
                # of the cmdlet show up in -ErrorVariable as well (CONTRACTS.md 5.2b).
                foreach ($lookupError in @($lookupErrors)) {
                    if ($null -ne $lookupError -and $null -ne $lookupError.PSObject.Properties['FullyQualifiedErrorId'] -and [string]$lookupError.FullyQualifiedErrorId -like 'DnsTools.Get-DnsLiveRecord.LookupFailed*') {
                        $lookupFailure = $lookupError
                        break
                    }
                }
            }

            $hostRecord = $null
            $cnameRecord = $null
            if ($null -eq $itemError -and $null -eq $lookupFailure -and -not $isAddressKind -and -not $hasPtrTarget) {
                $hostRecords = @(
                    foreach ($record in $forwardRecords) {
                        if ($record['Type'] -eq 'A' -or $record['Type'] -eq 'AAAA') {
                            $record
                        }
                    }
                )
                $cnameRecords = @(
                    foreach ($record in $forwardRecords) {
                        if ($record['Type'] -eq 'CNAME') {
                            $record
                        }
                    }
                )

                if ($forwardRecords.Count -eq 0) {
                    $notFoundText = "'$displayName' has no A, AAAA or CNAME record on '$serverKey'."
                    if ($isExactRecord) {
                        $notFoundText = "The $($resolved['Type']) record '$displayName' -> '$($resolved['Data'])' does not exist on '$serverKey' (any more). Read it again with Get-DnsEntry."
                    }
                    $itemError = @{ Reason = 'NotFound'; Message = $notFoundText; Category = 'ObjectNotFound'; Report = $true; Unreachable = $false }
                }
                elseif ($hasAddress) {
                    if ($hostRecords.Count -eq 0) {
                        $itemError = @{ Reason = 'NotAHost'; Message = "-Address changes the address of an A or AAAA record, but '$displayName' is an alias (CNAME). Change an alias with -Target."; Category = 'InvalidArgument'; Report = $true; Unreachable = $false }
                    }
                    elseif ($hostRecords.Count -gt 1) {
                        $addressList = @(foreach ($record in $hostRecords) { $record['Data'] }) -join ', '
                        $itemError = @{ Reason = 'Ambiguous'; Message = "'$displayName' has $($hostRecords.Count) A/AAAA records ($addressList); -Address changes exactly one. Pipe the entry to change from Get-DnsEntry, for example: Get-DnsEntry '$displayName' -Server $serverKey | Where-Object Data -eq '$($hostRecords[0]['Data'])' | Set-DnsEntry -Address $newAddress -Server $serverKey"; Category = 'InvalidArgument'; Report = $true; Unreachable = $false }
                    }
                    else {
                        $hostRecord = $hostRecords[0]
                        if (($newAddress.IndexOf(':') -ge 0) -ne ($hostRecord['Type'] -eq 'AAAA')) {
                            $itemError = @{ Reason = 'AddressFamilyMismatch'; Message = "'$newAddress' does not fit the $($hostRecord['Type']) record '$displayName' ($($hostRecord['Data'])); a record keeps its type. Remove it with Remove-DnsEntry and create the new one with New-DnsEntry."; Category = 'InvalidArgument'; Report = $true; Unreachable = $false }
                        }
                    }
                }
                elseif ($hasTarget) {
                    if ($cnameRecords.Count -eq 0) {
                        $itemError = @{ Reason = 'NotACname'; Message = "-Target changes the target of an alias (CNAME), but '$displayName' has A/AAAA records and no CNAME."; Category = 'InvalidArgument'; Report = $true; Unreachable = $false }
                    }
                    else {
                        $cnameRecord = $cnameRecords[0]
                    }
                }
            }

            # --- Which addresses need their PTR records read, and how far ---
            # AllZones: every covering reverse zone (PTRs that point at the name may
            # sit in a shadowed zone too); otherwise the expected zone only. Cname:
            # read a CNAME at the expected node when it has no PTR (RFC 2317).
            $ptrRequests = @{}
            if ($null -eq $itemError -and $null -eq $lookupFailure) {
                if ($null -ne $subjectAddress) {
                    $ptrRequests[$subjectAddress] = @{ AllZones = $false; Cname = $hasPtrTarget }
                }
                elseif ($hasAddress) {
                    $ptrRequests[$newAddress] = @{ AllZones = $false; Cname = $true }
                    if ($hostRecord['Data'] -ne $newAddress) {
                        $ptrRequests[$hostRecord['Data']] = @{ AllZones = $true; Cname = $false }
                    }
                }
                elseif ($hasTtl -and -not $hasTarget) {
                    foreach ($record in $forwardRecords) {
                        if ($record['Type'] -eq 'A' -or $record['Type'] -eq 'AAAA') {
                            $ptrRequests[$record['Data']] = @{ AllZones = $true; Cname = $false }
                        }
                    }
                }
            }

            # --- Live read of those PTR nodes; the expected zone comes first ---
            $ptrNodes = @{}
            foreach ($ptrAddress in @($ptrRequests.Keys)) {
                $request = $ptrRequests[$ptrAddress]
                $reverseName = (ConvertTo-DnsReverseName -Address $ptrAddress)['ReverseName']
                $isFirstZone = $true
                $ptrNodes[$ptrAddress] = @(
                    foreach ($reverseZone in @(Find-DnsZoneForName -Name $reverseName -ZoneTable $zoneTable -Reverse)) {
                        $reverseZoneInfo = $zoneLookup[$reverseZone]
                        # Stub and forwarder zones hold no records on this server.
                        if ($null -eq $reverseZoneInfo -or [string]$reverseZoneInfo.ZoneType -eq 'Stub' -or [string]$reverseZoneInfo.ZoneType -eq 'Forwarder') {
                            continue
                        }
                        $isExpected = $isFirstZone
                        $isFirstZone = $false
                        if (-not $isExpected -and -not $request['AllZones']) {
                            break
                        }
                        $reverseNode = Get-DnsReverseNodeName -ReverseName $reverseName -ZoneName $reverseZone -ClasslessHostLabel:($reverseZoneInfo.IsClassless -eq $true)
                        if ($null -eq $reverseNode) {
                            continue
                        }

                        $lookupErrors = $null
                        $ptrRecords = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $reverseZone -NodeName $reverseNode -RRType 'PTR' -ErrorVariable lookupErrors)
                        $cnameTarget = $null
                        if ($isExpected -and $request['Cname'] -and $ptrRecords.Count -eq 0) {
                            $cnameErrors = $null
                            foreach ($record in @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $reverseZone -NodeName $reverseNode -RRType 'CNAME' -ErrorVariable cnameErrors)) {
                                $cnameTarget = $record['Data']
                            }
                            $lookupErrors = @($lookupErrors) + @($cnameErrors)
                        }
                        foreach ($lookupError in @($lookupErrors)) {
                            if ($null -ne $lookupError -and $null -ne $lookupError.PSObject.Properties['FullyQualifiedErrorId'] -and [string]$lookupError.FullyQualifiedErrorId -like 'DnsTools.Get-DnsLiveRecord.LookupFailed*') {
                                $lookupFailure = $lookupError
                                break
                            }
                        }

                        $nodeOwner = $reverseZone
                        if ($reverseNode -ne '@') {
                            $nodeOwner = $reverseNode + '.' + $reverseZone
                        }
                        @{ Zone = $reverseZone; NodeName = $reverseNode; Owner = $nodeOwner; IsExpected = $isExpected; Ptrs = $ptrRecords; CnameTarget = $cnameTarget }
                    }
                )
            }

            if ($null -eq $itemError -and $null -ne $lookupFailure) {
                $itemError = @{ Reason = 'LookupFailed'; Message = "Could not read the records of '$displayName' on '$serverKey': $($lookupFailure.Exception.Message)"; Category = 'ReadError'; Report = $false; Unreachable = (Test-DnsConnectionError -ErrorRecord $lookupFailure) }
            }

            # --- Plan: value changes first, then the TTL changes ---
            # Every sub-operation is a hashtable: Action, Name, Type, Data, Zone,
            # NodeName, Before (record), Write (Set/Add/Remove), RRType, Current
            # (data that finds the record), NewTtl, NewData, AddTtl, Needs (earlier
            # sub-operations that must succeed first), Summary (for the prompt), and
            # Result/Error when the outcome is known without writing.
            $valueOperations = @()
            $ttlSubjects = @()

            if ($null -eq $itemError -and $hasAddress) {
                $oldAddress = $hostRecord['Data']
                $ownerName = $hostRecord['Owner']
                $addressOperation = @{
                    Action = 'SetAddress'; Name = $ownerName; Type = $hostRecord['Type']; Data = $newAddress; Zone = $hostRecord['Zone']; NodeName = $hostRecord['NodeName']
                    Before = $hostRecord; Write = 'Set'; RRType = $hostRecord['Type']; Current = $oldAddress; NewData = $newAddress; Needs = @()
                    Summary = "change $($hostRecord['Type']) $ownerName from $oldAddress to $newAddress"
                }
                if ($oldAddress -eq $newAddress) {
                    $addressOperation['Result'] = 'AlreadyDone'
                }

                # PTR records to remove: the old address's PTRs that point at the
                # name, then (with -ReplacePtr) the new address's PTRs to other names.
                $removals = @()
                if ($oldAddress -ne $newAddress) {
                    $removals = @(
                        foreach ($node in @($ptrNodes[$oldAddress])) {
                            foreach ($ptrRecord in @($node['Ptrs'])) {
                                if ($ptrRecord['Data'] -eq $ownerName) {
                                    @{ Node = $node; Record = $ptrRecord }
                                }
                            }
                        }
                    )
                }

                $expectedNode = $null
                foreach ($node in @($ptrNodes[$newAddress])) {
                    if ($node['IsExpected']) {
                        $expectedNode = $node
                        break
                    }
                }

                $newReverseName = (ConvertTo-DnsReverseName -Address $newAddress)['ReverseName']
                $addPtrOperation = @{
                    Action = 'AddPtr'; Name = $newReverseName; Type = 'PTR'; Data = $ownerName; Zone = $null; NodeName = $null
                    Before = $null; Write = 'Add'; RRType = 'PTR'; Current = $ownerName; Needs = @($addressOperation)
                    Summary = "add PTR $newReverseName -> $ownerName"
                }
                if ($hasTtl) {
                    $addPtrOperation['AddTtl'] = $TTL
                }

                if ($null -eq $expectedNode) {
                    $addPtrOperation['Result'] = 'Skipped'
                    $addPtrOperation['Error'] = "No reverse zone for $newAddress is hosted on '$serverKey', so no PTR record was added. Create the zone with New-DnsReverseZone and run Set-DnsEntry again."
                    Write-Warning $addPtrOperation['Error']
                }
                else {
                    $addPtrOperation['Name'] = $expectedNode['Owner']
                    $addPtrOperation['Zone'] = $expectedNode['Zone']
                    $addPtrOperation['NodeName'] = $expectedNode['NodeName']
                    $addPtrOperation['Summary'] = "add PTR $($expectedNode['Owner']) -> $ownerName"
                    $ownPtrs = @(foreach ($ptrRecord in @($expectedNode['Ptrs'])) { if ($ptrRecord['Data'] -eq $ownerName) { $ptrRecord } })
                    $otherPtrs = @(foreach ($ptrRecord in @($expectedNode['Ptrs'])) { if ($ptrRecord['Data'] -ne $ownerName) { $ptrRecord } })

                    if ($ownPtrs.Count -gt 0) {
                        $addPtrOperation['Result'] = 'AlreadyDone'
                        $addPtrOperation['Before'] = $ownPtrs[0]
                        if ($hasTtl) {
                            $ttlSubjects = @(@{ Record = $ownPtrs[0]; Current = $ownerName; Needs = @($addressOperation) })
                        }
                    }
                    elseif ($otherPtrs.Count -gt 0) {
                        $otherTargets = @(foreach ($ptrRecord in $otherPtrs) { $ptrRecord['Data'] }) -join ', '
                        if ($ReplacePtr) {
                            $removals = @($removals) + @(foreach ($ptrRecord in $otherPtrs) { @{ Node = $expectedNode; Record = $ptrRecord } })
                        }
                        else {
                            $addPtrOperation['Result'] = 'Skipped'
                            $addPtrOperation['Error'] = "The PTR record $($expectedNode['Owner']) already points at $otherTargets. Add -ReplacePtr to replace it."
                        }
                    }
                    elseif ($expectedNode['CnameTarget']) {
                        $addPtrOperation['Result'] = 'Skipped'
                        $addPtrOperation['Error'] = "The PTR record of $newAddress is delegated (RFC 2317 CNAME $($expectedNode['Owner']) -> $($expectedNode['CnameTarget'])) to a zone that is not hosted on '$serverKey'; add it on the server that hosts that zone."
                        Write-Warning $addPtrOperation['Error']
                    }
                }

                $removeOperations = @(
                    foreach ($removal in $removals) {
                        $node = $removal['Node']
                        $ptrRecord = $removal['Record']
                        @{
                            Action = 'RemovePtr'; Name = $node['Owner']; Type = 'PTR'; Data = $ptrRecord['Data']; Zone = $node['Zone']; NodeName = $node['NodeName']
                            Before = $ptrRecord; Write = 'Remove'; RRType = 'PTR'; Current = $ptrRecord['Data']; Needs = @($addressOperation)
                            Summary = "remove PTR $($node['Owner']) -> $($ptrRecord['Data'])"
                        }
                    }
                )
                # A replaced PTR must be gone before the new one is added, or the
                # address ends up with two PTR records.
                if ($ReplacePtr) {
                    $addPtrOperation['Needs'] = @($addressOperation) + @(
                        foreach ($removeOperation in $removeOperations) {
                            if ($removeOperation['Zone'] -eq $addPtrOperation['Zone'] -and $removeOperation['NodeName'] -eq $addPtrOperation['NodeName']) {
                                $removeOperation
                            }
                        }
                    )
                }

                $valueOperations = @(@($addressOperation) + $removeOperations + @($addPtrOperation))
                if ($hasTtl) {
                    $ttlSubjects = @(@{ Record = $hostRecord; Current = $newAddress; Needs = @($addressOperation) }) + $ttlSubjects
                }
            }
            elseif ($null -eq $itemError -and $hasTarget) {
                $targetOperation = @{
                    Action = 'SetTarget'; Name = $cnameRecord['Owner']; Type = 'CNAME'; Data = $newTargetName; Zone = $cnameRecord['Zone']; NodeName = $cnameRecord['NodeName']
                    Before = $cnameRecord; Write = 'Set'; RRType = 'CNAME'; Current = $cnameRecord['Data']; NewData = $newTargetName; Needs = @()
                    Summary = "change CNAME $($cnameRecord['Owner']) from $($cnameRecord['Data']) to $newTargetName"
                }
                if ($cnameRecord['Data'] -eq $newTargetName) {
                    $targetOperation['Result'] = 'AlreadyDone'
                }
                $valueOperations = @($targetOperation)
                if ($hasTtl) {
                    $ttlSubjects = @(@{ Record = $cnameRecord; Current = $newTargetName; Needs = @($targetOperation) })
                }
            }
            elseif ($null -eq $itemError -and $null -ne $subjectAddress) {
                $expectedNode = $null
                foreach ($node in @($ptrNodes[$subjectAddress])) {
                    if ($node['IsExpected']) {
                        $expectedNode = $node
                        break
                    }
                }
                $subjectReverseName = (ConvertTo-DnsReverseName -Address $subjectAddress)['ReverseName']
                $ptrRecords = @()
                if ($null -ne $expectedNode) {
                    $ptrRecords = @($expectedNode['Ptrs'])
                }

                if ($null -eq $expectedNode) {
                    $itemError = @{ Reason = 'NoReverseZone'; Message = "No reverse zone for $subjectAddress is hosted on '$serverKey'. Create one with New-DnsReverseZone."; Category = 'ObjectNotFound'; Report = $true; Unreachable = $false }
                }
                elseif (-not $hasPtrTarget) {
                    # -TTL alone on an address: every PTR record at its node.
                    if ($ptrRecords.Count -eq 0) {
                        $itemError = @{ Reason = 'NotFound'; Message = "$subjectAddress has no PTR record ($subjectReverseName) in zone '$($expectedNode['Zone'])' on '$serverKey'."; Category = 'ObjectNotFound'; Report = $true; Unreachable = $false }
                    }
                    else {
                        $ttlSubjects = @(foreach ($ptrRecord in $ptrRecords) { @{ Record = $ptrRecord; Current = $ptrRecord['Data']; Needs = @() } })
                    }
                }
                else {
                    $matchingPtrs = @(foreach ($ptrRecord in $ptrRecords) { if ($ptrRecord['Data'] -eq $newTargetName) { $ptrRecord } })
                    if ($matchingPtrs.Count -gt 0) {
                        $valueOperations = @(@{
                                Action = 'SetPtrTarget'; Name = $expectedNode['Owner']; Type = 'PTR'; Data = $newTargetName; Zone = $expectedNode['Zone']; NodeName = $expectedNode['NodeName']
                                Before = $matchingPtrs[0]; Result = 'AlreadyDone'; Needs = @()
                            })
                        if ($hasTtl) {
                            $ttlSubjects = @(@{ Record = $matchingPtrs[0]; Current = $newTargetName; Needs = @() })
                        }
                    }
                    elseif ($ptrRecords.Count -eq 1) {
                        $ptrOperation = @{
                            Action = 'SetPtrTarget'; Name = $expectedNode['Owner']; Type = 'PTR'; Data = $newTargetName; Zone = $expectedNode['Zone']; NodeName = $expectedNode['NodeName']
                            Before = $ptrRecords[0]; Write = 'Set'; RRType = 'PTR'; Current = $ptrRecords[0]['Data']; NewData = $newTargetName; Needs = @()
                            Summary = "change PTR $($expectedNode['Owner']) from $($ptrRecords[0]['Data']) to $newTargetName"
                        }
                        $valueOperations = @($ptrOperation)
                        if ($hasTtl) {
                            $ttlSubjects = @(@{ Record = $ptrRecords[0]; Current = $newTargetName; Needs = @($ptrOperation) })
                        }
                    }
                    elseif ($ptrRecords.Count -gt 1) {
                        $ptrList = @(foreach ($ptrRecord in $ptrRecords) { $ptrRecord['Data'] }) -join ', '
                        $itemError = @{ Reason = 'Ambiguous'; Message = "$subjectAddress has $($ptrRecords.Count) PTR records in zone '$($expectedNode['Zone'])' ($ptrList), so it is not clear which one to change. Remove the wrong PTR records first, then run Set-DnsEntry again."; Category = 'InvalidArgument'; Report = $true; Unreachable = $false }
                    }
                    elseif ($expectedNode['CnameTarget']) {
                        $itemError = @{ Reason = 'Delegated'; Message = "The PTR record of $subjectAddress is delegated (RFC 2317 CNAME $($expectedNode['Owner']) -> $($expectedNode['CnameTarget'])) to a zone that is not hosted on '$serverKey'. Change it on the server that hosts that zone."; Category = 'InvalidOperation'; Report = $true; Unreachable = $false }
                    }
                    else {
                        $addPtrOperation = @{
                            Action = 'AddPtr'; Name = $expectedNode['Owner']; Type = 'PTR'; Data = $newTargetName; Zone = $expectedNode['Zone']; NodeName = $expectedNode['NodeName']
                            Before = $null; Write = 'Add'; RRType = 'PTR'; Current = $newTargetName; Needs = @()
                            Summary = "add PTR $($expectedNode['Owner']) -> $newTargetName"
                        }
                        if ($hasTtl) {
                            $addPtrOperation['AddTtl'] = $TTL
                        }
                        $valueOperations = @($addPtrOperation)
                    }
                }
            }
            elseif ($null -eq $itemError) {
                # -TTL alone on a name or an entry: the forward record(s), then every
                # PTR record that points at the name, shadowed zones included.
                $ttlSubjects = @(
                    foreach ($record in $forwardRecords) {
                        @{ Record = $record; Current = $record['Data']; Needs = @() }
                    }
                    foreach ($record in $forwardRecords) {
                        if ($record['Type'] -ne 'A' -and $record['Type'] -ne 'AAAA') {
                            continue
                        }
                        foreach ($node in @($ptrNodes[$record['Data']])) {
                            foreach ($ptrRecord in @($node['Ptrs'])) {
                                if ($ptrRecord['Data'] -eq $record['Owner']) {
                                    @{ Record = $ptrRecord; Current = $ptrRecord['Data']; Needs = @() }
                                }
                            }
                        }
                    }
                )
            }

            $ttlOperations = @(
                foreach ($subject in $ttlSubjects) {
                    $record = $subject['Record']
                    $ttlOperation = @{
                        Action = 'SetTtl'; Name = $record['Owner']; Type = $record['Type']; Data = $subject['Current']; Zone = $record['Zone']; NodeName = $record['NodeName']
                        Before = $record; Write = 'Set'; RRType = $record['Type']; Current = $subject['Current']; NewTtl = $TTL; Needs = $subject['Needs']
                        Summary = "set the TTL of $($record['Type']) $($record['Owner']) from $($record['Ttl']) to $TTL s"
                    }
                    if ($record['Ttl'] -eq $TTL) {
                        $ttlOperation['Result'] = 'AlreadyDone'
                    }
                    $ttlOperation
                }
            )

            if ($null -ne $itemError) {
                $errorType = $resolved['Type']
                if ($isAddressKind) {
                    $errorType = 'PTR'
                }
                $errorData = $requestedValue
                if ($null -eq $errorData) {
                    $errorData = $resolved['Data']
                    if ($null -eq $errorData) {
                        $errorData = $resolved['Address']
                    }
                }
                $operations = @(@{
                        Action = $primaryAction; Name = $displayName; Type = $errorType; Data = $errorData; Zone = $resolved['Zone']; NodeName = $resolved['NodeName']
                        Before = $null; Result = 'Failed'; Error = $itemError['Message']; Needs = @()
                        ErrorReason = $itemError['Reason']; ErrorCategory = $itemError['Category']; Report = $itemError['Report']; Unreachable = $itemError['Unreachable']
                    })
            }
            else {
                $operations = @($valueOperations) + @($ttlOperations)
            }

            # --- Outcomes known without writing: read-only zones and dynamic records ---
            foreach ($operation in $operations) {
                if ($null -ne $operation['Result']) {
                    continue
                }
                $operationZone = $zoneLookup[[string]$operation['Zone']]
                if ($null -ne $operationZone -and $operationZone.IsReadOnly -eq $true) {
                    $operation['Result'] = 'Skipped'
                    $operation['Error'] = "Zone '$($operation['Zone'])' is not writable on '$serverKey' (zone type $($operationZone.ZoneType)); change the record on a server that hosts the primary zone."
                    continue
                }
                $before = $operation['Before']
                if ($operation['Write'] -ne 'Add' -and $null -ne $before -and $null -ne $before['Timestamp'] -and ($before['Type'] -eq 'A' -or $before['Type'] -eq 'AAAA' -or $before['Type'] -eq 'PTR')) {
                    if ($IncludeDynamic) {
                        Write-Warning "Changing the dynamic $($before['Type']) record '$($operation['Name'])' ($($before['Data'])) because of -IncludeDynamic; the client or the DHCP server may register the old value again."
                    }
                    else {
                        $operation['Result'] = 'Skipped'
                        $operation['Error'] = $dynamicText
                    }
                }
            }

            # A sub-operation whose prerequisite will not run does not run either; it
            # must not be offered at the prompt.
            foreach ($operation in $operations) {
                if ($null -ne $operation['Result']) {
                    continue
                }
                foreach ($need in @($operation['Needs'])) {
                    $needResult = $need['Result']
                    if ($null -ne $needResult -and $needResult -ne 'AlreadyDone') {
                        $operation['Result'] = 'Skipped'
                        $operation['Error'] = "Not done because $($need['Action']) of '$($need['Name'])' was $($needResult.ToLowerInvariant())."
                        break
                    }
                }
            }

            # --- Gate: one confirmation per item ---
            $pending = @(foreach ($operation in $operations) { if ($null -eq $operation['Result']) { $operation } })
            $confirmed = $false
            if ($pending.Count -gt 0) {
                $gateTarget = $displayName + ': ' + (@(foreach ($operation in $pending) { $operation['Summary'] }) -join '; ')
                $confirmErrors = $null
                # Silenced and re-raised below: a session that cannot prompt ends the
                # batch with exactly one terminating error (CONTRACTS.md 5.8). [S]top
                # throws and is not affected by -ErrorAction.
                $confirmed = Confirm-DnsAction -Target $gateTarget -Action 'Change DNS records' -Impact $impact -State $batch['Confirm'] -Force:$batch['Force'] -ErrorAction SilentlyContinue -ErrorVariable confirmErrors
                foreach ($confirmError in @($confirmErrors)) {
                    if ($null -ne $confirmError -and $null -ne $confirmError.PSObject.Properties['FullyQualifiedErrorId'] -and [string]$confirmError.FullyQualifiedErrorId -like 'DnsTools.Confirm.NonInteractive*') {
                        Write-Error -Message $confirmError.Exception.Message -Category InvalidOperation -ErrorId 'DnsTools.Confirm.NonInteractive' -TargetObject $gateTarget -ErrorAction Stop
                    }
                }
            }

            # --- Execute in order; every sub-operation gives exactly one Result ---
            foreach ($operation in $operations) {
                $result = $operation['Result']
                $errorText = $operation['Error']
                $failureReason = $null
                $failureCategory = $null
                $isUnreachable = $false
                $after = $null

                if ($result -eq 'Failed') {
                    if ($operation['Report']) {
                        $failureReason = $operation['ErrorReason']
                        $failureCategory = $operation['ErrorCategory']
                    }
                    $isUnreachable = $operation['Unreachable'] -eq $true
                }

                if ($null -eq $result) {
                    foreach ($need in @($operation['Needs'])) {
                        $needOutcome = $need['Outcome']
                        if ($needOutcome -ne 'Success' -and $needOutcome -ne 'AlreadyDone' -and $needOutcome -ne 'WhatIf') {
                            $result = 'Skipped'
                            $errorText = "Not done because $($need['Action']) of '$($need['Name'])' ended as $needOutcome."
                            break
                        }
                    }
                }

                if ($null -eq $result) {
                    if ($WhatIfPreference) {
                        $result = 'WhatIf'
                    }
                    elseif (-not $confirmed) {
                        $result = 'Skipped'
                        $errorText = 'Declined at the confirmation prompt.'
                    }
                    else {
                        $writeError = $null
                        if ($operation['Write'] -eq 'Set') {
                            $setParameters = @{
                                ServerParameter = $serverParameter
                                ZoneName        = $operation['Zone']
                                NodeName        = $operation['NodeName']
                                RRType          = $operation['RRType']
                                Data            = $operation['Current']
                            }
                            if ($null -ne $operation['NewTtl']) {
                                $setParameters['NewTtl'] = $operation['NewTtl']
                            }
                            if ($null -ne $operation['NewData']) {
                                $setParameters['NewData'] = $operation['NewData']
                            }
                            $outcome = Set-DnsLiveRecord @setParameters
                            if ($null -eq $outcome['Error']) {
                                $result = 'Success'
                                $after = $outcome['Record']
                                if ($null -ne $after) {
                                    Write-Verbose "$($operation['Action']) $($operation['Type']) '$($operation['Name'])': timestamp before '$($operation['Before']['Timestamp'])', after '$($after['Timestamp'])'."
                                }
                            }
                            else {
                                $writeError = $outcome
                            }
                        }
                        elseif ($operation['Write'] -eq 'Add') {
                            $addParameters = @{
                                ServerParameter = $serverParameter
                                ZoneName        = $operation['Zone']
                                NodeName        = $operation['NodeName']
                                RRType          = $operation['RRType']
                                Data            = $operation['Current']
                            }
                            if ($null -ne $operation['AddTtl']) {
                                $addParameters['Ttl'] = $operation['AddTtl']
                            }
                            $outcome = Add-DnsLiveRecord @addParameters
                            if ($outcome['Reason'] -eq 'Added') {
                                $result = 'Success'
                                $after = $outcome['Record']
                            }
                            elseif ($outcome['Reason'] -eq 'AlreadyExists') {
                                $result = 'AlreadyDone'
                                $after = $outcome['Record']
                            }
                            else {
                                $writeError = $outcome
                            }
                        }
                        else {
                            $outcome = Remove-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $operation['Zone'] -NodeName $operation['NodeName'] -RRType $operation['RRType'] -Data $operation['Current']
                            if ($outcome['Removed']) {
                                $result = 'Success'
                            }
                            elseif ($outcome['AlreadyGone']) {
                                $result = 'AlreadyDone'
                            }
                            else {
                                $writeError = $outcome
                            }
                        }

                        # Codes from winerror.h (CONTRACTS.md 13.9): 9712 read-only zone
                        # -> Skipped, 9707 CNAME loop and everything else -> Failed, an
                        # unreachable server ends the batch after this Result.
                        if ($null -ne $writeError) {
                            $errorText = [string]$writeError['Error']
                            $errorId = [string]$writeError['ErrorId']
                            if ($writeError['Unreachable'] -eq $true) {
                                $result = 'Failed'
                                $isUnreachable = $true
                            }
                            elseif ($errorId -like '*9712*') {
                                $result = 'Skipped'
                            }
                            else {
                                $result = 'Failed'
                                $failureReason = 'WriteFailed'
                                $failureCategory = 'WriteError'
                                if ($errorId -like '*9707*') {
                                    $failureReason = 'CnameLoop'
                                    $failureCategory = 'InvalidOperation'
                                }
                            }
                        }
                    }
                }

                # The Result (and its log line) comes first: under -ErrorAction Stop
                # the error below ends the run, and the log must still show the failure.
                Write-DnsResult -Batch $batch -Action $operation['Action'] -Name $operation['Name'] -Type $operation['Type'] -Data $operation['Data'] -Zone $operation['Zone'] -NodeName $operation['NodeName'] -Result $result -ErrorMessage $errorText -Before $operation['Before'] -After $after
                $operation['Outcome'] = $result
                if ($null -ne $failureReason) {
                    Write-Error -Message $errorText -Category $failureCategory -ErrorId "DnsTools.Set-DnsEntry.$failureReason" -TargetObject $operation['Name']
                }

                if ($isUnreachable) {
                    Write-Error -Message "The DNS server '$serverKey' cannot be reached ($errorText). The run was stopped after $itemCount item(s); check the server and run the command again." -Category ConnectionError -ErrorId 'DnsTools.Set-DnsEntry.ServerUnreachable' -TargetObject $serverKey -ErrorAction Stop
                }
            }
        }
    }

    end {
        if ($sleepPending) {
            Start-Sleep -Seconds $Delay
        }

        $counts = $batch['Counts']
        $countText = @(
            foreach ($resultName in @('Success', 'AlreadyDone', 'WhatIf', 'Skipped', 'Failed')) {
                if ($counts[$resultName]) {
                    '{0} {1}' -f $counts[$resultName], $resultName
                }
            }
        ) -join ', '
        if (-not $countText) {
            $countText = 'no sub-operations'
        }
        Write-Verbose "Set-DnsEntry on '$serverKey' (batch $($batch['BatchId'])): $itemCount item(s); $countText."
        if ($counts['Success']) {
            Write-Verbose 'The local snapshot is not updated after changes; run Update-DnsSnapshot before you search it again.'
        }
    }
}
