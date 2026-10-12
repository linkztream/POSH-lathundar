function Test-DnsConnectionError {
    <#
    .SYNOPSIS
        Tells whether an error record says the DNS server cannot be reached.

    .DESCRIPTION
        The live write helpers (Remove-, Add- and Set-DnsLiveRecord) run the
        DnsServer cmdlets silenced and classify the errors they collect. Most
        errors belong to one record and end that item as Failed; an unreachable
        server ends the whole batch instead, because every following item would
        fail the same way after its own timeout (CONTRACTS.md sections 5.8, 7.5
        and 13.9). This helper makes that one decision, so the three helpers
        cannot drift apart.

        Returns $true when any of these holds:
        - the error category is ConnectionError;
        - the FullyQualifiedErrorId contains '1722' (RPC_S_SERVER_UNAVAILABLE, as
          the DnsServer cmdlets report it: 'WIN32 1722,...');
        - the FullyQualifiedErrorId contains '0x800706BA' (the same error as an
          HRESULT, as CIM reports it);
        - the FullyQualifiedErrorId contains '0x8033' (a WSMan transport failure:
          WinRM not listening, the host not found, the session timed out).
        The text comparisons ignore case, because CIM writes HRESULTs in either
        case. Anything else, including access denied (Win32 5), returns $false: the
        server answered, it only refused this item.

        Duck-typed: any object with FullyQualifiedErrorId and CategoryInfo works,
        including a deserialized error record. $null returns $false.

    .PARAMETER ErrorRecord
        The error record to classify, usually one entry of an -ErrorVariable.

    .OUTPUTS
        System.Boolean

    .EXAMPLE
        $outcome['Unreachable'] = Test-DnsConnectionError -ErrorRecord $removeError

        Marks a failed removal as "server unreachable" so the caller ends the batch.

    .EXAMPLE
        Get-DnsServerResourceRecord -ComputerName 'dc99' -ZoneName 'contoso.local' -ErrorAction SilentlyContinue -ErrorVariable lookupErrors
        Test-DnsConnectionError -ErrorRecord $lookupErrors[0]

        Returns $true when dc99 does not answer RPC (WIN32 1722).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$ErrorRecord
    )

    if ($null -eq $ErrorRecord) {
        return $false
    }

    # Properties are looked up through PSObject so that a foreign object never
    # trips strict mode; the module runs under Set-StrictMode -Version Latest.
    $category = $null
    $categoryInfo = $ErrorRecord.PSObject.Properties['CategoryInfo']
    if ($null -ne $categoryInfo -and $null -ne $categoryInfo.Value -and $null -ne $categoryInfo.Value.PSObject.Properties['Category']) {
        $category = [string]$categoryInfo.Value.Category
    }
    if ($category -eq 'ConnectionError') {
        return $true
    }

    $errorIdProperty = $ErrorRecord.PSObject.Properties['FullyQualifiedErrorId']
    if ($null -eq $errorIdProperty -or $null -eq $errorIdProperty.Value) {
        return $false
    }
    $errorId = [string]$errorIdProperty.Value

    # -like ignores case, which the HRESULT forms need.
    $errorId -like '*1722*' -or $errorId -like '*0x800706BA*' -or $errorId -like '*0x8033*'
}
