function Resolve-DnsChangeTarget {
    <#
    .SYNOPSIS
        Turns one input item of a change command into the zone, node and record it is about.

    .DESCRIPTION
        Change commands accept Entry objects from Get-DnsEntry, plain strings and CSV
        rows. This helper classifies one item and returns a hashtable with the keys
        Kind, Fqdn, Zone, NodeName, Address, Type, Data and Server (CONTRACTS.md
        section 7.5):

        - Entry object (type name DnsLathund.Entry, or Deserialized.DnsLathund.Entry
          after Export-Clixml / Import-Clixml or remoting): the identity is taken from
          the entry's Name, Type, Data, Zone, NodeName and Server, so it names one
          exact record. Kind is 'Cname' for a CNAME entry and 'Name' otherwise;
          Address is the entry's Data for A/AAAA. A wildcard owner ('*.contoso.local')
          is a real record name here and is accepted. The entry's zone must be hosted
          on the server of -ZoneTable.
        - String, checked in this order:
            contains '*' or '?'                   -> error PatternNotAllowed
            an IPv4 or IPv6 address               -> Kind 'Address', Address set
            a name with a dot inside a hosted
            forward zone (longest zone wins; with
            -Zone it must lie inside -Zone)       -> Kind 'Name'
            a bare name (no dot) and -Zone        -> Kind 'Name' in -Zone ('@' = apex)
            a bare name without -Zone, or a name
            with a dot outside every hosted
            forward zone                          -> error ZoneNotFound
          Type, Data and Server are $null: a string names a node or an address, not
          one record.
        - CSV row (hashtable from Read-DnsInputFile -Csv): the Name column is the
          identity (the Address column when Name is empty) and is resolved like a
          string; the row's Zone column overrides -Zone. An Address column sets Type
          (A or AAAA) and Data to the canonical address; a Target column sets Kind
          'Cname', Type CNAME and Data to the target; a row with both is rejected,
          also when its Name cell is empty. The TTL column is left to the caller.

        Errors are thrown as terminating errors (Write-Error -ErrorAction Stop) so the
        caller can turn each into its own per-item, non-terminating error and Result.
        The ErrorId is DnsLathund.Resolve-DnsChangeTarget.<Reason>, with Reason one of
        PatternNotAllowed, ZoneNotFound or InvalidInput (empty identity, a CSV row
        with both Address and Target, or an Address cell that is not an address); the
        caller reads the reason from the part of $_.FullyQualifiedErrorId before the
        first comma and reports DnsLathund.<Command>.<Reason>. Category and message
        are meant to be passed on unchanged.

    .PARAMETER InputObject
        One input item: an Entry object, a string or a CSV row hashtable.

    .PARAMETER ZoneTable
        The zone table of the server the command changes (Get-DnsZoneTable).

    .PARAMETER Zone
        The command's -Zone: the zone for bare names, and a restriction for FQDNs.

    .OUTPUTS
        System.Collections.Hashtable

    .EXAMPLE
        Resolve-DnsChangeTarget -InputObject 'srv01.contoso.local' -ZoneTable $zoneTable

        Returns @{ Kind = 'Name'; Fqdn = 'srv01.contoso.local'; Zone = 'contoso.local'; NodeName = 'srv01'; ... }.

    .EXAMPLE
        try { $target = Resolve-DnsChangeTarget -InputObject $item -ZoneTable $zoneTable -Zone $Zone }
        catch {
            $reason = (([string]$_.FullyQualifiedErrorId).Split(',')[0]).Split('.')[-1]
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId "DnsLathund.Remove-DnsEntry.$reason" -TargetObject $item
        }

        How a public command turns a failed resolution into its own per-item error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$ZoneTable,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Zone
    )

    $errorPrefix = 'DnsLathund.Resolve-DnsChangeTarget.'
    $zoneLookup = $ZoneTable.ZoneLookup
    $serverText = 'the server'
    if ($null -ne $ZoneTable.PSObject.Properties['Server'] -and $ZoneTable.Server) {
        $serverText = "'" + [string]$ZoneTable.Server + "'"
    }

    $target = @{ Kind = 'Name'; Fqdn = $null; Zone = $null; NodeName = $null; Address = $null; Type = $null; Data = $null; Server = $null }

    $typeNames = @()
    if ($null -ne $InputObject) {
        $typeNames = @($InputObject.PSObject.TypeNames)
    }

    # --- Entry object: one exact record ---
    if ($typeNames -contains 'DnsLathund.Entry' -or $typeNames -contains 'Deserialized.DnsLathund.Entry') {
        $values = @{}
        foreach ($propertyName in @('Name', 'Type', 'Data', 'Zone', 'NodeName', 'Server')) {
            $values[$propertyName] = $null
            $property = $InputObject.PSObject.Properties[$propertyName]
            if ($null -ne $property -and $null -ne $property.Value -and '' -ne [string]$property.Value) {
                $values[$propertyName] = [string]$property.Value
            }
        }

        $fqdn = ConvertTo-DnsNormalizedName -Name $values['Name']
        if (-not $fqdn) {
            Write-Error -Message 'The entry has no Name. Pipe entries straight from Get-DnsEntry.' -Category InvalidArgument -ErrorId ($errorPrefix + 'InvalidInput') -TargetObject $InputObject -ErrorAction Stop
        }

        $entryZone = ConvertTo-DnsNormalizedName -Name $values['Zone']
        if (-not $entryZone) {
            foreach ($candidate in @(Find-DnsZoneForName -Name $fqdn -ZoneTable $ZoneTable)) {
                $entryZone = $candidate
                break
            }
        }
        if (-not $entryZone -or -not $zoneLookup.ContainsKey($entryZone)) {
            Write-Error -Message "The zone '$entryZone' of entry '$fqdn' is not hosted on $serverText. Run the command against the server the entry came from (-Server), or read the entry again from this server with Get-DnsEntry." -Category ObjectNotFound -ErrorId ($errorPrefix + 'ZoneNotFound') -TargetObject $InputObject -ErrorAction Stop
        }

        $nodeName = $values['NodeName']
        if (-not $nodeName) {
            $nodeName = '@'
            if ($fqdn -ne $entryZone) {
                $nodeName = $fqdn.Substring(0, $fqdn.Length - $entryZone.Length - 1)
            }
        }

        $type = $null
        if ($values['Type']) {
            $type = $values['Type'].ToUpperInvariant()
        }
        $data = $values['Data']
        if ($null -ne $data) {
            if ($type -eq 'A' -or $type -eq 'AAAA') {
                $address = ConvertTo-DnsNormalizedAddress -Address $data
                if ($null -ne $address) {
                    $data = $address
                }
                $target['Address'] = $data
            }
            else {
                $data = ConvertTo-DnsNormalizedName -Name $data
            }
        }

        if ($type -eq 'CNAME') {
            $target['Kind'] = 'Cname'
        }
        $target['Fqdn'] = $fqdn
        $target['Zone'] = $entryZone
        $target['NodeName'] = $nodeName
        $target['Type'] = $type
        $target['Data'] = $data
        $target['Server'] = $values['Server']
        return $target
    }

    # --- CSV row or string: one identity text plus an optional zone ---
    $row = $null
    $zoneText = $Zone
    if ($InputObject -is [System.Collections.IDictionary]) {
        $row = @{}
        foreach ($columnName in @('Name', 'Address', 'Target', 'TTL', 'Zone')) {
            $row[$columnName] = $null
            $cell = $InputObject[$columnName]
            if ($null -ne $cell -and '' -ne ([string]$cell).Trim()) {
                $row[$columnName] = ([string]$cell).Trim()
            }
        }
        $identity = $row['Name']
        if (-not $identity) {
            $identity = $row['Address']
        }
        if ($row['Zone']) {
            $zoneText = $row['Zone']
        }
    }
    elseif ($null -ne $InputObject) {
        $identity = ([string]$InputObject).Trim()
    }
    else {
        $identity = ''
    }

    # Checked before the identity is resolved: the row is contradictory whatever
    # its Name says, and with an empty Name it would otherwise pass as a plain
    # address and the Target would be dropped without a word.
    if ($null -ne $row -and $row['Address'] -and $row['Target']) {
        Write-Error -Message "The row for '$identity' has both an Address and a Target. A name is either a host (Address) or an alias (Target)." -Category InvalidArgument -ErrorId ($errorPrefix + 'InvalidInput') -TargetObject $InputObject -ErrorAction Stop
    }

    if (-not $identity) {
        Write-Error -Message 'An input item is empty. Give a name, an address, or a CSV row with a Name column.' -Category InvalidArgument -ErrorId ($errorPrefix + 'InvalidInput') -TargetObject $InputObject -ErrorAction Stop
    }

    if ($identity.IndexOf('*') -ge 0 -or $identity.IndexOf('?') -ge 0) {
        Write-Error -Message "'$identity' is a pattern. Change commands take exact names or addresses; find the entries with Get-DnsEntry -Find '$identity', check them, and pipe them to this command." -Category InvalidArgument -ErrorId ($errorPrefix + 'PatternNotAllowed') -TargetObject $InputObject -ErrorAction Stop
    }

    $zoneFilter = ConvertTo-DnsNormalizedName -Name $zoneText
    if ($zoneFilter -and -not $zoneLookup.ContainsKey($zoneFilter)) {
        Write-Error -Message "Zone '$zoneFilter' is not hosted on $serverText. Check -Zone (or the Zone column), or specify another -Server." -Category ObjectNotFound -ErrorId ($errorPrefix + 'ZoneNotFound') -TargetObject $InputObject -ErrorAction Stop
    }

    $address = ConvertTo-DnsNormalizedAddress -Address $identity
    if ($null -ne $address) {
        $target['Kind'] = 'Address'
        $target['Address'] = $address
    }
    else {
        $name = ConvertTo-DnsNormalizedName -Name $identity
        $resolvedZone = $null

        if ($name.IndexOf('.') -lt 0) {
            if (-not $zoneFilter) {
                Write-Error -Message "'$identity' is not a fully qualified name. Use the FQDN (for example $name.contoso.local), or specify -Zone." -Category ObjectNotFound -ErrorId ($errorPrefix + 'ZoneNotFound') -TargetObject $InputObject -ErrorAction Stop
            }
            $resolvedZone = $zoneFilter
            if ($name -eq '@') {
                $name = $zoneFilter
            }
            else {
                $name = $name + '.' + $zoneFilter
            }
        }
        else {
            $forwardZones = @(
                foreach ($candidate in @(Find-DnsZoneForName -Name $name -ZoneTable $ZoneTable)) {
                    if (-not $zoneLookup[$candidate].IsReverse) {
                        $candidate
                    }
                }
            )
            if ($zoneFilter) {
                if ($forwardZones -contains $zoneFilter) {
                    $resolvedZone = $zoneFilter
                }
                else {
                    Write-Error -Message "'$identity' is not inside zone '$zoneFilter'. Remove -Zone (or the Zone column) to use the zone the name belongs to." -Category ObjectNotFound -ErrorId ($errorPrefix + 'ZoneNotFound') -TargetObject $InputObject -ErrorAction Stop
                }
            }
            elseif ($forwardZones.Count -gt 0) {
                $resolvedZone = $forwardZones[0]
            }
            else {
                $hint = 'Check the spelling, or specify the -Server that hosts its zone.'
                if ($name.EndsWith('.in-addr.arpa') -or $name.EndsWith('.ip6.arpa')) {
                    $hint = 'Reverse lookup names are not accepted; give the IP address instead.'
                }
                Write-Error -Message "'$identity' is not in any forward zone hosted on $serverText. $hint" -Category ObjectNotFound -ErrorId ($errorPrefix + 'ZoneNotFound') -TargetObject $InputObject -ErrorAction Stop
            }
        }

        $target['Fqdn'] = $name
        $target['Zone'] = $resolvedZone
        $target['NodeName'] = '@'
        if ($name -ne $resolvedZone) {
            $target['NodeName'] = $name.Substring(0, $name.Length - $resolvedZone.Length - 1)
        }
    }

    # --- CSV row: the record it describes ---
    if ($null -ne $row) {
        if ($row['Name'] -and $row['Address']) {
            $rowAddress = ConvertTo-DnsNormalizedAddress -Address $row['Address']
            if ($null -eq $rowAddress) {
                Write-Error -Message "The Address '$($row['Address'])' of '$identity' is not an IPv4 or IPv6 address." -Category InvalidArgument -ErrorId ($errorPrefix + 'InvalidInput') -TargetObject $InputObject -ErrorAction Stop
            }
            $target['Address'] = $rowAddress
            $target['Data'] = $rowAddress
            $target['Type'] = 'A'
            if ($rowAddress.IndexOf(':') -ge 0) {
                $target['Type'] = 'AAAA'
            }
        }
        elseif ($row['Name'] -and $row['Target']) {
            $target['Kind'] = 'Cname'
            $target['Type'] = 'CNAME'
            $target['Data'] = ConvertTo-DnsNormalizedName -Name $row['Target']
        }
    }

    $target
}
