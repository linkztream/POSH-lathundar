<#
.SYNOPSIS
    In-memory stand-ins for the DnsServer cmdlets that DnsLathund calls.

.DESCRIPTION
    Test helper, not part of the module. Defines functions with the names and
    parameters of Get-DnsServerZone, Get-DnsServerZoneAging,
    Get-DnsServerScavenging, Get-DnsServerResourceRecord and Export-DnsServerZone,
    backed by a hashtable store in $script:DnsStub, plus the helpers
    Reset-DnsStubStore, Add-DnsStubZone and Add-DnsStubRecord.

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

    Stubs for state-changing cmdlets (Export-DnsServerZone now, the
    Add-/Remove-/Set- record cmdlets later) declare SupportsShouldProcess like the
    real cmdlets, so module calls with -WhatIf:$false -Confirm:$false bind, and
    they skip the change when $WhatIfPreference is set ($PSCmdlet.ShouldProcess is
    not available in Constrained Language Mode).

    Records mimic the CIM instances of the real cmdlets: HostName (relative, '@' at
    the apex), RecordType, RecordClass, RecordData (IPv4Address / IPv6Address as
    [ipaddress], PtrDomainName / HostNameAlias / NameServer / DomainName /
    MailExchange as FQDN with trailing dot), TimeToLive ([timespan]), Timestamp
    ($null for static records), DistinguishedName and Type.
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
        Zones      = [ordered]@{}
        Records    = @{}
        Aging      = @{}
        Scavenging = $null
        ExportRoot = $ExportRoot
        Fail       = @{}
        Calls      = @{}
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

    .PARAMETER Command
        The stubbed command name.

    .PARAMETER ZoneName
        The zone the call is about; empty for server-level commands.

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
        [string]$ZoneName = ''
    )

    $script:DnsStub.Calls[$Command] = 1 + [int]$script:DnsStub.Calls[$Command]

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
    $record = New-Object -TypeName PSObject -Property ([ordered]@{
            DistinguishedName = 'DC={0},DC={1},cn=MicrosoftDNS,DC=DomainDnsZones,{2}' -f $nodeName, $script:DnsStub.Zones[$zoneKey].ZoneName, $zoneDn
            HostName          = $nodeName
            RecordClass       = 'IN'
            RecordData        = $recordDataObject
            RecordType        = $recordType
            Timestamp         = $recordTimestamp
            TimeToLive        = New-TimeSpan -Seconds $TimeToLive
            Type              = $typeNumber
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
        Write-Error -Message "Stub failure: could not read records of zone $ZoneName on server $serverName." -Category ConnectionError -ErrorId 'WIN32 1722,Get-DnsServerResourceRecord' -TargetObject $ZoneName
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

    foreach ($record in $records) {
        if (-not $RRType -or $record.RecordType -eq $RRType) {
            $record
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

Reset-DnsStubStore
