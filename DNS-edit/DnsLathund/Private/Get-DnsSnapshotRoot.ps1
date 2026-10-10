function Get-DnsSnapshotRoot {
    <#
    .SYNOPSIS
        Returns the folder where zone snapshots are stored.

    .DESCRIPTION
        Without -Server, returns the snapshot root folder, chosen in this order:
        1. $script:SnapshotRoot, when set (tests and callers that want an
           isolated store set it in the module scope);
        2. the environment variable DNSLATHUND_SNAPSHOTPATH, so that a scheduled
           task or a shared jump host can keep snapshots somewhere other than
           the profile;
        3. %LOCALAPPDATA%\DnsLathund\snapshot (CONTRACTS.md section 9.4).

        With -Server, returns the server's folder below the root,
        <root>\<server>, with the server name in lower case. Characters that are
        not valid in a folder name (anything outside A-Z, a-z, 0-9, '.', '_' and
        '-', for example the colons of an IPv6 address) are replaced with '_';
        ordinary host names are unchanged.

        The folder is neither created nor checked; callers that write create it
        after their confirmation gate, so -WhatIf leaves no trace on disk.

    .PARAMETER Server
        Optional DNS server name. When given, the server's subfolder is returned.

    .EXAMPLE
        Get-DnsSnapshotRoot

        Returns, for example, 'C:\Users\me\AppData\Local\DnsLathund\snapshot'.

    .EXAMPLE
        Get-DnsSnapshotRoot -Server 'DC01'

        Returns, for example, 'C:\Users\me\AppData\Local\DnsLathund\snapshot\dc01'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Server
    )

    if ($script:SnapshotRoot) {
        $root = [string]$script:SnapshotRoot
        $source = 'the module setting $script:SnapshotRoot'
    }
    elseif ($env:DNSLATHUND_SNAPSHOTPATH) {
        $root = [string]$env:DNSLATHUND_SNAPSHOTPATH
        $source = 'the environment variable DNSLATHUND_SNAPSHOTPATH'
    }
    else {
        $root = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'DnsLathund\snapshot'
        $source = 'the default location'
    }

    if (-not $Server) {
        Write-Verbose "Snapshot root: '$root' (from $source)."
        return $root
    }

    $serverFolder = $Server.Trim().ToLowerInvariant() -replace '[^a-z0-9._-]', '_'
    $serverPath = Join-Path -Path $root -ChildPath $serverFolder
    Write-Verbose "Snapshot folder: '$serverPath' (root from $source)."
    $serverPath
}
