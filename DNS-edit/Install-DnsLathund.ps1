<#
.SYNOPSIS
    Installs the DnsLathund PowerShell module so that Import-Module finds it.

.DESCRIPTION
    Copies the DnsLathund folder that sits next to this script into the
    PowerShell module folder, removes the "downloaded from the internet"
    mark from every copied file, and then starts a fresh PowerShell to check
    that the module really loads.

    You can start it by right-clicking the file and choosing "Run with
    PowerShell", or from a console. Nothing is installed until the source
    folder has been checked. An existing installation is never overwritten
    in place: it is renamed to DnsLathund.bak-<timestamp> first, so you can
    go back.

    The script never contacts a DNS server, never changes DNS and never
    changes the execution policy. If the execution policy stops the module
    from loading, the script prints the one command that fixes it and leaves
    the decision to you.

    Where the module goes:
      CurrentUser, Desktop : <Documents>\WindowsPowerShell\Modules\DnsLathund
      CurrentUser, Core    : <Documents>\PowerShell\Modules\DnsLathund
      AllUsers,    Desktop : <Program Files>\WindowsPowerShell\Modules\DnsLathund
      AllUsers,    Core    : <Program Files>\PowerShell\Modules\DnsLathund
    <Documents> is the real, possibly OneDrive-redirected, Documents folder.
    "Desktop" is Windows PowerShell 5.1, "Core" is PowerShell 7.

    With -Edition Both, the PowerShell 7 copy is skipped (with a message) when
    PowerShell 7 is not installed. With -Edition Core it is installed anyway,
    but cannot be verified.

    Exit code: 0 when every requested copy was installed and verified, 1
    otherwise.

.PARAMETER Scope
    CurrentUser (default) installs for the account running the script and
    needs no administrator rights. AllUsers installs for every account on the
    computer and requires an elevated (administrator) PowerShell.

.PARAMETER Edition
    Desktop installs for Windows PowerShell 5.1, Core for PowerShell 7, Both
    (default) for both.

.PARAMETER Source
    The folder that contains DnsLathund.psd1. Default: the DnsLathund folder
    next to this script.

.PARAMETER NoPause
    Do not wait for Enter at the end. Without this switch an interactive run
    waits, so that a window opened by "Run with PowerShell" stays readable.
    Non-interactive hosts never wait.

.PARAMETER TargetPath
    For testing only. The full path of the module folder to create, replacing
    the computed path (for example C:\Temp\x\DnsLathund). Needs a single
    -Edition (Desktop or Core). The parent folder is added to PSModulePath of
    the verification process only.

.EXAMPLE
    .\Install-DnsLathund.ps1

    Installs DnsLathund for the current user into both Windows PowerShell 5.1
    and PowerShell 7 (if present), then verifies that it loads. This is also
    what right-click, Run with PowerShell does.

.EXAMPLE
    .\Install-DnsLathund.ps1 -Edition Desktop -NoPause

    Installs only for Windows PowerShell 5.1 and returns to the prompt
    without waiting. Use this in a script or when you do not want the pause.

.EXAMPLE
    .\Install-DnsLathund.ps1 -Scope AllUsers -Source D:\Downloads\DnsLathund-1.0\DnsLathund

    Run from an elevated PowerShell. Installs for every user of this computer,
    taking the module from a folder other than the one next to the script.
#>
[CmdletBinding()]
param (
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'CurrentUser',

    [ValidateSet('Desktop', 'Core', 'Both')]
    [string]$Edition = 'Both',

    [string]$Source,

    [switch]$NoPause,

    [string]$TargetPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$moduleName = 'DnsLathund'
$exitCode = 0

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Describes one PowerShell edition: where its modules live and which program
# starts it. Exe is $null when the edition is not installed.
function Get-EngineInfo {
    param ([string]$Name)

    $exe = $null
    if ($Name -eq 'Desktop') {
        $label = 'Windows PowerShell 5.1'
        $subfolder = 'WindowsPowerShell\Modules'
        $candidate = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $candidate) { $exe = $candidate }
    }
    else {
        $label = 'PowerShell 7'
        $subfolder = 'PowerShell\Modules'
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $exe = (Get-Process -Id $PID).Path
        }
        else {
            $found = Get-Command -Name pwsh -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($found) { $exe = $found.Source }
            else {
                $candidate = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
                if (Test-Path -LiteralPath $candidate) { $exe = $candidate }
            }
        }
    }

    return New-Object PSObject -Property @{
        Name      = $Name
        Label     = $label
        Subfolder = $subfolder
        Exe       = $exe
    }
}

function Get-ModuleRoot {
    param ([string]$Subfolder, [string]$Scope)

    if ($Scope -eq 'AllUsers') {
        # ProgramW6432 is the real Program Files even from a 32-bit process.
        $base = $env:ProgramW6432
        if (-not $base) { $base = $env:ProgramFiles }
    }
    else {
        $base = [Environment]::GetFolderPath('MyDocuments')
    }
    if (-not $base) {
        throw "Cannot work out the base folder for scope '$Scope'. Use -TargetPath or install by hand."
    }
    return Join-Path $base $Subfolder
}

# Starts a clean engine and imports the module the way a user would, so that
# execution policy, blocked files and module path problems show up here and
# not on the first real use.
function Test-ModuleLoad {
    param ([string]$Exe, [string]$ExtraModulePath)

    # $ErrorActionPreference makes PowerShell 7 stop at the failed import too;
    # without it the next statement runs and adds a confusing second error.
    $command = '$ErrorActionPreference = ''Stop''; Import-Module DnsLathund -ErrorAction Stop; ' +
        '(Get-Module DnsLathund).Version.ToString(); (Get-Module DnsLathund).ModuleBase'
    if ($ExtraModulePath) {
        $quoted = $ExtraModulePath.Replace("'", "''")
        $command = "`$env:PSModulePath = '$quoted;' + `$env:PSModulePath; " + $command
    }

    $stdoutFile = Join-Path ([IO.Path]::GetTempPath()) ('DnsLathund-verify-{0}.out' -f [guid]::NewGuid())
    $stderrFile = Join-Path ([IO.Path]::GetTempPath()) ('DnsLathund-verify-{0}.err' -f [guid]::NewGuid())
    try {
        $process = Start-Process -FilePath $Exe -Wait -PassThru -NoNewWindow `
            -ArgumentList ('-NoProfile -NonInteractive -Command "{0}"' -f $command) `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $lines = @(Get-Content -LiteralPath $stdoutFile -ErrorAction SilentlyContinue)
        $errorText = (@(Get-Content -LiteralPath $stderrFile -ErrorAction SilentlyContinue) -join "`n")
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }

    $version = $null
    $base = $null
    if ($lines.Count -ge 1 -and $lines[0] -match '^\d+(\.\d+)+') { $version = $lines[0] }
    if ($lines.Count -ge 2) { $base = $lines[1] }

    $allText = (($lines -join "`n") + "`n" + $errorText)
    return New-Object PSObject -Property @{
        Success       = ($process.ExitCode -eq 0 -and $null -ne $version)
        Version       = $version
        ModuleBase    = $base
        ErrorText     = $errorText.Trim()
        PolicyProblem = ($allText -match 'running scripts is disabled|digitally signed|about_Execution_Policies|PSSecurityException')
    }
}

function Wait-ForEnter {
    if ($NoPause) { return }
    if (-not [Environment]::UserInteractive) { return }
    $commandLine = [Environment]::GetCommandLineArgs()
    if (@($commandLine | Where-Object { $_ -match '^[-/]noni' }).Count -gt 0) { return }
    try { Read-Host 'Press Enter to close' | Out-Null } catch { Write-Verbose 'No console to wait on.' }
}

try {
    if ($env:OS -ne 'Windows_NT') {
        throw 'This installer supports Windows only.'
    }

    # 1. Validate the source folder before touching anything.
    if (-not $Source) {
        $here = $PSScriptRoot
        if (-not $here) { $here = (Get-Location).ProviderPath }
        $Source = Join-Path $here $moduleName
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Source "$moduleName.psd1"))) {
        throw ("Cannot find $moduleName.psd1 in '$Source'. Keep Install-DnsLathund.ps1 next to the " +
            "$moduleName folder, or pass -Source <the folder that contains $moduleName.psd1>.")
    }
    $Source = (Resolve-Path -LiteralPath $Source).ProviderPath.TrimEnd('\')

    $sourceVersion = ''
    try {
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $Source "$moduleName.psd1")
        $sourceVersion = ' ' + $manifest.ModuleVersion
    }
    catch { Write-Verbose "Could not read the module version: $($_.Exception.Message)" }

    # 2. Decide which editions to install for.
    if ($Edition -eq 'Both') { $editionNames = @('Desktop', 'Core') } else { $editionNames = @($Edition) }
    if ($TargetPath -and $editionNames.Count -ne 1) {
        throw '-TargetPath needs a single -Edition (Desktop or Core).'
    }

    # 3. All-users installs write below Program Files and need elevation.
    if ($Scope -eq 'AllUsers' -and -not $TargetPath -and -not (Test-IsElevated)) {
        $self = $PSCommandPath
        if (-not $self) { $self = '.\Install-DnsLathund.ps1' }
        throw ("Installing for all users needs an elevated (administrator) PowerShell, and this one is not.`n" +
            "  Close this window, start PowerShell with 'Run as administrator', and run:`n" +
            "      & '$self' -Scope AllUsers`n" +
            "  Or install for yourself only (no administrator rights needed): run this installer without -Scope.")
    }

    Write-Host ''
    Write-Host 'DnsLathund installer' -ForegroundColor Cyan
    Write-Host "  Installing$sourceVersion from: $Source"
    Write-Host "  Scope: $Scope    Edition: $Edition"

    $installed = @()
    foreach ($name in $editionNames) {
        $engine = Get-EngineInfo -Name $name
        Write-Host ''
        Write-Host ('[{0}]' -f $engine.Label) -ForegroundColor Cyan

        if (-not $engine.Exe -and $Edition -eq 'Both' -and -not $TargetPath) {
            Write-Host '  PowerShell 7 (pwsh) was not found, so this copy is skipped.' -ForegroundColor Yellow
            Write-Host '  Run this installer again after installing PowerShell 7.'
            continue
        }

        $target = $null
        $backup = $null
        try {
            if ($TargetPath) { $target = $TargetPath.TrimEnd('\') }
            else { $target = Join-Path (Get-ModuleRoot -Subfolder $engine.Subfolder -Scope $Scope) $moduleName }
            Write-Host "  Target:  $target"

            if ($target -eq $Source) {
                throw 'The source and the target are the same folder. Nothing to install.'
            }

            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                Write-Host "  Created folder: $parent"
            }

            if (Test-Path -LiteralPath $target) {
                $backup = '{0}.bak-{1}' -f $target, (Get-Date -Format 'yyyyMMdd-HHmmss')
                try { Move-Item -LiteralPath $target -Destination $backup }
                catch {
                    throw ("Cannot move the existing copy out of the way ($($_.Exception.Message)). " +
                        "Close every PowerShell window that has $moduleName loaded and try again.")
                }
                Write-Host "  Existing copy moved to: $backup"
            }

            try {
                Copy-Item -LiteralPath $Source -Destination $target -Recurse -Force
            }
            catch {
                # Put the old copy back so a failed install never leaves nothing behind.
                if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
                if ($backup -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $target }
                throw "Copy failed: $($_.Exception.Message)"
            }

            $files = @(Get-ChildItem -LiteralPath $target -Recurse -File)
            $blocked = 0
            foreach ($file in $files) {
                if (Get-Item -LiteralPath $file.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue) { $blocked++ }
            }
            $files | Unblock-File
            Write-Host "  Copied $($files.Count) files; removed the internet-download mark from $blocked."

            if (-not $engine.Exe) {
                Write-Host '  PowerShell 7 (pwsh) was not found, so the copy could not be verified.' -ForegroundColor Yellow
                $installed += $engine.Label
                continue
            }

            $extra = $null
            if ($TargetPath) { $extra = $parent }
            $check = Test-ModuleLoad -Exe $engine.Exe -ExtraModulePath $extra

            if ($check.Success) {
                Write-Host ("  Verified: $moduleName {0} loads in {1}." -f $check.Version, $engine.Label) -ForegroundColor Green
                if ($check.ModuleBase -and $check.ModuleBase.TrimEnd('\') -ne $target) {
                    Write-Host "  Warning: PowerShell loaded another copy from '$($check.ModuleBase)'." -ForegroundColor Yellow
                    Write-Host '  An older installation earlier in $env:PSModulePath hides the new one. Remove or rename it.'
                }
                $installed += $engine.Label
            }
            else {
                $exitCode = 1
                Write-Host "  The files were copied, but $moduleName does not load in $($engine.Label)." -ForegroundColor Red
                if ($check.PolicyProblem) {
                    Write-Host '  Cause: the PowerShell execution policy does not allow module files to run.'
                    Write-Host "  Fix: open $($engine.Label) and run this once (no administrator rights needed):"
                    Write-Host ''
                    Write-Host '      Set-ExecutionPolicy -Scope CurrentUser RemoteSigned' -ForegroundColor Yellow
                    Write-Host ''
                    Write-Host '  Then open a new window and run:  Import-Module DnsLathund'
                    Write-Host '  If that command is refused, Group Policy sets the policy; ask the person who'
                    Write-Host '  administers your computers. To see which scope wins, run: Get-ExecutionPolicy -List'
                }
                else {
                    Write-Host '  PowerShell reported:'
                }
                if ($check.ErrorText) {
                    $shown = @($check.ErrorText -split "`n" | Select-Object -First 6)
                    foreach ($line in $shown) { Write-Host "    $line" -ForegroundColor DarkGray }
                }
            }
        }
        catch {
            $exitCode = 1
            Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host ''
    if ($exitCode -eq 0 -and $installed.Count -gt 0) {
        Write-Host "Done. $moduleName is installed for: $($installed -join ', ')." -ForegroundColor Green
        Write-Host ''
        Write-Host 'Open a new PowerShell window and try these four commands. None of them changes DNS.'
        Write-Host '(Replace dc01 with the name of one of your domain controllers.)'
        Write-Host ''
        Write-Host '    Update-DnsSnapshot -Server dc01 -WhatIf -Verbose   # 1. preview which zones would be exported'
        Write-Host '    Update-DnsSnapshot -Server dc01                    # 2. export them into the local snapshot'
        Write-Host '    Get-DnsSnapshot -Server dc01                       # 3. what is cached, and how old'
        Write-Host '    Get-DnsEntry -Find srv01 -Server dc01              # 4. search it'
        Write-Host ''
        Write-Host 'Help:  Get-Help Get-DnsEntry -Examples    and    Get-Help about_DnsLathund'
    }
    elseif ($exitCode -ne 0) {
        Write-Host 'The installation did not finish cleanly. Read the messages above.' -ForegroundColor Red
    }
    else {
        Write-Host 'Nothing was installed.' -ForegroundColor Yellow
    }
}
catch {
    $exitCode = 1
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ''
Wait-ForEnter
exit $exitCode
