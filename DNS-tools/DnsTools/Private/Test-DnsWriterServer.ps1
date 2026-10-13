function Test-DnsWriterServer {
    <#
    .SYNOPSIS
        Warns when this session changes DNS on a different server than before.

    .DESCRIPTION
        AD-integrated DNS replicates between domain controllers with a delay. When
        one session changes the same node on two servers before replication has
        caught up, the later write can overwrite the earlier one. Every change
        command calls this helper in begin {} with its server (CONTRACTS.md
        sections 7.5 and 13.9).

        The first server that is passed is remembered in $script:WriterServer: the
        server that received this session's first change (CONTRACTS.md section 7.1).
        Every later call with another server writes the warning

            This session already changed DNS on 'dc01'; changes on 'dc02' may be lost
            if both touch the same node before replication.

        and leaves $script:WriterServer as it is, so the warning keeps naming the
        server the session started on. Server names are compared case-insensitively.
        No output.

    .PARAMETER Server
        The server the calling command is about to change.

    .OUTPUTS
        None.

    .EXAMPLE
        Test-DnsWriterServer -Server $serverKey

        Remembers the server on the first change of the session; warns on a later
        change on another server.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Server
    )

    $serverKey = $Server.Trim().ToLowerInvariant()

    if (-not $script:WriterServer) {
        $script:WriterServer = $serverKey
        Write-Verbose "DNS changes in this session go to '$serverKey'."
        return
    }

    if ($script:WriterServer -ne $serverKey) {
        Write-Warning ("This session already changed DNS on '{0}'; changes on '{1}' may be lost if both touch the same node before replication." -f $script:WriterServer, $serverKey)
    }
}
