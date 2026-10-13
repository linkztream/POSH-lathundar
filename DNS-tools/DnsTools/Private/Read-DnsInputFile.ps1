function Read-DnsInputFile {
    <#
    .SYNOPSIS
        Reads the -InputFile of a change command: a list of names or a CSV file.

    .DESCRIPTION
        Two formats are accepted (CONTRACTS.md section 7.5):

        - A plain list: one identity (name or address) per line. Lines are trimmed;
          blank lines and lines that start with '#' are skipped; duplicates are
          removed case-insensitively, keeping the first occurrence. Returns the
          remaining lines as strings.
        - CSV: with -Csv, or when the first line that is neither blank nor a '#'
          comment is a CSV header with a column named 'Name' (a lone 'Name' or
          '"Name"' line counts, so the output of Export-Csv on a single column is
          recognised). Returns one hashtable per row with exactly the keys Name,
          Address, Target, TTL and Zone. Column names are matched
          case-insensitively; values are trimmed strings, and an empty cell or a
          missing column gives $null. Columns other than these five produce one
          warning that names them, and are ignored. Rows are not de-duplicated.
          The delimiter is a comma, or a semicolon when the header has semicolons
          but no comma (Excel with a Swedish or other European locale writes ';').
          Blank lines and '#' lines (such as the #TYPE line of Export-Csv on
          Windows PowerShell) are skipped.

        The file is read with Get-Content -Encoding UTF8, which reads UTF-8 with and
        without a BOM on both PowerShell editions, so names such as 'kåken' survive
        a file saved by Notepad, Excel or PowerShell 7.

        A missing file, an empty file, or a file with nothing but blank lines,
        comments or a CSV header throws: an empty batch is almost certainly the
        wrong file.

    .PARAMETER Path
        The input file.

    .PARAMETER Csv
        Read the file as CSV even when the first line does not look like a header
        with a Name column.

    .OUTPUTS
        System.String for a plain list; System.Collections.Hashtable for CSV.

    .EXAMPLE
        $identities = @(Read-DnsInputFile -Path '.\remove.txt')

        Returns the distinct names and addresses in remove.txt.

    .EXAMPLE
        foreach ($row in @(Read-DnsInputFile -Path '.\new.csv')) { $row['Name']; $row['Address'] }

        Reads a CSV file with a Name,Address header; each row is a hashtable.
    #>
    [CmdletBinding()]
    [OutputType([string], [hashtable])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [switch]$Csv
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The input file '$Path' does not exist. Check the path; a relative path is resolved from the current folder '$($PWD.Path)'."
    }

    $rawLines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)
    $lines = @(
        foreach ($rawLine in $rawLines) {
            if ($null -eq $rawLine) {
                continue
            }
            $line = ([string]$rawLine).Trim()
            if ($line -and -not $line.StartsWith('#')) {
                $line
            }
        }
    )

    if ($lines.Count -eq 0) {
        throw "The input file '$Path' is empty (only blank lines or '#' comments). Put one name or address per line, or a CSV header with a Name column and one row per entry."
    }

    $header = $lines[0]
    $delimiter = ','
    if ($header.IndexOf(';') -ge 0 -and $header.IndexOf(',') -lt 0) {
        $delimiter = ';'
    }

    $isCsv = [bool]$Csv
    if (-not $isCsv) {
        foreach ($headerField in $header.Split($delimiter)) {
            if ($headerField.Trim().Trim('"').Trim() -eq 'Name') {
                $isCsv = $true
                break
            }
        }
    }

    if (-not $isCsv) {
        # A plain hashtable is case-insensitive, which is what DNS names need.
        $seen = @{}
        foreach ($line in $lines) {
            if ($seen.ContainsKey($line)) {
                continue
            }
            $seen[$line] = $true
            $line
        }
        return
    }

    try {
        $rows = @($lines | ConvertFrom-Csv -Delimiter $delimiter -ErrorAction Stop)
    }
    catch {
        throw "The input file '$Path' could not be read as CSV: $($_.Exception.Message) Check the header line; every column needs a distinct name."
    }

    if ($rows.Count -eq 0) {
        throw "The input file '$Path' has a CSV header but no rows. Add one row per entry below the header."
    }

    # Header names as written -> contract key, so 'name', 'NAME' and 'Name' all work.
    $knownColumns = @{ Name = 'Name'; Address = 'Address'; Target = 'Target'; TTL = 'TTL'; Zone = 'Zone' }
    $columnMap = @{}
    $unknownColumns = @(
        foreach ($property in $rows[0].PSObject.Properties) {
            $columnName = [string]$property.Name
            if ($knownColumns.ContainsKey($columnName.Trim())) {
                $columnMap[$columnName] = $knownColumns[$columnName.Trim()]
            }
            else {
                $columnName
            }
        }
    )
    if ($unknownColumns.Count -gt 0) {
        Write-Warning ("The input file '{0}' has column(s) that are ignored: {1}. Known columns: Name, Address, Target, TTL, Zone." -f $Path, ($unknownColumns -join ', '))
    }

    foreach ($row in $rows) {
        $entry = @{ Name = $null; Address = $null; Target = $null; TTL = $null; Zone = $null }
        foreach ($columnName in @($columnMap.Keys)) {
            $value = $row.PSObject.Properties[$columnName].Value
            if ($null -ne $value) {
                $value = ([string]$value).Trim()
            }
            if ($value) {
                $entry[$columnMap[$columnName]] = $value
            }
        }
        $entry
    }
}
