<#
.SYNOPSIS
    Normalises source files to UTF-8 with BOM and CRLF line endings.

.DESCRIPTION
    Developer tool, not part of the module. Windows PowerShell 5.1 reads a
    BOM-less file as ANSI, which breaks any non-ASCII character in help
    text or comments. Editors and generators frequently emit LF without a
    BOM, so this script is run on every source file before it is handed
    over for review. Markdown files are left alone.

.PARAMETER Path
    Files or directories. Directories are searched recursively for
    .ps1, .psm1, .psd1, .ps1xml and .help.txt files.

.EXAMPLE
    .\Set-SourceFileFormat.ps1 -Path ..\DnsLathund

    Normalises every module source file.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
    [string[]]$Path
)

begin {
    # Plain .txt is deliberately excluded: zone-file fixtures must stay
    # BOM-less like a real Export-DnsServerZone output. Only about-topics
    # (*.help.txt) are source files in the sense of this tool.
    $extensions = @('.ps1', '.psm1', '.psd1', '.ps1xml')
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
}

process {
    foreach ($item in $Path) {
        $resolved = Resolve-Path -Path $item -ErrorAction Stop

        foreach ($entry in $resolved) {
            $files = if (Test-Path -LiteralPath $entry.Path -PathType Container) {
                Get-ChildItem -LiteralPath $entry.Path -Recurse -File |
                    Where-Object { $extensions -contains $_.Extension -or $_.Name -like '*.help.txt' }
            }
            else {
                Get-Item -LiteralPath $entry.Path
            }

            foreach ($file in $files) {
                $content = [System.IO.File]::ReadAllText($file.FullName)
                $normalised = $content -replace "`r?`n", "`r`n"

                if (-not $normalised.EndsWith("`r`n")) {
                    $normalised += "`r`n"
                }

                $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
                $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF

                if ($hasBom -and $normalised -eq $content) {
                    continue
                }

                if ($PSCmdlet.ShouldProcess($file.FullName, 'Rewrite as UTF-8 with BOM and CRLF')) {
                    [System.IO.File]::WriteAllText($file.FullName, $normalised, $utf8Bom)
                    Write-Verbose "Normalised $($file.FullName)"
                }
            }
        }
    }
}
