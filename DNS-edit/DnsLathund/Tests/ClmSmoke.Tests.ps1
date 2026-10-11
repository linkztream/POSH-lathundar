<#
.SYNOPSIS
    Runs the Constrained Language Mode smoke test in child processes.

.DESCRIPTION
    Enforces CONTRACTS §16. Starts Tests\Clm\Invoke-ClmSmokeTest.ps1 with
    powershell.exe (Windows PowerShell 5.1) and, when it is on the PATH,
    with pwsh (PowerShell 7), and asserts exit code 0 plus the runner's
    success marker.

    The constrained runspace is never created inside the Pester process:
    one failed cast in Constrained Language Mode poisons every later cast
    in that process (PowerShell issue #28128). For the same reason this file
    does not import the module itself.

    Skips, rather than fails, while DnsLathund.psd1 does not exist yet.
#>

BeforeAll {
    $script:SmokeManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\DnsLathund.psd1'
    $script:SmokeRunnerPath = Join-Path -Path $PSScriptRoot -ChildPath 'Clm\Invoke-ClmSmokeTest.ps1'
    $script:SmokeSuccessMarker = 'CLM-SMOKE: PASS'

    function Invoke-ClmSmokeChild {
        param (
            [string]$FilePath,
            [string[]]$ArgumentList
        )

        $output = & $FilePath @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE

        @{
            ExitCode = $exitCode
            Text     = (@($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
        }
    }
}

Describe 'DnsLathund works in Constrained Language Mode (CONTRACTS §16)' {
    It 'passes the smoke scenario in Windows PowerShell 5.1 (powershell.exe)' {
        if (-not (Test-Path -LiteralPath $script:SmokeManifestPath -PathType Leaf)) {
            Set-ItResult -Skipped -Because 'DnsLathund.psd1 does not exist yet'
            return
        }

        $windowsPowerShell = Join-Path -Path $env:windir -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
            Set-ItResult -Skipped -Because "Windows PowerShell was not found at $windowsPowerShell"
            return
        }

        $manifest = (Resolve-Path -LiteralPath $script:SmokeManifestPath).ProviderPath
        $result = Invoke-ClmSmokeChild -FilePath $windowsPowerShell -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $script:SmokeRunnerPath, '-ModulePath', $manifest
        )

        $result.ExitCode | Should -Be 0 -Because ("the smoke runner reported:`n" + $result.Text)
        $result.Text | Should -Match ([regex]::Escape($script:SmokeSuccessMarker))
    }

    It 'passes the smoke scenario in PowerShell 7 (pwsh)' {
        if (-not (Test-Path -LiteralPath $script:SmokeManifestPath -PathType Leaf)) {
            Set-ItResult -Skipped -Because 'DnsLathund.psd1 does not exist yet'
            return
        }

        $pwsh = Get-Command -Name pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $pwsh) {
            Set-ItResult -Skipped -Because 'pwsh is not on the PATH'
            return
        }

        $manifest = (Resolve-Path -LiteralPath $script:SmokeManifestPath).ProviderPath
        $result = Invoke-ClmSmokeChild -FilePath $pwsh.Source -ArgumentList @(
            '-NoProfile', '-NonInteractive',
            '-File', $script:SmokeRunnerPath, '-ModulePath', $manifest
        )

        $result.ExitCode | Should -Be 0 -Because ("the smoke runner reported:`n" + $result.Text)
        $result.Text | Should -Match ([regex]::Escape($script:SmokeSuccessMarker))
    }
}
