function New-DnsReverseZone {
    <#
    .SYNOPSIS
        Creates an Active Directory-integrated reverse lookup zone with the settings of an existing zone.

    .DESCRIPTION
        New-DnsReverseZone creates the reverse lookup zone (in-addr.arpa or
        ip6.arpa) for one network on one Microsoft DNS server, so that PTR records
        for the addresses in that network can be created. The zone name follows
        from -NetworkId: an IPv4 /8, /16 or /24 network, or an IPv6 network whose
        prefix is a multiple of 4 ('10.0.16.0/24' gives 16.0.10.in-addr.arpa).
        Host bits are ignored, so '10.0.16.5/24' gives the same zone.

        The new zone copies its settings from the zone named in -CopySettingsFrom,
        usually the forward zone of the hosts that will get PTR records:

        - Replication: the zone is stored in the same Active Directory partition
          (ReplicationScope Custom with that zone's DirectoryPartitionName). That
          gives the same result as Domain or Forest and is also right when the
          command runs from a child domain. -ReplicationScope overrides this and is
          required when the source zone is file-backed or uses the Legacy scope.
        - Dynamic update: the source zone's setting, unless -DynamicUpdate is given.
        - Aging: aging on or off, the no-refresh and refresh intervals and the
          scavenge servers are copied with Set-DnsServerZoneAging. When the source
          zone's aging settings could not be read, this step is skipped with a
          warning.

        A zone that is already hosted on the server is reported as AlreadyDone
        and left exactly as it is; its settings are not changed. The command asks
        for confirmation once (impact High: it prompts with the default
        $ConfirmPreference); -Force or -Confirm:$false confirm without asking, and
        -WhatIf shows what would be created. Every step is written to the change
        log and returned as a DnsLathund.Result object.

        New-DnsEntry -CreateReverseZone creates zones in exactly the same way, for
        the /24 (IPv4) or /64 (IPv6) network around an address that has no reverse
        zone yet, as part of its own run.

        What it does NOT do: it does not create classless (RFC 2317) reverse zones
        or zones for prefixes that are not on a label boundary (/23, /25, /62
        ...), file-backed zones, secondary or stub zones, or delegations in a
        parent zone; it does not change an existing zone; it does not create any
        records; and it does not wait for Active Directory replication.

    .PARAMETER NetworkId
        The network the zone covers, as address/prefix: '10.0.16.0/24',
        '172.20.0.0/16', '2001:db8:0:1::/64'. IPv4 prefixes must be 8, 16 or 24;
        IPv6 prefixes a multiple of 4 between 4 and 124. Any other prefix stops the
        command with an error that names the nearest allowed prefixes.

    .PARAMETER CopySettingsFrom
        The zone whose replication, dynamic update and aging settings the new zone
        gets, usually the forward zone of the hosts ('contoso.local'). It must be
        hosted on -Server.

    .PARAMETER ReplicationScope
        Domain, Forest, Legacy or Custom. Without it the new zone is stored in the
        same directory partition as the -CopySettingsFrom zone (Custom). Required
        when that zone is file-backed or uses Legacy. Custom always uses the
        partition of the -CopySettingsFrom zone.

    .PARAMETER DynamicUpdate
        None, NonsecureAndSecure or Secure. Without it the setting of the
        -CopySettingsFrom zone is used.

    .PARAMETER Server
        The DNS server that gets the zone. Default: the logon server
        ($env:LOGONSERVER without the leading backslashes).

    .PARAMETER Credential
        Alternate credentials. All DnsServer calls then go through a CIM session;
        the command throws when none can be opened and never falls back to the
        logged-on user.

    .PARAMETER TimeoutSec
        Timeout in seconds for the CIM session and remote operations. Default: 300.

    .PARAMETER LogPath
        The change-log file (JSON lines). Default: $env:DNSLATHUND_LOGPATH, else
        %LOCALAPPDATA%\DnsLathund\log\DnsLathund_<yyyy-MM>.jsonl. -WhatIf runs are
        logged too.

    .PARAMETER Force
        Create the zone without asking for confirmation. -Force changes nothing
        else: the checks and the -ReplicationScope rule still apply.

    .EXAMPLE
        New-DnsReverseZone -NetworkId 10.0.17.0/24 -CopySettingsFrom contoso.local -Server dc01

        Creates 17.0.10.in-addr.arpa on dc01, in the same Active Directory partition
        as contoso.local and with its dynamic update and aging settings, after
        asking for confirmation. The two Result objects (CreateZone and
        SetZoneAging) show what was done.

    .EXAMPLE
        '10.0.17.0/24', '10.0.18.0/24' | ForEach-Object { New-DnsReverseZone -NetworkId $_ -CopySettingsFrom contoso.local -Server dc01 -WhatIf }

        Shows, for two networks, which zones would be created and with which
        settings, without changing anything. The "What if:" lines name each zone
        and its settings; the Result objects have Result = WhatIf and are logged.

    .EXAMPLE
        $results = @(New-DnsReverseZone -NetworkId '2001:db8:0:1::/64' -CopySettingsFrom contoso.local -ReplicationScope Forest -DynamicUpdate Secure -Server dc01 -Force -LogPath 'D:\Logs\dns-changes.jsonl' -ErrorAction Stop)
        if ($results.Result -contains 'Failed') { throw 'The reverse zone was not set up completely.' }

        For a scheduled task or another unattended script: creates the IPv6 reverse
        zone forest-wide with secure dynamic updates, never prompts, writes the
        change log to a fixed file and stops on the first error. A zone that
        already exists gives one Result with AlreadyDone, which is a success.

    .INPUTS
        None

        New-DnsReverseZone does not take pipeline input. Call it once per network,
        for example inside ForEach-Object.

    .OUTPUTS
        DnsLathund.Result

        One object for the zone creation (Action CreateZone) and, when the zone was
        created or would be created under -WhatIf, one for the aging settings
        (Action SetZoneAging). Properties, in this order:
        - Action (string): CreateZone or SetZoneAging.
        - Name (string): the zone name, for example 17.0.10.in-addr.arpa.
        - Type (string): always $null for zone operations.
        - Data (string): CreateZone: the network ('10.0.17.0/24'); SetZoneAging: the aging settings that were copied.
        - Result (string): Success, Failed, Skipped, WhatIf or AlreadyDone.
        - Error (string): why the step failed or was skipped; $null otherwise.
        - Zone (string): the zone name.
        - NodeName (string): always $null for zone operations.
        - Server (string): the DNS server, lower case.
        - Id (string): the GUID of this result, also in the change log.
        - BatchId (string): the GUID shared by every result of this run.
        - Timestamp (datetime): when the result was produced.

    .NOTES
        - Replication: other domain controllers see the new zone only after Active
          Directory replication plus their DsPollingInterval (180 seconds by
          default). Until then, create its PTR records on the same -Server; a
          warning says so after every creation.
        - The -CopySettingsFrom zone must be stored in Active Directory with the
          Domain, Forest or Custom scope; for a file-backed or Legacy zone give
          -ReplicationScope. New-DnsEntry -CreateReverseZone cannot pass
          -ReplicationScope, so create such zones with this command first.
        - Aging: when the aging settings of the -CopySettingsFrom zone could not be
          read (access denied, older server), the new zone keeps the server's
          default aging and a warning says so. Scavenge servers are copied as IP
          addresses.
        - A zone that already exists is never changed, even when its settings
          differ from those of the -CopySettingsFrom zone.
        - Server unreachable (RPC 1722, WinRM or CIM transport failure): the
          Failed result is written, then the command stops with the error
          DnsLathund.New-DnsReverseZone.ServerUnreachable.
        - An invalid -NetworkId stops the command with the error
          DnsLathund.New-DnsReverseZone.InvalidNetworkId before the server is
          contacted.
        - Change several domain controllers in one session only with care: a
          warning appears when this session already changed another server. A
          -WhatIf run changes nothing and does not count.
        - Works in Constrained Language Mode. Needs the DnsServer module (RSAT: DNS
          Server Tools).
        - The change log is UTF-8; Windows PowerShell 5.1 writes a BOM when it
          creates the file, PowerShell 7 does not. Both read either.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('DnsLathund.Result')]
    param (
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NetworkId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CopySettingsFrom,

        [Parameter()]
        [ValidateSet('Domain', 'Forest', 'Legacy', 'Custom')]
        [string]$ReplicationScope,

        [Parameter()]
        [ValidateSet('None', 'NonsecureAndSecure', 'Secure')]
        [string]$DynamicUpdate,

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

    # An unusable network makes the whole call pointless; it is reported before the
    # server is contacted, with the nearest allowed prefixes as the hint.
    # New-DnsLiveReverseZone checks it again for its other callers.
    try {
        $null = Get-DnsReverseZoneName -NetworkId $NetworkId
    }
    catch {
        Write-Error -Message $_.Exception.Message -Category InvalidArgument -ErrorId 'DnsLathund.New-DnsReverseZone.InvalidNetworkId' -TargetObject $NetworkId -ErrorAction Stop
    }

    $serverKey = Resolve-DnsServerName -Server $Server
    $batch = New-DnsBatch -Server $serverKey -LogPath $LogPath -Force:$Force
    # A preview changes nothing, so it must not become the session's writer server.
    if (-not $WhatIfPreference) {
        Test-DnsWriterServer -Server $serverKey
    }
    $zoneTable = Get-DnsZoneTable -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec
    $serverParameter = Get-DnsServerParameter -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec

    $zoneParameters = @{
        Batch            = $batch
        NetworkId        = $NetworkId
        CopySettingsFrom = $CopySettingsFrom
        ZoneTable        = $zoneTable
        ServerParameter  = $serverParameter
        Credential       = $Credential
        TimeoutSec       = $TimeoutSec
    }
    if ($ReplicationScope) {
        $zoneParameters['ReplicationScope'] = $ReplicationScope
    }
    if ($DynamicUpdate) {
        $zoneParameters['DynamicUpdate'] = $DynamicUpdate
    }

    # The helper does the work and writes the Results; its errors are terminating
    # and come after their Result. They are raised again under this command's name:
    # a bad network or an unreachable server ends the call, the rest is per item
    # (CONTRACTS.md sections 5.2 and 13.9).
    try {
        New-DnsLiveReverseZone @zoneParameters
    }
    catch {
        $zoneError = $_
        $errorId = [string]$zoneError.FullyQualifiedErrorId
        $reasonPrefix = 'DnsLathund.New-DnsLiveReverseZone.'
        if (-not $errorId.StartsWith($reasonPrefix)) {
            # DnsLathund.Confirm.NonInteractive and [S]top end the call as they are.
            throw
        }

        $reason = $errorId.Split(',')[0].Substring($reasonPrefix.Length)
        $ownError = @{
            Message      = $zoneError.Exception.Message
            Category     = $zoneError.CategoryInfo.Category
            ErrorId      = 'DnsLathund.New-DnsReverseZone.' + $reason
            TargetObject = $zoneError.TargetObject
        }
        if ($reason -eq 'ServerUnreachable' -or $reason -eq 'InvalidNetworkId') {
            Write-Error @ownError -ErrorAction Stop
        }
        Write-Error @ownError
    }
}
