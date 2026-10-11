Set-StrictMode -Version Latest

# Module state (CONTRACTS.md section 7.1). Keys of every cache are lower-case server names.
$script:ModuleRoot             = $PSScriptRoot
$script:LanguageMode           = [string]$ExecutionContext.SessionState.LanguageMode
$script:ZoneTableCache         = @{}
$script:CimSessionCache        = @{}
$script:SnapshotIndexCache     = @{}
$script:DnsServerModuleChecked = $false

# Where Export-DnsServerZone drops its file on the DNS server. Read when the server is
# this machine; tests point it at TestDrive together with the stub export root.
$script:DnsServerExportRoot    = Join-Path $env:windir 'System32\dns'
$script:SnapshotRoot           = $null   # Snapshot root override (Get-DnsSnapshotRoot); $null = DNSLATHUND_SNAPSHOTPATH or %LOCALAPPDATA%. Tests point it at TestDrive.

# Private helpers first so that public functions can rely on them while loading.
# A folder that does not exist yet is simply skipped, so the module imports during
# phased development.
$publicFunctionNames = [ordered]@{}
foreach ($folderName in @('Private', 'Public')) {
    $folderPath = Join-Path -Path $PSScriptRoot -ChildPath $folderName
    if (-not (Test-Path -LiteralPath $folderPath -PathType Container)) {
        continue
    }

    # -Filter '*.ps1' also matches '.ps1xml' through 8.3 short names, hence the extension check.
    $sourceFiles = Get-ChildItem -LiteralPath $folderPath -File |
        Where-Object { $_.Extension -eq '.ps1' } |
        Sort-Object -Property Name

    foreach ($sourceFile in $sourceFiles) {
        try {
            . $sourceFile.FullName
        }
        catch {
            throw "DnsLathund: failed to load '$($sourceFile.FullName)': $($_.Exception.Message)"
        }

        if ($folderName -eq 'Public') {
            $publicFunctionNames[$sourceFile.BaseName] = $true
        }
    }
}

# The manifest's FunctionsToExport narrows this further; exporting only what exists
# keeps the import clean while Public\ is still being filled.
Export-ModuleMember -Function @($publicFunctionNames.Keys)

Remove-Variable -Name publicFunctionNames, folderName, folderPath, sourceFiles, sourceFile -ErrorAction SilentlyContinue

$onRemove = {
    foreach ($cachedSession in @($script:CimSessionCache.Values)) {
        # 'Unavailable' marks a server where no session could be opened.
        if ($null -eq $cachedSession -or $cachedSession -is [string]) {
            continue
        }

        try {
            Remove-CimSession -CimSession $cachedSession -ErrorAction Stop
        }
        catch {
            Write-Verbose "DnsLathund: could not close a cached CIM session: $($_.Exception.Message)"
        }
    }

    $script:CimSessionCache = @{}
}

# Constrained Language Mode refuses property assignment on PSModuleInfo ("Property
# setting is supported only on core types"). There the handler is not registered and
# cached sessions close when the process exits; the import itself must not fail.
try {
    $ExecutionContext.SessionState.Module.OnRemove = $onRemove
}
catch {
    Write-Verbose "DnsLathund: cached CIM sessions will not be closed on Remove-Module in $script:LanguageMode mode."
}
Remove-Variable -Name onRemove -ErrorAction SilentlyContinue
