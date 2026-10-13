function Save-DnsSnapshotMeta {
    <#
    .SYNOPSIS
        Writes the meta.json of a server's snapshot.

    .DESCRIPTION
        Writes the metadata hashtable (the shape Get-DnsSnapshotMeta returns) to
        <snapshot root>\<server>\meta.json in the format of CONTRACTS.md
        section 9.4, creating the server folder when needed.

        ExportedAt is written as an ISO 8601 round-trip string with offset
        (.ToString('o') of a local time): ConvertTo-Json on Windows PowerShell 5.1
        would otherwise write a [datetime] as "\/Date(...)\/", which is neither
        readable nor portable. Zones are written in name order and each entry in
        a fixed key order so that the file is stable and diff-friendly.

        The file is written with Set-Content -Encoding UTF8 -WhatIf:$false
        -Confirm:$false: the caller has already passed its confirmation gate, and
        a caller's -WhatIf must not leave the files and their metadata out of
        step. Windows PowerShell 5.1 writes a BOM, PowerShell 7 does not; the
        reader accepts both. Write failures throw.

    .PARAMETER Server
        The DNS server the snapshot belongs to.

    .PARAMETER Meta
        Hashtable with a Zones hashtable (zone name -> hashtable with File,
        ExportedAt, IsReverse, ZoneType, ReplicationScope, DirectoryPartitionName,
        DynamicUpdate, AgingEnabled, FileSizeBytes). Server and SchemaVersion are
        always written as the lower-case server name and 1.

    .EXAMPLE
        Save-DnsSnapshotMeta -Server 'dc01' -Meta $meta

        Writes $meta to the meta.json of dc01's snapshot.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter(Mandatory)]
        [hashtable]$Meta
    )

    $serverKey = $Server.Trim().ToLowerInvariant()
    $serverFolder = Get-DnsSnapshotRoot -Server $serverKey
    $metaPath = Join-Path -Path $serverFolder -ChildPath 'meta.json'

    if (-not (Test-Path -LiteralPath $serverFolder -PathType Container)) {
        $null = New-Item -Path $serverFolder -ItemType Directory -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
    }

    $sourceZones = $Meta['Zones']
    if ($null -eq $sourceZones) {
        $sourceZones = @{}
    }

    $zones = [ordered]@{}
    foreach ($zoneName in @($sourceZones.Keys | Sort-Object)) {
        $source = $sourceZones[$zoneName]
        $exportedAt = $source['ExportedAt']
        if ($exportedAt -is [datetime]) {
            # A local time gives the offset form ('+02:00') the contract shows; a
            # UTC value would be written with 'Z'.
            if ($exportedAt.Kind -eq 'Utc') {
                $exportedAt = $exportedAt.ToLocalTime()
            }
            $exportedAt = $exportedAt.ToString('o')
        }
        elseif ($null -ne $exportedAt) {
            $exportedAt = [string]$exportedAt
        }

        $zones[([string]$zoneName).ToLowerInvariant()] = [ordered]@{
            File                   = $source['File']
            ExportedAt             = $exportedAt
            IsReverse              = $source['IsReverse']
            ZoneType               = $source['ZoneType']
            ReplicationScope       = $source['ReplicationScope']
            DirectoryPartitionName = $source['DirectoryPartitionName']
            DynamicUpdate          = $source['DynamicUpdate']
            AgingEnabled           = $source['AgingEnabled']
            FileSizeBytes          = $source['FileSizeBytes']
        }
    }

    $document = [ordered]@{
        Server        = $serverKey
        SchemaVersion = 1
        Zones         = $zones
    }

    $json = ConvertTo-Json -InputObject $document -Depth 5
    Write-Verbose "Writing snapshot metadata '$metaPath' ($(@($sourceZones.Keys).Count) zone(s))."
    Set-Content -LiteralPath $metaPath -Value $json -Encoding UTF8 -ErrorAction Stop -WhatIf:$false -Confirm:$false
}
