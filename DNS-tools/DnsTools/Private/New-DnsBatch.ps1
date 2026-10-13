function New-DnsBatch {
    <#
    .SYNOPSIS
        Creates the state hashtable that one run of a change command shares between its items.

    .DESCRIPTION
        Every change command (Remove-DnsEntry, New-DnsEntry, Set-DnsEntry,
        New-DnsReverseZone, Backup-DnsZone) creates one batch in begin {} and passes
        it to every helper that needs run-wide state (CONTRACTS.md section 7.5):

          BatchId     a new GUID string; every Result and change-log line of the run
                      carries it, so one run can be found again in the log
          Server      the DNS server, lower case
          LogPath     the -LogPath of the command, or $null for the default log
          Delay       seconds to sleep after each input item
          Force       the command's -Force as [bool]
          Confirm     the -State hashtable for Confirm-DnsAction (@{ All = @{} });
                      "Yes to all" is remembered per impact level in Confirm.All
          StartedAt   when the run started
          References  zone -> reference table, filled lazily by Get-DnsReference so
                      that each zone is queried at most once per run
          CimSession  the CIM session Get-DnsReference opened for WQL queries, or $null
          Counts      free-form counters for the end-of-run summary; Write-DnsResult
                      counts every Result value here

        The batch is a plain hashtable on purpose: helpers update it in place and it
        never leaves the module.

    .PARAMETER Server
        The DNS server the run changes, as resolved by Resolve-DnsServerName.

    .PARAMETER LogPath
        The change-log file of the run; $null or '' means the default (Write-DnsChangeLog).

    .PARAMETER Delay
        Seconds the command sleeps after each input item.

    .PARAMETER Force
        The command's -Force switch.

    .OUTPUTS
        System.Collections.Hashtable

    .EXAMPLE
        $batch = New-DnsBatch -Server $serverKey -LogPath $LogPath -Delay $Delay -Force:$Force
        Confirm-DnsAction -Target 'srv01.contoso.local' -Action 'Remove DNS records' -Impact High -State $batch['Confirm'] -Force:$batch['Force']

        Creates the batch in begin {} and uses its Confirm state for the gate.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogPath,

        [Parameter()]
        [ValidateRange(0, 86400)]
        [int]$Delay = 0,

        [Parameter()]
        [switch]$Force
    )

    # An empty -LogPath would be indistinguishable from "use the default" further
    # down; $null says so explicitly in the batch.
    $batchLogPath = $null
    if ($LogPath) {
        $batchLogPath = $LogPath
    }

    @{
        BatchId    = [guid]::NewGuid().ToString()
        Server     = $Server.Trim().ToLowerInvariant()
        LogPath    = $batchLogPath
        Delay      = $Delay
        Force      = [bool]$Force
        Confirm    = @{ All = @{} }
        StartedAt  = Get-Date
        References = @{}
        CimSession = $null
        Counts     = @{}
    }
}
