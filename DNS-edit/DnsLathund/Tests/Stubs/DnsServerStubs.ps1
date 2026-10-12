<#
.SYNOPSIS
    In-memory stand-ins for the DnsServer cmdlets that DnsLathund calls.

.DESCRIPTION
    Test helper, not part of the module. Defines functions with the names and
    parameters of the DnsServer cmdlets DnsLathund calls, backed by a hashtable
    store in $script:DnsStub:

        phase 1  Get-DnsServerZone, Get-DnsServerZoneAging, Get-DnsServerScavenging,
                 Get-DnsServerResourceRecord (returns copies), Export-DnsServerZone
        phase 2  Add-DnsServerResourceRecordA / AAAA / CName / Ptr,
                 Remove-DnsServerResourceRecord, Set-DnsServerResourceRecord,
                 Add-DnsServerPrimaryZone, Set-DnsServerZoneAging,
                 Get-DnsServerZoneScope, and the CIM cmdlets New-CimSession,
                 Remove-CimSession and Get-CimInstance (root\MicrosoftDNS WQL)

    plus the helpers Reset-DnsStubStore, Add-DnsStubZone and Add-DnsStubRecord.

    Load the file into the module scope so that module code calls the stubs
    without Mock (functions take precedence over the real cmdlets):

        InModuleScope DnsLathund -Parameters @{ StubPath = $stubPath } {
            param ($StubPath)
            . $StubPath
        }

    Every function is declared with the script: scope modifier. InModuleScope
    (and & $module { }) run the script block in a child scope of the module, so
    without the modifier the functions would vanish when the block returns.
    Loading the file resets the store.

    The file is loaded into a Constrained Language Mode runspace by the CLM smoke
    test, so it uses only CLM-legal constructs: New-Object PSObject, hashtables,
    no [PSCustomObject], no generic collections, no [System.IO.*].

    Store layout ($script:DnsStub):

        Zones      [ordered] lower-case zone name -> zone object (Get-DnsServerZone shape)
        Records    @{}       lower-case zone name -> object[] of record objects
        Aging      @{}       lower-case zone name -> aging object (Get-DnsServerZoneAging shape)
        Scavenging           server scavenging object (Get-DnsServerScavenging shape)
        ExportRoot           folder that Export-DnsServerZone writes to
        Fail       @{}       command name -> string[] of zone-name wildcards; a matching
                             call writes an error instead of answering ('*' = every call;
                             server-level commands fail whenever their key exists)
        Calls      @{}       command name -> number of calls (for caching tests)
        CallLog    @{}       command name -> hashtable[] of the bound parameters of every
                             call of a writing stub and of the CIM stubs, in call order
        FailCode   @{}       command name -> Win32 code that an injected failure raises,
                             with the category a real cmdlet uses for it
                             (Get-DnsStubErrorCategory): 5 access denied (PermissionDenied),
                             1722 RPC server unavailable (ConnectionError), or any code below.
                             Default 5 for the writing stubs and Get-DnsServerZoneScope,
                             1722 for Get-DnsServerResourceRecord
        BeforeCall @{}       command name -> script block run at the start of every call of
                             that stub, right after the call is counted, with the call's
                             bound parameters as its only argument ($null for stubs that do
                             not log them), so that a test can change the store between the
                             module's read and its write (another administrator, scavenging)
        ZoneScopes @{}       lower-case zone name -> string[] of extra zone scopes
                             returned by Get-DnsServerZoneScope after the default scope
        CimUnavailable       $true makes New-CimSession fail (WinRM and DCOM), so that
                             Get-DnsCimSession returns $null
        NextId               last record Id handed out

    Stubs for state-changing cmdlets declare SupportsShouldProcess like the real
    cmdlets, so module calls with -WhatIf:$false -Confirm:$false bind, and they
    skip the change when $WhatIfPreference is set ($PSCmdlet.ShouldProcess is not
    available in Constrained Language Mode); the call is still counted and logged.
    -Confirm never prompts.

    Records mimic the CIM instances of the real cmdlets: HostName (relative, '@' at
    the apex), RecordType, RecordClass, RecordData (IPv4Address / IPv6Address as
    [ipaddress], PtrDomainName / HostNameAlias / NameServer / DomainName /
    MailExchange as FQDN with trailing dot), TimeToLive ([timespan]), Timestamp
    ($null for static records), DistinguishedName and Type, plus a stable Id (not
    a real CIM property; module code must not read it) by which the writing stubs
    match -InputObject and -OldInputObject. Get-DnsServerResourceRecord returns
    copies, RecordData included, so two reads give two independent objects (the
    "fetch twice" pattern of Set-DnsLiveRecord) and changing a returned record
    never changes the store.

    Errors carry the Win32 codes of winerror.h (CONTRACTS.md section 13.9) as
    'WIN32 <code>' in the FullyQualifiedErrorId: 9601 zone missing, 9701 record
    missing at a node that still has other records, 9714 name (node) missing,
    9711 record exists, 9708 node is a CNAME, 9709 CNAME collision, 9707 CNAME
    loop, 9712 zone not writable (not a primary), 5 access denied, 1722 RPC
    server unavailable.
#>

function script:Reset-DnsStubStore {
    <#
    .SYNOPSIS
        Empties the stub store.

    .DESCRIPTION
        Replaces $script:DnsStub with an empty store. The export root defaults to
        $script:DnsServerExportRoot when that module variable is visible (the stubs
        are loaded into the module scope), else to a folder under TEMP.

    .PARAMETER ExportRoot
        Folder that Export-DnsServerZone writes to.

    .EXAMPLE
        Reset-DnsStubStore -ExportRoot $TestDrive

        Starts every test with no zones and exports going to TestDrive.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter()]
        [string]$ExportRoot
    )

    if (-not $ExportRoot) {
        $ExportRoot = Get-Variable -Name 'DnsServerExportRoot' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    }
    if (-not $ExportRoot) {
        $ExportRoot = Join-Path -Path $env:TEMP -ChildPath 'DnsLathundStubExport'
    }

    $script:DnsStub = @{
        Zones          = [ordered]@{}
        Records        = @{}
        Aging          = @{}
        Scavenging     = $null
        ExportRoot     = $ExportRoot
        Fail           = @{}
        Calls          = @{}
        CallLog        = @{}
        FailCode       = @{}
        BeforeCall     = @{}
        ZoneScopes     = @{}
        CimUnavailable = $false
        NextId         = 0
    }

    $scavenging = New-Object -TypeName PSObject -Property ([ordered]@{
            NoRefreshInterval  = New-TimeSpan -Days 7
            RefreshInterval    = New-TimeSpan -Days 7
            ScavengingInterval = New-TimeSpan -Days 7
            ScavengingState    = $true
            LastScavengeTime   = (Get-Date).Date.AddDays(-1)
        })
    Add-Member -InputObject $scavenging -TypeName 'Microsoft.Management.Infrastructure.CimInstance#root/Microsoft/Windows/DNS/DnsServerScavenging'
    $script:DnsStub.Scavenging = $scavenging
}

function script:Register-DnsStubCall {
    <#
    .SYNOPSIS
        Counts a stub call and reports whether it is set up to fail.

    .DESCRIPTION
        Increments $script:DnsStub.Calls[<Command>] and returns $true when
        $script:DnsStub.Fail has an entry for the command whose wildcard list
        matches the zone (or, for server-level commands, when any entry exists).
        With -BoundParameters, a copy of them is appended to
        $script:DnsStub.CallLog[<Command>], so tests can assert on exactly which
        parameters module code passed. Then runs $script:DnsStub.BeforeCall[<Command>]
        with -BoundParameters as its argument when a test has set one.

    .PARAMETER Command
        The stubbed command name.

    .PARAMETER ZoneName
        The zone the call is about; empty for server-level commands.

    .PARAMETER BoundParameters
        The stub's $PSBoundParameters, to be recorded in the call log.

    .EXAMPLE
        if (Register-DnsStubCall -Command 'Get-DnsServerZoneAging' -ZoneName $Name) { ... }

        Counts the call and tells the stub whether to fail.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter()]
        [string]$ZoneName = '',

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary]$BoundParameters
    )

    $script:DnsStub.Calls[$Command] = 1 + [int]$script:DnsStub.Calls[$Command]

    if ($null -ne $BoundParameters) {
        $entry = @{}
        foreach ($key in @($BoundParameters.Keys)) {
            $entry[$key] = $BoundParameters[$key]
        }
        if ($null -eq $script:DnsStub.CallLog[$Command]) {
            $script:DnsStub.CallLog[$Command] = @()
        }
        $script:DnsStub.CallLog[$Command] = @($script:DnsStub.CallLog[$Command]) + @($entry)
    }

    # Runs before the stub looks at the store, so the call sees whatever the hook
    # changed, exactly like a write that races another administrator.
    $hook = $script:DnsStub.BeforeCall[$Command]
    if ($null -ne $hook) {
        $null = & $hook $BoundParameters
    }

    if (-not $script:DnsStub.Fail.ContainsKey($Command)) {
        return $false
    }

    if (-not $ZoneName) {
        return $true
    }

    foreach ($pattern in @($script:DnsStub.Fail[$Command])) {
        if ($ZoneName -like $pattern) {
            return $true
        }
    }

    return $false
}

function script:ConvertTo-DnsStubNodeName {
    <#
    .SYNOPSIS
        Returns the node name of a record name relative to a zone ('@' at the apex).

    .DESCRIPTION
        Accepts relative names, '@', '' and FQDNs inside the zone (with or without
        the trailing dot), like the real cmdlets.

    .PARAMETER Name
        The record name.

    .PARAMETER ZoneName
        The zone.

    .EXAMPLE
        ConvertTo-DnsStubNodeName -Name 'srv01.contoso.local.' -ZoneName 'contoso.local'

        Returns 'srv01'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$ZoneName
    )

    $zone = $ZoneName.TrimEnd('.')
    $node = $Name.Trim()
    if (-not $node -or $node -eq '@' -or $node.TrimEnd('.') -eq $zone) {
        return '@'
    }

    $node = $node.TrimEnd('.')
    $zoneSuffix = '.' + $zone
    if ($node.EndsWith($zoneSuffix, 'OrdinalIgnoreCase')) {
        $node = $node.Substring(0, $node.Length - $zoneSuffix.Length)
    }

    $node
}

function script:Add-DnsStubZone {
    <#
    .SYNOPSIS
        Adds a zone to the stub store.

    .DESCRIPTION
        Creates an object shaped like Get-DnsServerZone output and its aging
        settings. IsReverseLookupZone follows the name (in-addr.arpa / ip6.arpa).
        Forwarder and Stub zones have no DynamicUpdate property, as on a real
        server, so that callers have to read it defensively.

    .PARAMETER Name
        The zone name.

    .PARAMETER ZoneType
        Primary, Secondary, Stub or Forwarder.

    .PARAMETER IsDsIntegrated
        Whether the zone is stored in Active Directory.

    .PARAMETER ReplicationScope
        Domain, Forest, Legacy or Custom; ignored when not DS-integrated.

    .PARAMETER DirectoryPartitionName
        The AD partition; ignored when not DS-integrated.

    .PARAMETER DynamicUpdate
        None, Secure or NonsecureAndSecure.

    .PARAMETER IsAutoCreated
        The zone was created by the server (0, 127 and 255.in-addr.arpa).

    .PARAMETER AgingEnabled
        Aging setting returned by Get-DnsServerZoneAging.

    .PARAMETER NoRefreshInterval
        Aging setting returned by Get-DnsServerZoneAging.

    .PARAMETER RefreshInterval
        Aging setting returned by Get-DnsServerZoneAging.

    .PARAMETER ScavengeServers
        Aging setting returned by Get-DnsServerZoneAging.

    .PARAMETER PrimaryServer
        The name written into the SOA record of an export.

    .PARAMETER PassThru
        Return the zone object.

    .EXAMPLE
        Add-DnsStubZone -Name 'contoso.local' -AgingEnabled $true

        Adds an AD-integrated primary zone with aging enabled.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter()]
        [ValidateSet('Primary', 'Secondary', 'Stub', 'Forwarder')]
        [string]$ZoneType = 'Primary',

        [Parameter()]
        [bool]$IsDsIntegrated = $true,

        [Parameter()]
        [string]$ReplicationScope = 'Domain',

        [Parameter()]
        [string]$DirectoryPartitionName = 'DomainDnsZones.contoso.local',

        [Parameter()]
        [string]$DynamicUpdate = 'Secure',

        [Parameter()]
        [switch]$IsAutoCreated,

        [Parameter()]
        [bool]$AgingEnabled = $false,

        [Parameter()]
        [timespan]$NoRefreshInterval = (New-TimeSpan -Days 7),

        [Parameter()]
        [timespan]$RefreshInterval = (New-TimeSpan -Days 7),

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$ScavengeServers = @(),

        [Parameter()]
        [string]$PrimaryServer = 'dc01.contoso.local',

        [Parameter()]
        [switch]$PassThru
    )

    $zoneName = $Name.TrimEnd('.')
    $zoneKey = $zoneName.ToLowerInvariant()
    $isReverse = $zoneKey.EndsWith('.in-addr.arpa') -or $zoneKey.EndsWith('.ip6.arpa')

    $scope = $null
    $partition = $null
    if ($IsDsIntegrated) {
        $scope = $ReplicationScope
        $partition = $DirectoryPartitionName
    }

    $properties = [ordered]@{
        ZoneName               = $zoneName
        ZoneType               = $ZoneType
        IsAutoCreated          = [bool]$IsAutoCreated
        IsDsIntegrated         = $IsDsIntegrated
        IsReverseLookupZone    = $isReverse
        IsSigned               = $false
        IsPaused               = $false
        IsShutdown             = $false
        ReplicationScope       = $scope
        DirectoryPartitionName = $partition
        ZoneFile               = $null
        PrimaryServer          = $PrimaryServer
    }
    if ($ZoneType -eq 'Primary' -or $ZoneType -eq 'Secondary') {
        $properties['DynamicUpdate'] = $DynamicUpdate
    }
    if (-not $IsDsIntegrated) {
        $properties['ZoneFile'] = $zoneName + '.dns'
    }

    $cimClass = 'DnsServerPrimaryZone'
    if ($ZoneType -eq 'Secondary') {
        $cimClass = 'DnsServerSecondaryZone'
    }
    elseif ($ZoneType -eq 'Stub') {
        $cimClass = 'DnsServerStubZone'
    }
    elseif ($ZoneType -eq 'Forwarder') {
        $cimClass = 'DnsServerConditionalForwarderZone'
    }

    $zone = New-Object -TypeName PSObject -Property $properties
    Add-Member -InputObject $zone -TypeName ('Microsoft.Management.Infrastructure.CimInstance#root/Microsoft/Windows/DNS/' + $cimClass)

    $aging = New-Object -TypeName PSObject -Property ([ordered]@{
            ZoneName             = $zoneName
            AgingEnabled         = $AgingEnabled
            AvailForScavengeTime = $null
            RefreshInterval      = $RefreshInterval
            NoRefreshInterval    = $NoRefreshInterval
            ScavengeServers      = $ScavengeServers
        })
    Add-Member -InputObject $aging -TypeName 'Microsoft.Management.Infrastructure.CimInstance#root/Microsoft/Windows/DNS/DnsServerZoneAging'

    $script:DnsStub.Zones[$zoneKey] = $zone
    $script:DnsStub.Records[$zoneKey] = @()
    $script:DnsStub.Aging[$zoneKey] = $aging

    if ($PassThru) {
        $zone
    }
}

function script:Add-DnsStubRecord {
    <#
    .SYNOPSIS
        Adds a resource record to a stub zone.

    .DESCRIPTION
        Creates an object shaped like a Get-DnsServerResourceRecord CIM instance
        and appends it to the zone. FQDN data (CNAME, PTR, NS, MX, SRV targets) gets
        a trailing dot like on a real server.

    .PARAMETER ZoneName
        The zone; it must have been added with Add-DnsStubZone.

    .PARAMETER Name
        The node name relative to the zone ('@' for the apex) or an FQDN inside it.

    .PARAMETER RRType
        A, AAAA, CNAME, PTR, NS, MX, SRV, DHCID or TXT.

    .PARAMETER Data
        The address, target name, DHCID base64 string or text.

    .PARAMETER TimeToLive
        TTL in seconds.

    .PARAMETER Timestamp
        Aging timestamp; $null (the default) makes the record static.

    .PARAMETER AgeHours
        Aging timestamp as hours since 1601-01-01 UTC, as in an [AGE:n] export
        field. Overrides -Timestamp.

    .PARAMETER Priority
        SRV priority.

    .PARAMETER Weight
        SRV weight.

    .PARAMETER Port
        SRV port.

    .PARAMETER Preference
        MX preference.

    .PARAMETER PassThru
        Return the record object.

    .EXAMPLE
        Add-DnsStubRecord -ZoneName 'contoso.local' -Name 'srv01' -RRType A -Data '10.0.16.20' -AgeHours 3636304

        Adds a dynamic A record.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ZoneName,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('A', 'AAAA', 'CNAME', 'PTR', 'NS', 'MX', 'SRV', 'DHCID', 'TXT')]
        [string]$RRType,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Data,

        [Parameter()]
        [int]$TimeToLive = 3600,

        [Parameter()]
        [AllowNull()]
        [object]$Timestamp = $null,

        [Parameter()]
        [int]$AgeHours = -1,

        [Parameter()]
        [int]$Priority = 0,

        [Parameter()]
        [int]$Weight = 100,

        [Parameter()]
        [int]$Port = 389,

        [Parameter()]
        [int]$Preference = 10,

        [Parameter()]
        [switch]$PassThru
    )

    $zoneKey = $ZoneName.TrimEnd('.').ToLowerInvariant()
    if ($null -eq $script:DnsStub.Zones[$zoneKey]) {
        throw "Stub zone '$ZoneName' does not exist. Call Add-DnsStubZone first."
    }

    $recordType = $RRType.ToUpperInvariant()
    $nodeName = ConvertTo-DnsStubNodeName -Name $Name -ZoneName $script:DnsStub.Zones[$zoneKey].ZoneName

    $target = $Data
    if (-not $target.EndsWith('.')) {
        $target = $target + '.'
    }

    switch ($recordType) {
        'A' { $recordData = [ordered]@{ IPv4Address = [ipaddress]$Data }; $typeNumber = 1 }
        'AAAA' { $recordData = [ordered]@{ IPv6Address = [ipaddress]$Data }; $typeNumber = 28 }
        'CNAME' { $recordData = [ordered]@{ HostNameAlias = $target }; $typeNumber = 5 }
        'PTR' { $recordData = [ordered]@{ PtrDomainName = $target }; $typeNumber = 12 }
        'NS' { $recordData = [ordered]@{ NameServer = $target }; $typeNumber = 2 }
        'MX' { $recordData = [ordered]@{ MailExchange = $target; Preference = $Preference }; $typeNumber = 15 }
        'SRV' { $recordData = [ordered]@{ DomainName = $target; Port = $Port; Priority = $Priority; Weight = $Weight }; $typeNumber = 33 }
        'DHCID' { $recordData = [ordered]@{ DHCID = $Data }; $typeNumber = 49 }
        'TXT' { $recordData = [ordered]@{ DescriptiveText = $Data }; $typeNumber = 16 }
    }

    $recordDataObject = New-Object -TypeName PSObject -Property $recordData
    Add-Member -InputObject $recordDataObject -TypeName ('Microsoft.Management.Infrastructure.CimInstance#root/Microsoft/Windows/DNS/DnsServerResourceRecord' + $recordType)

    $recordTimestamp = $null
    if ($AgeHours -ge 0) {
        $recordTimestamp = [datetime]::FromFileTimeUtc(0).AddHours($AgeHours).ToLocalTime()
    }
    elseif ($null -ne $Timestamp) {
        $recordTimestamp = [datetime]$Timestamp
    }

    $zoneLabels = $script:DnsStub.Zones[$zoneKey].ZoneName.Split('.')
    $zoneDn = 'DC=' + ($zoneLabels -join ',DC=')
    $script:DnsStub.NextId = 1 + [int]$script:DnsStub.NextId
    $record = New-Object -TypeName PSObject -Property ([ordered]@{
            DistinguishedName = 'DC={0},DC={1},cn=MicrosoftDNS,DC=DomainDnsZones,{2}' -f $nodeName, $script:DnsStub.Zones[$zoneKey].ZoneName, $zoneDn
            HostName          = $nodeName
            RecordClass       = 'IN'
            RecordData        = $recordDataObject
            RecordType        = $recordType
            Timestamp         = $recordTimestamp
            TimeToLive        = New-TimeSpan -Seconds $TimeToLive
            Type              = $typeNumber
            Id                = 'stub-rr-' + $script:DnsStub.NextId
        })
    Add-Member -InputObject $record -TypeName 'Microsoft.Management.Infrastructure.CimInstance#root/Microsoft/Windows/DNS/DnsServerResourceRecord'

    $script:DnsStub.Records[$zoneKey] = @($script:DnsStub.Records[$zoneKey]) + @($record)

    if ($PassThru) {
        $record
    }
}

function script:Get-DnsServerZone {
    <#
    .SYNOPSIS
        Stub for Get-DnsServerZone.

    .DESCRIPTION
        Returns every stub zone in insertion order, or the named zone. An unknown
        zone writes an ObjectNotFound error like the real cmdlet.

    .PARAMETER Name
        Zone name.

    .PARAMETER ComputerName
        Server name; used in error messages only.

    .PARAMETER CimSession
        CIM session; accepted and ignored.

    .EXAMPLE
        Get-DnsServerZone -ComputerName 'dc01'

        Returns all stub zones.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param (
        [Parameter(Position = 0)]
        [string]$Name,

        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [object]$CimSession
    )

    $serverName = 'localhost'
    if ($ComputerName) {
        $serverName = $ComputerName
    }
    elseif ($null -ne $CimSession) {
        $serverName = 'cimsession'
    }

    if (Register-DnsStubCall -Command 'Get-DnsServerZone' -ZoneName ([string]$Name)) {
        Write-Error -Message "Stub failure: could not enumerate zones on server $serverName." -Category ConnectionError -ErrorId 'WIN32 1722,Get-DnsServerZone'
        return
    }

    if (-not $Name) {
        foreach ($zone in $script:DnsStub.Zones.Values) {
            $zone
        }
        return
    }

    $zone = $script:DnsStub.Zones[$Name.TrimEnd('.').ToLowerInvariant()]
    if ($null -eq $zone) {
        Write-Error -Message "The zone $Name was not found on server $serverName." -Category ObjectNotFound -ErrorId 'WIN32 9601,Get-DnsServerZone' -TargetObject $Name
        return
    }

    $zone
}

function script:Get-DnsServerZoneAging {
    <#
    .SYNOPSIS
        Stub for Get-DnsServerZoneAging.

    .DESCRIPTION
        Returns the aging settings stored by Add-DnsStubZone.

    .PARAMETER Name
        Zone name.

    .PARAMETER ComputerName
        Server name; used in error messages only.

    .PARAMETER CimSession
        CIM session; accepted and ignored.

    .EXAMPLE
        Get-DnsServerZoneAging -Name 'contoso.local'

        Returns the aging settings of contoso.local.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [object]$CimSession
    )

    $serverName = 'localhost'
    if ($ComputerName) {
        $serverName = $ComputerName
    }
    elseif ($null -ne $CimSession) {
        $serverName = 'cimsession'
    }

    $zoneKey = $Name.TrimEnd('.').ToLowerInvariant()
    if (Register-DnsStubCall -Command 'Get-DnsServerZoneAging' -ZoneName $zoneKey) {
        Write-Error -Message "Stub failure: could not read aging of zone $Name on server $serverName." -Category PermissionDenied -ErrorId 'WIN32 5,Get-DnsServerZoneAging' -TargetObject $Name
        return
    }

    $aging = $script:DnsStub.Aging[$zoneKey]
    if ($null -eq $aging) {
        Write-Error -Message "The zone $Name was not found on server $serverName." -Category ObjectNotFound -ErrorId 'WIN32 9601,Get-DnsServerZoneAging' -TargetObject $Name
        return
    }

    $aging
}

function script:Get-DnsServerScavenging {
    <#
    .SYNOPSIS
        Stub for Get-DnsServerScavenging.

    .DESCRIPTION
        Returns the server scavenging settings from the store.

    .PARAMETER ComputerName
        Server name; used in error messages only.

    .PARAMETER CimSession
        CIM session; accepted and ignored.

    .EXAMPLE
        Get-DnsServerScavenging -ComputerName 'dc01'

        Returns the scavenging settings.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param (
        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [object]$CimSession
    )

    $serverName = 'localhost'
    if ($ComputerName) {
        $serverName = $ComputerName
    }
    elseif ($null -ne $CimSession) {
        $serverName = 'cimsession'
    }

    if (Register-DnsStubCall -Command 'Get-DnsServerScavenging') {
        Write-Error -Message "Stub failure: could not read scavenging settings on server $serverName." -Category PermissionDenied -ErrorId 'WIN32 5,Get-DnsServerScavenging'
        return
    }

    $script:DnsStub.Scavenging
}

function script:Get-DnsServerResourceRecord {
    <#
    .SYNOPSIS
        Stub for Get-DnsServerResourceRecord.

    .DESCRIPTION
        Without -Name returns every record of the zone. With -Name returns the
        records at that node and at every node below it, like the real cmdlet; with
        -Node as well, only the records at the node itself. A name with no records
        at or below it writes an ObjectNotFound error (WIN32 9714) like the real
        cmdlet; a node that exists but has no record of -RRType returns nothing.
        Fails when $script:DnsStub.Fail matches the zone, with the Win32 code from
        FailCode (default 1722, ConnectionError).

    .PARAMETER ZoneName
        Zone name.

    .PARAMETER Name
        Node name relative to the zone ('@' for the apex) or an FQDN inside it.

    .PARAMETER Node
        Return only the records at the node itself.

    .PARAMETER RRType
        Record type filter.

    .PARAMETER ComputerName
        Server name; used in error messages only.

    .PARAMETER CimSession
        CIM session; accepted and ignored.

    .EXAMPLE
        Get-DnsServerResourceRecord -ZoneName 'contoso.local' -Name 'srv01' -Node -RRType A

        Returns the A records of srv01.contoso.local.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$ZoneName,

        [Parameter(Position = 1)]
        [string]$Name,

        [Parameter()]
        [switch]$Node,

        [Parameter()]
        [string]$RRType,

        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [object]$CimSession
    )

    $serverName = 'localhost'
    if ($ComputerName) {
        $serverName = $ComputerName
    }
    elseif ($null -ne $CimSession) {
        $serverName = 'cimsession'
    }

    $zoneKey = $ZoneName.TrimEnd('.').ToLowerInvariant()
    if (Register-DnsStubCall -Command 'Get-DnsServerResourceRecord' -ZoneName $zoneKey) {
        # 1722 unless a test picks another code: the tests written before FailCode
        # existed rely on an unreachable server here.
        $code = 1722
        if ($null -ne $script:DnsStub.FailCode['Get-DnsServerResourceRecord']) {
            $code = [int]$script:DnsStub.FailCode['Get-DnsServerResourceRecord']
        }
        Write-Error -Message "Stub failure: could not read records of zone $ZoneName on server $serverName." -Category (Get-DnsStubErrorCategory -Code $code) -ErrorId "WIN32 $code,Get-DnsServerResourceRecord" -TargetObject $ZoneName
        return
    }

    $zone = $script:DnsStub.Zones[$zoneKey]
    if ($null -eq $zone) {
        Write-Error -Message "Failed to get the zone information for $ZoneName on server $serverName." -Category ObjectNotFound -ErrorId 'WIN32 9601,Get-DnsServerResourceRecord' -TargetObject $ZoneName
        return
    }

    $records = @($script:DnsStub.Records[$zoneKey])

    if ($Name) {
        $nodeName = (ConvertTo-DnsStubNodeName -Name $Name -ZoneName $zone.ZoneName).ToLowerInvariant()
        $childSuffix = '.' + $nodeName
        $records = @(
            foreach ($record in $records) {
                $hostName = $record.HostName.ToLowerInvariant()
                if ($hostName -eq $nodeName) {
                    $record
                }
                elseif (-not $Node -and ($nodeName -eq '@' -or $hostName.EndsWith($childSuffix))) {
                    $record
                }
            }
        )

        if ($records.Count -eq 0) {
            Write-Error -Message "Failed to get $Name record in $ZoneName zone on $serverName server." -Category ObjectNotFound -ErrorId 'WIN32 9714,Get-DnsServerResourceRecord' -TargetObject $Name
            return
        }
    }

    # Copies, like the real cmdlet that returns new CIM instances on every call:
    # changing a returned record must not change the store.
    foreach ($record in $records) {
        if (-not $RRType -or $record.RecordType -eq $RRType) {
            Copy-DnsStubRecord -Record $record
        }
    }
}

function script:Export-DnsServerZone {
    <#
    .SYNOPSIS
        Stub for Export-DnsServerZone.

    .DESCRIPTION
        Writes the zone in the Windows zone-file export grammar (CONTRACTS.md
        section 9.2) to Join-Path $script:DnsStub.ExportRoot $FileName: comment
        header, SOA spanning lines in parentheses, apex NS records, $ORIGIN, then
        the records with [AGE:n] for dynamic records, a TTL column when the TTL
        differs from the 3600 s default, continuation lines (no owner) for further
        records at the same node and \040 for spaces in names (Windows writes \DDD
        escapes in octal: \040 is a space).

        Like the real cmdlet it refuses to overwrite an existing file and refuses
        auto-created zones. The file is written with Set-Content -Encoding UTF8,
        so Windows PowerShell adds a BOM that a real export does not have.

        Like the real cmdlet it declares SupportsShouldProcess, so callers can pass
        -WhatIf:$false -Confirm:$false (CONTRACTS.md section 3). When
        $WhatIfPreference is set (-WhatIf, or inherited from a caller) the call is
        counted but nothing is written and no error is raised. $PSCmdlet.ShouldProcess
        is not used because the stubs are loaded into a Constrained Language Mode
        runspace; -Confirm never prompts. Every future stub for a state-changing
        DnsServer cmdlet (Add-/Remove-/Set-DnsServerResourceRecord*) must follow the
        same pattern.

    .PARAMETER Name
        Zone name.

    .PARAMETER FileName
        File name relative to the export root.

    .PARAMETER ComputerName
        Server name; used in error messages only.

    .PARAMETER CimSession
        CIM session; accepted and ignored.

    .EXAMPLE
        Export-DnsServerZone -Name 'contoso.local' -FileName 'contoso.local.export'

        Writes the stub zone to the export root.

    .EXAMPLE
        Export-DnsServerZone -Name 'contoso.local' -FileName 'contoso.local.export' -WhatIf

        Counts the call and writes nothing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [Parameter(Mandatory, Position = 1)]
        [string]$FileName,

        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [object]$CimSession
    )

    $serverName = 'localhost'
    if ($ComputerName) {
        $serverName = $ComputerName
    }
    elseif ($null -ne $CimSession) {
        $serverName = 'cimsession'
    }

    $zoneKey = $Name.TrimEnd('.').ToLowerInvariant()
    $shouldFail = Register-DnsStubCall -Command 'Export-DnsServerZone' -ZoneName $zoneKey

    # The real cmdlet decides on ShouldProcess before it contacts the server, so a
    # WhatIf call neither writes nor fails.
    if ($WhatIfPreference) {
        Write-Verbose "What if: Export-DnsServerZone would export zone $Name to file $FileName on server $serverName."
        return
    }

    if ($shouldFail) {
        Write-Error -Message "Stub failure: failed to export zone $Name on server $serverName." -Category WriteError -ErrorId 'WIN32 5,Export-DnsServerZone' -TargetObject $Name
        return
    }

    $zone = $script:DnsStub.Zones[$zoneKey]
    if ($null -eq $zone) {
        Write-Error -Message "The zone $Name was not found on server $serverName." -Category ObjectNotFound -ErrorId 'WIN32 9601,Export-DnsServerZone' -TargetObject $Name
        return
    }

    if ($zone.IsAutoCreated) {
        Write-Error -Message "Failed to export zone $Name on server $serverName. The zone is auto-created and cannot be exported." -Category InvalidOperation -ErrorId 'WIN32 9611,Export-DnsServerZone' -TargetObject $Name
        return
    }

    $exportRoot = $script:DnsStub.ExportRoot
    $path = Join-Path -Path $exportRoot -ChildPath $FileName
    if (Test-Path -LiteralPath $path) {
        Write-Error -Message "Failed to export zone $Name to file $FileName on server $serverName. The file already exists." -Category ResourceExists -ErrorId 'WIN32 80,Export-DnsServerZone' -TargetObject $path
        return
    }

    if (-not (Test-Path -LiteralPath $exportRoot -PathType Container)) {
        $null = New-Item -Path $exportRoot -ItemType Directory -Force -WhatIf:$false -Confirm:$false
    }

    $zoneName = $zone.ZoneName
    $defaultTtl = 3600
    $fileTimeEpoch = [datetime]::FromFileTimeUtc(0)
    $ticksPerHour = 36000000000

    $records = @($script:DnsStub.Records[$zoneKey])
    $apexNs = @(foreach ($record in $records) { if ($record.HostName -eq '@' -and $record.RecordType -eq 'NS') { $record } })
    $others = @(foreach ($record in $records) { if (-not ($record.HostName -eq '@' -and $record.RecordType -eq 'NS')) { $record } })

    $header = @(
        ';'
        ";  Database file $FileName for $zoneName zone."
        ';      Zone version:  1'
        ';'
        ''
        ('@                       IN  SOA {0}. hostmaster.{1}. (' -f $zone.PrimaryServer.TrimEnd('.'), $zoneName)
        "`t`t`t  `t`t1            ; serial number"
        "`t`t`t  `t`t900          ; refresh"
        "`t`t`t  `t`t600          ; retry"
        "`t`t`t  `t`t86400        ; expire"
        "`t`t`t  `t`t3600       ) ; default TTL"
        ''
        ';'
        ';  Zone NS records'
        ';'
        ''
    )

    $nsLines = foreach ($record in $apexNs) {
        "@`t`t`tNS`t" + $record.RecordData.NameServer
    }

    $recordHeader = @(
        ''
        ';'
        ';  Zone records'
        ';'
        ''
        ('$ORIGIN ' + $zoneName + '.')
    )

    $groups = @($others | Group-Object -Property HostName)
    $recordLines = foreach ($group in $groups) {
        $owner = $group.Name.Replace(' ', '\040')
        $isFirst = $true
        foreach ($record in $group.Group) {
            $ownerColumn = ''
            if ($isFirst) {
                $ownerColumn = $owner
                $isFirst = $false
            }

            $ageColumn = ''
            if ($null -ne $record.Timestamp) {
                $sinceEpoch = $record.Timestamp.ToUniversalTime() - $fileTimeEpoch
                $hours = ($sinceEpoch.Ticks - ($sinceEpoch.Ticks % $ticksPerHour)) / $ticksPerHour
                $ageColumn = "`t[AGE:$hours]"
            }

            $ttlSeconds = [int]$record.TimeToLive.TotalSeconds
            $ttlColumn = ''
            if ($ttlSeconds -ne $defaultTtl) {
                $ttlColumn = "`t$ttlSeconds"
            }

            $recordData = $record.RecordData
            switch ($record.RecordType) {
                'A' { $dataColumn = $recordData.IPv4Address.IPAddressToString }
                'AAAA' { $dataColumn = $recordData.IPv6Address.IPAddressToString }
                'CNAME' { $dataColumn = $recordData.HostNameAlias }
                'PTR' { $dataColumn = $recordData.PtrDomainName }
                'NS' { $dataColumn = $recordData.NameServer }
                'MX' { $dataColumn = '{0} {1}' -f $recordData.Preference, $recordData.MailExchange }
                'SRV' { $dataColumn = '{0} {1} {2} {3}' -f $recordData.Priority, $recordData.Weight, $recordData.Port, $recordData.DomainName }
                'DHCID' { $dataColumn = $recordData.DHCID }
                'TXT' { $dataColumn = '"' + $recordData.DescriptiveText + '"' }
                default { $dataColumn = '' }
            }

            '{0}{1}{2}{3}{4}{5}{6}' -f $ownerColumn, $ageColumn, $ttlColumn, "`t", $record.RecordType, "`t", $dataColumn
        }
    }

    $lines = @($header) + @($nsLines) + @($recordHeader) + @($recordLines) + @('')
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8 -WhatIf:$false -Confirm:$false
}

function script:Copy-DnsStubRecord {
    <#
    .SYNOPSIS
        Returns an independent copy of a stub record, RecordData included.

    .DESCRIPTION
        The real Get-DnsServerResourceRecord returns new CIM instances on every
        call. Module code relies on that: Set-DnsLiveRecord reads a record twice
        and changes only the second copy. A shallow copy would share RecordData,
        so the nested object is copied as well. Type names are kept.

    .PARAMETER Record
        The record to copy.

    .EXAMPLE
        $copy = Copy-DnsStubRecord -Record $record

        Returns a copy that can be changed without touching $record.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory)]
        [object]$Record
    )

    $dataProperties = [ordered]@{}
    $dataTypeName = $null
    $recordData = $null
    if ($null -ne $Record.PSObject.Properties['RecordData']) {
        $recordData = $Record.RecordData
    }
    if ($null -ne $recordData) {
        foreach ($property in $recordData.PSObject.Properties) {
            $dataProperties[$property.Name] = $property.Value
        }
        $dataTypeName = [string]$recordData.PSObject.TypeNames[0]
    }
    $dataCopy = New-Object -TypeName PSObject -Property $dataProperties
    if ($dataTypeName -like 'Microsoft.Management.Infrastructure.CimInstance#*') {
        Add-Member -InputObject $dataCopy -TypeName $dataTypeName
    }

    $properties = [ordered]@{}
    foreach ($property in $Record.PSObject.Properties) {
        $properties[$property.Name] = $property.Value
    }
    $properties['RecordData'] = $dataCopy

    $copy = New-Object -TypeName PSObject -Property $properties
    Add-Member -InputObject $copy -TypeName 'Microsoft.Management.Infrastructure.CimInstance#root/Microsoft/Windows/DNS/DnsServerResourceRecord'
    $copy
}

function script:Get-DnsStubRecordValue {
    <#
    .SYNOPSIS
        Returns the data of a stub record in comparable form.

    .DESCRIPTION
        Addresses in canonical text form, names in lower case without the trailing
        dot, DHCID and TXT as they are. Works for stored records and for records
        that module code changed (an address set as a string).

    .PARAMETER Record
        The record.

    .EXAMPLE
        Get-DnsStubRecordValue -Record $record

        Returns for example '10.0.16.20' or 'srv01.contoso.local'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [object]$Record
    )

    $propertyByType = @{
        A     = 'IPv4Address'
        AAAA  = 'IPv6Address'
        CNAME = 'HostNameAlias'
        PTR   = 'PtrDomainName'
        NS    = 'NameServer'
        MX    = 'MailExchange'
        SRV   = 'DomainName'
        DHCID = 'DHCID'
        TXT   = 'DescriptiveText'
    }
    $recordType = ([string]$Record.RecordType).ToUpperInvariant()
    $propertyName = $propertyByType[$recordType]
    if ($null -eq $propertyName -or $null -eq $Record.RecordData) {
        return $null
    }
    $property = $Record.RecordData.PSObject.Properties[$propertyName]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $null
    }

    $value = [string]$property.Value
    if ($recordType -eq 'A' -or $recordType -eq 'AAAA') {
        try {
            return ([ipaddress]$value).IPAddressToString.ToLowerInvariant()
        }
        catch {
            return $value
        }
    }
    if ($recordType -eq 'DHCID' -or $recordType -eq 'TXT') {
        return $value
    }
    $value.Trim().TrimEnd('.').ToLowerInvariant()
}

function script:Get-DnsStubErrorCategory {
    <#
    .SYNOPSIS
        Returns the error category a real DnsServer cmdlet uses for a Win32 code.

    .DESCRIPTION
        Keeps the categories of the stub errors consistent, so module code that
        looks at the category (ObjectNotFound means "no record") sees what the real
        cmdlets report.

    .PARAMETER Code
        The Win32 error code.

    .EXAMPLE
        Get-DnsStubErrorCategory -Code 9714

        Returns 'ObjectNotFound'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [int]$Code
    )

    switch ($Code) {
        5 { return 'PermissionDenied' }
        87 { return 'InvalidArgument' }
        1722 { return 'ConnectionError' }
        9601 { return 'ObjectNotFound' }
        9609 { return 'ResourceExists' }
        9701 { return 'ObjectNotFound' }
        9711 { return 'ResourceExists' }
        9712 { return 'InvalidOperation' }
        9714 { return 'ObjectNotFound' }
    }
    'InvalidOperation'
}

function script:Test-DnsStubNode {
    <#
    .SYNOPSIS
        Tells whether a zone in the stub store has any record at a node.

    .DESCRIPTION
        winerror.h tells a missing record (9701) from a missing name (9714). The
        writing stubs use this helper to pick the code for a record that is not
        there: 9701 while its node still holds other records, 9714 once the node
        itself is gone.

    .PARAMETER ZoneKey
        The lower-case zone name.

    .PARAMETER NodeName
        The node name relative to the zone ('@' for the apex).

    .EXAMPLE
        Test-DnsStubNode -ZoneKey 'contoso.local' -NodeName 'srv01'

        Returns $true while srv01 has at least one record.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [string]$ZoneKey,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$NodeName
    )

    $nodeKey = $NodeName.ToLowerInvariant()
    foreach ($record in @($script:DnsStub.Records[$ZoneKey])) {
        if ($null -ne $record -and $record.HostName.ToLowerInvariant() -eq $nodeKey) {
            return $true
        }
    }
    $false
}

function script:Find-DnsStubRecord {
    <#
    .SYNOPSIS
        Finds the stored record that an -InputObject or -OldInputObject stands for.

    .DESCRIPTION
        A record with an Id must match the stored record with that Id and still
        have the same type and data (a stale object no longer matches, as on a
        real server); a record without an Id matches by node, type and data.
        Returns nothing when no stored record matches.

    .PARAMETER ZoneKey
        The lower-case zone name.

    .PARAMETER Record
        The record object passed to the stub.

    .EXAMPLE
        Find-DnsStubRecord -ZoneKey 'contoso.local' -Record $InputObject

        Returns the stored record or nothing.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory)]
        [string]$ZoneKey,

        [Parameter(Mandatory)]
        [object]$Record
    )

    $id = $null
    if ($null -ne $Record.PSObject.Properties['Id'] -and $Record.Id) {
        $id = [string]$Record.Id
    }
    $hostName = ([string]$Record.HostName).ToLowerInvariant()
    $recordType = ([string]$Record.RecordType).ToUpperInvariant()
    $value = Get-DnsStubRecordValue -Record $Record

    foreach ($candidate in @($script:DnsStub.Records[$ZoneKey])) {
        if ($null -eq $candidate) {
            continue
        }
        if ($id -and $candidate.Id -ne $id) {
            continue
        }
        if ($candidate.HostName.ToLowerInvariant() -eq $hostName -and $candidate.RecordType -eq $recordType -and (Get-DnsStubRecordValue -Record $candidate) -eq $value) {
            return $candidate
        }
    }
}

function script:Add-DnsStubLiveRecord {
    <#
    .SYNOPSIS
        Shared body of the Add-DnsServerResourceRecord* stubs.

    .DESCRIPTION
        Checks the zone and the node like a DNS server does, then stores the record.
        -Name is taken relative to the zone unless it ends with a dot, as by the
        real cmdlets: 'srv01.contoso.local' in zone contoso.local becomes the node
        'srv01.contoso.local' (srv01.contoso.local.contoso.local). Errors: 9601 zone
        missing, 9712 zone not a primary, 9708 the node is a CNAME (adding anything
        else), 9709 CNAME collision (adding a CNAME to a node with other records),
        9711 the identical record exists. Without -TimeToLive the record gets the
        zone default of 3600 s; with -AgeRecord it gets a timestamp (dynamic).

    .PARAMETER Command
        The calling stub, for error ids.

    .PARAMETER ZoneName
        The zone.

    .PARAMETER Name
        The record name as passed to the cmdlet.

    .PARAMETER RRType
        A, AAAA, CNAME or PTR.

    .PARAMETER Data
        The address or target.

    .PARAMETER TimeToLive
        The TTL, or $null for the zone default.

    .PARAMETER AgeRecord
        Store the record with a timestamp.

    .PARAMETER PassThru
        Return a copy of the new record.

    .PARAMETER ServerName
        The server name for messages.

    .EXAMPLE
        Add-DnsStubLiveRecord -Command 'Add-DnsServerResourceRecordA' -ZoneName 'contoso.local' -Name 'srv01' -RRType A -Data '10.0.16.20' -ServerName 'dc01'

        Stores an A record the way the stub for Add-DnsServerResourceRecordA does.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string]$ZoneName,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$RRType,

        [Parameter(Mandatory)]
        [string]$Data,

        [Parameter()]
        [AllowNull()]
        [object]$TimeToLive,

        [Parameter()]
        [bool]$AgeRecord,

        [Parameter()]
        [bool]$PassThru,

        [Parameter()]
        [string]$ServerName = 'localhost'
    )

    $zoneKey = $ZoneName.TrimEnd('.').ToLowerInvariant()
    $zone = $script:DnsStub.Zones[$zoneKey]
    if ($null -eq $zone) {
        Write-Error -Message "Failed to create resource record $Name in zone $ZoneName on server $ServerName. The zone was not found." -Category ObjectNotFound -ErrorId "WIN32 9601,$Command" -TargetObject $Name
        return
    }
    if ($zone.ZoneType -ne 'Primary') {
        Write-Error -Message "Failed to create resource record $Name in zone $ZoneName on server $ServerName. The zone is not a primary zone." -Category InvalidOperation -ErrorId "WIN32 9712,$Command" -TargetObject $Name
        return
    }

    $nodeName = $Name.Trim()
    if (-not $nodeName -or $nodeName -eq '@') {
        $nodeName = '@'
    }
    elseif ($nodeName.EndsWith('.')) {
        $nodeName = ConvertTo-DnsStubNodeName -Name $nodeName -ZoneName $zone.ZoneName
    }
    $nodeKey = $nodeName.ToLowerInvariant()

    $probe = New-Object -TypeName PSObject -Property @{ RecordType = $RRType; RecordData = (New-Object -TypeName PSObject -Property @{ IPv4Address = $Data; IPv6Address = $Data; HostNameAlias = $Data; PtrDomainName = $Data }) }
    $wanted = Get-DnsStubRecordValue -Record $probe

    foreach ($existing in @($script:DnsStub.Records[$zoneKey])) {
        if ($null -eq $existing -or $existing.HostName.ToLowerInvariant() -ne $nodeKey) {
            continue
        }
        $existingValue = Get-DnsStubRecordValue -Record $existing
        if ($existing.RecordType -eq $RRType -and $existingValue -eq $wanted) {
            Write-Error -Message "Failed to create resource record $Name in zone $ZoneName on server $ServerName. The record already exists." -Category ResourceExists -ErrorId "WIN32 9711,$Command" -TargetObject $Name
            return
        }
        if ($RRType -eq 'CNAME') {
            Write-Error -Message "Failed to create resource record $Name in zone $ZoneName on server $ServerName. A CNAME cannot be added to a node that has other records." -Category InvalidOperation -ErrorId "WIN32 9709,$Command" -TargetObject $Name
            return
        }
        if ($existing.RecordType -eq 'CNAME') {
            Write-Error -Message "Failed to create resource record $Name in zone $ZoneName on server $ServerName. The node is a CNAME." -Category InvalidOperation -ErrorId "WIN32 9708,$Command" -TargetObject $Name
            return
        }
    }

    $ttlSeconds = 3600
    if ($null -ne $TimeToLive) {
        $ttlSeconds = [int]([timespan]$TimeToLive).TotalSeconds
    }
    $timestamp = $null
    if ($AgeRecord) {
        $now = Get-Date
        $timestamp = $now.Date.AddHours($now.Hour)
    }

    # An FQDN with a trailing dot is the only form Add-DnsStubRecord never shortens.
    $recordName = '@'
    if ($nodeName -ne '@') {
        $recordName = $nodeName + '.' + $zone.ZoneName + '.'
    }
    $record = Add-DnsStubRecord -ZoneName $zone.ZoneName -Name $recordName -RRType $RRType -Data $Data -TimeToLive $ttlSeconds -Timestamp $timestamp -PassThru
    if ($PassThru) {
        Copy-DnsStubRecord -Record $record
    }
}

function script:Add-DnsServerResourceRecordA {
    <#
    .SYNOPSIS
        Stub for Add-DnsServerResourceRecordA.

    .DESCRIPTION
        Counts and logs the call, skips the change under -WhatIf, fails when
        $script:DnsStub.Fail matches the zone (Win32 code from FailCode, default 5),
        and otherwise stores the record (Add-DnsStubLiveRecord). -CreatePtr is
        recorded only; no PTR is created.

    .PARAMETER ZoneName
        Zone name.

    .PARAMETER Name
        Record name, relative to the zone.

    .PARAMETER IPv4Address
        The address.

    .PARAMETER TimeToLive
        TTL; the zone default (3600 s) when omitted.

    .PARAMETER AgeRecord
        Store a timestamp (dynamic record).

    .PARAMETER CreatePtr
        Recorded only.

    .PARAMETER AllowUpdateAny
        Recorded only.

    .PARAMETER PassThru
        Return the new record.

    .PARAMETER ComputerName
        Server name; used in error messages only.

    .PARAMETER CimSession
        CIM session; accepted and ignored.

    .EXAMPLE
        Add-DnsServerResourceRecordA -ZoneName 'contoso.local' -Name 'srv01' -IPv4Address '10.0.16.20' -WhatIf:$false -Confirm:$false

        Adds an A record to the stub store.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory)]
        [string]$ZoneName,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ipaddress]$IPv4Address,

        [Parameter()]
        [timespan]$TimeToLive,

        [Parameter()]
        [switch]$AgeRecord,

        [Parameter()]
        [switch]$CreatePtr,

        [Parameter()]
        [switch]$AllowUpdateAny,

        [Parameter()]
        [switch]$PassThru,

        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [object]$CimSession
    )

    $command = 'Add-DnsServerResourceRecordA'
    $serverName = 'localhost'
    if ($ComputerName) {
        $serverName = $ComputerName
    }
    elseif ($null -ne $CimSession) {
        $serverName = 'cimsession'
    }

    $shouldFail = Register-DnsStubCall -Command $command -ZoneName $ZoneName.TrimEnd('.').ToLowerInvariant() -BoundParameters $PSBoundParameters
    if ($WhatIfPreference) {
        Write-Verbose "What if: $command would add $Name A $IPv4Address (CreatePtr: $CreatePtr, AllowUpdateAny: $AllowUpdateAny)."
        return
    }
    if ($shouldFail) {
        $code = 5
        if ($null -ne $script:DnsStub.FailCode[$command]) {
            $code = [int]$script:DnsStub.FailCode[$command]
        }
        Write-Error -Message "Stub failure: failed to create resource record $Name in zone $ZoneName on server $serverName." -Category (Get-DnsStubErrorCategory -Code $code) -ErrorId "WIN32 $code,$command" -TargetObject $Name
        return
    }

    $ttl = $null
    if ($PSBoundParameters.Keys -contains 'TimeToLive') {
        $ttl = $TimeToLive
    }
    Add-DnsStubLiveRecord -Command $command -ZoneName $ZoneName -Name $Name -RRType 'A' -Data $IPv4Address.IPAddressToString -TimeToLive $ttl -AgeRecord ([bool]$AgeRecord) -PassThru ([bool]$PassThru) -ServerName $serverName
}

function script:Add-DnsServerResourceRecordAAAA {
    <#
    .SYNOPSIS
        Stub for Add-DnsServerResourceRecordAAAA.

    .DESCRIPTION
        As the stub for Add-DnsServerResourceRecordA, for IPv6 addresses.

    .PARAMETER ZoneName
        Zone name.

    .PARAMETER Name
        Record name, relative to the zone.

    .PARAMETER IPv6Address
        The address.

    .PARAMETER TimeToLive
        TTL; the zone default (3600 s) when omitted.

    .PARAMETER AgeRecord
        Store a timestamp (dynamic record).

    .PARAMETER CreatePtr
        Recorded only.

    .PARAMETER AllowUpdateAny
        Recorded only.

    .PARAMETER PassThru
        Return the new record.

    .PARAMETER ComputerName
        Server name; used in error messages only.

    .PARAMETER CimSession
        CIM session; accepted and ignored.

    .EXAMPLE
        Add-DnsServerResourceRecordAAAA -ZoneName 'contoso.local' -Name 'v6host' -IPv6Address '2001:db8::10' -WhatIf:$false -Confirm:$false

        Adds an AAAA record to the stub store.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory)]
        [string]$ZoneName,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ipaddress]$IPv6Address,

        [Parameter()]
        [timespan]$TimeToLive,

        [Parameter()]
        [switch]$AgeRecord,

        [Parameter()]
        [switch]$CreatePtr,

        [Parameter()]
        [switch]$AllowUpdateAny,

        [Parameter()]
        [switch]$PassThru,

        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [object]$CimSession
    )

    $command = 'Add-DnsServerResourceRecordAAAA'
    $serverName = 'localhost'
    if ($ComputerName) {
        $serverName = $ComputerName
    }
    elseif ($null -ne $CimSession) {
        $serverName = 'cimsession'
    }

    $shouldFail = Register-DnsStubCall -Command $command -ZoneName $ZoneName.TrimEnd('.').ToLowerInvariant() -BoundParameters $PSBoundParameters
    if ($WhatIfPreference) {
        Write-Verbose "What if: $command would add $Name AAAA $IPv6Address (CreatePtr: $CreatePtr, AllowUpdateAny: $AllowUpdateAny)."
        return
    }
    if ($shouldFail) {
        $code = 5
        if ($null -ne $script:DnsStub.FailCode[$command]) {
            $code = [int]$script:DnsStub.FailCode[$command]
        }
        Write-Error -Message "Stub failure: failed to create resource record $Name in zone $ZoneName on server $serverName." -Category (Get-DnsStubErrorCategory -Code $code) -ErrorId "WIN32 $code,$command" -TargetObject $Name
        return
    }

    $ttl = $null
    if ($PSBoundParameters.Keys -contains 'TimeToLive') {
        $ttl = $TimeToLive
    }
    Add-DnsStubLiveRecord -Command $command -ZoneName $ZoneName -Name $Name -RRType 'AAAA' -Data $IPv6Address.IPAddressToString -TimeToLive $ttl -AgeRecord ([bool]$AgeRecord) -PassThru ([bool]$PassThru) -ServerName $serverName
}

function script:Add-DnsServerResourceRecordCName {
    <#
    .SYNOPSIS
        Stub for Add-DnsServerResourceRecordCName.

    .DESCRIPTION
        As the stub for Add-DnsServerResourceRecordA, for aliases. A CNAME cannot
        join a node that has other records (WIN32 9709).

    .PARAMETER ZoneName
        Zone name.

    .PARAMETER Name
        Alias name, relative to the zone.

    .PARAMETER HostNameAlias
        The target FQDN.

    .PARAMETER TimeToLive
        TTL; the zone default (3600 s) when omitted.

    .PARAMETER AgeRecord
        Store a timestamp (dynamic record).

    .PARAMETER AllowUpdateAny
        Recorded only.

    .PARAMETER PassThru
        Return the new record.

    .PARAMETER ComputerName
        Server name; used in error messages only.

    .PARAMETER CimSession
        CIM session; accepted and ignored.

    .EXAMPLE
        Add-DnsServerResourceRecordCName -ZoneName 'contoso.local' -Name 'www' -HostNameAlias 'web01.contoso.local' -WhatIf:$false -Confirm:$false

        Adds a CNAME record to the stub store.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory)]
        [string]$ZoneName,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$HostNameAlias,

        [Parameter()]
        [timespan]$TimeToLive,

        [Parameter()]
        [switch]$AgeRecord,

        [Parameter()]
        [switch]$AllowUpdateAny,

        [Parameter()]
        [switch]$PassThru,

        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [object]$CimSession
    )

    $command = 'Add-DnsServerResourceRecordCName'
    $serverName = 'localhost'
    if ($ComputerName) {
        $serverName = $ComputerName
    }
    elseif ($null -ne $CimSession) {
        $serverName = 'cimsession'
    }

    $shouldFail = Register-DnsStubCall -Command $command -ZoneName $ZoneName.TrimEnd('.').ToLowerInvariant() -BoundParameters $PSBoundParameters
    if ($WhatIfPreference) {
        Write-Verbose "What if: $command would add $Name CNAME $HostNameAlias (AllowUpdateAny: $AllowUpdateAny)."
        return
    }
    if ($shouldFail) {
        $code = 5
        if ($null -ne $script:DnsStub.FailCode[$command]) {
            $code = [int]$script:DnsStub.FailCode[$command]
        }
        Write-Error -Message "Stub failure: failed to create resource record $Name in zone $ZoneName on server $serverName." -Category (Get-DnsStubErrorCategory -Code $code) -ErrorId "WIN32 $code,$command" -TargetObject $Name
        return
    }

    $ttl = $null
    if ($PSBoundParameters.Keys -contains 'TimeToLive') {
        $ttl = $TimeToLive
    }
    Add-DnsStubLiveRecord -Command $command -ZoneName $ZoneName -Name $Name -RRType 'CNAME' -Data $HostNameAlias -TimeToLive $ttl -AgeRecord ([bool]$AgeRecord) -PassThru ([bool]$PassThru) -ServerName $serverName
}

function script:Add-DnsServerResourceRecordPtr {
    <#
    .SYNOPSIS
        Stub for Add-DnsServerResourceRecordPtr.

    .DESCRIPTION
        As the stub for Add-DnsServerResourceRecordA, for PTR records in a reverse
        zone.

    .PARAMETER ZoneName
        Reverse zone name.

    .PARAMETER Name
        Node name relative to the zone ('5', or '5.16' in a /16 zone).

    .PARAMETER PtrDomainName
        The target FQDN.

    .PARAMETER TimeToLive
        TTL; the zone default (3600 s) when omitted.

    .PARAMETER AgeRecord
        Store a timestamp (dynamic record).

    .PARAMETER AllowUpdateAny
        Recorded only.

    .PARAMETER PassThru
        Return the new record.

    .PARAMETER ComputerName
        Server name; used in error messages only.

    .PARAMETER CimSession
        CIM session; accepted and ignored.

    .EXAMPLE
        Add-DnsServerResourceRecordPtr -ZoneName '16.0.10.in-addr.arpa' -Name '20' -PtrDomainName 'srv01.contoso.local' -WhatIf:$false -Confirm:$false

        Adds a PTR record to the stub store.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory)]
        [string]$ZoneName,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$PtrDomainName,

        [Parameter()]
        [timespan]$TimeToLive,

        [Parameter()]
        [switch]$AgeRecord,

        [Parameter()]
        [switch]$AllowUpdateAny,

        [Parameter()]
        [switch]$PassThru,

        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [object]$CimSession
    )

    $command = 'Add-DnsServerResourceRecordPtr'
    $serverName = 'localhost'
    if ($ComputerName) {
        $serverName = $ComputerName
    }
    elseif ($null -ne $CimSession) {
        $serverName = 'cimsession'
    }

    $shouldFail = Register-DnsStubCall -Command $command -ZoneName $ZoneName.TrimEnd('.').ToLowerInvariant() -BoundParameters $PSBoundParameters
    if ($WhatIfPreference) {
        Write-Verbose "What if: $command would add $Name PTR $PtrDomainName (AllowUpdateAny: $AllowUpdateAny)."
        return
    }
    if ($shouldFail) {
        $code = 5
        if ($null -ne $script:DnsStub.FailCode[$command]) {
            $code = [int]$script:DnsStub.FailCode[$command]
        }
        Write-Error -Message "Stub failure: failed to create resource record $Name in zone $ZoneName on server $serverName." -Category (Get-DnsStubErrorCategory -Code $code) -ErrorId "WIN32 $code,$command" -TargetObject $Name
        return
    }

    $ttl = $null
    if ($PSBoundParameters.Keys -contains 'TimeToLive') {
        $ttl = $TimeToLive
    }
    Add-DnsStubLiveRecord -Command $command -ZoneName $ZoneName -Name $Name -RRType 'PTR' -Data $PtrDomainName -TimeToLive $ttl -AgeRecord ([bool]$AgeRecord) -PassThru ([bool]$PassThru) -ServerName $serverName
}

function script:Remove-DnsServerResourceRecord {
    <#
    .SYNOPSIS
        Stub for Remove-DnsServerResourceRecord (the -InputObject form).

    .DESCRIPTION
        Removes each piped record from the store. The record is found by its Id
        and must still have the same type and data (Find-DnsStubRecord); a record
        that is not there writes WIN32 9701 while its node still holds other
        records and WIN32 9714 when the node is gone (Test-DnsStubNode). Counts and
        logs every record, skips the change under -WhatIf, and fails when
        $script:DnsStub.Fail matches the zone (Win32 code from FailCode, default 5).

    .PARAMETER ZoneName
        Zone name.

    .PARAMETER InputObject
        The record to remove, usually piped from Get-DnsServerResourceRecord.

    .PARAMETER Force
        Accepted; the stub never prompts.

    .PARAMETER PassThru
        Return the removed record.

    .PARAMETER ComputerName
        Server name; used in error messages only.

    .PARAMETER CimSession
        CIM session; accepted and ignored.

    .EXAMPLE
        $record | Remove-DnsServerResourceRecord -ZoneName 'contoso.local' -Force -WhatIf:$false -Confirm:$false

        Removes the record from the stub store.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$ZoneName,

        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$InputObject,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$PassThru,

        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [object]$CimSession
    )

    process {
        $command = 'Remove-DnsServerResourceRecord'
        $serverName = 'localhost'
        if ($ComputerName) {
            $serverName = $ComputerName
        }
        elseif ($null -ne $CimSession) {
            $serverName = 'cimsession'
        }

        $zoneKey = $ZoneName.TrimEnd('.').ToLowerInvariant()
        $shouldFail = Register-DnsStubCall -Command $command -ZoneName $zoneKey -BoundParameters $PSBoundParameters
        if ($WhatIfPreference) {
            Write-Verbose "What if: $command would remove $($InputObject.HostName) $($InputObject.RecordType) (Force: $Force)."
            return
        }
        if ($shouldFail) {
            $code = 5
            if ($null -ne $script:DnsStub.FailCode[$command]) {
                $code = [int]$script:DnsStub.FailCode[$command]
            }
            Write-Error -Message "Stub failure: failed to remove the resource record $($InputObject.HostName) in zone $ZoneName on server $serverName." -Category (Get-DnsStubErrorCategory -Code $code) -ErrorId "WIN32 $code,$command" -TargetObject $InputObject
            return
        }

        if ($null -eq $script:DnsStub.Zones[$zoneKey]) {
            Write-Error -Message "Failed to remove the resource record in zone $ZoneName on server $serverName. The zone was not found." -Category ObjectNotFound -ErrorId "WIN32 9601,$command" -TargetObject $InputObject
            return
        }

        $stored = Find-DnsStubRecord -ZoneKey $zoneKey -Record $InputObject
        if ($null -eq $stored) {
            if (Test-DnsStubNode -ZoneKey $zoneKey -NodeName ([string]$InputObject.HostName)) {
                Write-Error -Message "Failed to remove the resource record $($InputObject.HostName) in zone $ZoneName on server $serverName. The record does not exist." -Category ObjectNotFound -ErrorId "WIN32 9701,$command" -TargetObject $InputObject
            }
            else {
                Write-Error -Message "Failed to remove the resource record $($InputObject.HostName) in zone $ZoneName on server $serverName. The name does not exist." -Category ObjectNotFound -ErrorId "WIN32 9714,$command" -TargetObject $InputObject
            }
            return
        }

        $script:DnsStub.Records[$zoneKey] = @(
            foreach ($record in @($script:DnsStub.Records[$zoneKey])) {
                if ($record.Id -ne $stored.Id) {
                    $record
                }
            }
        )

        if ($PassThru) {
            Copy-DnsStubRecord -Record $stored
        }
    }
}

function script:Set-DnsServerResourceRecord {
    <#
    .SYNOPSIS
        Stub for Set-DnsServerResourceRecord (-OldInputObject -NewInputObject).

    .DESCRIPTION
        Replaces the stored record that -OldInputObject stands for (by Id, and only
        while its data is unchanged) with a copy of -NewInputObject that keeps the
        stored Id and DistinguishedName. Everything else comes from
        -NewInputObject, including Timestamp, so a test sees whatever the caller
        carried through. Addresses set as strings are stored as [ipaddress] and
        target names get their trailing dot, the shapes the other stubs use.

        Errors: 9601 zone missing; 9701 old record not there while its node still
        holds other records, 9714 when the node is gone (as for
        Remove-DnsServerResourceRecord); 87 when name or type differ between the
        two objects; 9711 when another record at the node already has the new
        data; 9707 when a CNAME would point at itself. Counts and logs the call,
        skips the change under -WhatIf, and fails when $script:DnsStub.Fail matches
        the zone (Win32 code from FailCode, default 5).

    .PARAMETER ZoneName
        Zone name.

    .PARAMETER OldInputObject
        The record as it is.

    .PARAMETER NewInputObject
        The record as it should be.

    .PARAMETER PassThru
        Return the stored record.

    .PARAMETER ComputerName
        Server name; used in error messages only.

    .PARAMETER CimSession
        CIM session; accepted and ignored.

    .EXAMPLE
        Set-DnsServerResourceRecord -ZoneName 'contoso.local' -OldInputObject $old -NewInputObject $new -WhatIf:$false -Confirm:$false

        Replaces the record in the stub store.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$ZoneName,

        [Parameter(Mandatory)]
        [object]$OldInputObject,

        [Parameter(Mandatory)]
        [object]$NewInputObject,

        [Parameter()]
        [switch]$PassThru,

        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [object]$CimSession
    )

    $command = 'Set-DnsServerResourceRecord'
    $serverName = 'localhost'
    if ($ComputerName) {
        $serverName = $ComputerName
    }
    elseif ($null -ne $CimSession) {
        $serverName = 'cimsession'
    }

    $zoneKey = $ZoneName.TrimEnd('.').ToLowerInvariant()
    $shouldFail = Register-DnsStubCall -Command $command -ZoneName $zoneKey -BoundParameters $PSBoundParameters
    if ($WhatIfPreference) {
        Write-Verbose "What if: $command would change $($OldInputObject.HostName) $($OldInputObject.RecordType)."
        return
    }
    if ($shouldFail) {
        $code = 5
        if ($null -ne $script:DnsStub.FailCode[$command]) {
            $code = [int]$script:DnsStub.FailCode[$command]
        }
        Write-Error -Message "Stub failure: failed to update the resource record $($OldInputObject.HostName) in zone $ZoneName on server $serverName." -Category (Get-DnsStubErrorCategory -Code $code) -ErrorId "WIN32 $code,$command" -TargetObject $OldInputObject
        return
    }

    $zone = $script:DnsStub.Zones[$zoneKey]
    if ($null -eq $zone) {
        Write-Error -Message "Failed to update the resource record in zone $ZoneName on server $serverName. The zone was not found." -Category ObjectNotFound -ErrorId "WIN32 9601,$command" -TargetObject $OldInputObject
        return
    }

    $stored = Find-DnsStubRecord -ZoneKey $zoneKey -Record $OldInputObject
    if ($null -eq $stored) {
        if (Test-DnsStubNode -ZoneKey $zoneKey -NodeName ([string]$OldInputObject.HostName)) {
            Write-Error -Message "Failed to update the resource record $($OldInputObject.HostName) in zone $ZoneName on server $serverName. The record does not exist." -Category ObjectNotFound -ErrorId "WIN32 9701,$command" -TargetObject $OldInputObject
        }
        else {
            Write-Error -Message "Failed to update the resource record $($OldInputObject.HostName) in zone $ZoneName on server $serverName. The name does not exist." -Category ObjectNotFound -ErrorId "WIN32 9714,$command" -TargetObject $OldInputObject
        }
        return
    }

    $recordType = $stored.RecordType
    if (([string]$NewInputObject.HostName).ToLowerInvariant() -ne $stored.HostName.ToLowerInvariant() -or ([string]$NewInputObject.RecordType).ToUpperInvariant() -ne $recordType) {
        Write-Error -Message "Failed to update the resource record $($stored.HostName) in zone $ZoneName on server $serverName. The new record must have the same name and type." -Category InvalidArgument -ErrorId "WIN32 87,$command" -TargetObject $NewInputObject
        return
    }

    $newValue = Get-DnsStubRecordValue -Record $NewInputObject
    foreach ($other in @($script:DnsStub.Records[$zoneKey])) {
        if ($null -eq $other -or $other.Id -eq $stored.Id -or $other.HostName.ToLowerInvariant() -ne $stored.HostName.ToLowerInvariant() -or $other.RecordType -ne $recordType) {
            continue
        }
        if ((Get-DnsStubRecordValue -Record $other) -eq $newValue) {
            Write-Error -Message "Failed to update the resource record $($stored.HostName) in zone $ZoneName on server $serverName. The record already exists." -Category ResourceExists -ErrorId "WIN32 9711,$command" -TargetObject $NewInputObject
            return
        }
    }

    $owner = $zone.ZoneName.ToLowerInvariant()
    if ($stored.HostName -ne '@') {
        $owner = $stored.HostName.ToLowerInvariant() + '.' + $owner
    }
    if ($recordType -eq 'CNAME' -and $newValue -eq $owner) {
        Write-Error -Message "Failed to update the resource record $($stored.HostName) in zone $ZoneName on server $serverName. The CNAME would point at itself." -Category InvalidOperation -ErrorId "WIN32 9707,$command" -TargetObject $NewInputObject
        return
    }

    # Add-Member -Force, not assignment: an object built by the caller may lack Id.
    $replacement = Copy-DnsStubRecord -Record $NewInputObject
    $kept = @{ Id = $stored.Id; DistinguishedName = $stored.DistinguishedName; HostName = $stored.HostName; RecordType = $recordType }
    foreach ($keptName in @($kept.Keys)) {
        Add-Member -InputObject $replacement -NotePropertyName $keptName -NotePropertyValue $kept[$keptName] -Force
    }
    $data = $replacement.RecordData
    foreach ($addressProperty in @('IPv4Address', 'IPv6Address')) {
        if ($null -ne $data.PSObject.Properties[$addressProperty] -and $data.$addressProperty -is [string]) {
            $data.$addressProperty = [ipaddress]$data.$addressProperty
        }
    }
    foreach ($nameProperty in @('HostNameAlias', 'PtrDomainName', 'NameServer', 'MailExchange', 'DomainName')) {
        if ($null -ne $data.PSObject.Properties[$nameProperty] -and $data.$nameProperty -and -not ([string]$data.$nameProperty).EndsWith('.')) {
            $data.$nameProperty = [string]$data.$nameProperty + '.'
        }
    }

    $script:DnsStub.Records[$zoneKey] = @(
        foreach ($record in @($script:DnsStub.Records[$zoneKey])) {
            if ($record.Id -eq $stored.Id) {
                $replacement
            }
            else {
                $record
            }
        }
    )

    if ($PassThru) {
        Copy-DnsStubRecord -Record $replacement
    }
}

function script:Add-DnsServerPrimaryZone {
    <#
    .SYNOPSIS
        Stub for Add-DnsServerPrimaryZone (the -Name and the -NetworkId sets).

    .DESCRIPTION
        Adds a primary zone to the stub store. With -NetworkId the zone name is
        derived from the network on whole labels, like the real cmdlet: an IPv4
        /8, /16 or /24 network becomes 'c.b.a.in-addr.arpa', an IPv6 network with a
        prefix that is a multiple of 4 becomes the reversed nibbles plus
        '.ip6.arpa'; any other prefix writes WIN32 87. The derivation is written
        independently of the module's Get-DnsReverseZoneName on purpose, so a test
        can compare the two.

        With -ReplicationScope the zone is AD-integrated (Custom needs
        -DirectoryPartitionName, WIN32 87 otherwise; Domain and Forest get the
        DomainDnsZones / ForestDnsZones partition of contoso.local); with
        -ZoneFile it is file-backed. -DynamicUpdate defaults to None, as on the
        real cmdlet. An existing zone writes WIN32 9609. Counts and logs the call,
        skips the change under -WhatIf, and fails when $script:DnsStub.Fail
        matches the zone.

    .PARAMETER Name
        Zone name (forward or reverse).

    .PARAMETER NetworkId
        Network for a reverse zone, for example '10.0.16.0/24'.

    .PARAMETER ReplicationScope
        Domain, Forest, Legacy or Custom.

    .PARAMETER DirectoryPartitionName
        The AD partition for Custom.

    .PARAMETER DynamicUpdate
        None, Secure or NonsecureAndSecure.

    .PARAMETER ZoneFile
        File name of a file-backed zone.

    .PARAMETER PassThru
        Return the new zone.

    .PARAMETER ComputerName
        Server name; used in error messages only.

    .PARAMETER CimSession
        CIM session; accepted and ignored.

    .EXAMPLE
        Add-DnsServerPrimaryZone -NetworkId '10.0.17.0/24' -ReplicationScope Custom -DirectoryPartitionName 'DomainDnsZones.contoso.local' -DynamicUpdate Secure -WhatIf:$false -Confirm:$false

        Adds the zone 17.0.10.in-addr.arpa to the stub store.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Name')]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Name')]
        [string]$Name,

        [Parameter(Mandatory, ParameterSetName = 'NetworkId')]
        [string]$NetworkId,

        [Parameter()]
        [string]$ReplicationScope,

        [Parameter()]
        [string]$DirectoryPartitionName,

        [Parameter()]
        [string]$DynamicUpdate = 'None',

        [Parameter()]
        [string]$ZoneFile,

        [Parameter()]
        [switch]$PassThru,

        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [object]$CimSession
    )

    $command = 'Add-DnsServerPrimaryZone'
    $serverName = 'localhost'
    if ($ComputerName) {
        $serverName = $ComputerName
    }
    elseif ($null -ne $CimSession) {
        $serverName = 'cimsession'
    }

    $zoneName = $null
    if ($NetworkId) {
        $text = $NetworkId.Trim()
        if ($text -match '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$') {
            $octets = @($Matches[1], $Matches[2], $Matches[3], $Matches[4])
            $prefix = [int]$Matches[5]
            if ($prefix -eq 8 -or $prefix -eq 16 -or $prefix -eq 24) {
                $labelCount = [int]($prefix / 8)
                $labels = for ($index = $labelCount - 1; $index -ge 0; $index--) {
                    [string][int]$octets[$index]
                }
                $zoneName = (@($labels) -join '.') + '.in-addr.arpa'
            }
        }
        elseif ($text -match '^([0-9A-Fa-f:]+)/(\d{1,3})$') {
            $prefix = [int]$Matches[2]
            $address = $null
            try {
                $address = [ipaddress]$Matches[1]
            }
            catch {
                $address = $null
            }
            if ($null -ne $address -and $prefix -ge 4 -and $prefix -le 124 -and ($prefix % 4) -eq 0) {
                $hex = -join @(foreach ($addressByte in $address.GetAddressBytes()) { '{0:x2}' -f $addressByte })
                $labels = for ($index = [int]($prefix / 4) - 1; $index -ge 0; $index--) {
                    [string]$hex[$index]
                }
                $zoneName = (@($labels) -join '.') + '.ip6.arpa'
            }
        }
    }
    else {
        $zoneName = $Name.Trim().TrimEnd('.')
    }

    $zoneKey = ''
    if ($zoneName) {
        $zoneKey = $zoneName.ToLowerInvariant()
    }
    $shouldFail = Register-DnsStubCall -Command $command -ZoneName $zoneKey -BoundParameters $PSBoundParameters
    if ($WhatIfPreference) {
        Write-Verbose "What if: $command would add zone '$zoneName' (file '$ZoneFile')."
        return
    }
    if ($shouldFail) {
        $code = 5
        if ($null -ne $script:DnsStub.FailCode[$command]) {
            $code = [int]$script:DnsStub.FailCode[$command]
        }
        Write-Error -Message "Stub failure: failed to create zone $zoneName on server $serverName." -Category (Get-DnsStubErrorCategory -Code $code) -ErrorId "WIN32 $code,$command" -TargetObject $zoneName
        return
    }

    if (-not $zoneName) {
        Write-Error -Message "Failed to create the zone for network '$NetworkId' on server $serverName. The network ID is not valid." -Category InvalidArgument -ErrorId "WIN32 87,$command" -TargetObject $NetworkId
        return
    }
    if ($null -ne $script:DnsStub.Zones[$zoneKey]) {
        Write-Error -Message "Failed to create zone $zoneName on server $serverName. The zone already exists." -Category ResourceExists -ErrorId "WIN32 9609,$command" -TargetObject $zoneName
        return
    }

    $isDsIntegrated = [bool]$ReplicationScope
    $partition = 'DomainDnsZones.contoso.local'
    if ($ReplicationScope -eq 'Custom') {
        if (-not $DirectoryPartitionName) {
            Write-Error -Message "Failed to create zone $zoneName on server $serverName. ReplicationScope Custom needs DirectoryPartitionName." -Category InvalidArgument -ErrorId "WIN32 87,$command" -TargetObject $zoneName
            return
        }
        $partition = $DirectoryPartitionName
    }
    elseif ($ReplicationScope -eq 'Forest') {
        $partition = 'ForestDnsZones.contoso.local'
    }
    $scope = 'Domain'
    if ($ReplicationScope) {
        $scope = $ReplicationScope
    }

    $zone = Add-DnsStubZone -Name $zoneName -IsDsIntegrated $isDsIntegrated -ReplicationScope $scope -DirectoryPartitionName $partition -DynamicUpdate $DynamicUpdate -PassThru
    if ($ZoneFile -and -not $isDsIntegrated) {
        $zone.ZoneFile = $ZoneFile
    }
    if ($PassThru) {
        $zone
    }
}

function script:Set-DnsServerZoneAging {
    <#
    .SYNOPSIS
        Stub for Set-DnsServerZoneAging.

    .DESCRIPTION
        Changes the aging settings stored by Add-DnsStubZone; only the parameters
        that were passed change. ScavengeServers are stored as strings. Counts and
        logs the call, skips the change under -WhatIf, and fails when
        $script:DnsStub.Fail matches the zone; an unknown zone writes WIN32 9601.

    .PARAMETER Name
        Zone name.

    .PARAMETER Aging
        Enable or disable aging.

    .PARAMETER RefreshInterval
        Refresh interval.

    .PARAMETER NoRefreshInterval
        No-refresh interval.

    .PARAMETER ScavengeServers
        Servers allowed to scavenge the zone.

    .PARAMETER PassThru
        Return the aging settings.

    .PARAMETER ComputerName
        Server name; used in error messages only.

    .PARAMETER CimSession
        CIM session; accepted and ignored.

    .EXAMPLE
        Set-DnsServerZoneAging -Name '17.0.10.in-addr.arpa' -Aging $true -WhatIf:$false -Confirm:$false

        Enables aging on the stub zone.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [Parameter()]
        [bool]$Aging,

        [Parameter()]
        [timespan]$RefreshInterval,

        [Parameter()]
        [timespan]$NoRefreshInterval,

        [Parameter()]
        [object[]]$ScavengeServers,

        [Parameter()]
        [switch]$PassThru,

        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [object]$CimSession
    )

    $command = 'Set-DnsServerZoneAging'
    $serverName = 'localhost'
    if ($ComputerName) {
        $serverName = $ComputerName
    }
    elseif ($null -ne $CimSession) {
        $serverName = 'cimsession'
    }

    $zoneKey = $Name.TrimEnd('.').ToLowerInvariant()
    $shouldFail = Register-DnsStubCall -Command $command -ZoneName $zoneKey -BoundParameters $PSBoundParameters
    if ($WhatIfPreference) {
        Write-Verbose "What if: $command would change aging of zone $Name."
        return
    }
    if ($shouldFail) {
        $code = 5
        if ($null -ne $script:DnsStub.FailCode[$command]) {
            $code = [int]$script:DnsStub.FailCode[$command]
        }
        Write-Error -Message "Stub failure: failed to set aging of zone $Name on server $serverName." -Category (Get-DnsStubErrorCategory -Code $code) -ErrorId "WIN32 $code,$command" -TargetObject $Name
        return
    }

    $agingSettings = $script:DnsStub.Aging[$zoneKey]
    if ($null -eq $agingSettings) {
        Write-Error -Message "The zone $Name was not found on server $serverName." -Category ObjectNotFound -ErrorId "WIN32 9601,$command" -TargetObject $Name
        return
    }

    if ($PSBoundParameters.Keys -contains 'Aging') {
        $agingSettings.AgingEnabled = $Aging
    }
    if ($PSBoundParameters.Keys -contains 'RefreshInterval') {
        $agingSettings.RefreshInterval = $RefreshInterval
    }
    if ($PSBoundParameters.Keys -contains 'NoRefreshInterval') {
        $agingSettings.NoRefreshInterval = $NoRefreshInterval
    }
    if ($PSBoundParameters.Keys -contains 'ScavengeServers') {
        $agingSettings.ScavengeServers = [string[]]@(foreach ($scavengeServer in @($ScavengeServers)) { if ($null -ne $scavengeServer) { [string]$scavengeServer } })
    }
    if ($PassThru) {
        $agingSettings
    }
}

function script:Get-DnsServerZoneScope {
    <#
    .SYNOPSIS
        Stub for Get-DnsServerZoneScope.

    .DESCRIPTION
        Returns the default zone scope (named like the zone) and then the extra
        scopes listed in $script:DnsStub.ZoneScopes[<zone>]; with -Name only that
        scope. An unknown zone writes WIN32 9601; $script:DnsStub.Fail makes the
        call fail.

    .PARAMETER ZoneName
        Zone name.

    .PARAMETER Name
        A single scope name.

    .PARAMETER ComputerName
        Server name; used in error messages only.

    .PARAMETER CimSession
        CIM session; accepted and ignored.

    .EXAMPLE
        Get-DnsServerZoneScope -ZoneName 'contoso.local'

        Returns the default scope of contoso.local.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$ZoneName,

        [Parameter(Position = 1)]
        [string]$Name,

        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [object]$CimSession
    )

    $command = 'Get-DnsServerZoneScope'
    $serverName = 'localhost'
    if ($ComputerName) {
        $serverName = $ComputerName
    }
    elseif ($null -ne $CimSession) {
        $serverName = 'cimsession'
    }

    $zoneKey = $ZoneName.TrimEnd('.').ToLowerInvariant()
    if (Register-DnsStubCall -Command $command -ZoneName $zoneKey) {
        $code = 5
        if ($null -ne $script:DnsStub.FailCode[$command]) {
            $code = [int]$script:DnsStub.FailCode[$command]
        }
        Write-Error -Message "Stub failure: could not read the zone scopes of $ZoneName on server $serverName." -Category (Get-DnsStubErrorCategory -Code $code) -ErrorId "WIN32 $code,$command" -TargetObject $ZoneName
        return
    }

    $zone = $script:DnsStub.Zones[$zoneKey]
    if ($null -eq $zone) {
        Write-Error -Message "The zone $ZoneName was not found on server $serverName." -Category ObjectNotFound -ErrorId "WIN32 9601,$command" -TargetObject $ZoneName
        return
    }

    $scopeNames = @($zone.ZoneName)
    if ($null -ne $script:DnsStub.ZoneScopes[$zoneKey]) {
        $scopeNames = $scopeNames + @($script:DnsStub.ZoneScopes[$zoneKey])
    }
    foreach ($scopeName in $scopeNames) {
        if ($Name -and $scopeName -ne $Name) {
            continue
        }
        $scope = New-Object -TypeName PSObject -Property ([ordered]@{ ZoneScope = $scopeName; FileName = '' })
        Add-Member -InputObject $scope -TypeName 'Microsoft.Management.Infrastructure.CimInstance#root/Microsoft/Windows/DNS/DnsServerZoneScope'
        $scope
    }
}

function script:New-CimSession {
    <#
    .SYNOPSIS
        Stub for New-CimSession.

    .DESCRIPTION
        Returns a duck-typed session object (ComputerName, Protocol, Id,
        InstanceId, Name) so that Get-DnsCimSession works offline. Protocol is
        'Dcom' when -SessionOption is a DCOM option and 'Wsman' otherwise. With
        $script:DnsStub.CimUnavailable set, every call writes a connection error
        instead, which Get-DnsCimSession turns into $null ('Unavailable'). Counts
        and logs every call.

    .PARAMETER ComputerName
        The server.

    .PARAMETER Credential
        Accepted and recorded.

    .PARAMETER SessionOption
        The New-CimSessionOption result; decides Protocol.

    .PARAMETER OperationTimeoutSec
        Accepted and recorded.

    .EXAMPLE
        New-CimSession -ComputerName 'dc01' -SessionOption (New-CimSessionOption -Protocol Dcom)

        Returns a stub session with Protocol 'Dcom'.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param (
        [Parameter(Position = 0)]
        [string[]]$ComputerName,

        [Parameter()]
        [AllowNull()]
        [pscredential]$Credential,

        [Parameter()]
        [object]$SessionOption,

        [Parameter()]
        [uint32]$OperationTimeoutSec
    )

    $null = Register-DnsStubCall -Command 'New-CimSession' -BoundParameters $PSBoundParameters
    $computer = 'localhost'
    if ($ComputerName) {
        $computer = [string]$ComputerName[0]
    }

    if ($script:DnsStub.CimUnavailable) {
        Write-Error -Message "Stub failure: WinRM cannot complete the operation on $computer (timeout $OperationTimeoutSec s, credential given: $($null -ne $Credential))." -Category ConnectionError -ErrorId 'HRESULT 0x80338126,Microsoft.Management.Infrastructure.CimCmdlets.NewCimSessionCommand' -TargetObject $computer
        return
    }

    $protocol = 'Wsman'
    if ($null -ne $SessionOption -and (@($SessionOption.PSObject.TypeNames) -join ' ') -match 'DCom') {
        $protocol = 'Dcom'
    }

    $sessionNumber = [int]$script:DnsStub.Calls['New-CimSession']
    $session = New-Object -TypeName PSObject -Property ([ordered]@{
            Id           = $sessionNumber
            Name         = 'CimSession' + $sessionNumber
            InstanceId   = [guid]::NewGuid()
            ComputerName = $computer
            Protocol     = $protocol
        })
    Add-Member -InputObject $session -TypeName 'Microsoft.Management.Infrastructure.CimSession'
    $session
}

function script:Remove-CimSession {
    <#
    .SYNOPSIS
        Stub for Remove-CimSession.

    .DESCRIPTION
        Counts and logs the call; there is nothing to close.

    .PARAMETER CimSession
        The session.

    .EXAMPLE
        Remove-CimSession -CimSession $session

        Counts the call.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param (
        [Parameter(Position = 0, ValueFromPipeline)]
        [object]$CimSession
    )

    process {
        $null = Register-DnsStubCall -Command 'Remove-CimSession' -BoundParameters $PSBoundParameters
        if ($WhatIfPreference) {
            Write-Verbose "What if: Remove-CimSession would close $($CimSession.ComputerName)."
        }
    }
}

function script:Get-CimInstance {
    <#
    .SYNOPSIS
        Stub for Get-CimInstance with a minimal WQL reader for root\MicrosoftDNS.

    .DESCRIPTION
        Understands

            SELECT <properties> FROM MicrosoftDNS_Server
            SELECT <properties> FROM MicrosoftDNS_<A|AAAA|CNAME|PTR|NS|MX|SRV>Type
                [WHERE <property>='<value>' [AND <property>='<value>' ...]]

        and answers from the stub store. Record objects carry ContainerName and
        DomainName (the zone), OwnerName (the owner FQDN without a trailing dot, the
        zone name at the apex), TTL, Timestamp, TextRepresentation and the
        type-specific property with a trailing dot on names: PrimaryName (CNAME),
        SRVDomainName (SRV), NSHost (NS), MailExchange (MX), PTRDomainName (PTR), or
        IPAddress / IPv6Address. Conditions compare case-insensitively; WQL escapes
        (\' and \\) are understood. All properties are returned whatever the
        SELECT list says.

        $script:DnsStub.Fail['Get-CimInstance'] matches the ContainerName of the
        query, or the class name for queries without one (MicrosoftDNS_Server), and
        then writes an access-denied error. An unknown class or an unreadable query
        writes an error too. Counts and logs every call.

    .PARAMETER ClassName
        Accepted; only -Query is evaluated.

    .PARAMETER Namespace
        Accepted and recorded (root\MicrosoftDNS).

    .PARAMETER Query
        The WQL query.

    .PARAMETER CimSession
        The session; its ComputerName is used as the server name.

    .PARAMETER OperationTimeoutSec
        Accepted and recorded.

    .EXAMPLE
        Get-CimInstance -CimSession $session -Namespace 'root\MicrosoftDNS' -Query "SELECT OwnerName, PrimaryName FROM MicrosoftDNS_CNAMEType WHERE ContainerName='contoso.local'"

        Returns the CNAME records of contoso.local.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param (
        [Parameter(Position = 0)]
        [string]$ClassName,

        [Parameter()]
        [string]$Namespace,

        [Parameter()]
        [string]$Query,

        [Parameter()]
        [object]$CimSession,

        [Parameter()]
        [uint32]$OperationTimeoutSec
    )

    $command = 'Get-CimInstance'
    $serverName = 'localhost'
    if ($null -ne $CimSession -and $null -ne $CimSession.PSObject.Properties['ComputerName'] -and $CimSession.ComputerName) {
        $serverName = [string]$CimSession.ComputerName
    }

    $text = $Query
    if (-not $text -and $ClassName) {
        $text = "SELECT * FROM $ClassName"
    }
    if ($text -notmatch '^\s*SELECT\s+.+?\s+FROM\s+(\w+)(?:\s+WHERE\s+(.+?))?\s*$') {
        $null = Register-DnsStubCall -Command $command -ZoneName 'invalid-query' -BoundParameters $PSBoundParameters
        Write-Error -Message "Invalid query '$text' (namespace $Namespace, timeout $OperationTimeoutSec s)." -Category InvalidArgument -ErrorId 'HRESULT 0x80041017,Microsoft.Management.Infrastructure.CimCmdlets.GetCimInstanceCommand' -TargetObject $text
        return
    }
    $class = $Matches[1]
    $whereText = $Matches[2]

    $conditions = @()
    if ($whereText) {
        $conditions = @(
            foreach ($part in ($whereText -split '\s+AND\s+')) {
                if ($part -match "^\s*(\w+)\s*=\s*'((?:[^'\\]|\\.)*)'\s*$") {
                    @{ Property = $Matches[1]; Value = ($Matches[2] -replace '\\(.)', '$1') }
                }
                else {
                    @{ Property = '?'; Value = $part }
                }
            }
        )
    }

    $failKey = $class
    foreach ($condition in $conditions) {
        if ($condition['Property'] -eq 'ContainerName') {
            $failKey = $condition['Value'].TrimEnd('.').ToLowerInvariant()
        }
    }
    if (Register-DnsStubCall -Command $command -ZoneName $failKey -BoundParameters $PSBoundParameters) {
        Write-Error -Message "Stub failure: access denied reading $class on $serverName." -Category PermissionDenied -ErrorId 'HRESULT 0x80041003,Microsoft.Management.Infrastructure.CimCmdlets.GetCimInstanceCommand' -TargetObject $text
        return
    }

    if ($class -eq 'MicrosoftDNS_Server') {
        New-Object -TypeName PSObject -Property ([ordered]@{ Name = $serverName })
        return
    }

    $classes = @{
        MicrosoftDNS_AType     = @{ Type = 'A'; Property = 'IPAddress'; DataProperty = 'IPv4Address' }
        MicrosoftDNS_AAAAType  = @{ Type = 'AAAA'; Property = 'IPv6Address'; DataProperty = 'IPv6Address' }
        MicrosoftDNS_CNAMEType = @{ Type = 'CNAME'; Property = 'PrimaryName'; DataProperty = 'HostNameAlias' }
        MicrosoftDNS_PTRType   = @{ Type = 'PTR'; Property = 'PTRDomainName'; DataProperty = 'PtrDomainName' }
        MicrosoftDNS_NSType    = @{ Type = 'NS'; Property = 'NSHost'; DataProperty = 'NameServer' }
        MicrosoftDNS_MXType    = @{ Type = 'MX'; Property = 'MailExchange'; DataProperty = 'MailExchange' }
        MicrosoftDNS_SRVType   = @{ Type = 'SRV'; Property = 'SRVDomainName'; DataProperty = 'DomainName' }
    }
    $classInfo = $classes[$class]
    if ($null -eq $classInfo) {
        Write-Error -Message "Invalid class '$class'." -Category ObjectNotFound -ErrorId 'HRESULT 0x80041010,Microsoft.Management.Infrastructure.CimCmdlets.GetCimInstanceCommand' -TargetObject $text
        return
    }

    foreach ($zoneKey in @($script:DnsStub.Zones.Keys)) {
        $zone = $script:DnsStub.Zones[$zoneKey]
        foreach ($record in @($script:DnsStub.Records[$zoneKey])) {
            if ($null -eq $record -or $record.RecordType -ne $classInfo['Type']) {
                continue
            }

            $owner = $zone.ZoneName
            if ($record.HostName -ne '@') {
                $owner = $record.HostName + '.' + $zone.ZoneName
            }
            # Addresses in canonical form; names exactly as stored, trailing dot included.
            $value = Get-DnsStubRecordValue -Record $record
            if ($classInfo['Type'] -ne 'A' -and $classInfo['Type'] -ne 'AAAA') {
                $value = [string]$record.RecordData.PSObject.Properties[$classInfo['DataProperty']].Value
            }
            $timestampHours = 0
            if ($null -ne $record.Timestamp) {
                $timestampHours = [int](($record.Timestamp.ToUniversalTime() - [datetime]::FromFileTimeUtc(0)).TotalHours)
            }

            $properties = [ordered]@{
                ContainerName      = $zone.ZoneName
                DnsServerName      = $serverName
                DomainName         = $zone.ZoneName
                OwnerName          = $owner
                RecordClass        = 1
                TTL                = [int]$record.TimeToLive.TotalSeconds
                Timestamp          = $timestampHours
                TextRepresentation = '{0} IN {1} {2}' -f $owner, $classInfo['Type'], $value
            }
            $properties[$classInfo['Property']] = $value
            if ($classInfo['Type'] -eq 'MX') {
                $properties['Preference'] = $record.RecordData.Preference
            }
            if ($classInfo['Type'] -eq 'SRV') {
                $properties['Port'] = $record.RecordData.Port
                $properties['Priority'] = $record.RecordData.Priority
                $properties['Weight'] = $record.RecordData.Weight
            }

            $isMatch = $true
            foreach ($condition in $conditions) {
                $conditionProperty = $condition['Property']
                # Keys -contains, not .Contains(): methods on [ordered] are blocked in CLM on 5.1.
                if (@($properties.Keys) -notcontains $conditionProperty -or [string]$properties[$conditionProperty] -ne $condition['Value']) {
                    $isMatch = $false
                    break
                }
            }
            if (-not $isMatch) {
                continue
            }

            $instance = New-Object -TypeName PSObject -Property $properties
            Add-Member -InputObject $instance -TypeName ('Microsoft.Management.Infrastructure.CimInstance#root/MicrosoftDNS/' + $class)
            $instance
        }
    }
}

Reset-DnsStubStore
