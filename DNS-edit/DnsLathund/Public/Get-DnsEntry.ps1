function Get-DnsEntry {
    <#
    .SYNOPSIS
        Finds A, AAAA and CNAME records by name, address or pattern and reports their PTR status.

    .DESCRIPTION
        Get-DnsEntry looks up DNS entries on one or more Microsoft DNS servers and
        returns one DnsLathund.Entry object per A, AAAA or CNAME record: the record
        itself, whether its reverse (PTR) record is right, who else uses the same
        address, which aliases and service records point at it, and where the data
        came from.

        Each -Find value is classified on its own:

        1. Pattern - contains * or ?: matched with -like against every owner name
           in the local snapshot (and against every address when the pattern only
           has digits, dots, colons, hex letters and wildcards). A pattern matches
           the whole FQDN, so 'srv*' finds srv01.contoso.local but 'srv0?' does
           not; end a pattern with * to match any zone. Needs a snapshot; when the
           server has none yet it is exported first (Update-DnsSnapshot), which
           can take minutes on large zones.
        2. IP address - a dotted-quad IPv4 address or an IPv6 address: the PTR
           records of the address are read live from every hosted reverse zone
           that covers it, and every name that has an A/AAAA record for the
           address in the snapshot is added when a snapshot exists. Every
           candidate is then read live and one entry is returned per A/AAAA
           record that really has the address. No snapshot is created for this.
           When PTR records exist but no A/AAAA record has the address, the
           warning names those orphaned PTR records and their targets.
        3. FQDN - ends with the name of a forward zone hosted on the server: the
           node is read live (A, AAAA and CNAME).
        4. Anything else (a bare name such as 'srv01'): with -Exact or -Zone it
           is read live as a node of -Zone, or with -Exact alone of every hosted
           forward zone. Without both it is a substring search ('*srv01*') over
           the snapshot, like a pattern.

        Live results are always current. Snapshot results are as old as the
        export (see Get-DnsSnapshot). Live results are still enriched from the
        snapshot (SharedWith, Aliases, ReferencedBy, HasDhcid, TargetExists) when
        one exists, whatever its age; SnapshotAge tells how old that part is.

        Use Get-DnsEntry to find a host, to see which names use an address, to
        check PTR records before cleaning up, or to feed names and addresses into
        other commands.

        What it does NOT do: it changes nothing in DNS, it does not create a
        snapshot for live lookups (FQDN, address, -Exact, -Zone), it never
        refreshes an existing snapshot, it does not return other record types
        (MX, SRV, TXT, ...) as entries, and it does not query reverse names
        ('5.16.0.10.in-addr.arpa'); pass the address instead.

    .PARAMETER Find
        What to look for: an FQDN, a bare name, an IPv4 or IPv6 address, or a
        pattern with * and ?. A pattern must match the whole FQDN ('srv*' or
        '*sql*', not 'srv0?'). Several values are processed one after the other.
        Accepts pipeline input, both plain strings (for example from Get-Content)
        and objects with a Name, Identity, HostName, IPAddress or Address
        property. Empty values (blank lines) are skipped.

    .PARAMETER Server
        The DNS server(s) to query. The whole search is repeated per server and
        every entry carries its Server. Default: the logon server
        ($env:LOGONSERVER without the leading backslashes).

    .PARAMETER Zone
        Restricts the search to records in this zone. A bare name is then read
        live as a node of this zone (with or without -Exact), and an FQDN is read
        only when it lies in this zone ('x.lab.contoso.local' with -Zone
        contoso.local reads node 'x.lab' of contoso.local). Address lookups and
        patterns return only records of this zone. A zone that is not hosted on
        a server gives one non-terminating error for that server.

    .PARAMETER Exact
        Never search the snapshot for names: a bare name is read live in -Zone, or
        in every hosted forward zone when -Zone is not given (a warning appears
        when that is more than 10 zones). A value with wildcards is rejected with
        a non-terminating error.

    .PARAMETER First
        Stop after this many entries in total, across all values and servers.
        Pipeline input that arrives after that is still read, but ignored: the
        command cannot stop the commands before it in the pipeline.

    .PARAMETER ExcludeNetwork
        DHCP or other dynamic ranges in CIDR notation ('10.0.50.0/24',
        'fd00::/64'). Entries whose address lies in one of them get
        InDhcpRange = $true; they are still returned. Invalid entries give one
        warning each and are ignored.

    .PARAMETER MaxSnapshotAge
        A snapshot older than this is still used, but with a warning that
        suggests Update-DnsSnapshot. Default: 24 hours.

    .PARAMETER Credential
        Alternate credentials. All DnsServer calls then go through a CIM session;
        the command throws when none can be opened and never falls back to the
        logged-on user.

    .PARAMETER TimeoutSec
        Timeout in seconds for the CIM session and remote operations. Default: 300.

    .EXAMPLE
        Get-DnsEntry srv01.contoso.local

        Reads the A, AAAA and CNAME records of srv01.contoso.local live from the
        logon server and shows them with their PTR status. Pipe the result to
        Format-List * to see every property.

    .EXAMPLE
        Get-Content .\servers.txt | Get-DnsEntry -Server dc01 | Where-Object PtrStatus -ne 'Ok' | Export-Csv .\ptr-problems.csv -NoTypeInformation -Encoding UTF8

        Looks up every line of servers.txt (names, FQDNs or addresses; blank lines
        are skipped) on dc01 and exports the entries whose reverse record is not
        in order. The columns follow the documented property order. List
        properties (PtrTargets, SharedWith, Aliases, ReferencedBy) are written
        by Export-Csv as System.String[]; join them with a calculated property
        when the file must show their values.

    .EXAMPLE
        $entries = @(Get-DnsEntry -Find 'app01' -Server dc01, dc02 -Exact -WarningAction SilentlyContinue -ErrorAction Stop)
        if ($entries.Count -eq 0) { throw 'app01 is not registered in DNS.' }

        For a scheduled task or another unattended script: reads the node app01
        live in every hosted forward zone on two servers, never touches or
        creates a snapshot for the search itself, and stops on any error. Each
        entry carries the Server it came from, so differences between the two
        servers show up as different entries.

    .EXAMPLE
        Get-DnsEntry '10.0.16.20' -Server dc01

        Lists every A record that points at 10.0.16.20, from the PTR records and,
        when a snapshot of dc01 exists, from the snapshot's address index. Each
        record is confirmed live before it is returned.

    .EXAMPLE
        Get-DnsEntry '*sql*' -Server dc01 -Zone contoso.local -ExcludeNetwork 10.0.50.0/24 | Format-Table Name, Data, PtrStatus, InDhcpRange

        Searches the snapshot of dc01 for names containing 'sql' in the zone
        contoso.local and marks the entries whose address is in the DHCP range.

    .INPUTS
        System.String

        Names, addresses or patterns can be piped to Get-DnsEntry, as strings or as
        objects with a Name, Identity, HostName, IPAddress or Address property.

    .OUTPUTS
        DnsLathund.Entry

        One object per A, AAAA or CNAME record, with these properties in this
        order:
        - Name (string): owner FQDN, lower case, no trailing dot, \DDD escapes decoded.
        - Type (string): A, AAAA or CNAME.
        - Data (string): the canonical address, or the CNAME target FQDN.
        - TTL (int): time to live in seconds.
        - PtrStatus (string): Ok, Missing, WrongTarget, Shadowed, Delegated, Multiple, NoReverseZone, or NotApplicable for a CNAME.
        - Zone (string): the zone that holds the record, lower case.
        - NodeName (string): the node within the zone ('@' for the apex); as stored for live records, lower case for snapshot records.
        - Timestamp (datetime): the aging timestamp; $null for a static record.
        - IsStatic (bool): $true when the record has no aging timestamp.
        - HasDhcid (bool): a DHCID record exists at the node (from the snapshot); $null when no snapshot was used.
        - InDhcpRange (bool): the address lies in one of the -ExcludeNetwork networks.
        - ReverseZone (string): the reverse zone that should hold the PTR (the longest hosted one); $null for a CNAME or when none is hosted.
        - PtrTargets (string[]): the targets of the PTR records found for the address; @() when none was found, $null when not evaluated.
        - PtrZoneFound (string): the zone where the PTR was found, or that holds the CNAME target of a Delegated PTR.
        - SharedWith (string[]): other names with an A/AAAA record for the same address (from the snapshot).
        - Aliases (string[]): CNAME owners that point at Name (from the snapshot).
        - ReferencedBy (string[]): SRV, NS and MX records that point at Name, as 'SRV:_ldap._tcp.contoso.local' (from the snapshot).
        - Target (string): the CNAME target; $null for A/AAAA.
        - TargetExists (bool): for a CNAME, the target has an A, AAAA or CNAME record in the snapshot; $null otherwise.
        - DistinguishedName (string): the AD object of the node (live records only).
        - Owner (string): reserved for the owner of the AD object; always $null in this version.
        - Server (string): the DNS server that answered, lower case.
        - Source (string): Live (read from the server now) or Snapshot (from the local zone export).
        - SnapshotAge (timespan): age of the oldest zone export behind the snapshot-derived properties; $null when no snapshot was used.

    .NOTES
        - Live and snapshot: FQDNs, addresses and -Exact/-Zone lookups are read
          live with Get-DnsServerResourceRecord -Node (Source = Live). Patterns and
          substring searches read the local snapshot (Source = Snapshot), which
          is as old as its export; refresh it with Update-DnsSnapshot. A live
          lookup never creates a snapshot, but uses an existing one of any age
          for SharedWith, Aliases, ReferencedBy, HasDhcid and TargetExists.
        - SnapshotAge is the age of the oldest zone export in the snapshot that
          was used, measured when the snapshot was loaded for this command; it is
          $null when no snapshot was used. A snapshot older than -MaxSnapshotAge
          gives a warning but is still used.
        - $null versus empty: a list property that is $null was not evaluated (for
          example SharedWith or Aliases without a snapshot); an empty list (@())
          was evaluated and has no members. The same holds for HasDhcid and
          TargetExists ($null = unknown).
        - IP lookups: DNS has no index from an address to the A records that use
          it. Live, only the PTR records of the address can be read, and they
          name at most the host the PTR points at. Listing every A record of an
          address therefore needs the snapshot's address index; without a
          snapshot an address lookup returns only the PTR target's A record.
        - Without a snapshot, PtrStatus cannot use SharedWith (a PTR to another
          name with the same address shows as WrongTarget) and cannot see NS
          delegations in reverse zones (a delegated PTR shows as Missing).
        - With -First the remaining pipeline input is still read, but ignored.
        - Real lookup failures (access denied, server unreachable) are reported
          as non-terminating errors with the ErrorId
          DnsLathund.Get-DnsLiveRecord.LookupFailed; the search goes on with the
          next zone, value and server. A missing record is not an error. Note
          that PowerShell still records the silenced "not found" answers of
          Get-DnsServerResourceRecord in $Error and in a caller's -ErrorVariable;
          check the error stream (2>&1) or use -ErrorAction Stop instead.
        - Works in Constrained Language Mode. Needs the DnsServer module (RSAT:
          DNS Server Tools) for every server call.
        - Aging timestamps of snapshot entries come from the export ([AGE:n]) and
          are as old as the export.
        - Snapshot files and meta.json are UTF-8; on Windows PowerShell 5.1 some
          are written with a BOM, on PowerShell 7 without. Both read the same.
    #>
    [CmdletBinding()]
    [OutputType('DnsLathund.Entry')]
    param (
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Name', 'Identity', 'HostName', 'IPAddress', 'Address')]
        [AllowEmptyString()]
        [string[]]$Find,

        [Parameter()]
        [Alias('ComputerName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Server,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Zone,

        [Parameter()]
        [switch]$Exact,

        [Parameter()]
        [ValidateRange(1, 2147483647)]
        [int]$First,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]]$ExcludeNetwork,

        [Parameter()]
        [timespan]$MaxSnapshotAge = (New-TimeSpan -Hours 24),

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.Credential()]
        [pscredential]$Credential,

        [Parameter()]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSec = 300
    )

    begin {
        $tab = [char]9
        $progressId = 95

        $requestedServers = @($Server)
        if (-not $Server) {
            # An empty name makes Resolve-DnsServerName use the logon server.
            $requestedServers = @('')
        }
        $seenServers = @{}
        $serverKeys = @(
            foreach ($serverEntry in $requestedServers) {
                $serverKey = Resolve-DnsServerName -Server $serverEntry
                if (-not $seenServers.ContainsKey($serverKey)) {
                    $seenServers[$serverKey] = $true
                    $serverKey
                }
            }
        )

        $zoneFilter = ''
        if ($Zone) {
            $zoneFilter = ConvertTo-DnsNormalizedName -Name $Zone
        }

        # Validated once here (CONTRACTS.md 13.1), so that Test-DnsAddressInNetwork
        # never warns once per entry about the same typo. The rules are those of
        # Test-DnsAddressInNetwork; calling it with a silenced warning would still
        # leave the warning in a caller's -WarningVariable.
        $networks = [string[]]@(
            foreach ($networkEntry in @($ExcludeNetwork)) {
                if ($null -eq $networkEntry) {
                    continue
                }
                $networkText = $networkEntry.Trim()
                $prefixText = $null
                $slash = $networkText.IndexOf('/')
                if ($slash -ge 0) {
                    $prefixText = $networkText.Substring($slash + 1)
                    $networkText = $networkText.Substring(0, $slash)
                }
                $networkAddress = ConvertTo-DnsNormalizedAddress -Address $networkText
                $isValid = $false
                if ($null -ne $networkAddress) {
                    $maximumPrefix = 32
                    if ($networkAddress.IndexOf(':') -ge 0) {
                        $maximumPrefix = 128
                    }
                    $isValid = ($null -eq $prefixText) -or ($prefixText -match '^\d{1,3}$' -and [int]$prefixText -le $maximumPrefix)
                }
                if ($isValid) {
                    $networkEntry
                }
                else {
                    Write-Warning "'$networkEntry' is not a valid network in CIDR notation (for example 10.0.50.0/24 or fd00::/8); it is ignored."
                }
            }
        )

        # Per server: zone table, server splat and snapshot state, set up on first
        # use so that each server's zone table is read once per call.
        $contexts = @{}
        $emittedCount = 0
        $limitReached = $false
    }

    process {
        if ($limitReached) {
            return
        }

        foreach ($findValue in @($Find)) {
            $display = [string]$findValue
            $text = $display.Trim()
            if (-not $text) {
                Write-Verbose 'Skipping an empty -Find value.'
                continue
            }

            $isPattern = ($text.IndexOf('*') -ge 0) -or ($text.IndexOf('?') -ge 0)
            if ($isPattern -and $Exact) {
                Write-Error -Message "'$display' contains wildcards, but -Exact only looks up exact names. Remove -Exact to search the snapshot with the pattern, or give an exact name." -Category InvalidArgument -ErrorId 'DnsLathund.Get-DnsEntry.PatternWithExact' -TargetObject $display
                continue
            }
            if ($isPattern) {
                # An unbalanced '[' would otherwise throw from -like in the middle of
                # a scan and end the whole command.
                try {
                    $null = 'probe' -like $text
                }
                catch {
                    Write-Error -Message "'$display' is not a valid wildcard pattern: $($_.Exception.Message) Escape a literal [ or ] with a backtick (``[)." -Category InvalidArgument -ErrorId 'DnsLathund.Get-DnsEntry.InvalidPattern' -TargetObject $display
                    continue
                }
            }

            $address = $null
            $name = ''
            if (-not $isPattern) {
                $address = ConvertTo-DnsNormalizedAddress -Address $text
                if ($null -eq $address) {
                    $name = ConvertTo-DnsNormalizedName -Name $text
                }
            }

            foreach ($serverKey in $serverKeys) {
                $context = $contexts[$serverKey]
                if ($null -eq $context) {
                    $context = @{
                        ZoneTable       = Get-DnsZoneTable -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec
                        ServerParameter = Get-DnsServerParameter -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec
                        Index           = $null
                        IndexState      = 'Unknown'
                        SnapshotAge     = $null
                        ZoneState       = 'Unchecked'
                        ExactWarned     = $false
                    }
                    $contexts[$serverKey] = $context
                }
                $zoneTable = $context['ZoneTable']
                $zoneLookup = $zoneTable.ZoneLookup
                $serverParameter = $context['ServerParameter']
                $matchCount = 0
                $ptrZones = @()
                $ptrTargetsByZone = @{}

                # -Zone must be hosted; checked once per server and call. The error
                # explains the empty result, so no "no entry matched" warning follows.
                if ($zoneFilter) {
                    if ($context['ZoneState'] -eq 'Unchecked') {
                        if ($null -eq $zoneLookup[$zoneFilter]) {
                            Write-Error -Message "Zone '$Zone' is not hosted on '$serverKey'. Check the name, or list the zones with Get-DnsServerZone -ComputerName $serverKey." -Category ObjectNotFound -ErrorId 'DnsLathund.Get-DnsEntry.ZoneNotFound' -TargetObject $Zone
                            $context['ZoneState'] = 'Missing'
                        }
                        else {
                            $context['ZoneState'] = 'Hosted'
                        }
                    }
                    if ($context['ZoneState'] -eq 'Missing') {
                        continue
                    }
                }

                # --- Classify: pattern, address, FQDN or bare name ---
                $searchPattern = $null
                $scanAddrs = $false
                $fqdnZone = $null
                if ($isPattern) {
                    $searchPattern = $text.TrimEnd('.')
                    $scanAddrs = $searchPattern -match '^[0-9a-fA-F.:*?]+$'
                    Write-Verbose "'$display' is a pattern; searching the snapshot of '$serverKey'."
                }
                elseif ($null -eq $address) {
                    foreach ($zoneName in @(Find-DnsZoneForName -Name $name -ZoneTable $zoneTable)) {
                        if (-not $zoneLookup[$zoneName].IsReverse) {
                            $fqdnZone = $zoneName
                            break
                        }
                    }
                    if ($null -ne $fqdnZone) {
                        Write-Verbose "'$display' is an FQDN in zone '$fqdnZone' of '$serverKey'; reading it live."
                    }
                    elseif (-not $Exact -and -not $zoneFilter) {
                        $searchPattern = '*' + [WildcardPattern]::Escape($name) + '*'
                        Write-Verbose "'$display' is not in a hosted forward zone of '$serverKey'; searching the snapshot for '$searchPattern'."
                    }
                    else {
                        Write-Verbose "'$display' is a bare name; reading it live (-Exact or -Zone)."
                    }
                }
                else {
                    Write-Verbose "'$display' is the address '$address'; reading its PTR records and A/AAAA records live."
                }

                # --- Snapshot needed: pattern or substring search ---
                if ($null -ne $searchPattern) {
                    if ($context['IndexState'] -ne 'Loaded') {
                        $context['Index'] = Get-DnsSnapshotIndex -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec -MaxSnapshotAge $MaxSnapshotAge
                        $context['IndexState'] = 'Loaded'
                        if ($null -ne $context['Index']['OldestExportedAt']) {
                            $context['SnapshotAge'] = (Get-Date) - [datetime]$context['Index']['OldestExportedAt']
                        }
                    }
                }
                elseif ($context['IndexState'] -eq 'Unknown') {
                    # Live lookups use a snapshot only when one already exists; they must
                    # never trigger the automatic export of Get-DnsSnapshotIndex.
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
                        $context['Index'] = Get-DnsSnapshotIndex -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec -MaxSnapshotAge $MaxSnapshotAge
                        $context['IndexState'] = 'Loaded'
                        if ($null -ne $context['Index']['OldestExportedAt']) {
                            $context['SnapshotAge'] = (Get-Date) - [datetime]$context['Index']['OldestExportedAt']
                        }
                    }
                    else {
                        Write-Verbose "No snapshot of '$serverKey' exists; live entries are returned without snapshot data."
                        $context['IndexState'] = 'None'
                    }
                }
                $index = $context['Index']
                $snapshotAge = $context['SnapshotAge']

                if ($null -ne $searchPattern) {
                    # --- Pattern and substring search over the snapshot, streamed ---
                    $nameIndex = $index['Name']
                    $names = $index['Names']
                    $nameTotal = $names.Count
                    $showProgress = $nameTotal -gt 100000
                    $progressShown = $false
                    $progressActivity = "Searching the snapshot of '$serverKey' for '$display'"
                    $nextProgressAt = 10000
                    $lastProgressAt = [datetime]::UtcNow
                    $scanned = 0
                    $zoneSuffix = '.' + $zoneFilter
                    $zoneTail = [string]$tab + $zoneFilter

                    foreach ($ownerName in $names) {
                        $scanned++
                        if ($showProgress -and $scanned -ge $nextProgressAt) {
                            $nextProgressAt = $scanned + 10000
                            $now = [datetime]::UtcNow
                            if (($now - $lastProgressAt).TotalMilliseconds -ge 500) {
                                Write-Progress -Id $progressId -Activity $progressActivity -Status "$scanned of $nameTotal names" -PercentComplete ([int]($scanned * 100 / $nameTotal))
                                $lastProgressAt = $now
                                $progressShown = $true
                            }
                        }
                        if ($zoneFilter -and $ownerName -ne $zoneFilter -and -not $ownerName.EndsWith($zoneSuffix)) {
                            continue
                        }
                        if ($ownerName -notlike $searchPattern) {
                            continue
                        }

                        foreach ($indexValue in $nameIndex[$ownerName]) {
                            # TYPE DATA TTL AGE ZONE
                            $field = $indexValue.Split($tab)
                            if ($field[0] -ne 'A' -and $field[0] -ne 'AAAA' -and $field[0] -ne 'CNAME') {
                                continue
                            }
                            if ($zoneFilter -and -not $indexValue.EndsWith($zoneTail)) {
                                continue
                            }

                            $ptrInfo = $null
                            if ($field[0] -ne 'CNAME') {
                                $ptrInfo = Resolve-DnsPtrStatus -Address $field[1] -Name $ownerName -ZoneTable $zoneTable -Index $index
                            }
                            ConvertTo-DnsEntry -Owner $ownerName -IndexValue $indexValue -PtrInfo $ptrInfo -Index $index -Network $networks -Source 'Snapshot' -Server $serverKey -SnapshotAge $snapshotAge
                            $matchCount++
                            $emittedCount++
                            if ($First -gt 0 -and $emittedCount -ge $First) {
                                $limitReached = $true
                                if ($progressShown) {
                                    Write-Progress -Id $progressId -Activity $progressActivity -Completed
                                }
                                return
                            }
                        }
                    }

                    if ($scanAddrs) {
                        # Owners whose name matched were returned above with all their records.
                        $addrIndex = $index['Addr']
                        foreach ($addressKey in $index['Addrs']) {
                            if ($addressKey -notlike $searchPattern) {
                                continue
                            }
                            foreach ($ownerName in $addrIndex[$addressKey]) {
                                if ($ownerName -like $searchPattern) {
                                    continue
                                }
                                foreach ($indexValue in $nameIndex[$ownerName]) {
                                    $field = $indexValue.Split($tab)
                                    if (($field[0] -ne 'A' -and $field[0] -ne 'AAAA') -or $field[1] -ne $addressKey) {
                                        continue
                                    }
                                    if ($zoneFilter -and -not $indexValue.EndsWith($zoneTail)) {
                                        continue
                                    }

                                    $ptrInfo = Resolve-DnsPtrStatus -Address $field[1] -Name $ownerName -ZoneTable $zoneTable -Index $index
                                    ConvertTo-DnsEntry -Owner $ownerName -IndexValue $indexValue -PtrInfo $ptrInfo -Index $index -Network $networks -Source 'Snapshot' -Server $serverKey -SnapshotAge $snapshotAge
                                    $matchCount++
                                    $emittedCount++
                                    if ($First -gt 0 -and $emittedCount -ge $First) {
                                        $limitReached = $true
                                        if ($progressShown) {
                                            Write-Progress -Id $progressId -Activity $progressActivity -Completed
                                        }
                                        return
                                    }
                                }
                            }
                        }
                    }

                    if ($progressShown) {
                        Write-Progress -Id $progressId -Activity $progressActivity -Completed
                    }
                }
                else {
                    # --- Live lookups: collect the records, then emit them ---
                    $liveRecords = @()

                    if ($null -ne $address) {
                        # Address: PTR targets (live) and the snapshot's owners of the
                        # address are the candidates; each is confirmed live.
                        $reverse = ConvertTo-DnsReverseName -Address $address
                        $addressType = 'A'
                        if ($reverse['Family'] -eq 'IPv6') {
                            $addressType = 'AAAA'
                        }

                        # PTR targets per reverse zone, kept for the orphaned-PTR warning.
                        $ptrTargetsByZone = @{}
                        $ptrZones = @(
                            foreach ($reverseZone in @(Find-DnsZoneForName -Name $reverse['ReverseName'] -ZoneTable $zoneTable -Reverse)) {
                                $reverseZoneInfo = $zoneLookup[$reverseZone]
                                if ($null -eq $reverseZoneInfo -or [string]$reverseZoneInfo.ZoneType -eq 'Stub' -or [string]$reverseZoneInfo.ZoneType -eq 'Forwarder') {
                                    continue
                                }
                                $reverseNode = Get-DnsReverseNodeName -ReverseName $reverse['ReverseName'] -ZoneName $reverseZone -ClasslessHostLabel:($reverseZoneInfo.IsClassless -eq $true)
                                if ($null -eq $reverseNode) {
                                    continue
                                }
                                $zoneTargets = @(
                                    foreach ($ptrRecord in @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $reverseZone -NodeName $reverseNode -RRType 'PTR')) {
                                        if ($ptrRecord['Data']) {
                                            $ptrRecord['Data']
                                        }
                                    }
                                )
                                if ($zoneTargets.Count -gt 0) {
                                    $ptrTargetsByZone[$reverseZone] = $zoneTargets
                                    $reverseZone
                                }
                            }
                        )

                        $candidateSeen = @{}
                        $candidates = @(
                            foreach ($ptrZone in $ptrZones) {
                                foreach ($ptrTarget in $ptrTargetsByZone[$ptrZone]) {
                                    if (-not $candidateSeen.ContainsKey($ptrTarget)) {
                                        $candidateSeen[$ptrTarget] = $true
                                        $ptrTarget
                                    }
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

                        $liveRecords = @(
                            foreach ($candidate in $candidates) {
                                # The snapshot knows the exact zone(s); otherwise the
                                # longest hosted forward zone of the name is the one.
                                $candidateZones = @{}
                                if ($null -ne $index) {
                                    foreach ($candidateEntry in @($index['Name'][$candidate])) {
                                        if ($null -eq $candidateEntry) {
                                            continue
                                        }
                                        $field = $candidateEntry.Split($tab)
                                        if ($field[0] -eq $addressType -and $field[1] -eq $address) {
                                            $candidateZones[$field[4]] = $true
                                        }
                                    }
                                }
                                if ($candidateZones.Count -eq 0) {
                                    foreach ($forwardZone in @(Find-DnsZoneForName -Name $candidate -ZoneTable $zoneTable)) {
                                        $forwardZoneInfo = $zoneLookup[$forwardZone]
                                        if (-not $forwardZoneInfo.IsReverse) {
                                            $candidateZones[$forwardZone] = $true
                                            break
                                        }
                                    }
                                }

                                foreach ($candidateZone in @($candidateZones.Keys | Sort-Object)) {
                                    if ($zoneFilter -and $candidateZone -ne $zoneFilter) {
                                        continue
                                    }
                                    $candidateNode = '@'
                                    if ($candidate -ne $candidateZone) {
                                        $candidateNode = $candidate.Substring(0, $candidate.Length - $candidateZone.Length - 1)
                                    }
                                    foreach ($liveRecord in @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $candidateZone -NodeName $candidateNode -RRType $addressType)) {
                                        if ($liveRecord['Data'] -eq $address) {
                                            $liveRecord
                                        }
                                    }
                                }
                            }
                        )
                    }
                    else {
                        # FQDN or bare name: which zones to read the node from.
                        $lookupZones = @()
                        $nodeIsRelative = $false
                        if ($zoneFilter) {
                            if ($null -ne $fqdnZone) {
                                # An FQDN is looked up in -Zone only when it lies in -Zone.
                                if ($name -eq $zoneFilter -or $name.EndsWith('.' + $zoneFilter)) {
                                    $lookupZones = @($zoneFilter)
                                }
                            }
                            else {
                                $lookupZones = @($zoneFilter)
                                $nodeIsRelative = $true
                            }
                        }
                        elseif ($null -ne $fqdnZone) {
                            $lookupZones = @($fqdnZone)
                        }
                        else {
                            # -Exact with a bare name: every hosted forward zone that holds records.
                            $lookupZones = @(
                                foreach ($forwardZone in @($zoneTable.ForwardZones)) {
                                    $forwardZoneType = [string]$zoneLookup[$forwardZone].ZoneType
                                    if ($forwardZoneType -ne 'Stub' -and $forwardZoneType -ne 'Forwarder') {
                                        $forwardZone
                                    }
                                }
                            )
                            $nodeIsRelative = $true
                            if ($lookupZones.Count -gt 10 -and -not $context['ExactWarned']) {
                                $context['ExactWarned'] = $true
                                Write-Warning "Looking up '$display' in $($lookupZones.Count) forward zones on '$serverKey' ($($lookupZones.Count * 3) queries per name). Specify -Zone to look in one zone only."
                            }
                        }

                        $liveRecords = @(
                            foreach ($lookupZone in $lookupZones) {
                                # Stub and forwarder zones only point elsewhere; the
                                # records do not live on this server.
                                $lookupZoneType = [string]$zoneLookup[$lookupZone].ZoneType
                                if ($lookupZoneType -eq 'Stub' -or $lookupZoneType -eq 'Forwarder') {
                                    Write-Verbose "Zone '$lookupZone' is a $lookupZoneType zone on '$serverKey'; its records are not hosted there."
                                    continue
                                }
                                if ($nodeIsRelative) {
                                    $lookupNode = $name
                                }
                                elseif ($name -eq $lookupZone) {
                                    $lookupNode = '@'
                                }
                                else {
                                    $lookupNode = $name.Substring(0, $name.Length - $lookupZone.Length - 1)
                                }
                                Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $lookupZone -NodeName $lookupNode -RRType 'A', 'AAAA', 'CNAME'
                            }
                        )
                    }

                    foreach ($liveRecord in $liveRecords) {
                        $ptrInfo = $null
                        if ($liveRecord['Type'] -ne 'CNAME' -and $liveRecord['Data']) {
                            $ptrInfo = Resolve-DnsPtrStatus -Address $liveRecord['Data'] -Name $liveRecord['Owner'] -ZoneTable $zoneTable -Index $index -ServerParameter $serverParameter
                        }
                        ConvertTo-DnsEntry -Record $liveRecord -PtrInfo $ptrInfo -Index $index -Network $networks -Source 'Live' -Server $serverKey -SnapshotAge $snapshotAge
                        $matchCount++
                        $emittedCount++
                        if ($First -gt 0 -and $emittedCount -ge $First) {
                            $limitReached = $true
                            return
                        }
                    }
                }

                if ($matchCount -eq 0) {
                    # PTR records without any A/AAAA for the address are the orphans the
                    # user is usually looking for; say so instead of "nothing found".
                    # With -Zone the A record may simply live in another zone.
                    if ($null -ne $address -and $ptrZones.Count -gt 0 -and -not $zoneFilter) {
                        $ptrSummary = @(
                            foreach ($ptrZone in $ptrZones) {
                                "{0} PTR record(s) in '{1}' point at: {2}" -f $ptrTargetsByZone[$ptrZone].Count, $ptrZone, ($ptrTargetsByZone[$ptrZone] -join ', ')
                            }
                        ) -join '; '
                        Write-Warning "No A/AAAA record has the address '$address' on '$serverKey', but $ptrSummary. These PTR records are orphaned (Test-DnsConsistency in a later phase reports them)."
                    }
                    else {
                        Write-Warning "No entry matched '$display' on '$serverKey'."
                    }
                }
            }
        }
    }
}
