@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # The module deliberately never calls $PSCmdlet.ShouldProcess(): method calls on
        # $PSCmdlet are blocked in Constrained Language Mode. Confirm-DnsAction implements
        # the WhatIf/Confirm/Force semantics instead (CONTRACTS.md section 10), so this
        # rule would flag every SupportsShouldProcess declaration.
        'PSShouldProcess',

        # New-DnsObject only builds an in-memory object; the "New" verb trips this rule
        # although no system state changes. State-changing public commands declare
        # SupportsShouldProcess and route through Confirm-DnsAction.
        'PSUseShouldProcessForStateChangingFunctions',

        # The only Write-Host in the module is in Confirm-DnsAction, which prints the
        # "What if:" line that $PSCmdlet.ShouldProcess would normally print; that line
        # must reach the console and must not pollute the output stream.
        'PSAvoidUsingWriteHost'
    )
}
