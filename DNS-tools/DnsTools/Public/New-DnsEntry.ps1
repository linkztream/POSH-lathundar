function New-DnsEntry {
    <#
    .SYNOPSIS
        Creates static A, AAAA and CNAME records, with the PTR records of the addresses, after checking that each change is safe.

    .DESCRIPTION
        New-DnsEntry creates DNS entries on one Microsoft DNS server:

        - A host (-Name and -Address): one A or AAAA record per address, plus the
          PTR record of each address in the reverse lookup zone that covers it.
        - An alias (-Name and -Target): one CNAME record.
        - A batch: a CSV file (-InputFile) with the columns Name, Address or Target,
          and optionally TTL and Zone, one entry per row; or objects with those
          properties from the pipeline, for example from Import-Csv.

        Records are created static (without an aging timestamp), so scavenging
        never removes them. Without -TTL the zone's default TTL applies. A PTR
        record gets the same TTL as its A or AAAA record.

        Every item is first checked live on the server, and nothing of it is
        written until every check passed (preflight). An item fails when:
        - the name is an alias (CNAME): a name with an alias cannot have other
          records (NodeIsCname);
        - an alias is requested for a name that already has other records
          (CnameCollision);
        - the name lies below a delegated subdomain: an NS record on a label
          between the name and the zone (Delegated);
        - no reverse lookup zone covers an address, and neither -NoPtr nor
          -CreateReverseZone is given (NoReverseZone). The A record is then NOT
          created either, so that no host is left without its PTR record;
        - the PTR of an address is delegated with an RFC 2317 CNAME to a classless
          zone that is not hosted on the server (Delegated). When that zone is
          hosted, the PTR record goes into it.

        The command is idempotent, so a batch can simply be run again:
        - an A, AAAA or CNAME record that already exists with the same data is
          AlreadyDone (with a warning when its TTL differs from -TTL);
        - a PTR record that already points at the name is AlreadyDone;
        - a PTR record that points at another name is left alone (Skipped)
          unless -ReplacePtr is given, which removes it and adds the right one.

        With -CreateReverseZone a missing reverse zone is created first, for the
        /24 (IPv4) or /64 (IPv6) network around the address, exactly as
        New-DnsReverseZone creates it, with the settings of the forward zone and
        as part of this run. That step has its own confirmation with impact High.

        Each item asks for confirmation once (impact Medium: no prompt with the
        default $ConfirmPreference; -Confirm asks). -Force or -Confirm:$false
        never ask, and -WhatIf shows what would be done. Every sub-operation is
        written to the change log and returned as a DnsTools.Result object, in
        the order reverse zone, A/AAAA or CNAME, then PTR.

        What it does NOT do: it does not change or remove existing records (use
        Set-DnsEntry and Remove-DnsEntry), it does not create records in a zone
        hosted on another server or behind a delegation, it does not create
        dynamic records or DHCID records, it does not create classless (RFC 2317)
        reverse zones, and it does not update the local snapshot (run
        Update-DnsSnapshot to find the new records with Get-DnsEntry patterns).

    .PARAMETER Name
        The name of the record to create: an FQDN in a zone hosted on the server
        ('srv01.contoso.local'), or a name relative to -Zone ('srv01', '@' for the
        zone apex). For an alias this is the alias name, not its target. Binds
        from the Name property of pipeline objects.

    .PARAMETER Address
        The IPv4 or IPv6 address(es) of the host; one A or AAAA record (and one PTR
        record) per address. Binds from the Address property of pipeline objects.

    .PARAMETER Target
        The FQDN the alias (CNAME) points to ('web.contoso.local'). It may lie
        outside the zones on the server. Binds from the Target property of
        pipeline objects.

    .PARAMETER InputFile
        A CSV file with one entry per row and the columns Name and Address (host)
        or Name and Target (alias), optionally TTL (seconds) and Zone (overrides
        -Zone for that row). The delimiter is a comma, or a semicolon when the
        header has semicolons and no comma (Excel with a European locale). The file
        is read as UTF-8, with or without a BOM. Alias: FilePath.

    .PARAMETER TTL
        Time to live in seconds. Without it the zone's default TTL applies. An
        empty TTL cell from Import-Csv counts as not given. Alias: TimeToLive.

    .PARAMETER NoPtr
        Create the A and AAAA records without PTR records. Use it for addresses
        whose reverse zone is managed elsewhere.

    .PARAMETER CreateReverseZone
        When no reverse lookup zone covers an address, create the /24 (IPv4) or
        /64 (IPv6) zone around it first, with the replication, dynamic update and
        aging settings of the forward zone (as New-DnsReverseZone does). The zone
        creation is confirmed separately with impact High.

    .PARAMETER ReplacePtr
        When the PTR record of an address points at another name, remove it and add
        the PTR record for this name. Without it such a PTR record is left alone
        and reported as Skipped.

    .PARAMETER Zone
        The zone for names that are not fully qualified, and a restriction for
        FQDNs (an FQDN outside this zone is an error). With -InputFile the Zone
        column of a row takes precedence for that row. Pipeline objects bind their
        Zone property here, unless -Zone is given on the command line, which then
        applies to every object. Alias: ZoneName.

    .PARAMETER Delay
        Seconds to wait after each item (not after each record), to spread a large
        batch over time. Not applied under -WhatIf. Default: 0.

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
        The change-log file (JSON lines). Default: $env:DNSTOOLS_LOGPATH, else
        %LOCALAPPDATA%\DnsTools\log\DnsTools_<yyyy-MM>.jsonl. -WhatIf runs are
        logged too.

    .PARAMETER Force
        Make the changes without asking for confirmation, also for the reverse zone
        of -CreateReverseZone. -Force changes nothing else: the preflight checks
        still apply, and replacing a PTR record still needs -ReplacePtr.

    .EXAMPLE
        New-DnsEntry -Name srv01.contoso.local -Address 10.0.16.20

        Creates the static A record srv01.contoso.local -> 10.0.16.20 and the PTR
        record 20.16.0.10.in-addr.arpa -> srv01.contoso.local on the logon server,
        after checking the name and the reverse zone. Run it again and both
        records report AlreadyDone.

    .EXAMPLE
        New-DnsEntry -Name www -Zone contoso.local -Target web.contoso.local -TTL 300 -Server dc01

        Creates the alias www.contoso.local pointing at web.contoso.local with a
        TTL of five minutes. It fails without writing anything when www already
        has other records.

    .EXAMPLE
        Import-Csv .\new-hosts.csv | New-DnsEntry -Server dc01 -WhatIf

        Previews a batch from a CSV file with the columns Name, Address (or
        Target), TTL and Zone: every row is checked live, one "What if:" line is
        printed per row, and each sub-operation is returned (and logged) with
        Result = WhatIf. A file with both Address and Target columns must be read
        with -InputFile instead, because one pipeline object cannot be a host and
        an alias at the same time.

    .EXAMPLE
        New-DnsEntry -Name lab07.contoso.local -Address 10.0.99.7 -CreateReverseZone -Server dc01

        The network 10.0.99.0/24 has no reverse zone yet: 99.0.10.in-addr.arpa is
        created first (with the settings of contoso.local, after its own
        confirmation), then the A record and its PTR record.

    .EXAMPLE
        $results = @(New-DnsEntry -InputFile 'D:\Dns\new-entries.csv' -Server dc01 -Force -LogPath 'D:\Dns\Logs\changes.jsonl' -Delay 1 -ErrorAction SilentlyContinue -ErrorVariable entryErrors)
        $results | Where-Object Result -in 'Failed', 'Skipped' | Export-Csv 'D:\Dns\Logs\not-done.csv' -NoTypeInformation -Encoding UTF8

        For a scheduled task or another unattended script: creates every entry of
        the file without prompting, waits one second after each row, writes the
        change log to a fixed file, and exports the rows that need attention. A
        per-row failure does not stop the batch; an unreachable server or a
        session that cannot prompt does, with one terminating error.

    .INPUTS
        System.Management.Automation.PSObject

        Objects with the properties Name and Address (host) or Name and Target
        (alias), optionally TTL and Zone, are bound by property name, for example
        the rows of Import-Csv.

    .OUTPUTS
        DnsTools.Result

        One object per sub-operation (CreateZone and SetZoneAging from
        -CreateReverseZone, AddA, AddAAAA, AddCName, RemovePtr, AddPtr), with
        these properties in this order:
        - Action (string): the sub-operation.
        - Name (string): the owner FQDN of the record: the host or alias name, or
          the reverse name ('20.16.0.10.in-addr.arpa') for RemovePtr and AddPtr;
          the zone name for CreateZone and SetZoneAging.
        - Type (string): A, AAAA, CNAME or PTR; $null for zone operations.
        - Data (string): the address, the alias target, or the name a PTR record
          points to; the network for CreateZone.
        - Result (string): Success, Failed, Skipped, WhatIf or AlreadyDone.
        - Error (string): why the sub-operation failed or was skipped; $null otherwise.
        - Zone (string): the zone that holds the record.
        - NodeName (string): the node within the zone ('srv01', '20', '@').
        - Server (string): the DNS server, lower case.
        - Id (string): the GUID of this result, also in the change log.
        - BatchId (string): the GUID shared by every result of this run.
        - Timestamp (datetime): when the result was produced.

    .NOTES
        - Records are static. A DHCP server or a client that registers the same
          name dynamically may later change or take over the record.
        - Live checks: the preflight reads the node, every label between the name
          and the zone (NS), and the PTR node of each address with
          Get-DnsServerResourceRecord -Node. The silenced "not found" answers stay
          in $Error and in a caller's -ErrorVariable; filter the errors on the
          ErrorId prefix DnsTools.New-DnsEntry.
        - A failed preflight writes nothing for that item and reports one Failed
          result per requested A, AAAA or CNAME record, with the reason in Error
          and a non-terminating error DnsTools.New-DnsEntry.<Reason>
          (NodeIsCname, CnameCollision, Delegated, NoReverseZone, InvalidInput,
          PatternNotAllowed, ZoneNotFound, LookupFailed). When an A or AAAA record
          cannot be created, its PTR record is Skipped.
        - Batch abort: an unreachable server (RPC 1722, WinRM or CIM transport
          failure) writes the Failed result and stops the batch with the error
          DnsTools.New-DnsEntry.ServerUnreachable; a session that cannot prompt
          (no -Force) stops it with DnsTools.Confirm.NonInteractive. Running the
          same batch again is safe.
        - A zone that is read-only on the server (secondary) gives Skipped; access
          denied gives Failed, never AlreadyDone.
        - -CreateReverseZone creates the zone within this run: its CreateZone and
          SetZoneAging results share the BatchId of the records. It needs a forward
          zone stored in Active Directory (Domain, Forest or Custom scope); for
          other zones create the reverse zone with New-DnsReverseZone
          -ReplicationScope first. A zone that cannot be created gives a Failed
          CreateZone result and a non-terminating error
          DnsTools.New-DnsEntry.<Reason> (ReplicationScopeRequired or
          CreateFailed), and the A, AAAA and PTR records of its addresses are
          Skipped. Aging settings that cannot be copied give a Failed SetZoneAging
          result and DnsTools.New-DnsEntry.AgingFailed; the records are still
          created. Other domain controllers see a new zone only after
          replication.
        - "Yes to all" at the zone prompt (High) also approves the zones of later
          items in the same run. "Yes to all" at the record prompt (Medium) never
          approves the creation of a reverse zone.
        - A -WhatIf run changes nothing, so it does not count for the warning that
          this session already changed DNS on another server.
        - Pipeline input: TTL and Zone come from the current object only, and an
          empty cell means "not given"; -TTL or -Zone on the command line applies
          to every object instead. A pipeline object without Address or Target
          (or with an empty one) cannot be bound and gives a parameter binding
          error for that object; the others are processed.
        - Names are exact: a name with * or ? is rejected (PatternNotAllowed),
          so wildcard records cannot be created with this command.
        - Names with characters outside a-z, 0-9 and '-' (such as 'kåken') are
          created as given; the input file must then be saved as UTF-8.
        - Works in Constrained Language Mode. Needs the DnsServer module (RSAT: DNS
          Server Tools).
        - The change log is UTF-8; Windows PowerShell 5.1 writes a BOM when it
          creates the file, PowerShell 7 does not. Both read either.
    #>
    # The default set is File, which nothing binds from the pipeline: with Host as
    # default, PowerShell would not switch to Alias for an object with Name and
    # Target (measured on 5.1 and 7).
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'File')]
    [OutputType('DnsTools.Result')]
    param (
        [Parameter(Mandatory, ParameterSetName = 'Host', ValueFromPipelineByPropertyName)]
        [Parameter(Mandatory, ParameterSetName = 'Alias', ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory, ParameterSetName = 'Host', ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Address,

        [Parameter(Mandatory, ParameterSetName = 'Alias', ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Target,

        [Parameter(Mandatory, ParameterSetName = 'File')]
        [Alias('FilePath')]
        [ValidateNotNullOrEmpty()]
        [string]$InputFile,

        [Parameter(ParameterSetName = 'Host', ValueFromPipelineByPropertyName)]
        [Parameter(ParameterSetName = 'Alias', ValueFromPipelineByPropertyName)]
        [Alias('TimeToLive')]
        [ValidateRange(0, 2147483647)]
        [int]$TTL,

        [Parameter(ParameterSetName = 'Host')]
        [Parameter(ParameterSetName = 'File')]
        [switch]$NoPtr,

        [Parameter(ParameterSetName = 'Host')]
        [Parameter(ParameterSetName = 'File')]
        [switch]$CreateReverseZone,

        [Parameter(ParameterSetName = 'Host')]
        [Parameter(ParameterSetName = 'File')]
        [switch]$ReplacePtr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('ZoneName')]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Zone,

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
        if ($NoPtr -and ($CreateReverseZone -or $ReplacePtr)) {
            throw '-NoPtr cannot be combined with -CreateReverseZone or -ReplacePtr: with -NoPtr no PTR record is created, replaced or given a zone. Remove one of them.'
        }

        $serverKey = Resolve-DnsServerName -Server $Server
        $batch = New-DnsBatch -Server $serverKey -LogPath $LogPath -Delay $Delay -Force:$Force
        $isWhatIf = [bool]$WhatIfPreference
        # A preview changes nothing, so it must not become the session's writer server.
        if (-not $isWhatIf) {
            Test-DnsWriterServer -Server $serverKey
        }
        $zoneTable = Get-DnsZoneTable -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec
        $serverParameter = Get-DnsServerParameter -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec

        # In begin {} $PSBoundParameters holds the command line only. In process {}
        # it keeps the keys of earlier pipeline objects (measured on 5.1 and 7), so
        # it cannot tell whether the current object brought a TTL.
        $ttlFromCommandLine = $PSBoundParameters.Keys -contains 'TTL'

        # Reverse zones created in this run, or that would be created under -WhatIf,
        # so that later items do not plan them again.
        $reverseZonesInRun = @{}
        $declinedText = 'Declined at the confirmation prompt.'
        $lookupErrorId = 'DnsTools.Get-DnsLiveRecord.LookupFailed*'
        $zoneErrorPrefix = 'DnsTools.New-DnsLiveReverseZone.'
        $rowNumber = 0
    }

    process {
        # --- One request per input item: a CSV row, or this call / pipeline object ---
        if ($InputFile) {
            $requests = @(
                foreach ($row in @(Read-DnsInputFile -Path $InputFile -Csv)) {
                    $rowNumber++
                    $label = $row['Name']
                    if (-not $label) {
                        $label = "row $rowNumber of '$InputFile'"
                    }
                    $rawAddresses = @()
                    if ($row['Address']) {
                        $rawAddresses = @($row['Address'])
                    }
                    @{ Label = $label; Resolve = $row; RawAddresses = $rawAddresses; RawTarget = $row['Target']; TtlText = $row['TTL']; Ttl = $null; IsFileRow = $true }
                }
            )
        }
        else {
            # An empty TTL cell of an Import-Csv row binds as 0; only a TTL that the
            # current object really carries counts as given.
            $ttlValue = $null
            $ttlGiven = $ttlFromCommandLine
            if (-not $ttlGiven -and $MyInvocation.ExpectingInput -and $null -ne $_) {
                foreach ($ttlPropertyName in @('TTL', 'TimeToLive')) {
                    $ttlProperty = $_.PSObject.Properties[$ttlPropertyName]
                    if ($null -ne $ttlProperty -and $null -ne $ttlProperty.Value -and '' -ne ([string]$ttlProperty.Value).Trim()) {
                        $ttlGiven = $true
                    }
                }
            }
            if ($ttlGiven) {
                $ttlValue = $TTL
            }

            $rawAddresses = @()
            if ($null -ne $Address) {
                $rawAddresses = @(foreach ($addressText in $Address) { if ($addressText) { $addressText } })
            }
            $resolveInput = @{ Name = $Name; Address = $null; Target = $null; TTL = $null; Zone = $null }
            if ($Target) {
                $resolveInput['Target'] = $Target
            }
            $requests = @(@{ Label = $Name; Resolve = $resolveInput; RawAddresses = $rawAddresses; RawTarget = $Target; TtlText = $null; Ttl = $ttlValue; IsFileRow = $false })
        }

        foreach ($request in $requests) {
            $failure = $null
            $lookupFailure = $null
            $kind = $null
            $fqdn = $null
            $zoneName = $null
            $nodeName = $null
            $addresses = @()
            $targetName = $null
            $recordTtl = $request['Ttl']
            $label = $request['Label']

            # A do/while ($false) block: 'break' ends the item early (resolution or
            # preflight failed); the Failed results are written after it.
            do {
                # --- 1. Resolve the name and check the input ---
                try {
                    $resolved = Resolve-DnsChangeTarget -InputObject $request['Resolve'] -ZoneTable $zoneTable -Zone $Zone
                }
                catch {
                    $failure = @{
                        Reason   = (([string]$_.FullyQualifiedErrorId).Split(',')[0]).Split('.')[-1]
                        Message  = $_.Exception.Message
                        Category = $_.CategoryInfo.Category
                    }
                    break
                }

                if ($resolved['Kind'] -eq 'Address') {
                    $message = "'$label' is an IP address. Name is the host or alias name to create (for example srv01.contoso.local); give the address with -Address or in the Address column."
                    if ($request['IsFileRow'] -and -not $request['Resolve']['Name']) {
                        $message = "The $label has no Name. Every row needs the name to create in the Name column."
                    }
                    $failure = @{ Reason = 'InvalidInput'; Message = $message; Category = 'InvalidArgument' }
                    break
                }
                $fqdn = $resolved['Fqdn']
                $zoneName = $resolved['Zone']
                $nodeName = $resolved['NodeName']
                $label = $fqdn

                if ($request['IsFileRow']) {
                    if ($resolved['Type'] -eq 'CNAME') {
                        $kind = 'Alias'
                        $targetName = $resolved['Data']
                    }
                    elseif ($resolved['Type'] -eq 'A' -or $resolved['Type'] -eq 'AAAA') {
                        $kind = 'Host'
                        $addresses = @($resolved['Data'])
                    }
                    else {
                        $failure = @{ Reason = 'InvalidInput'; Message = "The row for '$fqdn' has neither an Address nor a Target. Give the address of a host or the target of an alias."; Category = 'InvalidArgument' }
                        break
                    }

                    $ttlText = $request['TtlText']
                    if ($ttlText) {
                        $recordTtl = $null
                        if ($ttlText -match '^\d{1,10}$') {
                            $recordTtl = $ttlText -as [int]
                        }
                        if ($null -eq $recordTtl) {
                            $failure = @{ Reason = 'InvalidInput'; Message = "The TTL '$ttlText' of '$fqdn' is not a whole number of seconds between 0 and 2147483647."; Category = 'InvalidArgument' }
                            break
                        }
                    }
                }
                elseif ($request['RawTarget']) {
                    $kind = 'Alias'
                    $targetName = $resolved['Data']
                }
                else {
                    $kind = 'Host'
                    $invalidAddress = $null
                    $seenAddresses = @{}
                    $addresses = @(
                        foreach ($rawAddress in $request['RawAddresses']) {
                            $normalized = ConvertTo-DnsNormalizedAddress -Address $rawAddress
                            if ($null -eq $normalized) {
                                if ($null -eq $invalidAddress) {
                                    $invalidAddress = $rawAddress
                                }
                                continue
                            }
                            if (-not $seenAddresses.ContainsKey($normalized)) {
                                $seenAddresses[$normalized] = $true
                                $normalized
                            }
                        }
                    )
                    if ($null -ne $invalidAddress) {
                        $failure = @{ Reason = 'InvalidInput'; Message = "'$invalidAddress' (address of '$fqdn') is not an IPv4 or IPv6 address."; Category = 'InvalidArgument' }
                        break
                    }
                    if ($addresses.Count -eq 0) {
                        $failure = @{ Reason = 'InvalidInput'; Message = "No address was given for '$fqdn'."; Category = 'InvalidArgument' }
                        break
                    }
                }

                if ($kind -eq 'Alias') {
                    if (-not $targetName) {
                        $failure = @{ Reason = 'InvalidInput'; Message = "The target of alias '$fqdn' is empty."; Category = 'InvalidArgument' }
                        break
                    }
                    if ($null -ne (ConvertTo-DnsNormalizedAddress -Address $targetName)) {
                        $failure = @{ Reason = 'InvalidInput'; Message = "The target '$targetName' of alias '$fqdn' is an IP address. An alias (CNAME) points to a name; create a host with -Address instead."; Category = 'InvalidArgument' }
                        break
                    }
                    if ($targetName.IndexOf('.') -lt 0) {
                        $failure = @{ Reason = 'InvalidInput'; Message = "The target '$targetName' of alias '$fqdn' is not a fully qualified name. Give the FQDN, for example $targetName.$zoneName."; Category = 'InvalidArgument' }
                        break
                    }
                }

                # --- 2. Preflight: read the live state; nothing is written before every check passed ---
                $hasIPv4 = $false
                $hasIPv6 = $false
                foreach ($entryAddress in $addresses) {
                    if ($entryAddress.IndexOf(':') -ge 0) {
                        $hasIPv6 = $true
                    }
                    else {
                        $hasIPv4 = $true
                    }
                }
                if ($kind -eq 'Alias') {
                    # Any record at the node collides with a CNAME; these are the types
                    # that occur at host names. The server refuses the rest (9709).
                    $nodeTypes = @('CNAME', 'A', 'AAAA', 'TXT', 'MX', 'SRV', 'NS', 'DHCID')
                }
                else {
                    $nodeTypes = @('CNAME'; if ($hasIPv4) { 'A' }; if ($hasIPv6) { 'AAAA' })
                }

                $lookupErrors = $null
                $nodeRecords = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $zoneName -NodeName $nodeName -RRType $nodeTypes -ErrorAction SilentlyContinue -ErrorVariable lookupErrors)
                foreach ($lookupError in @($lookupErrors)) {
                    if ([string]$lookupError.FullyQualifiedErrorId -like $lookupErrorId) {
                        $lookupFailure = $lookupError
                    }
                }
                if ($null -ne $lookupFailure) {
                    break
                }

                $cnameRecord = $null
                $otherTypes = @{}
                $existingByAddress = @{}
                foreach ($record in $nodeRecords) {
                    if ($record['Type'] -eq 'CNAME') {
                        $cnameRecord = $record
                        continue
                    }
                    $otherTypes[$record['Type']] = $true
                    if (($record['Type'] -eq 'A' -or $record['Type'] -eq 'AAAA') -and $record['Data']) {
                        $existingByAddress[$record['Data']] = $record
                    }
                }

                $aliasState = 'Pending'
                $aliasExisting = $null
                $aliasWarning = $null
                if ($kind -eq 'Host' -and $null -ne $cnameRecord) {
                    $failure = @{ Reason = 'NodeIsCname'; Message = "'$fqdn' is an alias (CNAME for '$($cnameRecord['Data'])'). A name with an alias cannot have other records; remove the alias first, or choose another name."; Category = 'ResourceExists' }
                    break
                }
                if ($kind -eq 'Alias') {
                    if ($null -ne $cnameRecord) {
                        if ($cnameRecord['Data'] -ne $targetName) {
                            $failure = @{ Reason = 'NodeIsCname'; Message = "'$fqdn' is already an alias for '$($cnameRecord['Data'])'. Point it at '$targetName' with Set-DnsEntry -Target, or remove it first."; Category = 'ResourceExists' }
                            break
                        }
                        $aliasState = 'AlreadyDone'
                        $aliasExisting = $cnameRecord
                        if ($null -ne $recordTtl -and $null -ne $cnameRecord['Ttl'] -and $cnameRecord['Ttl'] -ne $recordTtl) {
                            $aliasWarning = "'$fqdn' is already an alias for '$targetName', with a TTL of $($cnameRecord['Ttl']) s instead of the requested $recordTtl s. Change it with Set-DnsEntry -TTL $recordTtl."
                        }
                    }
                    elseif ($otherTypes.Count -gt 0) {
                        $typeList = (@($otherTypes.Keys) | Sort-Object) -join ', '
                        $failure = @{ Reason = 'CnameCollision'; Message = "'$fqdn' already has $typeList record(s). An alias (CNAME) cannot share its name with other records; remove them first, or choose another name."; Category = 'ResourceExists' }
                        break
                    }
                }

                # An NS record on a label between the name and the zone apex hands
                # everything below it to other name servers.
                if ($nodeName -ne '@') {
                    $labels = @($nodeName.Split('.'))
                    for ($labelIndex = 1; $labelIndex -lt $labels.Count; $labelIndex++) {
                        $ancestor = $labels[$labelIndex..($labels.Count - 1)] -join '.'
                        $lookupErrors = $null
                        $nsRecords = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $zoneName -NodeName $ancestor -RRType 'NS' -ErrorAction SilentlyContinue -ErrorVariable lookupErrors)
                        foreach ($lookupError in @($lookupErrors)) {
                            if ([string]$lookupError.FullyQualifiedErrorId -like $lookupErrorId) {
                                $lookupFailure = $lookupError
                            }
                        }
                        if ($null -ne $lookupFailure) {
                            break
                        }
                        if ($nsRecords.Count -gt 0) {
                            $nameServers = @(foreach ($nsRecord in $nsRecords) { $nsRecord['Data'] }) -join ', '
                            $failure = @{ Reason = 'Delegated'; Message = "'$fqdn' lies below '$ancestor.$zoneName', which is delegated to other name servers ($nameServers). Create the record in the delegated zone, on a server that hosts it."; Category = 'InvalidOperation' }
                            break
                        }
                    }
                    if ($null -ne $failure -or $null -ne $lookupFailure) {
                        break
                    }
                }

                # Host: which addresses are already there.
                $forwardPlans = @(
                    foreach ($entryAddress in $addresses) {
                        $recordType = 'A'
                        if ($entryAddress.IndexOf(':') -ge 0) {
                            $recordType = 'AAAA'
                        }
                        $existing = $existingByAddress[$entryAddress]
                        $forwardState = 'Pending'
                        $forwardWarning = $null
                        if ($null -ne $existing -and $existing['Type'] -eq $recordType) {
                            $forwardState = 'AlreadyDone'
                            if ($null -ne $recordTtl -and $null -ne $existing['Ttl'] -and $existing['Ttl'] -ne $recordTtl) {
                                $forwardWarning = "'$fqdn' already has $recordType $entryAddress, with a TTL of $($existing['Ttl']) s instead of the requested $recordTtl s. Change it with Set-DnsEntry -TTL $recordTtl."
                            }
                        }
                        else {
                            $existing = $null
                        }
                        @{ Address = $entryAddress; RecordType = $recordType; State = $forwardState; Existing = $existing; Warning = $forwardWarning }
                    }
                )

                # Host: where each PTR record goes, and what is there already.
                $newZones = [ordered]@{}
                $reversePlanByAddress = @{}
                if ($kind -eq 'Host' -and -not $NoPtr) {
                    foreach ($forwardPlan in $forwardPlans) {
                        $entryAddress = $forwardPlan['Address']
                        $reverseName = (ConvertTo-DnsReverseName -Address $entryAddress)['ReverseName']
                        # Stub and forwarder zones hold no records of their own.
                        $coveringZones = @(
                            foreach ($candidate in @(Find-DnsZoneForName -Name $reverseName -ZoneTable $zoneTable -Reverse)) {
                                $candidateType = [string]$zoneTable.ZoneLookup[$candidate].ZoneType
                                if ($candidateType -ne 'Stub' -and $candidateType -ne 'Forwarder') {
                                    $candidate
                                }
                            }
                        )

                        $newZone = $null
                        if ($coveringZones.Count -eq 0) {
                            $prefix = '/24'
                            if ($entryAddress.IndexOf(':') -ge 0) {
                                $prefix = '/64'
                            }
                            $plannedZone = Get-DnsReverseZoneName -NetworkId ($entryAddress + $prefix)
                            $ptrZone = $plannedZone['ZoneName']
                            if (-not $reverseZonesInRun.ContainsKey($ptrZone)) {
                                if (-not $CreateReverseZone) {
                                    $forwardNote = "and '$fqdn' is not created either"
                                    if ($forwardPlan['State'] -eq 'AlreadyDone') {
                                        $forwardNote = "although '$fqdn' already has its $($forwardPlan['RecordType']) record"
                                    }
                                    $failure = @{ Reason = 'NoReverseZone'; Message = "No reverse lookup zone on '$serverKey' covers $entryAddress, so its PTR record cannot be created, $forwardNote. Add -NoPtr to create the record without a PTR record, or -CreateReverseZone to create the zone $ptrZone ($($plannedZone['Network'])) first."; Category = 'ObjectNotFound' }
                                    break
                                }
                                if (-not ($newZones.Keys -contains $ptrZone)) {
                                    $newZones[$ptrZone] = $plannedZone['Network']
                                }
                                $newZone = $ptrZone
                            }
                            $ptrNode = Get-DnsReverseNodeName -ReverseName $reverseName -ZoneName $ptrZone
                        }
                        else {
                            # The longest covering zone; a hosted RFC 2317 zone that
                            # covers the address comes first (Find-DnsZoneForName).
                            $ptrZone = $coveringZones[0]
                            $isClassless = $zoneTable.ZoneLookup[$ptrZone].IsClassless -eq $true
                            $ptrNode = Get-DnsReverseNodeName -ReverseName $reverseName -ZoneName $ptrZone -ClasslessHostLabel:$isClassless
                            if (-not $isClassless) {
                                # A CNAME at the node is the parent side of an RFC 2317
                                # delegation: the PTR belongs where the CNAME points.
                                $lookupErrors = $null
                                $aliasRecords = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $ptrZone -NodeName $ptrNode -RRType 'CNAME' -ErrorAction SilentlyContinue -ErrorVariable lookupErrors)
                                foreach ($lookupError in @($lookupErrors)) {
                                    if ([string]$lookupError.FullyQualifiedErrorId -like $lookupErrorId) {
                                        $lookupFailure = $lookupError
                                    }
                                }
                                if ($null -ne $lookupFailure) {
                                    break
                                }
                                if ($aliasRecords.Count -gt 0) {
                                    $delegatedName = $aliasRecords[0]['Data']
                                    $classlessZone = $null
                                    foreach ($candidate in @(Find-DnsZoneForName -Name $delegatedName -ZoneTable $zoneTable)) {
                                        $candidateInfo = $zoneTable.ZoneLookup[$candidate]
                                        $candidateType = [string]$candidateInfo.ZoneType
                                        if ($candidate -ne $ptrZone -and $candidateInfo.IsReverse -and $candidateType -ne 'Stub' -and $candidateType -ne 'Forwarder') {
                                            $classlessZone = $candidate
                                            break
                                        }
                                    }
                                    if ($null -eq $classlessZone) {
                                        $failure = @{ Reason = 'Delegated'; Message = "The PTR record of $entryAddress is delegated (RFC 2317): '$reverseName' is an alias for '$delegatedName', whose zone is not hosted on '$serverKey'. Create the PTR record on the server that hosts that zone, or add -NoPtr."; Category = 'InvalidOperation' }
                                        break
                                    }
                                    $ptrZone = $classlessZone
                                    $ptrNode = Get-DnsReverseNodeName -ReverseName $delegatedName -ZoneName $classlessZone
                                }
                            }
                        }

                        # A zone that is still to be created has no records to read.
                        $existingPtrs = @()
                        if ($coveringZones.Count -gt 0) {
                            $lookupErrors = $null
                            $existingPtrs = @(Get-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $ptrZone -NodeName $ptrNode -RRType 'PTR' -ErrorAction SilentlyContinue -ErrorVariable lookupErrors)
                            foreach ($lookupError in @($lookupErrors)) {
                                if ([string]$lookupError.FullyQualifiedErrorId -like $lookupErrorId) {
                                    $lookupFailure = $lookupError
                                }
                            }
                            if ($null -ne $lookupFailure) {
                                break
                            }
                        }

                        $samePtr = $null
                        $otherPtrs = @(
                            foreach ($ptrRecord in $existingPtrs) {
                                if ($ptrRecord['Data'] -eq $fqdn) {
                                    $samePtr = $ptrRecord
                                }
                                else {
                                    $ptrRecord
                                }
                            }
                        )
                        $ptrState = 'Pending'
                        $ptrReason = $null
                        if ($null -ne $samePtr) {
                            $ptrState = 'AlreadyDone'
                        }
                        elseif ($otherPtrs.Count -gt 0 -and -not $ReplacePtr) {
                            $ptrState = 'Skipped'
                            $otherTargets = @(foreach ($ptrRecord in $otherPtrs) { $ptrRecord['Data'] }) -join "', '"
                            $ptrReason = "$entryAddress already has a PTR record for '$otherTargets'. Add -ReplacePtr to replace it with one for '$fqdn'."
                        }
                        if ($ptrState -ne 'Pending') {
                            $otherPtrs = @()
                        }

                        $reversePlanByAddress[$entryAddress] = @{
                            Address     = $entryAddress
                            ReverseName = $reverseName
                            Zone        = $ptrZone
                            NodeName    = $ptrNode
                            NewZone     = $newZone
                            State       = $ptrState
                            Reason      = $ptrReason
                            Existing    = $samePtr
                            OtherPtrs   = $otherPtrs
                        }
                    }
                    if ($null -ne $failure -or $null -ne $lookupFailure) {
                        break
                    }
                }

                # --- 3. The plan, in execution order: zones, forward records, PTR records ---
                $operations = @(
                    foreach ($newZoneName in @($newZones.Keys)) {
                        @{ Kind = 'CreateZone'; State = 'Pending'; ZoneName = $newZoneName; Network = $newZones[$newZoneName] }
                    }
                    if ($kind -eq 'Alias') {
                        @{
                            Kind = 'Add'; State = $aliasState; RRType = 'CNAME'; Address = $null; NewZone = $null; Existing = $aliasExisting; Warning = $aliasWarning; Reason = $null
                            Splat = @{ Action = 'AddCName'; Name = $fqdn; Type = 'CNAME'; Data = $targetName; Zone = $zoneName; NodeName = $nodeName }
                        }
                    }
                    foreach ($forwardPlan in $forwardPlans) {
                        $planNewZone = $null
                        $reversePlan = $reversePlanByAddress[$forwardPlan['Address']]
                        if ($null -ne $reversePlan) {
                            $planNewZone = $reversePlan['NewZone']
                        }
                        @{
                            Kind = 'Add'; State = $forwardPlan['State']; RRType = $forwardPlan['RecordType']; Address = $forwardPlan['Address']; NewZone = $planNewZone
                            Existing = $forwardPlan['Existing']; Warning = $forwardPlan['Warning']; Reason = $null
                            Splat = @{ Action = 'Add' + $forwardPlan['RecordType']; Name = $fqdn; Type = $forwardPlan['RecordType']; Data = $forwardPlan['Address']; Zone = $zoneName; NodeName = $nodeName }
                        }
                    }
                    foreach ($forwardPlan in $forwardPlans) {
                        $reversePlan = $reversePlanByAddress[$forwardPlan['Address']]
                        if ($null -eq $reversePlan) {
                            continue
                        }
                        foreach ($otherPtr in $reversePlan['OtherPtrs']) {
                            @{
                                Kind = 'RemovePtr'; State = 'Pending'; RRType = 'PTR'; Address = $reversePlan['Address']; NewZone = $null; Existing = $otherPtr; Warning = $null; Reason = $null
                                Splat = @{ Action = 'RemovePtr'; Name = $reversePlan['ReverseName']; Type = 'PTR'; Data = $otherPtr['Data']; Zone = $reversePlan['Zone']; NodeName = $reversePlan['NodeName'] }
                            }
                        }
                        @{
                            Kind = 'Add'; State = $reversePlan['State']; RRType = 'PTR'; Address = $reversePlan['Address']; NewZone = $reversePlan['NewZone']
                            Existing = $reversePlan['Existing']; Warning = $null; Reason = $reversePlan['Reason']
                            Splat = @{ Action = 'AddPtr'; Name = $reversePlan['ReverseName']; Type = 'PTR'; Data = $fqdn; Zone = $reversePlan['Zone']; NodeName = $reversePlan['NodeName'] }
                        }
                    }
                )

                # --- 4. One confirmation per item, only when something is to be written ---
                $pending = @(foreach ($operation in $operations) { if ($operation['State'] -eq 'Pending') { $operation } })
                $decision = 'Nothing'
                if ($pending.Count -gt 0) {
                    $addParts = @(
                        foreach ($recordType in @('A', 'AAAA', 'CNAME', 'PTR')) {
                            $typeCount = 0
                            foreach ($operation in $pending) {
                                if ($operation['Kind'] -eq 'Add' -and $operation['RRType'] -eq $recordType) {
                                    $typeCount++
                                }
                            }
                            if ($typeCount -gt 0) {
                                "$typeCount $recordType"
                            }
                        }
                    )
                    $removeCount = @(foreach ($operation in $pending) { if ($operation['Kind'] -eq 'RemovePtr') { $operation } }).Count
                    $gateParts = @(
                        if ($addParts.Count -gt 0) {
                            'add ' + ($addParts -join ', ')
                        }
                        if ($removeCount -gt 0) {
                            "remove $removeCount PTR pointing elsewhere"
                        }
                        if ($newZones.Count -gt 0) {
                            'create reverse zone ' + (@($newZones.Keys) -join ', ')
                        }
                    )
                    $gateTarget = $fqdn + ': ' + ($gateParts -join '; ')

                    # -ErrorAction Stop turns the non-interactive refusal into the one
                    # terminating error that ends the batch (CONTRACTS.md section 5.8).
                    if (Confirm-DnsAction -Target $gateTarget -Action 'Add DNS records' -Impact Medium -State $batch['Confirm'] -Force:$Force -ErrorAction Stop) {
                        $decision = 'Approved'
                    }
                    elseif ($isWhatIf) {
                        $decision = 'WhatIf'
                    }
                    else {
                        $decision = 'Declined'
                    }
                }

                # --- 5. Execute, one Result per sub-operation ---
                $zoneMissing = @{}
                $forwardDone = @{}
                $ptrBlocked = @{}
                foreach ($operation in $operations) {
                    $operationKind = $operation['Kind']
                    $state = $operation['State']
                    $splat = $operation['Splat']
                    $operationAddress = $operation['Address']

                    if ($operationKind -eq 'CreateZone') {
                        $newZoneName = $operation['ZoneName']
                        if ($decision -eq 'Declined') {
                            $zoneMissing[$newZoneName] = "the reverse zone '$newZoneName' was not confirmed"
                            Write-DnsResult -Batch $batch -Action 'CreateZone' -Name $newZoneName -Type $null -Data $operation['Network'] -Zone $newZoneName -NodeName $null -Result 'Skipped' -ErrorMessage $declinedText
                            continue
                        }

                        # Its own confirmation (High), but in this batch: the results
                        # share its BatchId, and an [A]ll at the zone prompt carries to
                        # the next item's zone. Results stream through as they come.
                        $zoneResults = $null
                        $zoneError = $null
                        try {
                            New-DnsLiveReverseZone -Batch $batch -NetworkId $operation['Network'] -CopySettingsFrom $zoneName -ZoneTable $zoneTable -ServerParameter $serverParameter -Credential $Credential -TimeoutSec $TimeoutSec -OutVariable zoneResults
                        }
                        catch {
                            # DnsTools.Confirm.NonInteractive and [S]top end the batch as they are.
                            if (-not ([string]$_.FullyQualifiedErrorId).StartsWith($zoneErrorPrefix)) {
                                throw
                            }
                            $zoneError = $_
                        }

                        $zonePresent = $false
                        foreach ($zoneResult in @($zoneResults)) {
                            if ($null -ne $zoneResult -and $zoneResult.Action -eq 'CreateZone' -and @('Success', 'AlreadyDone', 'WhatIf') -contains $zoneResult.Result) {
                                $zonePresent = $true
                            }
                        }
                        if ($zonePresent) {
                            $reverseZonesInRun[$newZoneName] = $true
                            if (-not $isWhatIf) {
                                # The helper refreshed the cached table.
                                $zoneTable = Get-DnsZoneTable -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec
                            }
                        }
                        else {
                            $zoneMissing[$newZoneName] = "the reverse zone '$newZoneName' was not created"
                        }

                        # The helper's error, after its Result, under this command's
                        # name; only an unreachable server ends the batch.
                        if ($null -ne $zoneError) {
                            $zoneReason = ([string]$zoneError.FullyQualifiedErrorId).Split(',')[0].Substring($zoneErrorPrefix.Length)
                            $ownError = @{
                                Message      = $zoneError.Exception.Message
                                Category     = $zoneError.CategoryInfo.Category
                                ErrorId      = 'DnsTools.New-DnsEntry.' + $zoneReason
                                TargetObject = $zoneError.TargetObject
                            }
                            if ($zoneReason -eq 'ServerUnreachable') {
                                Write-Error @ownError -ErrorAction Stop
                            }
                            Write-Error @ownError
                        }
                        continue
                    }

                    if ($state -eq 'AlreadyDone') {
                        if ($operation['Warning']) {
                            Write-Warning $operation['Warning']
                        }
                        if ($operation['RRType'] -ne 'PTR' -and $operationAddress) {
                            $forwardDone[$operationAddress] = $true
                        }
                        Write-DnsResult -Batch $batch @splat -Result 'AlreadyDone' -Before $operation['Existing']
                        continue
                    }
                    if ($state -eq 'Skipped') {
                        Write-DnsResult -Batch $batch @splat -Result 'Skipped' -ErrorMessage $operation['Reason']
                        continue
                    }
                    if ($decision -eq 'Declined') {
                        Write-DnsResult -Batch $batch @splat -Result 'Skipped' -ErrorMessage $declinedText
                        continue
                    }

                    # Dependencies: no forward record without the zone for its PTR,
                    # no PTR change without the forward record.
                    $blockedReason = $null
                    $recordLabel = "the A record of '$fqdn' for $operationAddress"
                    if ($operationAddress -and $operationAddress.IndexOf(':') -ge 0) {
                        $recordLabel = "the AAAA record of '$fqdn' for $operationAddress"
                    }
                    if ($operation['NewZone'] -and $zoneMissing.ContainsKey($operation['NewZone'])) {
                        $blockedReason = "Not created, because $($zoneMissing[$operation['NewZone']]) and its PTR record would have no zone."
                    }
                    elseif ($operation['RRType'] -eq 'PTR' -and -not $forwardDone.ContainsKey($operationAddress)) {
                        $blockedReason = "Not changed, because $recordLabel was not created."
                    }
                    elseif ($operationKind -eq 'Add' -and $operation['RRType'] -eq 'PTR' -and $ptrBlocked.ContainsKey($operationAddress)) {
                        $blockedReason = $ptrBlocked[$operationAddress]
                    }
                    if ($blockedReason) {
                        Write-DnsResult -Batch $batch @splat -Result 'Skipped' -ErrorMessage $blockedReason
                        continue
                    }

                    if ($decision -eq 'WhatIf') {
                        if ($operation['RRType'] -ne 'PTR' -and $operationAddress) {
                            $forwardDone[$operationAddress] = $true
                        }
                        Write-DnsResult -Batch $batch @splat -Result 'WhatIf'
                        continue
                    }

                    if ($operationKind -eq 'RemovePtr') {
                        $removal = Remove-DnsLiveRecord -ServerParameter $serverParameter -ZoneName $splat['Zone'] -NodeName $splat['NodeName'] -RRType 'PTR' -Data $splat['Data']
                        if ($removal['Removed']) {
                            Write-DnsResult -Batch $batch @splat -Result 'Success' -Before $operation['Existing']
                            continue
                        }
                        if ($removal['AlreadyGone']) {
                            Write-DnsResult -Batch $batch @splat -Result 'AlreadyDone'
                            continue
                        }

                        $ptrBlocked[$operationAddress] = "Not created, because the PTR record of $operationAddress for '$($splat['Data'])' could not be removed."
                        if ([string]$removal['ErrorId'] -like '*9712*') {
                            Write-DnsResult -Batch $batch @splat -Result 'Skipped' -ErrorMessage "Zone '$($splat['Zone'])' is read-only on '$serverKey' (not a primary copy). Change it on the server that hosts the primary zone."
                            continue
                        }
                        Write-DnsResult -Batch $batch @splat -Result 'Failed' -ErrorMessage $removal['Error']
                        if ($removal['Unreachable']) {
                            Write-Error -Message "The DNS server '$serverKey' cannot be reached: $($removal['Error']) The batch was stopped; the remaining items were not processed. Check the server or specify another -Server, then run the command again (records that already exist report AlreadyDone)." -Category ConnectionError -ErrorId 'DnsTools.New-DnsEntry.ServerUnreachable' -TargetObject $splat['Name'] -ErrorAction Stop
                        }
                        Write-Error -Message $removal['Error'] -Category WriteError -ErrorId 'DnsTools.New-DnsEntry.RemoveFailed' -TargetObject $splat['Name']
                        continue
                    }

                    # Add: A, AAAA, CNAME or PTR.
                    $addParameters = @{ ServerParameter = $serverParameter; ZoneName = $splat['Zone']; NodeName = $splat['NodeName']; RRType = $operation['RRType']; Data = $splat['Data'] }
                    if ($null -ne $recordTtl) {
                        $addParameters['Ttl'] = $recordTtl
                    }
                    $outcome = Add-DnsLiveRecord @addParameters

                    if ($outcome['Reason'] -eq 'Added') {
                        if ($operation['RRType'] -ne 'PTR' -and $operationAddress) {
                            $forwardDone[$operationAddress] = $true
                        }
                        Write-DnsResult -Batch $batch @splat -Result 'Success' -After $outcome['Record']
                        continue
                    }
                    if ($outcome['Reason'] -eq 'AlreadyExists') {
                        # Created by someone else since the preflight read the node.
                        $existingRecord = $outcome['Record']
                        if ($operation['RRType'] -ne 'PTR' -and $null -ne $recordTtl -and $null -ne $existingRecord -and $null -ne $existingRecord['Ttl'] -and $existingRecord['Ttl'] -ne $recordTtl) {
                            Write-Warning "'$($splat['Name'])' already has $($splat['Type']) $($splat['Data']), with a TTL of $($existingRecord['Ttl']) s instead of the requested $recordTtl s. Change it with Set-DnsEntry -TTL $recordTtl."
                        }
                        if ($operation['RRType'] -ne 'PTR' -and $operationAddress) {
                            $forwardDone[$operationAddress] = $true
                        }
                        Write-DnsResult -Batch $batch @splat -Result 'AlreadyDone' -Before $existingRecord
                        continue
                    }
                    if ($outcome['Reason'] -eq 'CnameConflict') {
                        # 9708: the node is a CNAME; 9709: a CNAME cannot join a node
                        # that has other records. Both appeared after the preflight.
                        $conflictReason = 'CnameCollision'
                        $conflictMessage = "'$($splat['Name'])' has other records now, so the alias cannot be added: $($outcome['Error'])"
                        if ([string]$outcome['ErrorId'] -like '*9708*') {
                            $conflictReason = 'NodeIsCname'
                            $conflictMessage = "'$($splat['Name'])' is an alias (CNAME) now, so no other record can be added: $($outcome['Error'])"
                        }
                        Write-DnsResult -Batch $batch @splat -Result 'Failed' -ErrorMessage $conflictMessage
                        Write-Error -Message $conflictMessage -Category ResourceExists -ErrorId ('DnsTools.New-DnsEntry.' + $conflictReason) -TargetObject $splat['Name']
                        continue
                    }

                    # Failed.
                    if ([string]$outcome['ErrorId'] -like '*9712*') {
                        Write-DnsResult -Batch $batch @splat -Result 'Skipped' -ErrorMessage "Zone '$($splat['Zone'])' is read-only on '$serverKey' (not a primary copy). Create the record on the server that hosts the primary zone."
                        continue
                    }
                    $addMessage = "Could not create $($splat['Type']) record '$($splat['Name'])' -> '$($splat['Data'])' in zone '$($splat['Zone'])': $($outcome['Error'])"
                    Write-DnsResult -Batch $batch @splat -Result 'Failed' -ErrorMessage $addMessage
                    if ($outcome['Unreachable']) {
                        Write-Error -Message "The DNS server '$serverKey' cannot be reached: $($outcome['Error']) The batch was stopped; the remaining items were not processed. Check the server or specify another -Server, then run the command again (records that already exist report AlreadyDone)." -Category ConnectionError -ErrorId 'DnsTools.New-DnsEntry.ServerUnreachable' -TargetObject $splat['Name'] -ErrorAction Stop
                    }
                    Write-Error -Message $addMessage -Category WriteError -ErrorId 'DnsTools.New-DnsEntry.AddFailed' -TargetObject $splat['Name']
                }
            } while ($false)

            # --- A failed item: one Failed result per requested record, nothing written ---
            if ($null -ne $lookupFailure) {
                $failure = @{ Reason = 'LookupFailed'; Message = $lookupFailure.Exception.Message; Category = $lookupFailure.CategoryInfo.Category; Unreachable = (Test-DnsConnectionError -ErrorRecord $lookupFailure) }
            }
            if ($null -ne $failure) {
                $resultZone = $zoneName
                $resultNode = $nodeName
                $requestedRecords = @(
                    if ($kind -eq 'Alias' -or ($null -eq $kind -and $request['RawTarget'])) {
                        $aliasData = $targetName
                        if (-not $aliasData) {
                            $aliasData = $request['RawTarget']
                        }
                        @{ Action = 'AddCName'; Type = 'CNAME'; Data = $aliasData }
                    }
                    $addressList = $addresses
                    if ($addressList.Count -eq 0 -and $kind -ne 'Alias') {
                        $addressList = @($request['RawAddresses'])
                    }
                    foreach ($addressText in $addressList) {
                        if ([string]$addressText -like '*:*') {
                            @{ Action = 'AddAAAA'; Type = 'AAAA'; Data = $addressText }
                        }
                        else {
                            @{ Action = 'AddA'; Type = 'A'; Data = $addressText }
                        }
                    }
                )
                if ($requestedRecords.Count -eq 0) {
                    $requestedRecords = @(@{ Action = 'AddA'; Type = $null; Data = $null })
                }
                foreach ($requestedRecord in $requestedRecords) {
                    Write-DnsResult -Batch $batch -Action $requestedRecord['Action'] -Name $label -Type $requestedRecord['Type'] -Data $requestedRecord['Data'] -Zone $resultZone -NodeName $resultNode -Result 'Failed' -ErrorMessage $failure['Message']
                }

                if ($failure['Unreachable']) {
                    Write-Error -Message "The DNS server '$serverKey' cannot be reached: $($failure['Message']) The batch was stopped; the remaining items were not processed. Check the server or specify another -Server, then run the command again (records that already exist report AlreadyDone)." -Category ConnectionError -ErrorId 'DnsTools.New-DnsEntry.ServerUnreachable' -TargetObject $label -ErrorAction Stop
                }
                Write-Error -Message $failure['Message'] -Category $failure['Category'] -ErrorId ('DnsTools.New-DnsEntry.' + $failure['Reason']) -TargetObject $label
            }

            if ($Delay -gt 0 -and -not $isWhatIf) {
                Start-Sleep -Seconds $Delay
            }
        }
    }

    end {
        $counts = $batch['Counts']
        $summary = @(
            foreach ($resultName in @('Success', 'AlreadyDone', 'WhatIf', 'Skipped', 'Failed')) {
                '{0} {1}' -f [int]$counts[$resultName], $resultName
            }
        ) -join ', '
        Write-Verbose "New-DnsEntry on '$serverKey' finished: $summary (batch $($batch['BatchId']))."
        if ([int]$counts['Success'] -gt 0) {
            Write-Verbose "The local snapshot does not contain the new records; run Update-DnsSnapshot -Server $serverKey before searching for them with Get-DnsEntry patterns."
        }
    }
}
