<#
.SYNOPSIS
    Runs the DnsLathund Pester suite on Windows PowerShell 5.1 and/or
    PowerShell 7 and prints a compact summary with failures.

.DESCRIPTION
    Developer tool, not part of the module. Each engine runs in its own
    child process so that the Constrained Language Mode smoke test and the
    engine-specific behaviour (BOM handling, Clone(), ordered dictionaries)
    are exercised for real. Exits with 1 if any engine reports failures.

.PARAMETER Engine
    Desktop (powershell.exe), Core (pwsh) or Both.

.PARAMETER Path
    Test files or folders. Default: the module's Tests folder.

.PARAMETER Tag
    Run only tests with these tags (e.g. Performance).

.PARAMETER IncludePerformance
    Include the Performance-tagged suite (excluded by default).

.EXAMPLE
    .\Invoke-ModuleTests.ps1

    Runs the whole suite on both engines.

.EXAMPLE
    .\Invoke-ModuleTests.ps1 -Engine Desktop -Path ..\DnsLathund\Tests\Foundation.Tests.ps1

    Runs one file on Windows PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [ValidateSet('Desktop', 'Core', 'Both')]
    [string]$Engine = 'Both',

    [string[]]$Path = (Join-Path $PSScriptRoot '..\DnsLathund\Tests'),

    [string[]]$Tag,

    [switch]$IncludePerformance,

    [switch]$Detailed
)

$resolvedPaths = @($Path | ForEach-Object { (Resolve-Path $_).Path })
$pathLiteral = ($resolvedPaths | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
$excludeTag = if ($IncludePerformance) { '' } else { " -ExcludeTag Performance" }
$tagArg = if ($Tag) { " -Tag " + (($Tag | ForEach-Object { "'$_'" }) -join ',') } else { '' }
$output = if ($Detailed) { 'Detailed' } else { 'None' }

$inner = @"
Import-Module Pester -RequiredVersion 5.7.1 -ErrorAction Stop
`$r = Invoke-Pester -Path @($pathLiteral)$excludeTag$tagArg -Output $output -PassThru
'SUMMARY Total=' + `$r.TotalCount + ' Passed=' + `$r.PassedCount + ' Failed=' + `$r.FailedCount + ' Skipped=' + `$r.SkippedCount + ' Duration=' + [int]`$r.Duration.TotalSeconds + 's'
foreach (`$f in `$r.Failed) {
    'FAILED ' + `$f.ExpandedPath
    `$m = `$f.ErrorRecord.Exception.Message
    if (`$m) { '    ' + ((`$m -split "`r?`n") | Select-Object -First 3) -join "`n    " }
}
if (`$r.FailedCount -gt 0) { exit 1 }
"@

$engines = switch ($Engine) {
    'Desktop' { @('Desktop') }
    'Core'    { @('Core') }
    'Both'    { @('Desktop', 'Core') }
}

$failed = $false

foreach ($e in $engines) {
    $exe = if ($e -eq 'Desktop') { Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { 'pwsh' }
    Write-Host "===== $e ($exe) =====" -ForegroundColor Cyan

    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
    & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded

    if ($LASTEXITCODE -ne 0) {
        $failed = $true
    }
}

if ($failed) {
    exit 1
}
