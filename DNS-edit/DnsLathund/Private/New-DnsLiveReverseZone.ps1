function New-DnsLiveReverseZone {
    <#
    .SYNOPSIS
        Creates an AD-integrated reverse lookup zone with the settings of a forward zone, inside the caller's batch.

    .DESCRIPTION
        Does everything New-DnsReverseZone describes (CONTRACTS.md sections 7.5
        and 13.7), so that New-DnsReverseZone and New-DnsEntry -CreateReverseZone
        create zones the same way and within the run of the calling command:

        - The zone name comes from Get-DnsReverseZoneName.
        - A zone that is already hosted, or WIN32 9609
          (DNS_ERROR_ZONE_ALREADY_EXISTS) from Add-DnsServerPrimaryZone, is
          AlreadyDone and left as it is.
        - Add-DnsServerPrimaryZone -NetworkId -ReplicationScope Custom
          -DirectoryPartitionName <partition of -CopySettingsFrom> -DynamicUpdate
          <its setting>, unless -ReplicationScope or -DynamicUpdate say otherwise.
          A file-backed or Legacy source zone needs -ReplicationScope.
        - One gate: Confirm-DnsAction -Impact High -State $Batch['Confirm']
          -Force:$Batch['Force']. Because the state belongs to the batch, an [A]ll
          at this prompt also approves the next zone of the same run, and an [A]ll
          at a Medium prompt never approves it. Declined: Skipped with Error
          'Declined at the confirmation prompt.'
        - Set-DnsServerZoneAging with the aging settings of the source zone; when
          those could not be read, the step is Skipped with a warning.
        - Get-DnsZoneTable -Refresh after a creation (never under -WhatIf), and
          the warning that other domain controllers see the zone only after
          replication.

        Emits only the DnsLathund.Result objects CreateZone (Data = the network)
        and SetZoneAging (only when the zone was created, or would be under
        -WhatIf), through Write-DnsResult with the given batch, so they carry the
        caller's BatchId. The caller reads the CreateZone Result: Success,
        AlreadyDone or WhatIf means the zone is there for the PTR step.

        Every error is terminating (Write-Error -ErrorAction Stop) and comes after
        the Result it belongs to, with ErrorId
        DnsLathund.New-DnsLiveReverseZone.<Reason>:
          InvalidNetworkId          -NetworkId has no zone of its own; Failed CreateZone
                                    (Name and Data = -NetworkId, Zone $null)
          ZoneNotFound              -CopySettingsFrom is not hosted; Failed CreateZone
          ReplicationScopeRequired  the source zone has no partition to copy; Failed
                                    CreateZone
          CreateFailed              Add-DnsServerPrimaryZone failed; Failed CreateZone
          AgingFailed               Set-DnsServerZoneAging failed; Failed SetZoneAging,
                                    raised after the zone table refresh and the warnings
          ServerUnreachable         Test-DnsConnectionError recognised the error of
                                    either cmdlet; the message is the batch-abort text
                                    of CONTRACTS.md section 13.9
        The public caller catches them and re-raises them under its own name
        (DnsLathund.<Cmd>.<Reason>, same message and category), terminating for
        ServerUnreachable, as with Resolve-DnsChangeTarget.
        DnsLathund.Confirm.NonInteractive and [S]top from the gate pass through
        unchanged.

        $WhatIfPreference and $ConfirmPreference reach this helper and
        Confirm-DnsAction from the public command by dynamic scoping. Never logs
        or emits anything except through Write-DnsResult.

    .PARAMETER Batch
        The batch of the calling command (New-DnsBatch): server, log path, Force,
        confirmation state and counts.

    .PARAMETER NetworkId
        The network in CIDR form ('10.0.17.0/24', '2001:db8:0:1::/64'). Host bits
        are ignored.

    .PARAMETER CopySettingsFrom
        The hosted zone whose partition, dynamic update and aging settings the new
        zone gets.

    .PARAMETER ZoneTable
        The zone table of the batch's server (Get-DnsZoneTable).

    .PARAMETER ServerParameter
        The splat from Get-DnsServerParameter.

    .PARAMETER ReplicationScope
        Domain, Forest, Legacy or Custom instead of the partition of
        -CopySettingsFrom. Custom always uses that partition.

    .PARAMETER DynamicUpdate
        None, NonsecureAndSecure or Secure instead of the setting of
        -CopySettingsFrom.

    .PARAMETER Credential
        The caller's -Credential, for the zone table refresh.

    .PARAMETER TimeoutSec
        The caller's -TimeoutSec, for the zone table refresh. Default: 300.

    .OUTPUTS
        DnsLathund.Result

    .EXAMPLE
        New-DnsLiveReverseZone -Batch $batch -NetworkId '10.0.99.0/24' -CopySettingsFrom 'contoso.local' -ZoneTable $zoneTable -ServerParameter $serverParameter

        Creates 99.0.10.in-addr.arpa with the settings of contoso.local after the
        High gate, and returns the CreateZone and SetZoneAging Results of $batch.
    #>
    [CmdletBinding()]
    [OutputType('DnsLathund.Result')]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Batch,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NetworkId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CopySettingsFrom,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$ZoneTable,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$ServerParameter,

        [Parameter()]
        [ValidateSet('Domain', 'Forest', 'Legacy', 'Custom')]
        [string]$ReplicationScope,

        [Parameter()]
        [ValidateSet('None', 'NonsecureAndSecure', 'Secure')]
        [string]$DynamicUpdate,

        [Parameter()]
        [AllowNull()]
        [pscredential]$Credential,

        [Parameter()]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSec = 300
    )

    $serverKey = $Batch['Server']
    $errorPrefix = 'DnsLathund.New-DnsLiveReverseZone.'

    # --- The zone name; without one there is nothing to create ---
    $reverseZone = $null
    try {
        $reverseZone = Get-DnsReverseZoneName -NetworkId $NetworkId
    }
    catch {
        $message = $_.Exception.Message
        $networkText = $NetworkId.Trim()
        Write-DnsResult -Batch $Batch -Action 'CreateZone' -Name $networkText -Type $null -Data $networkText -Zone $null -NodeName $null -Result 'Failed' -ErrorMessage $message
        Write-Error -Message $message -Category InvalidArgument -ErrorId ($errorPrefix + 'InvalidNetworkId') -TargetObject $NetworkId -ErrorAction Stop
    }
    $zoneName = $reverseZone['ZoneName']
    $network = $reverseZone['Network']

    $createResult = @{ Batch = $Batch; Action = 'CreateZone'; Name = $zoneName; Type = $null; Data = $network; Zone = $zoneName; NodeName = $null }

    $existingZone = $ZoneTable.ZoneLookup[$zoneName]
    if ($null -ne $existingZone) {
        Write-Verbose "Zone '$zoneName' is already hosted on '$serverKey' ($($existingZone.ZoneType)); it is left as it is."
        Write-DnsResult @createResult -Result 'AlreadyDone'
        return
    }

    # --- Settings from the -CopySettingsFrom zone ---
    $sourceName = ConvertTo-DnsNormalizedName -Name $CopySettingsFrom
    $source = $ZoneTable.ZoneLookup[$sourceName]
    if ($null -eq $source) {
        $message = "Zone '$CopySettingsFrom' (-CopySettingsFrom) is not hosted on '$serverKey'. Give a zone hosted on that server; the new zone copies its replication, dynamic update and aging settings."
        Write-DnsResult @createResult -Result 'Failed' -ErrorMessage $message
        Write-Error -Message $message -Category ObjectNotFound -ErrorId ($errorPrefix + 'ZoneNotFound') -TargetObject $CopySettingsFrom -ErrorAction Stop
    }

    $sourcePartition = $source.DirectoryPartitionName
    $sourceInAd = ($source.IsDsIntegrated -eq $true) -and [bool]$sourcePartition
    $sourceIsLegacy = [string]$source.ReplicationScope -eq 'Legacy'
    $scope = $ReplicationScope
    $partition = $null
    $settingsProblem = $null
    if (-not $scope) {
        # Custom with the source's partition gives the same zone as Domain or Forest
        # and stays right when the command runs from a child domain. A file-backed or
        # Legacy zone has no DNS application partition to copy.
        if (-not $sourceInAd) {
            $settingsProblem = "Zone '$sourceName' is not stored in Active Directory (file-backed), so the new zone cannot copy its directory partition. Specify -ReplicationScope (Domain, Forest, Legacy or Custom)."
        }
        elseif ($sourceIsLegacy) {
            $settingsProblem = "Zone '$sourceName' uses the Legacy replication scope, so the new zone cannot copy its directory partition. Specify -ReplicationScope (Domain, Forest, Legacy or Custom)."
        }
        $scope = 'Custom'
        $partition = $sourcePartition
    }
    elseif ($scope -eq 'Custom') {
        if (-not $sourceInAd -or $sourceIsLegacy) {
            $settingsProblem = "-ReplicationScope Custom uses the directory partition of zone '$sourceName', which has none to copy (file-backed or Legacy). Specify -ReplicationScope Domain, Forest or Legacy instead."
        }
        $partition = $sourcePartition
    }
    if ($settingsProblem) {
        Write-DnsResult @createResult -Result 'Failed' -ErrorMessage $settingsProblem
        Write-Error -Message $settingsProblem -Category InvalidArgument -ErrorId ($errorPrefix + 'ReplicationScopeRequired') -TargetObject $CopySettingsFrom -ErrorAction Stop
    }

    $dynamicSetting = $DynamicUpdate
    if (-not $dynamicSetting -and $source.DynamicUpdate) {
        $dynamicSetting = [string]$source.DynamicUpdate
    }

    # --- Aging settings to copy; $null aging fields mean they could not be read ---
    $agingKnown = $null -ne $source.AgingEnabled
    $agingParameters = @{ Name = $zoneName }
    $agingText = $null
    if ($agingKnown) {
        $agingParameters['Aging'] = [bool]$source.AgingEnabled
        if ($null -ne $source.NoRefreshInterval) {
            $agingParameters['NoRefreshInterval'] = [timespan]$source.NoRefreshInterval
        }
        if ($null -ne $source.RefreshInterval) {
            $agingParameters['RefreshInterval'] = [timespan]$source.RefreshInterval
        }
        # Set-DnsServerZoneAging takes IP addresses; the zone table keeps strings.
        $scavengeServers = [ipaddress[]]@(
            foreach ($scavengeServer in @($source.ScavengeServers)) {
                if (-not $scavengeServer) {
                    continue
                }
                $scavengeAddress = ConvertTo-DnsNormalizedAddress -Address ([string]$scavengeServer)
                if ($null -eq $scavengeAddress) {
                    Write-Warning "Scavenge server '$scavengeServer' of zone '$sourceName' is not an IP address and is not copied to '$zoneName'."
                    continue
                }
                [ipaddress]$scavengeAddress
            }
        )
        $scavengeText = 'any'
        if ($scavengeServers.Count -gt 0) {
            $agingParameters['ScavengeServers'] = $scavengeServers
            $scavengeText = @(foreach ($scavengeAddress in $scavengeServers) { $scavengeAddress.IPAddressToString }) -join ' '
        }
        $agingText = 'Aging={0}, NoRefreshInterval={1}, RefreshInterval={2}, ScavengeServers={3}' -f $agingParameters['Aging'], $agingParameters['NoRefreshInterval'], $agingParameters['RefreshInterval'], $scavengeText
    }
    $agingResult = @{ Batch = $Batch; Action = 'SetZoneAging'; Name = $zoneName; Type = $null; Data = $agingText; Zone = $zoneName; NodeName = $null }
    $agingSkippedText = "The aging settings of zone '$sourceName' could not be read, so '$zoneName' keeps the server's default aging. Check them with Get-DnsServerZoneAging -Name $sourceName and set them with Set-DnsServerZoneAging."

    # --- One confirmation (impact High) for the zone and its aging ---
    $settingsText = "replication scope $scope"
    if ($partition) {
        $settingsText = "$settingsText ($partition)"
    }
    if ($dynamicSetting) {
        $settingsText = "$settingsText, dynamic update $dynamicSetting"
    }
    $gateTarget = "$zoneName ($network) on $serverKey, settings from ${sourceName}: $settingsText"
    # The batch's own state, so that [A]ll at High carries to the next zone of the
    # same run. -ErrorAction Stop turns the non-interactive refusal into the one
    # terminating error that ends the batch (CONTRACTS.md section 5.8).
    $approved = Confirm-DnsAction -Target $gateTarget -Action 'Create reverse zone' -Impact High -State $Batch['Confirm'] -Force:([bool]$Batch['Force']) -ErrorAction Stop
    if (-not $approved) {
        if ($WhatIfPreference) {
            Write-DnsResult @createResult -Result 'WhatIf'
            if ($agingKnown) {
                Write-DnsResult @agingResult -Result 'WhatIf'
            }
            else {
                Write-Warning $agingSkippedText
                Write-DnsResult @agingResult -Result 'Skipped' -ErrorMessage $agingSkippedText
            }
        }
        else {
            Write-DnsResult @createResult -Result 'Skipped' -ErrorMessage 'Declined at the confirmation prompt.'
        }
        return
    }

    # --- Create the zone ---
    $createParameters = @{ NetworkId = $network; ReplicationScope = $scope }
    if ($scope -eq 'Custom') {
        $createParameters['DirectoryPartitionName'] = $partition
    }
    if ($dynamicSetting) {
        $createParameters['DynamicUpdate'] = $dynamicSetting
    }
    Write-Verbose "Creating zone '$zoneName' for $network on '$serverKey' with $settingsText (Add-DnsServerPrimaryZone)."
    $createErrors = $null
    $null = Add-DnsServerPrimaryZone @ServerParameter @createParameters -WhatIf:$false -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable createErrors

    $createError = $null
    foreach ($candidateError in @($createErrors)) {
        if ($null -ne $candidateError) {
            $createError = $candidateError
            break
        }
    }
    if ($null -ne $createError) {
        # WIN32 9609 (DNS_ERROR_ZONE_ALREADY_EXISTS): created by someone else since
        # the zone list was read. The wanted state holds.
        if ([string]$createError.FullyQualifiedErrorId -like '*9609*') {
            Write-Verbose "Zone '$zoneName' was created on '$serverKey' by someone else in the meantime; it is left as it is."
            Write-DnsResult @createResult -Result 'AlreadyDone'
            $null = Get-DnsZoneTable -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec -Refresh
            return
        }

        $message = "Could not create zone '$zoneName' on '$serverKey': $($createError.Exception.Message)"
        Write-DnsResult @createResult -Result 'Failed' -ErrorMessage $message
        if (Test-DnsConnectionError -ErrorRecord $createError) {
            Write-Error -Message "The DNS server '$serverKey' cannot be reached: $($createError.Exception.Message) The run was stopped; the remaining input was not processed. Check the server and run the command again." -Category ConnectionError -ErrorId ($errorPrefix + 'ServerUnreachable') -TargetObject $zoneName -ErrorAction Stop
        }
        Write-Error -Message $message -Category $createError.CategoryInfo.Category -ErrorId ($errorPrefix + 'CreateFailed') -TargetObject $zoneName -ErrorAction Stop
    }
    Write-DnsResult @createResult -Result 'Success'

    # --- Copy the aging settings ---
    $agingFailure = $null
    if (-not $agingKnown) {
        Write-Warning $agingSkippedText
        Write-DnsResult @agingResult -Result 'Skipped' -ErrorMessage $agingSkippedText
    }
    else {
        Write-Verbose "Setting aging of zone '$zoneName' on '$serverKey' to $agingText (Set-DnsServerZoneAging)."
        $agingErrors = $null
        $null = Set-DnsServerZoneAging @ServerParameter @agingParameters -WhatIf:$false -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable agingErrors

        $agingError = $null
        foreach ($candidateError in @($agingErrors)) {
            if ($null -ne $candidateError) {
                $agingError = $candidateError
                break
            }
        }
        if ($null -ne $agingError) {
            $message = "Zone '$zoneName' was created, but its aging settings could not be set: $($agingError.Exception.Message) Set them with Set-DnsServerZoneAging -Name $zoneName."
            Write-DnsResult @agingResult -Result 'Failed' -ErrorMessage $message
            if (Test-DnsConnectionError -ErrorRecord $agingError) {
                Write-Error -Message "The DNS server '$serverKey' cannot be reached: $($agingError.Exception.Message) The run was stopped; the remaining input was not processed. Check the server and run the command again." -Category ConnectionError -ErrorId ($errorPrefix + 'ServerUnreachable') -TargetObject $zoneName -ErrorAction Stop
            }
            # Raised at the end: the zone exists, so the zone table refresh and the
            # replication warning must still happen.
            $agingFailure = @{ Message = $message; Category = $agingError.CategoryInfo.Category }
        }
        else {
            Write-DnsResult @agingResult -Result 'Success'
        }
    }

    # The cached zone list must know the new zone, so that the caller's PTR step and
    # every later command in this session put PTR records into it.
    $refreshedTable = Get-DnsZoneTable -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec -Refresh
    if ($null -eq $refreshedTable.ZoneLookup[$zoneName]) {
        Write-Warning "Zone '$zoneName' was created, but '$serverKey' does not list it under that name. Check the zone list with Get-DnsServerZone -ComputerName $serverKey."
    }
    Write-Warning "Zone '$zoneName' was created on '$serverKey'. Other domain controllers see it only after Active Directory replication plus their DsPollingInterval (180 seconds by default); until then, create its records on '$serverKey'."

    if ($null -ne $agingFailure) {
        Write-Error -Message $agingFailure['Message'] -Category $agingFailure['Category'] -ErrorId ($errorPrefix + 'AgingFailed') -TargetObject $zoneName -ErrorAction Stop
    }
}
