function Write-DnsResult {
    <#
    .SYNOPSIS
        Creates one DnsTools.Result object and writes the matching change-log line.

    .DESCRIPTION
        The only way module code reports a sub-operation of a change command
        (CONTRACTS.md sections 7.5, 11 and 12.2). One call does two things that must
        never drift apart:

        1. It writes exactly one change-log line through Write-DnsChangeLog, with the
           same Id, Timestamp, Name, Data and Result as the object, plus the batch's
           BatchId, Server and LogPath. Operator is filled in by Write-DnsChangeLog.
           Name and Data are on every line, so a WhatIf or Failed line without
           Before and After still says which record it concerns. The line
           is written for every Result value, including WhatIf and Skipped, and also
           while the caller runs under -WhatIf, because Write-DnsChangeLog writes
           with -WhatIf:$false.
        2. It returns the DnsTools.Result object with the properties Action, Name,
           Type, Data, Result, Error, Zone, NodeName, Server, Id, BatchId and
           Timestamp, in that order. The caller emits it immediately (streaming).

        Before and After describe the record before and after the change. Any
        hashtable with Data, Ttl and Timestamp works, including a record from
        Get-DnsLiveRecord; the log gets exactly Data, Ttl, Timestamp and IsStatic.
        IsStatic is taken from the hashtable when present, otherwise it is $true
        when Timestamp is $null.

        Empty strings for Data, Error, Type, Zone and NodeName become $null, so that
        "not applicable" looks the same in the object and in the log. The batch's
        Counts hashtable counts every Result value (Counts['Success'] and so on) for
        the end-of-run summary.

        The error text parameter is called ErrorMessage, with the alias Error that
        the contract uses: a parameter named $Error would shadow PowerShell's $Error
        variable for this function and everything it calls.

    .PARAMETER Batch
        The batch from New-DnsBatch.

    .PARAMETER Action
        The sub-operation, for example RemoveA or AddPtr (CONTRACTS.md section 12.2).

    .PARAMETER Name
        The owner FQDN the sub-operation is about.

    .PARAMETER Type
        The record type, for example A or PTR.

    .PARAMETER Data
        The record data (address or target), the NetworkId for CreateZone, the local
        file for Backup, or $null.

    .PARAMETER Zone
        The zone that holds the record.

    .PARAMETER NodeName
        The node name relative to the zone ('@' for the apex).

    .PARAMETER Result
        Success, Failed, Skipped, WhatIf, AlreadyDone or Pending.

    .PARAMETER ErrorMessage
        Why the sub-operation failed or was skipped. Alias: Error.

    .PARAMETER Before
        The record before the change: @{ Data; Ttl; Timestamp; IsStatic } or $null.

    .PARAMETER After
        The record after the change: @{ Data; Ttl; Timestamp; IsStatic } or $null.

    .OUTPUTS
        DnsTools.Result

    .EXAMPLE
        Write-DnsResult -Batch $batch -Action 'RemoveA' -Name 'srv01.contoso.local' -Type 'A' -Data '10.0.16.20' -Zone 'contoso.local' -NodeName 'srv01' -Result 'Success' -Before $liveRecord

        Logs the removal of an A record and returns the Result object for it.

    .EXAMPLE
        Write-DnsResult -Batch $batch -Action 'RemoveA' -Name 'srv01.contoso.local' -Type 'A' -Data '10.0.16.20' -Zone 'contoso.local' -NodeName 'srv01' -Result 'Skipped' -Error 'Referenced by 1 SRV record (_ldap._tcp.contoso.local). Add -AllowReferenced to remove it anyway.'

        Logs and returns a skipped sub-operation with its reason.
    #>
    [CmdletBinding()]
    [OutputType('DnsTools.Result')]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Batch,

        [Parameter(Mandatory)]
        [ValidateSet('RemovePtr', 'RemoveA', 'RemoveAAAA', 'RemoveCName', 'RemoveDhcid', 'AddA', 'AddAAAA', 'AddPtr', 'AddCName',
            'SetTtl', 'SetAddress', 'SetTarget', 'SetPtrTarget', 'CreateZone', 'SetZoneAging', 'ExportZone', 'Backup')]
        [string]$Action,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Type,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Data,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Zone,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Failed', 'Skipped', 'WhatIf', 'AlreadyDone', 'Pending')]
        [string]$Result,

        [Parameter()]
        [Alias('Error')]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ErrorMessage,

        [Parameter()]
        [AllowNull()]
        [hashtable]$Before,

        [Parameter()]
        [AllowNull()]
        [hashtable]$After
    )

    # [string] parameters turn $null into ''; the contract wants $null for "not applicable".
    $text = @{ Type = $Type; Data = $Data; Zone = $Zone; NodeName = $NodeName; Error = $ErrorMessage }
    foreach ($key in @($text.Keys)) {
        if ('' -eq $text[$key]) {
            $text[$key] = $null
        }
    }

    # Only the four documented fields reach the log, whatever the caller passed, so
    # every line has the same shape (CONTRACTS.md section 11).
    $states = @{ Before = $null; After = $null }
    foreach ($stateName in @('Before', 'After')) {
        $source = $Before
        if ($stateName -eq 'After') {
            $source = $After
        }
        if ($null -eq $source) {
            continue
        }

        $isStatic = $null -eq $source['Timestamp']
        if ($null -ne $source['IsStatic']) {
            $isStatic = [bool]$source['IsStatic']
        }
        $states[$stateName] = [ordered]@{
            Data      = $source['Data']
            Ttl       = $source['Ttl']
            Timestamp = $source['Timestamp']
            IsStatic  = $isStatic
        }
    }

    $id = [guid]::NewGuid().ToString()
    $timestamp = Get-Date

    Write-DnsChangeLog -LogPath $Batch['LogPath'] -Entry @{
        Id        = $id
        BatchId   = $Batch['BatchId']
        Timestamp = $timestamp
        Server    = $Batch['Server']
        Action    = $Action
        Zone      = $text['Zone']
        NodeName  = $text['NodeName']
        Name      = $Name
        Type      = $text['Type']
        Data      = $text['Data']
        Before    = $states['Before']
        After     = $states['After']
        Result    = $Result
        Error     = $text['Error']
    }

    if ($Batch['Counts'] -is [hashtable]) {
        $Batch['Counts'][$Result] = 1 + [int]$Batch['Counts'][$Result]
    }

    New-DnsObject -TypeName 'Result' -Property ([ordered]@{
            Action    = $Action
            Name      = $Name
            Type      = $text['Type']
            Data      = $text['Data']
            Result    = $Result
            Error     = $text['Error']
            Zone      = $text['Zone']
            NodeName  = $text['NodeName']
            Server    = $Batch['Server']
            Id        = $id
            BatchId   = $Batch['BatchId']
            Timestamp = $timestamp
        })
}
