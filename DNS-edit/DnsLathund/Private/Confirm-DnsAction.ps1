function Confirm-DnsAction {
    <#
    .SYNOPSIS
        Decides whether a state-changing action may run (WhatIf, Confirm, Force).

    .DESCRIPTION
        Replaces $PSCmdlet.ShouldProcess(), which cannot be called in Constrained
        Language Mode. The calling public function declares SupportsShouldProcess,
        so -WhatIf and -Confirm set $WhatIfPreference and $ConfirmPreference in its
        scope, and this helper reads them through dynamic scoping. Rules, in order:

        1. $WhatIfPreference is set: print the standard "What if:" line with
           Write-Host and return $false.
        2. -Force, or $State.All set by an earlier "Yes to all": return $true.
        3. Prompt only when $ConfirmPreference is not 'None' and the action's
           impact is at least $ConfirmPreference; otherwise return $true.
           -Confirm:$false sets 'None' (never prompt), -Confirm sets 'Low'.
        4. Prompt with Read-Host: Y/Yes returns $true; A/All sets $State.All and
           returns $true; S/Stop throws "Operation stopped by the operator.";
           anything else (including just Enter) returns $false.
        5. When the host cannot prompt (Read-Host throws, for example under
           -NonInteractive), write a non-terminating error with the ErrorId
           DnsLathund.Confirm.NonInteractive and return $false, so an unattended
           run that forgot -Force changes nothing.

        This is the only function in the module that prompts or calls Write-Host.

    .PARAMETER Target
        What the action applies to, for example 'srv01.contoso.local (A 10.0.16.20)'.

    .PARAMETER Action
        What will be done, for example 'Remove A record'.

    .PARAMETER Impact
        Low, Medium or High; compared with $ConfirmPreference.

    .PARAMETER State
        A hashtable created once per public command call (@{ All = $false }); it
        carries "Yes to all" from one item to the next.

    .PARAMETER Force
        The public command's -Force: confirm without prompting.

    .EXAMPLE
        $state = @{ All = $false }
        if (Confirm-DnsAction -Target 'srv01.contoso.local' -Action 'Remove A record' -Impact High -State $state -Force:$Force) {
            # make the change
        }

        Typical use inside a public function that declares SupportsShouldProcess.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Target,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Action,

        [Parameter(Mandatory)]
        [ValidateSet('Low', 'Medium', 'High')]
        [string]$Impact,

        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter()]
        [switch]$Force
    )

    if ($WhatIfPreference) {
        Write-Host "What if: Performing the operation ""$Action"" on target ""$Target""."
        return $false
    }

    if ($Force -or $State['All'] -eq $true) {
        return $true
    }

    $preference = [int][System.Management.Automation.ConfirmImpact][string]$ConfirmPreference
    $impactValue = [int][System.Management.Automation.ConfirmImpact]$Impact
    if ($preference -eq 0 -or $impactValue -lt $preference) {
        return $true
    }

    $prompt = "$Action`n  $Target`n[Y] Yes  [N] No  [A] Yes to all  [S] Stop (default is N)"
    try {
        $answer = Read-Host -Prompt $prompt
    }
    catch {
        Write-Error -Message 'This session cannot prompt. Re-run with -Force to confirm all actions, or -WhatIf to preview.' -Category InvalidOperation -ErrorId 'DnsLathund.Confirm.NonInteractive' -TargetObject $Target
        return $false
    }

    $choice = ''
    if ($null -ne $answer) {
        $choice = ([string]$answer).Trim().ToLowerInvariant()
    }

    switch ($choice) {
        { $_ -eq 'y' -or $_ -eq 'yes' } {
            return $true
        }
        { $_ -eq 'a' -or $_ -eq 'all' } {
            $State['All'] = $true
            return $true
        }
        { $_ -eq 's' -or $_ -eq 'stop' } {
            throw 'Operation stopped by the operator.'
        }
    }

    return $false
}
