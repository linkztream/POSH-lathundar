function Write-DnsChangeLog {
    <#
    .SYNOPSIS
        Appends one change record to the DnsLathund change log (JSON Lines).

    .DESCRIPTION
        Writes exactly one line of compact JSON per call. Every line has the same
        keys in the same order - Id, BatchId, Timestamp, Operator, Server, Action,
        Zone, NodeName, Type, Before, After, Result, Error - with null for anything
        the entry does not supply, so the log can be read with
        Get-Content -Encoding UTF8 <file> | ConvertFrom-Json. Keys outside the schema
        are appended after Error. Id defaults to a new GUID, Timestamp to now and
        Operator to DOMAIN\user. Dates are written in round-trip format
        (2026-10-09T15:00:00.0000000+02:00) on both PowerShell editions.

        The log path is, in order: -LogPath, $env:DNSLATHUND_LOGPATH, or
        $env:LOCALAPPDATA\DnsLathund\log\DnsLathund_<yyyy-MM>.jsonl. The directory
        is created when missing. Writes carry -WhatIf:$false -Confirm:$false so that
        -WhatIf runs are logged too.

        Logging must never break the change it records: a locked file (IOException)
        is retried once after 200 ms, and any failure becomes a warning that names
        the path and the reason. This function never throws.

    .PARAMETER Entry
        The change record. Keys as in the schema above; Before and After are
        hashtables such as @{ Data = '10.0.16.5'; Ttl = 3600; Timestamp = $null; IsStatic = $true }.

    .PARAMETER LogPath
        The log file. Overrides the environment variable and the default.

    .EXAMPLE
        Write-DnsChangeLog -Entry @{ BatchId = $batchId; Server = 'dc01'; Action = 'RemoveA'; Zone = 'contoso.local'; NodeName = 'srv01'; Type = 'A'; Result = 'Success' }

        Appends one line to this month's default log file.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Entry,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogPath
    )

    $path = $null
    try {
        if ($LogPath) {
            $path = $LogPath
        }
        elseif ($env:DNSLATHUND_LOGPATH) {
            $path = $env:DNSLATHUND_LOGPATH
        }
        elseif ($env:LOCALAPPDATA) {
            $fileName = 'DnsLathund_{0}.jsonl' -f (Get-Date).ToString('yyyy-MM')
            $path = Join-Path -Path $env:LOCALAPPDATA -ChildPath (Join-Path -Path 'DnsLathund\log' -ChildPath $fileName)
        }
        else {
            Write-Warning 'Could not write the change log: no -LogPath, DNSLATHUND_LOGPATH or LOCALAPPDATA. The change was not logged.'
            return
        }

        if (-not (Split-Path -Path $path -IsAbsolute)) {
            $path = Join-Path -Path $PWD.Path -ChildPath $path
        }
        Write-Verbose "Change log: '$path'."

        # Membership is checked on a hashtable: Windows PowerShell 5.1 blocks method
        # calls on [ordered] dictionaries in Constrained Language Mode.
        $schemaKeys = @('Id', 'BatchId', 'Timestamp', 'Operator', 'Server', 'Action', 'Zone', 'NodeName', 'Type', 'Before', 'After', 'Result', 'Error')
        $isSchemaKey = @{}
        $record = [ordered]@{}
        foreach ($key in $schemaKeys) {
            $isSchemaKey[$key] = $true
            $record[$key] = $null
            if ($Entry.ContainsKey($key)) {
                $record[$key] = $Entry[$key]
            }
        }
        foreach ($key in $Entry.Keys) {
            if (-not $isSchemaKey.ContainsKey($key)) {
                $record[$key] = $Entry[$key]
            }
        }

        if ($null -eq $record['Id'] -or '' -eq [string]$record['Id']) {
            $record['Id'] = [guid]::NewGuid().ToString()
        }
        if ($null -eq $record['Timestamp']) {
            $record['Timestamp'] = Get-Date
        }
        if ($null -eq $record['Operator'] -or '' -eq [string]$record['Operator']) {
            $record['Operator'] = $env:USERNAME
            if ($env:USERDOMAIN) {
                $record['Operator'] = $env:USERDOMAIN + '\' + $env:USERNAME
            }
        }

        # Windows PowerShell serialises [datetime] as "\/Date(...)\/"; write one
        # readable format on both editions instead.
        foreach ($key in @($record.Keys)) {
            $value = $record[$key]
            if ($value -is [datetime]) {
                $record[$key] = $value.ToString('o')
            }
            elseif ($value -is [System.Collections.IDictionary]) {
                $nested = [ordered]@{}
                foreach ($nestedKey in @($value.Keys)) {
                    $nestedValue = $value[$nestedKey]
                    if ($nestedValue -is [datetime]) {
                        $nestedValue = $nestedValue.ToString('o')
                    }
                    $nested[$nestedKey] = $nestedValue
                }
                $record[$key] = $nested
            }
        }

        $line = ConvertTo-Json -InputObject $record -Compress -Depth 5

        $directory = Split-Path -Path $path -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
            $null = New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
        }
    }
    catch {
        Write-Warning "Could not write the change log '$path': $($_.Exception.Message) The change was not logged."
        return
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Add-Content -LiteralPath $path -Value $line -Encoding UTF8 -ErrorAction Stop -WhatIf:$false -Confirm:$false
            return
        }
        catch {
            # A sharing violation from a concurrent writer is an IOException; it
            # usually clears quickly. Anything else will not get better by waiting.
            $isIoError = $_.Exception.PSObject.TypeNames -contains 'System.IO.IOException'
            if ($attempt -eq 1 -and $isIoError) {
                Write-Verbose "Change log '$path' is busy; retrying once: $($_.Exception.Message)"
                Start-Sleep -Milliseconds 200
                continue
            }

            Write-Warning "Could not write the change log '$path': $($_.Exception.Message) The change was not logged."
            return
        }
    }
}
