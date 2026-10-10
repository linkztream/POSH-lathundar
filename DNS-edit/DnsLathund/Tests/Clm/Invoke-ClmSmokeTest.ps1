<#
.SYNOPSIS
    Runs the DnsLathund smoke scenario inside a Constrained Language Mode runspace.

.DESCRIPTION
    Test tool for CONTRACTS §16. ClmSmoke.Tests.ps1 starts it as a child
    process (powershell.exe and pwsh). It must never run inside the Pester
    process: one failed cast in Constrained Language Mode poisons every
    later cast in that process (PowerShell issue #28128).

    The runner itself runs in Full language. It creates a runspace from
    InitialSessionState.CreateDefault2() with LanguageMode set to
    ConstrainedLanguage and runs a bootstrap script in it that:

      1. asserts that the language mode is ConstrainedLanguage;
      2. imports the module from -ModulePath;
      3. dot-sources the stub file into the module scope with
             . (Get-Module DnsLathund) { . $args[0] } <StubsPath>
         Dot-sourcing the module-bound script block is what makes the stub
         functions land in the module's top-level scope, where module code
         finds them. '& (Get-Module DnsLathund) { . <file> }' also runs in
         CLM, but defines the stubs in a throw-away child scope, so module
         code falls through to the real DnsServer cmdlets.
         [scriptblock]::Create is not needed (and is blocked in CLM);
      4. dot-sources the scenario file.

    The real DnsServer module is never imported: it cannot be loaded in a
    manually constrained runspace, which is why the stubs exist.

    Every record of every stream is printed to stdout, one line each,
    prefixed with the stream name (OUTPUT, ERROR, WARNING, VERBOSE, DEBUG,
    INFORMATION, PROGRESS); the runner's own lines start with RUNNER. The
    run fails (exit code 1, last line 'CLM-SMOKE: FAIL') if the bootstrap or
    the scenario throws, if any error record was written, if any text
    contains a CLM failure signature ('Only core types', 'Method invocation
    is supported only on core types', 'Cannot create type'), or if the
    scenario did not run to its end. Otherwise the last line is
    'CLM-SMOKE: PASS' and the exit code is 0.

.PARAMETER ModulePath
    Path of DnsLathund.psd1. Defaults to the module two folders up.

.PARAMETER StubsPath
    Path of the DnsServer stub file. Defaults to ..\Stubs\DnsServerStubs.ps1
    relative to this script. A missing file is reported and the run
    continues without stubs.

.PARAMETER ScenarioPath
    Path of the scenario file that is dot-sourced in the constrained
    runspace. Defaults to Scenario.ps1 next to this script.

.EXAMPLE
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Tests\Clm\Invoke-ClmSmokeTest.ps1

    Runs the default scenario against the module in this repository under
    Windows PowerShell 5.1.

.EXAMPLE
    pwsh -NoProfile -NonInteractive -File .\Tests\Clm\Invoke-ClmSmokeTest.ps1 -ScenarioPath .\MyScenario.ps1

    Runs another scenario under PowerShell 7.
#>
[CmdletBinding()]
param (
    [ValidateNotNullOrEmpty()]
    [string]$ModulePath,

    [ValidateNotNullOrEmpty()]
    [string]$StubsPath,

    [ValidateNotNullOrEmpty()]
    [string]$ScenarioPath
)

# Defaults are resolved here, not in the param block: Windows PowerShell
# 5.1 leaves $PSScriptRoot empty in parameter defaults under -File.
if (-not $ModulePath) {
    $ModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\DnsLathund.psd1'
}

if (-not $StubsPath) {
    $StubsPath = Join-Path -Path $PSScriptRoot -ChildPath '..\Stubs\DnsServerStubs.ps1'
}

if (-not $ScenarioPath) {
    $ScenarioPath = Join-Path -Path $PSScriptRoot -ChildPath 'Scenario.ps1'
}

$successMarker = 'CLM-SMOKE: PASS'
$failureMarker = 'CLM-SMOKE: FAIL'
$completionMarker = 'CLM-SMOKE: scenario completed'
$clmSignatures = @(
    'Only core types',
    'Method invocation is supported only on core types',
    'Cannot create type'
)

# Runs in the constrained runspace, so it must itself obey CLM. Paths
# arrive as variables set through SessionStateProxy, which avoids quoting
# them into the script text.
$bootstrap = @'
if ([string]$ExecutionContext.SessionState.LanguageMode -ne 'ConstrainedLanguage') {
    throw ('The smoke runspace is in {0} mode; expected ConstrainedLanguage.' -f $ExecutionContext.SessionState.LanguageMode)
}
Write-Output ('Language mode: {0}' -f $ExecutionContext.SessionState.LanguageMode)

Import-Module -Name $ClmSmokeModulePath -Force -ErrorAction Stop
$ClmSmokeModule = Get-Module -Name DnsLathund
if ($null -eq $ClmSmokeModule) {
    throw ('Importing {0} did not load a module named DnsLathund.' -f $ClmSmokeModulePath)
}
Write-Output ('Imported module {0} {1} from {2}' -f $ClmSmokeModule.Name, $ClmSmokeModule.Version, $ClmSmokeModule.ModuleBase)

if ($ClmSmokeStubsPath) {
    . $ClmSmokeModule { . $args[0] } $ClmSmokeStubsPath
    Write-Output ('Stubs dot-sourced into the module scope: {0}' -f $ClmSmokeStubsPath)
}

. $ClmSmokeScenarioPath

Write-Output 'CLM-SMOKE: scenario completed'
'@

$lines = New-Object -TypeName System.Collections.Generic.List[string]
$failures = New-Object -TypeName System.Collections.Generic.List[string]

function Add-RunnerLine {
    param (
        [string]$Stream,
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        $Text = ''
    }

    foreach ($line in ($Text -split "`r?`n")) {
        $lines.Add(('{0}: {1}' -f $Stream, $line))
    }
}

function ConvertTo-RunnerValue {
    param ($Value)

    if ($null -eq $Value) {
        return '<null>'
    }

    if ($Value -is [string]) {
        return $Value
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary]) {
        return '@(' + ((@($Value) | ForEach-Object { ConvertTo-RunnerValue -Value $_ }) -join ', ') + ')'
    }

    [string]$Value
}

# One line per output object: strings as they are, objects as
# '[TypeName] Name=Value; ...' so DnsLathund objects stay readable.
function ConvertTo-RunnerText {
    param ($InputObject)

    if ($null -eq $InputObject) {
        return '<null>'
    }

    $baseObject = $InputObject
    if ($InputObject -is [psobject]) {
        $baseObject = $InputObject.PSObject.BaseObject
    }

    if ($baseObject -is [string] -or $baseObject -is [ValueType]) {
        return [string]$baseObject
    }

    if ($baseObject -is [System.Collections.IDictionary]) {
        $pairs = foreach ($key in $baseObject.Keys) {
            '{0}={1}' -f $key, (ConvertTo-RunnerValue -Value $baseObject[$key])
        }
        return '@{' + ($pairs -join '; ') + '}'
    }

    if ($baseObject -is [System.Management.Automation.PSCustomObject]) {
        $pairs = foreach ($property in $InputObject.PSObject.Properties) {
            '{0}={1}' -f $property.Name, (ConvertTo-RunnerValue -Value $property.Value)
        }
        return '[{0}] {1}' -f $InputObject.PSObject.TypeNames[0], ($pairs -join '; ')
    }

    [string]$InputObject
}

function Add-RunnerErrorRecord {
    param (
        [string]$Stream,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Add-RunnerLine -Stream $Stream -Text $ErrorRecord.ToString()
    Add-RunnerLine -Stream $Stream -Text ('  FullyQualifiedErrorId: {0}' -f $ErrorRecord.FullyQualifiedErrorId)
    Add-RunnerLine -Stream $Stream -Text ('  CategoryInfo: {0}' -f $ErrorRecord.CategoryInfo)

    if ($null -ne $ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
        Add-RunnerLine -Stream $Stream -Text $ErrorRecord.InvocationInfo.PositionMessage
    }

    if ($ErrorRecord.ScriptStackTrace) {
        Add-RunnerLine -Stream $Stream -Text $ErrorRecord.ScriptStackTrace
    }
}

function Write-RunnerResult {
    foreach ($line in $lines) {
        Write-Output $line
    }

    if ($failures.Count -gt 0) {
        foreach ($failure in $failures) {
            Write-Output ('RUNNER: failure: {0}' -f $failure)
        }
        Write-Output $failureMarker
        exit 1
    }

    Write-Output $successMarker
    exit 0
}

try {
    $resolvedModulePath = (Resolve-Path -LiteralPath $ModulePath -ErrorAction Stop).ProviderPath
    $resolvedScenarioPath = (Resolve-Path -LiteralPath $ScenarioPath -ErrorAction Stop).ProviderPath
}
catch {
    $failures.Add($_.Exception.Message)
    Write-RunnerResult
}

$resolvedStubsPath = ''
if (Test-Path -LiteralPath $StubsPath -PathType Leaf) {
    $resolvedStubsPath = (Resolve-Path -LiteralPath $StubsPath).ProviderPath
}
else {
    Add-RunnerLine -Stream 'RUNNER' -Text ("Stub file '{0}' not found; continuing without stubs." -f $StubsPath)
}

Add-RunnerLine -Stream 'RUNNER' -Text ('Host engine: PowerShell {0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
Add-RunnerLine -Stream 'RUNNER' -Text ('Module:   {0}' -f $resolvedModulePath)
Add-RunnerLine -Stream 'RUNNER' -Text ('Stubs:    {0}' -f $(if ($resolvedStubsPath) { $resolvedStubsPath } else { '<none>' }))
Add-RunnerLine -Stream 'RUNNER' -Text ('Scenario: {0}' -f $resolvedScenarioPath)

$initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
$initialState.LanguageMode = [System.Management.Automation.PSLanguageMode]::ConstrainedLanguage
# The child runspace must not depend on the machine's execution policy;
# what is under test is the language mode.
$initialState.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass

$runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialState)
$shell = $null
$output = New-Object -TypeName 'System.Management.Automation.PSDataCollection[psobject]'

try {
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('ClmSmokeModulePath', $resolvedModulePath)
    $runspace.SessionStateProxy.SetVariable('ClmSmokeStubsPath', $resolvedStubsPath)
    $runspace.SessionStateProxy.SetVariable('ClmSmokeScenarioPath', $resolvedScenarioPath)

    $shell = [System.Management.Automation.PowerShell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript($bootstrap)

    $exception = $null
    try {
        # Passing an output collection keeps what was written before a throw.
        [void]$shell.Invoke($null, $output)
    }
    catch {
        # The invocation state holds the exception raised inside the
        # runspace, with the scenario's position; $_ only wraps it in a
        # MethodInvocationException pointing at the Invoke() call above.
        $exception = $shell.InvocationStateInfo.Reason
        if ($null -eq $exception) {
            $exception = $_.Exception
        }

        $failures.Add(('the bootstrap or scenario threw: {0}' -f $exception.Message))
    }

    foreach ($item in $output) {
        Add-RunnerLine -Stream 'OUTPUT' -Text (ConvertTo-RunnerText -InputObject $item)
    }

    if ($null -ne $exception) {
        if ($exception -is [System.Management.Automation.IContainsErrorRecord] -and $null -ne $exception.ErrorRecord) {
            Add-RunnerErrorRecord -Stream 'EXCEPTION' -ErrorRecord $exception.ErrorRecord
        }
        else {
            Add-RunnerLine -Stream 'EXCEPTION' -Text $exception.Message
        }
    }

    foreach ($record in $shell.Streams.Error) {
        Add-RunnerErrorRecord -Stream 'ERROR' -ErrorRecord $record
    }

    foreach ($record in $shell.Streams.Warning) {
        Add-RunnerLine -Stream 'WARNING' -Text $record.Message
    }

    foreach ($record in $shell.Streams.Verbose) {
        Add-RunnerLine -Stream 'VERBOSE' -Text $record.Message
    }

    foreach ($record in $shell.Streams.Debug) {
        Add-RunnerLine -Stream 'DEBUG' -Text $record.Message
    }

    foreach ($record in $shell.Streams.Information) {
        Add-RunnerLine -Stream 'INFORMATION' -Text ([string]$record.MessageData)
    }

    foreach ($record in $shell.Streams.Progress) {
        Add-RunnerLine -Stream 'PROGRESS' -Text ('{0} | {1} | {2}% | {3}' -f $record.Activity, $record.StatusDescription, $record.PercentComplete, $record.RecordType)
    }

    if ($shell.Streams.Error.Count -gt 0) {
        $failures.Add(('{0} error record(s) were written' -f $shell.Streams.Error.Count))
    }

    $completed = $false
    foreach ($item in $output) {
        if ([string]$item -eq $completionMarker) {
            $completed = $true
        }
    }

    if (-not $completed) {
        $failures.Add('the scenario did not run to its end')
    }
}
catch {
    $failures.Add(('the runner failed: {0}' -f $_.Exception.Message))
}
finally {
    if ($null -ne $shell) {
        $shell.Dispose()
    }

    $runspace.Dispose()
}

foreach ($signature in $clmSignatures) {
    foreach ($line in $lines) {
        if ($line.IndexOf($signature, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $failures.Add(("CLM failure signature '{0}' found: {1}" -f $signature, $line))
        }
    }
}

Write-RunnerResult
