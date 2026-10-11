function Get-DnsSnapshotMeta {
    <#
    .SYNOPSIS
        Reads the meta.json of a server's snapshot.

    .DESCRIPTION
        Reads <snapshot root>\<server>\meta.json (CONTRACTS.md section 9.4) and
        returns it as a hashtable:

            @{
                Server        = 'dc01'
                SchemaVersion = 1
                Zones         = @{ 'contoso.local' = @{ File = 'contoso.local.txt'; ExportedAt = [datetime]; IsReverse = $false; ... } }
            }

        Plain hashtables instead of typed objects: the result is internal, zone
        lookups are case-insensitive, and missing keys read as $null under strict
        mode.

        ExportedAt is stored as an ISO 8601 round-trip string with offset and is
        returned as a local [datetime]. PowerShell 7 already converts such strings
        while parsing the JSON; Windows PowerShell 5.1 leaves them as strings, so
        both shapes are accepted.

        A missing file, a file that is not valid JSON, or a schema version other
        than 1 returns $null with a warning: the snapshot cannot be used as is and
        Update-DnsSnapshot recreates it. A single zone entry without a file name
        or with an unreadable date is skipped with a warning; the other zones stay
        usable. Callers that merely probe for a snapshot test for the file first,
        so that a snapshot that was never created does not warn twice.

    .PARAMETER Server
        The DNS server whose snapshot is read.

    .EXAMPLE
        $meta = Get-DnsSnapshotMeta -Server 'dc01'
        $meta['Zones']['contoso.local']['ExportedAt']

        Returns when contoso.local was last exported from dc01.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Server
    )

    $serverKey = $Server.Trim().ToLowerInvariant()
    $metaPath = Join-Path -Path (Get-DnsSnapshotRoot -Server $serverKey) -ChildPath 'meta.json'
    $updateHint = "Run Update-DnsSnapshot -Server $serverKey to recreate the snapshot."

    if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
        Write-Warning "The snapshot of '$serverKey' has no meta.json ('$metaPath'). $updateHint"
        return $null
    }

    try {
        Write-Verbose "Reading snapshot metadata '$metaPath'."
        $json = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning "The snapshot metadata '$metaPath' could not be read: $($_.Exception.Message) $updateHint"
        return $null
    }

    # An empty file or a JSON scalar parses without error but is not a snapshot.
    if ($null -eq $json -or $null -eq $json.PSObject.Properties['Zones'] -or $null -eq $json.PSObject.Properties['SchemaVersion']) {
        Write-Warning "The snapshot metadata '$metaPath' is not in the expected format. $updateHint"
        return $null
    }

    $schemaVersion = $json.SchemaVersion -as [int]
    if ($schemaVersion -ne 1) {
        Write-Warning "The snapshot metadata '$metaPath' has schema version '$($json.SchemaVersion)'; this version of DnsLathund reads version 1. $updateHint"
        return $null
    }

    $metaServer = $serverKey
    if ($null -ne $json.PSObject.Properties['Server'] -and $json.Server) {
        $metaServer = ([string]$json.Server).ToLowerInvariant()
    }

    $entryKeys = @('File', 'ExportedAt', 'IsReverse', 'ZoneType', 'ReplicationScope', 'DirectoryPartitionName', 'DynamicUpdate', 'AgingEnabled', 'FileSizeBytes')
    $zones = @{}
    if ($null -ne $json.Zones) {
        foreach ($zoneProperty in $json.Zones.PSObject.Properties) {
            $zoneName = ([string]$zoneProperty.Name).ToLowerInvariant()
            $source = $zoneProperty.Value
            if ($null -eq $source) {
                Write-Warning "Zone '$zoneName' in '$metaPath' has no details and is ignored. $updateHint"
                continue
            }

            # Copied key by key so that an entry written by an older or newer
            # version, with keys missing, never trips strict mode later on.
            $entry = @{}
            foreach ($entryKey in $entryKeys) {
                $entry[$entryKey] = $null
                $property = $source.PSObject.Properties[$entryKey]
                if ($null -ne $property) {
                    $entry[$entryKey] = $property.Value
                }
            }

            if (-not $entry['File']) {
                Write-Warning "Zone '$zoneName' in '$metaPath' has no file name and is ignored. $updateHint"
                continue
            }
            $entry['File'] = [string]$entry['File']

            $exportedAt = $entry['ExportedAt']
            if ($exportedAt -isnot [datetime]) {
                try {
                    $exportedAt = [datetime]::Parse([string]$exportedAt)
                }
                catch {
                    $exportedAt = $null
                }
            }
            if ($null -eq $exportedAt) {
                Write-Warning "Zone '$zoneName' in '$metaPath' has no valid ExportedAt and is ignored. $updateHint"
                continue
            }
            # Age is computed against Get-Date (local); a UTC value would be off by the offset.
            if ($exportedAt.Kind -eq 'Utc') {
                $exportedAt = $exportedAt.ToLocalTime()
            }
            $entry['ExportedAt'] = $exportedAt

            if ($null -ne $entry['IsReverse']) {
                $entry['IsReverse'] = [bool]$entry['IsReverse']
            }
            if ($null -ne $entry['FileSizeBytes']) {
                $entry['FileSizeBytes'] = $entry['FileSizeBytes'] -as [long]
            }

            $zones[$zoneName] = $entry
        }
    }

    @{
        Server        = $metaServer
        SchemaVersion = 1
        Zones         = $zones
    }
}
