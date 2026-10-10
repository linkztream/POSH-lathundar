function Export-DnsZoneFile {
    <#
    .SYNOPSIS
        Exports one DNS zone on the server and copies the export file here.

    .DESCRIPTION
        Runs Export-DnsServerZone on the DNS server, which always writes into
        %windir%\System32\dns on the server, then retrieves that file to
        -DestinationPath and removes the server copy (CONTRACTS.md section 9.1).
        Returns the full local path.

        The server-side file name is unique per call,
        dnslathund_<zone>_<yyyyMMddHHmmssfff>.txt (characters outside
        A-Z, a-z, 0-9, '.', '_' and '-' in the zone name become '_'), because
        Export-DnsServerZone refuses to overwrite and two operators may export
        the same zone at the same time.

        Retrieval, in this order:
        1. The server is this computer (-Server equals COMPUTERNAME, its DNS
           host name or FQDN, 'localhost', '.', '127.0.0.1' or '::1'): copy from
           the local export folder ($script:DnsServerExportRoot). Nothing else is
           tried, because the other paths would only reach the same folder.
        2. Otherwise, without -Credential: copy from
           \\<server>\admin$\System32\dns\<file>. Skipped with -Credential,
           because a UNC copy cannot carry alternate credentials.
        3. Otherwise, or when the UNC copy fails: Invoke-Command (with
           -Credential when given) reads the file with Get-Content -ReadCount 2000
           on the server and the chunks are appended locally with Add-Content as
           they arrive, so a 550 000-line zone never travels as one string.

        The server copy is removed in a finally block, also when the retrieval
        fails, unless -KeepRemoteFile is set. A failed removal is a warning that
        names the exact remote path, not an error: the local copy is good.

        Every file write carries -WhatIf:$false -Confirm:$false, so a caller's
        -WhatIf cannot leave a half-made snapshot behind; the caller decides
        whether to export at all before calling this function.

        Throws when the zone cannot be exported (for example when it does not
        exist, is not a primary zone, or access is denied), when the file cannot
        be retrieved by any method, or when -DestinationPath already exists.

    .PARAMETER ZoneName
        The zone to export.

    .PARAMETER Server
        The DNS server that hosts the zone.

    .PARAMETER DestinationPath
        Full path of the local file to create. It must not exist; its folder is
        created when missing.

    .PARAMETER Credential
        Alternate credentials. The export then runs through a CIM session
        (Get-DnsServerParameter), the UNC copy is skipped and Invoke-Command uses
        the credentials.

    .PARAMETER TimeoutSec
        Timeout for the CIM session, for opening the remoting session and for
        each remoting operation.

    .PARAMETER KeepRemoteFile
        Leave the export file on the server (for troubleshooting).

    .EXAMPLE
        Export-DnsZoneFile -ZoneName 'contoso.local' -Server 'dc01' -DestinationPath 'C:\Temp\contoso.local.txt'

        Exports contoso.local on dc01, copies it to C:\Temp and removes the copy
        on dc01. Returns 'C:\Temp\contoso.local.txt'.

    .EXAMPLE
        Export-DnsZoneFile -ZoneName '16.0.10.in-addr.arpa' -Server 'dc01' -DestinationPath $path -Credential $cred

        Exports through a CIM session as $cred and streams the file back over
        WinRM as $cred.

    .NOTES
        Windows PowerShell 5.1 writes a UTF-8 BOM when Add-Content -Encoding UTF8
        creates the local file (WinRM path only; the local and UNC paths copy the
        bytes unchanged). A real export has no BOM. The zone file parser sniffs
        the BOM, so both forms read the same.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ZoneName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [Parameter()]
        [AllowNull()]
        [pscredential]$Credential,

        [Parameter()]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSec = 300,

        [Parameter()]
        [switch]$KeepRemoteFile
    )

    $serverKey = $Server.Trim().ToLowerInvariant()
    $zone = $ZoneName.Trim().TrimEnd('.')
    $hasCredential = ($null -ne $Credential) -and ('' -ne [string]$Credential.UserName)

    # Refusing before anything runs on the server keeps an existing snapshot file
    # safe from a wrong argument.
    if (Test-Path -LiteralPath $DestinationPath) {
        throw "The destination file '$DestinationPath' already exists and is never overwritten. Remove it or specify another -DestinationPath."
    }
    $destinationFolder = Split-Path -Path $DestinationPath -Parent
    if ($destinationFolder -and -not (Test-Path -LiteralPath $destinationFolder -PathType Container)) {
        $null = New-Item -Path $destinationFolder -ItemType Directory -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
    }

    # --- Is the server this computer? ---
    $localNames = @($env:COMPUTERNAME, 'localhost', '.', '127.0.0.1', '::1')
    try {
        # COMPUTERNAME is the NetBIOS name (15 characters at most); the DNS host
        # name and the primary DNS suffix live in the TCP/IP parameters.
        $tcpip = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -ErrorAction Stop
        $hostName = ''
        $domainName = ''
        if ($null -ne $tcpip.PSObject.Properties['Hostname']) {
            $hostName = [string]$tcpip.Hostname
        }
        if ($null -ne $tcpip.PSObject.Properties['Domain']) {
            $domainName = [string]$tcpip.Domain
        }
        $localNames = $localNames + @(
            $hostName
            if ($domainName) {
                "$($env:COMPUTERNAME).$domainName"
                if ($hostName) {
                    "$hostName.$domainName"
                }
            }
        )
    }
    catch {
        Write-Verbose "Could not read the DNS host name of this computer: $($_.Exception.Message)"
    }
    $isLocal = $localNames -contains $serverKey

    $safeZone = $zone -replace '[^A-Za-z0-9._-]', '_'
    $remoteFileName = 'dnslathund_{0}_{1}.txt' -f $safeZone, (Get-Date -Format 'yyyyMMddHHmmssfff')
    $localSource = Join-Path -Path $script:DnsServerExportRoot -ChildPath $remoteFileName
    $uncPath = '\\{0}\admin$\System32\dns\{1}' -f $serverKey, $remoteFileName
    if ($isLocal) {
        $remoteDisplayPath = "'$localSource'"
    }
    else {
        $remoteDisplayPath = "'%windir%\System32\dns\$remoteFileName' on '$serverKey' ($uncPath)"
    }

    $invokeParameters = @{
        ComputerName  = $serverKey
        SessionOption = New-PSSessionOption -OpenTimeout ($TimeoutSec * 1000) -OperationTimeout ($TimeoutSec * 1000)
        ErrorAction   = 'Stop'
    }
    if ($hasCredential) {
        $invokeParameters['Credential'] = $Credential
    }

    # --- Export on the server ---
    Import-DnsServerModule
    $serverParameters = Get-DnsServerParameter -Server $serverKey -Credential $Credential -TimeoutSec $TimeoutSec
    try {
        Write-Verbose "Exporting zone '$zone' on '$serverKey' to $remoteDisplayPath (Export-DnsServerZone)."
        $null = Export-DnsServerZone -Name $zone -FileName $remoteFileName @serverParameters -ErrorAction Stop -WhatIf:$false -Confirm:$false
    }
    catch {
        throw "Could not export zone '$zone' on '$serverKey': $($_.Exception.Message) Check that the zone exists on that server, that it is a primary zone, and that your account may export it (DnsAdmins or Administrators)."
    }

    # --- Retrieve, then always clean up the server copy ---
    $retrievedBy = ''
    $failures = @{}
    try {
        if ($isLocal) {
            try {
                Write-Verbose "Copying '$localSource' to '$DestinationPath' (the DNS server is this computer)."
                Copy-Item -LiteralPath $localSource -Destination $DestinationPath -ErrorAction Stop -WhatIf:$false -Confirm:$false
                $retrievedBy = 'Local'
            }
            catch {
                $failures['Local copy'] = $_.Exception.Message
            }
        }
        else {
            if ($hasCredential) {
                Write-Verbose "Skipping the copy from '$uncPath': a UNC copy cannot use -Credential."
            }
            else {
                try {
                    Write-Verbose "Copying '$uncPath' to '$DestinationPath'."
                    Copy-Item -LiteralPath $uncPath -Destination $DestinationPath -ErrorAction Stop -WhatIf:$false -Confirm:$false
                    $retrievedBy = 'Unc'
                }
                catch {
                    $failures['admin$ share'] = $_.Exception.Message
                }
            }

            if (-not $retrievedBy) {
                # A failed copy may have left a partial file behind.
                if (Test-Path -LiteralPath $DestinationPath) {
                    Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
                }
                try {
                    Write-Verbose "Streaming '$remoteFileName' from '$serverKey' over WinRM (Invoke-Command, 2000 lines per chunk) to '$DestinationPath'."
                    # Each chunk is a string[] of up to 2000 lines that Add-Content appends
                    # as it arrives, so memory stays flat whatever the zone size.
                    Invoke-Command @invokeParameters -ScriptBlock {
                        Get-Content -LiteralPath (Join-Path -Path $env:windir -ChildPath ('System32\dns\' + $using:remoteFileName)) -ReadCount 2000 -Encoding UTF8 -ErrorAction Stop
                    } | Add-Content -LiteralPath $DestinationPath -Encoding UTF8 -ErrorAction Stop -WhatIf:$false -Confirm:$false

                    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
                        throw 'The server returned no content.'
                    }
                    $retrievedBy = 'WinRM'
                }
                catch {
                    $failures['WinRM'] = $_.Exception.Message
                }
            }
        }

        if (-not $retrievedBy) {
            if (Test-Path -LiteralPath $DestinationPath) {
                Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
            }
            $reasons = @(foreach ($method in @($failures.Keys | Sort-Object)) { "[$method] $($failures[$method])" }) -join ' '
            throw "Zone '$zone' was exported on '$serverKey' but the file $remoteDisplayPath could not be copied here. $reasons Check that this computer can reach the admin`$ share or WinRM on '$serverKey'."
        }

        Write-Verbose "Retrieved zone '$zone' from '$serverKey' ($retrievedBy) to '$DestinationPath'."
    }
    finally {
        if ($KeepRemoteFile) {
            Write-Verbose "Keeping the export file $remoteDisplayPath (-KeepRemoteFile)."
        }
        else {
            # The way that already worked comes first; WinRM is the fallback for UNC.
            if ($isLocal) {
                $cleanupMethods = @('Local')
            }
            elseif ($hasCredential -or $retrievedBy -eq 'WinRM') {
                $cleanupMethods = @('WinRM')
            }
            else {
                $cleanupMethods = @('Unc', 'WinRM')
            }

            $removed = $false
            $cleanupFailures = foreach ($cleanupMethod in $cleanupMethods) {
                try {
                    if ($cleanupMethod -eq 'Local') {
                        Write-Verbose "Removing '$localSource'."
                        Remove-Item -LiteralPath $localSource -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
                    }
                    elseif ($cleanupMethod -eq 'Unc') {
                        Write-Verbose "Removing '$uncPath'."
                        Remove-Item -LiteralPath $uncPath -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
                    }
                    else {
                        Write-Verbose "Removing '$remoteFileName' on '$serverKey' over WinRM (Invoke-Command)."
                        $null = Invoke-Command @invokeParameters -ScriptBlock {
                            Remove-Item -LiteralPath (Join-Path -Path $env:windir -ChildPath ('System32\dns\' + $using:remoteFileName)) -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
                        }
                    }
                    $removed = $true
                    break
                }
                catch {
                    "[$cleanupMethod] $($_.Exception.Message)"
                }
            }

            if (-not $removed) {
                Write-Warning "Could not remove the export file $remoteDisplayPath from the DNS server: $(@($cleanupFailures) -join ' ') Delete it manually."
            }
        }
    }

    Convert-Path -LiteralPath $DestinationPath
}
