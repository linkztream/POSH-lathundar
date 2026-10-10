<#
.SYNOPSIS
    AST lint that keeps DnsLathund module code inside Constrained Language Mode.

.DESCRIPTION
    Enforces CONTRACTS §4.1 and §16. Every *.ps1 under Private\ and Public\
    plus DnsLathund.psm1 is parsed with the PowerShell parser (this test runs
    in Full language, so .NET is fine here) and checked against thirteen rules.
    Each rule is its own It, so a failure names the rule, the file and the
    line.

    The rules are plain functions in this file. The module scan and the
    self-tests ('Lint rules detect violations') call the same functions, so
    the self-tests prove that the scan can actually see what it forbids.

    The scan passes vacuously while Private\ and Public\ are empty or only
    partly populated.
#>

BeforeDiscovery {
    $script:ClmRuleCases = @(
        @{ Number = '01'; Function = 'Find-ClmRule01Violation'; Title = 'no [PSCustomObject] casts' }
        @{ Number = '02'; Function = 'Find-ClmRule02Violation'; Title = 'no forbidden .NET type names (IO, generic collections, ArrayList/Queue/Stack, Text except Encoding reads, Reflection, ErrorRecord/PSCmdlet/Host/Language, Math, BitConverter, Convert, ref)' }
        @{ Number = '03'; Function = 'Find-ClmRule03Violation'; Title = 'no method calls on $PSCmdlet, $Host, $ExecutionContext, $MyInvocation or $PSBoundParameters' }
        @{ Number = '04'; Function = 'Find-ClmRule04Violation'; Title = 'no static method calls on types outside the allow-list' }
        @{ Number = '05'; Function = 'Find-ClmRule05Violation'; Title = 'no new/Invoke/InvokeReturnAsIs/Create/TryParse/GetNewClosure/TypeNames.Insert/GetUnresolvedProviderPathFromPSPath calls' }
        @{ Number = '06'; Function = 'Find-ClmRule06Violation'; Title = 'no New-Object except PSObject, no -ComObject, Add-Type, Invoke-Expression or Set-Variable -Scope Global' }
        @{ Number = '07'; Function = 'Find-ClmRule07Violation'; Title = 'internal file writes and zone exports carry -WhatIf:$false and -Confirm:$false' }
        @{ Number = '08'; Function = 'Find-ClmRule08Violation'; Title = 'no += on a variable, index or member inside a loop, ForEach-Object/Where-Object or .ForEach()/.Where() (numeric constant counters excepted)' }
        @{ Number = '09'; Function = 'Find-ClmRule09Violation'; Title = 'no class/enum definitions and no using statements' }
        @{ Number = '10'; Function = 'Find-ClmRule10Violation'; Title = 'no Write-Host outside Private\Confirm-DnsAction.ps1' }
        @{ Number = '11'; Function = 'Find-ClmRule11Violation'; Title = 'no Read-Host outside Private\Confirm-DnsAction.ps1' }
        @{ Number = '12'; Function = 'Find-ClmRule12Violation'; Title = 'no CIM type literals (Microsoft.Management.Infrastructure.*) and no ErrorCategory type names' }
        @{ Number = '13'; Function = 'Find-ClmRule13Violation'; Title = 'no ForEach-Object member-name form (first positional argument must be a script block; no -MemberName)' }
    )

    $snippetPath = 'Public\Test-ClmSnippet.ps1'
    $confirmPath = 'Private\Confirm-DnsAction.ps1'

    # Each snippet is linted on its own. A violation snippet must make its
    # rule fire at least once; a compliant snippet must leave it silent.
    $script:ClmViolationCases = @(
        @{ Number = '01'; Path = $snippetPath; Snippet = '$o = [PSCustomObject]@{ A = 1 }' }
        @{ Number = '01'; Path = $snippetPath; Snippet = '$o = [pscustomobject][ordered]@{ A = 1 }' }
        @{ Number = '01'; Path = $snippetPath; Snippet = '$o = [System.Management.Automation.PSCustomObject]@{ A = 1 }' }
        @{ Number = '01'; Path = $snippetPath; Snippet = '$o = [PSCustomObject]$table' }

        @{ Number = '02'; Path = $snippetPath; Snippet = '[System.IO.File]::Exists($p)' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$text = [IO.File]$p' }
        @{ Number = '02'; Path = $snippetPath; Snippet = 'function f { param([System.IO.FileInfo]$File) }' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '[System.Collections.Generic.List[string]]$list = @()' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$d = [Collections.Generic.Dictionary[string, int]]@{}' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '[Nullable[System.IO.FileAttributes]]$attributes = $null' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$isList = $x -is [System.Collections.ArrayList]' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$q = $x -as ''System.Collections.Queue''' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$s = $x -isnot [Collections.Stack]' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$sb = [System.Text.StringBuilder]''x''' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$bytes = [System.Text.Encoding]::UTF8.GetBytes($s)' }
        @{ Number = '02'; Path = $snippetPath; Snippet = 'function f { param([System.Text.Encoding]$Encoding) }' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$asm = [System.Reflection.Assembly]$x' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$e = [System.Management.Automation.ErrorRecord]$x' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$c = $x -is [System.Management.Automation.PSCmdlet]' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$h = $x -is [System.Management.Automation.Host.PSHost]' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$a = $x -is [System.Management.Automation.Language.Ast]' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$r = [math]::Round(1.5)' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$b = [System.BitConverter]::GetBytes(1)' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$t = [Convert]::ToBase64String($b)' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$ok = [ipaddress]::TryParse($s, [ref]$address)' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$r = [System.Management.Automation.PSReference]$x' }
        @{ Number = '02'; Path = $snippetPath; Snippet = 'function f { [IO.Fake()] param() }' }

        @{ Number = '03'; Path = $snippetPath; Snippet = 'if ($PSCmdlet.ShouldProcess($t)) { }' }
        @{ Number = '03'; Path = $snippetPath; Snippet = '$PSCmdlet.WriteError($e)' }
        @{ Number = '03'; Path = $snippetPath; Snippet = '($PSCmdlet).ThrowTerminatingError($e)' }
        @{ Number = '03'; Path = $snippetPath; Snippet = '$Host.UI.WriteLine(''x'')' }
        @{ Number = '03'; Path = $snippetPath; Snippet = '$Host.UI.RawUI.FlushInputBuffer()' }
        @{ Number = '03'; Path = $snippetPath; Snippet = '$p = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($x)' }
        @{ Number = '03'; Path = $snippetPath; Snippet = '$n = $MyInvocation.MyCommand.ToString()' }
        @{ Number = '03'; Path = $snippetPath; Snippet = '$global:Host.UI.WriteLine(''x'')' }
        @{ Number = '03'; Path = $snippetPath; Snippet = '$given = $PSBoundParameters.ContainsKey(''Server'')' }
        @{ Number = '03'; Path = $snippetPath; Snippet = '[void]$PSBoundParameters.Remove(''Force'')' }
        @{ Number = '03'; Path = $snippetPath; Snippet = 'if ($PSBoundParameters.TryGetValue(''Server'', [ref]$s)) { }' }

        @{ Number = '04'; Path = $snippetPath; Snippet = '$n = [System.IO.Path]::GetFileName($p)' }
        @{ Number = '04'; Path = $snippetPath; Snippet = '$sb = [scriptblock]::Create(''1'')' }
        @{ Number = '04'; Path = $snippetPath; Snippet = '[Console]::WriteLine(''x'')' }
        @{ Number = '04'; Path = $snippetPath; Snippet = '$m = [math]::Max(1, 2)' }
        @{ Number = '04'; Path = $snippetPath; Snippet = '$o = [System.Activator]::CreateInstance($t)' }
        @{ Number = '04'; Path = $snippetPath; Snippet = '$e = [System.Text.Encoding]::GetEncoding(1252)' }

        @{ Number = '05'; Path = $snippetPath; Snippet = '$h = [hashtable]::new()' }
        @{ Number = '05'; Path = $snippetPath; Snippet = '$r = $sb.Invoke()' }
        @{ Number = '05'; Path = $snippetPath; Snippet = '$r = $sb.InvokeReturnAsIs()' }
        @{ Number = '05'; Path = $snippetPath; Snippet = '$sb = [scriptblock]::Create(''1'')' }
        @{ Number = '05'; Path = $snippetPath; Snippet = '$ok = [int]::TryParse($s, [ref]$n)' }
        @{ Number = '05'; Path = $snippetPath; Snippet = '$c = $sb.GetNewClosure()' }
        @{ Number = '05'; Path = $snippetPath; Snippet = '$o.PSObject.TypeNames.Insert(0, ''DnsLathund.Entry'')' }
        @{ Number = '05'; Path = $snippetPath; Snippet = '$p = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($x)' }

        @{ Number = '06'; Path = $snippetPath; Snippet = '$l = New-Object System.Collections.ArrayList' }
        @{ Number = '06'; Path = $snippetPath; Snippet = '$sb = New-Object -TypeName System.Text.StringBuilder' }
        @{ Number = '06'; Path = $snippetPath; Snippet = '$o = New-Object -Type:System.Object' }
        @{ Number = '06'; Path = $snippetPath; Snippet = '$o = New-Object -TypeName $typeName -Property @{ A = 1 }' }
        @{ Number = '06'; Path = $snippetPath; Snippet = '$o = New-Object @splat' }
        @{ Number = '06'; Path = $snippetPath; Snippet = '$shell = New-Object -ComObject Shell.Application' }
        @{ Number = '06'; Path = $snippetPath; Snippet = 'Add-Type -AssemblyName System.Web' }
        @{ Number = '06'; Path = $snippetPath; Snippet = 'Invoke-Expression ''Get-Date''' }
        @{ Number = '06'; Path = $snippetPath; Snippet = 'iex ''Get-Date''' }
        @{ Number = '06'; Path = $snippetPath; Snippet = 'Set-Variable -Name x -Value 1 -Scope Global' }
        @{ Number = '06'; Path = $snippetPath; Snippet = 'Set-Variable x 1 -Scope:global' }

        @{ Number = '07'; Path = $snippetPath; Snippet = 'Set-Content -Path $p -Value ''x''' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'Add-Content -Path $p -Value ''x'' -WhatIf' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'Remove-Item -LiteralPath $p -WhatIf:$true' }
        @{ Number = '07'; Path = $snippetPath; Snippet = '''x'' | Out-File -FilePath $p' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'New-Item -ItemType Directory -Path $p -Confirm:$false' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'Copy-Item -Path $a -Destination $b' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'Move-Item -Path $a -Destination $b' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'Export-DnsServerZone -Name $zone -FileName $file' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'rm $p' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'Set-Content @splat' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'Set-Content -Path $p -Value ''x'' -WhatIf:$false' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'Remove-Item -LiteralPath $p -WhatIf:$false -Confirm:$true' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'Remove-Item -LiteralPath $p -WhatIf:$false -Confirm' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'New-Item -Path $p -ItemType File -wi:$false -Confirm:$false' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'Export-DnsServerZone -Name $zone -FileName $file -WhatIf:$false' }

        @{ Number = '08'; Path = $snippetPath; Snippet = 'foreach ($i in 1..3) { $a += $i }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = 'for ($i = 0; $i -lt 3; $i++) { $a += ''x'' }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = 'while ($more) { $h[$k] += @($v) }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = 'do { $a += $x } while ($more)' }
        @{ Number = '08'; Path = $snippetPath; Snippet = 'do { $a += $x } until ($done)' }
        @{ Number = '08'; Path = $snippetPath; Snippet = 'switch ($items) { default { $a += $_ } }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = '1..3 | ForEach-Object { $a += $_ }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = '1..3 | ForEach-Object -Process { $a += $_ }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = '1..3 | Where-Object { $a += $_; $true }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = '1..3 | % { $a += $_ }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = 'foreach ($i in 1..3) { if ($i) { $script:total += $i.Count } }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = '$items.ForEach({ $a += $_ })' }
        @{ Number = '08'; Path = $snippetPath; Snippet = '$hits = @($items).Where({ $a += $_; $true })' }
        @{ Number = '08'; Path = $snippetPath; Snippet = '$items.foreach({ param($x) $h[$x] += @($x) })' }
        @{ Number = '08'; Path = $snippetPath; Snippet = 'foreach ($i in 1..3) { $o.Names += $i }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = '1..3 | ForEach-Object { $script:state.Rows += $_ }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = 'foreach ($i in 1..3) { $o.Count += $i.Length }' }

        @{ Number = '12'; Path = $snippetPath; Snippet = '$isCim = $x -is [Microsoft.Management.Infrastructure.CimInstance]' }
        @{ Number = '12'; Path = $snippetPath; Snippet = 'function f { param([Microsoft.Management.Infrastructure.CimSession]$CimSession) }' }
        @{ Number = '12'; Path = $snippetPath; Snippet = '[Microsoft.Management.Infrastructure.CimInstance[]]$records = @()' }
        @{ Number = '12'; Path = $snippetPath; Snippet = '$c = [ciminstance]$x' }
        @{ Number = '12'; Path = $snippetPath; Snippet = 'function f { param([CimSession]$Session) }' }
        @{ Number = '12'; Path = $snippetPath; Snippet = '$t = [Microsoft.Management.Infrastructure.CimType]::String' }
        @{ Number = '12'; Path = $snippetPath; Snippet = '$cat = [System.Management.Automation.ErrorCategory]::InvalidOperation' }
        @{ Number = '12'; Path = $snippetPath; Snippet = '$cat = [System.Management.Automation.ErrorCategory]''InvalidOperation''' }
        @{ Number = '12'; Path = $snippetPath; Snippet = 'function f { param([Management.Automation.ErrorCategory]$Category) }' }

        @{ Number = '13'; Path = $snippetPath; Snippet = '$names = $items | ForEach-Object Name' }
        @{ Number = '13'; Path = $snippetPath; Snippet = '$names = $items | ForEach-Object -MemberName Name' }
        @{ Number = '13'; Path = $snippetPath; Snippet = '$names = $items | ForEach-Object -M Name' }
        @{ Number = '13'; Path = $snippetPath; Snippet = '$upper = $items | ForEach-Object ToUpper' }
        @{ Number = '13'; Path = $snippetPath; Snippet = '$names = $items | % Name' }
        @{ Number = '13'; Path = $snippetPath; Snippet = '$names = $items | foreach ''Name''' }
        @{ Number = '13'; Path = $snippetPath; Snippet = '$names = $items | Microsoft.PowerShell.Core\ForEach-Object Name' }
        @{ Number = '13'; Path = $snippetPath; Snippet = '$out = $items | ForEach-Object $scriptBlock' }

        @{ Number = '09'; Path = $snippetPath; Snippet = 'class Foo { [string]$Name }' }
        @{ Number = '09'; Path = $snippetPath; Snippet = 'enum Color { Red; Green }' }
        @{ Number = '09'; Path = $snippetPath; Snippet = 'using namespace System.IO' }

        @{ Number = '10'; Path = $snippetPath; Snippet = 'Write-Host ''x''' }
        @{ Number = '10'; Path = $snippetPath; Snippet = 'Microsoft.PowerShell.Utility\Write-Host ''x''' }
        @{ Number = '10'; Path = 'Private\Confirm-DnsActionHelper.ps1'; Snippet = 'Write-Host ''x''' }

        @{ Number = '11'; Path = $snippetPath; Snippet = '$answer = Read-Host ''Continue?''' }
        @{ Number = '11'; Path = 'Public\Confirm-DnsAction.ps1'; Snippet = '$answer = Read-Host ''Continue?''' }
    )

    $script:ClmCompliantCases = @(
        @{ Number = '01'; Path = $snippetPath; Snippet = '$o = New-Object -TypeName PSObject -Property ([ordered]@{ A = 1 })' }
        @{ Number = '01'; Path = $snippetPath; Snippet = '$h = [ordered]@{ A = 1 }' }

        @{ Number = '02'; Path = $snippetPath; Snippet = '$e = [System.Text.Encoding]::UTF8' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$n = [Text.Encoding]::UTF8.WebName' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$a = [ipaddress]''10.0.0.1''' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$m = [regex]::Match($s, ''x'', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$s = [System.Text.RegularExpressions.Regex]::Escape($s)' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$h = [hashtable]@{}; [string[]]$a = @(); $t = [datetime]::FromFileTime(0)' }
        @{ Number = '02'; Path = $snippetPath; Snippet = 'function f { [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Name, [System.Management.Automation.Credential()] [pscredential]$Credential, [PSTypeName(''DnsLathund.Entry'')] $Entry) }' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$i = [int][System.Management.Automation.ConfirmImpact]$Impact' }
        @{ Number = '02'; Path = $snippetPath; Snippet = '$ok = ($x -is [string]) -and ($y -as ''int'')' }

        @{ Number = '03'; Path = $snippetPath; Snippet = '$set = $PSCmdlet.ParameterSetName' }
        @{ Number = '03'; Path = $snippetPath; Snippet = '$n = $MyInvocation.MyCommand.Name' }
        @{ Number = '03'; Path = $snippetPath; Snippet = '$m = [string]$ExecutionContext.SessionState.LanguageMode' }
        @{ Number = '03'; Path = $snippetPath; Snippet = '$given = $PSBoundParameters.Keys -contains ''Server''; $count = $PSBoundParameters.Count' }
        @{ Number = '03'; Path = $snippetPath; Snippet = '$server = $PSBoundParameters[''Server'']; $keys = @($PSBoundParameters.Keys)' }
        @{ Number = '03'; Path = $snippetPath; Snippet = '$name = $Host.Name; $s = $hostName.ToLower()' }

        @{ Number = '04'; Path = $snippetPath; Snippet = '$e = [string]::IsNullOrEmpty($x); $j = [System.String]::Join('','', $a)' }
        @{ Number = '04'; Path = $snippetPath; Snippet = '$s = [regex]::Escape($x); $m = [System.Text.RegularExpressions.Regex]::Match($a, $b)' }
        @{ Number = '04'; Path = $snippetPath; Snippet = '$a = [ipaddress]::Parse($x); $b = [System.Net.IPAddress]::Parse($x)' }
        @{ Number = '04'; Path = $snippetPath; Snippet = '$t = [datetime]::FromFileTime(0); $s = [timespan]::FromHours(1); $g = [guid]::NewGuid()' }
        @{ Number = '04'; Path = $snippetPath; Snippet = '$v = [Environment]::GetEnvironmentVariable(''X''); $nl = [Environment]::NewLine' }
        @{ Number = '04'; Path = $snippetPath; Snippet = '$w = [WildcardPattern]::ContainsWildcardCharacters($x); $e = [System.Management.Automation.WildcardPattern]::Escape($x)' }
        @{ Number = '04'; Path = $snippetPath; Snippet = '$n = [int]::Parse(''1''); $d = [char]::IsDigit($c); $v = [version]::Parse(''1.0''); $u = [uri]::EscapeDataString($x)' }
        @{ Number = '04'; Path = $snippetPath; Snippet = '$e = [System.Text.Encoding]::UTF8; $max = [int]::MaxValue' }

        @{ Number = '05'; Path = $snippetPath; Snippet = '$r = & $sb; $s = ''abc''.Insert(1, ''x''); $t = $o.PSObject.TypeNames[0]' }
        @{ Number = '05'; Path = $snippetPath; Snippet = 'Add-Member -InputObject $o -TypeName ''DnsLathund.Entry''' }

        @{ Number = '06'; Path = $snippetPath; Snippet = '$o = New-Object PSObject -Property @{ A = 1 }' }
        @{ Number = '06'; Path = $snippetPath; Snippet = '$o = New-Object -TypeName System.Management.Automation.PSObject -Property $p' }
        @{ Number = '06'; Path = $snippetPath; Snippet = '$o = New-Object -Property $p -TypeName ''psobject''' }
        @{ Number = '06'; Path = $snippetPath; Snippet = '$o = Microsoft.PowerShell.Utility\New-Object -TypeName PSObject' }
        @{ Number = '06'; Path = $snippetPath; Snippet = 'Set-Variable -Name x -Value 1 -Scope Script' }

        @{ Number = '07'; Path = $snippetPath; Snippet = 'Set-Content -Path $p -Value ''x'' -Encoding UTF8 -WhatIf:$false -Confirm:$false' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'Add-Content -Path $p -Value $line -WhatIf:$false -Confirm:$false' }
        @{ Number = '07'; Path = $snippetPath; Snippet = 'Export-DnsServerZone -Name $zone -FileName $file -WhatIf:$false -Confirm:$false' }
        @{ Number = '07'; Path = $snippetPath; Snippet = '$text = Get-Content -Path $p -Raw' }

        @{ Number = '08'; Path = $snippetPath; Snippet = 'foreach ($i in 1..3) { $count += 1; $h[$k] += 2; $bytes += 1.5 }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = '$a += $x' }
        @{ Number = '08'; Path = $snippetPath; Snippet = '$rows = foreach ($i in 1..3) { $i }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = '1..3 | ForEach-Object { $n += 1 }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = 'Invoke-Command -ScriptBlock { $a += $x }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = '$items.ForEach({ $n += 1 }); $hits = $items.Where({ $_ -gt 1 })' }
        @{ Number = '08'; Path = $snippetPath; Snippet = 'foreach ($i in 1..3) { $o.Count += 1; $script:state.Total += 2 }' }
        @{ Number = '08'; Path = $snippetPath; Snippet = '$o.Names += $x; $names = $items.ForEach(''Name'')' }

        @{ Number = '09'; Path = $snippetPath; Snippet = '$h = @{ class = 1; enum = 2 }; $u = ''using''' }

        @{ Number = '10'; Path = $confirmPath; Snippet = 'Write-Host ''What if: Performing the operation''' }
        @{ Number = '10'; Path = $snippetPath; Snippet = 'Write-Verbose ''x''; Write-Warning ''y''' }

        @{ Number = '11'; Path = $confirmPath; Snippet = '$answer = Read-Host ''Continue?''' }
        @{ Number = '11'; Path = $snippetPath; Snippet = 'Write-Information ''x''' }

        @{ Number = '12'; Path = $confirmPath; Snippet = '$i = [int][System.Management.Automation.ConfirmImpact]$Impact' }
        @{ Number = '12'; Path = $snippetPath; Snippet = 'Write-Error -Message ''m'' -Category InvalidOperation -ErrorId ''DnsLathund.X.Y'' -TargetObject $n' }
        @{ Number = '12'; Path = $snippetPath; Snippet = '$s = New-CimSession -ComputerName $server; $r = Get-CimInstance -CimSession $s -Query $q' }
        @{ Number = '12'; Path = $snippetPath; Snippet = '$hasData = $null -ne $record.PSObject.Properties[''RecordData'']' }

        @{ Number = '13'; Path = $snippetPath; Snippet = '$names = $items | ForEach-Object { $_.Name }' }
        @{ Number = '13'; Path = $snippetPath; Snippet = '$names = $items | ForEach-Object -Process { $_.Name }' }
        @{ Number = '13'; Path = $snippetPath; Snippet = '$total = $items | ForEach-Object -Begin { $n = 0 } -Process { $n++ } -End { $n }' }
        @{ Number = '13'; Path = $snippetPath; Snippet = '$total = $items | % { $n = 0 } { $n++ } { $n }' }
        @{ Number = '13'; Path = $snippetPath; Snippet = '$names = $items | ForEach-Object -ErrorAction Stop { $_.Name }' }
        @{ Number = '13'; Path = $snippetPath; Snippet = 'foreach ($item in $items) { $item.Name }' }
    )
}

BeforeAll {
    $script:ModuleRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).ProviderPath

    # A fixed table of default aliases instead of Get-Alias, so the lint
    # result does not depend on the engine version or a profile.
    $script:ClmCommandAliases = @{
        '%'       = 'ForEach-Object'
        'foreach' = 'ForEach-Object'
        '?'       = 'Where-Object'
        'where'   = 'Where-Object'
        'iex'     = 'Invoke-Expression'
        'set'     = 'Set-Variable'
        'sv'      = 'Set-Variable'
        'ac'      = 'Add-Content'
        'sc'      = 'Set-Content'
        'copy'    = 'Copy-Item'
        'cp'      = 'Copy-Item'
        'cpi'     = 'Copy-Item'
        'move'    = 'Move-Item'
        'mv'      = 'Move-Item'
        'mi'      = 'Move-Item'
        'del'     = 'Remove-Item'
        'erase'   = 'Remove-Item'
        'rd'      = 'Remove-Item'
        'ri'      = 'Remove-Item'
        'rm'      = 'Remove-Item'
        'rmdir'   = 'Remove-Item'
        'ni'      = 'New-Item'
    }

    $script:ClmCommonValueParameters = @(
        'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable',
        'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable'
    )
    $script:ClmCommonSwitchParameters = @('Verbose', 'Debug', 'WhatIf', 'Confirm')

    # Rule 2. The pattern is the contract's, verbatim.
    $script:ClmForbiddenTypePattern = '^(System\.)?(IO\.|Collections\.Generic\.|Collections\.ArrayList|Collections\.Queue|Collections\.Stack|Text\.(?!Encoding$)|Reflection\.|Management\.Automation\.(ErrorRecord|PSCmdlet|Host\.|Language\.)|Math$|BitConverter$|Convert$)'
    # The contract pattern would also match System.Text.RegularExpressions.*,
    # which CONTRACTS §4.2 explicitly allows ([regex] including RegexOptions)
    # and rule 4 allow-lists, so that namespace is carved out on purpose.
    $script:ClmRegexNamespacePattern = '^(System\.)?Text\.RegularExpressions\.'
    $script:ClmEncodingPattern = '^(System\.)?Text\.Encoding$'

    # Rule 4. Both the written names and the full names they resolve to are
    # accepted, so [System.String]::Join passes as well as [string]::Join.
    $script:ClmStaticAllowNames = @{}
    $script:ClmStaticAllowFullNames = @{}
    $staticAllowList = @(
        'string', 'regex', 'ipaddress', 'datetime', 'timespan', 'guid', 'version', 'Environment', 'char',
        'WildcardPattern', 'int', 'long', 'uint32', 'double', 'decimal', 'bool', 'array', 'hashtable',
        'pscredential', 'uri', 'System.Net.IPAddress', 'System.Text.RegularExpressions.Regex',
        'System.Management.Automation.WildcardPattern'
    )
    foreach ($allowedName in $staticAllowList) {
        $script:ClmStaticAllowNames[$allowedName] = $true
        $allowedType = $allowedName -as [type]
        if ($null -eq $allowedType) {
            throw "Rule 4 allow-list entry '$allowedName' does not resolve to a type."
        }
        $script:ClmStaticAllowFullNames[$allowedType.FullName] = $true
    }

    # Rule 5.
    $script:ClmForbiddenMemberNames = @(
        'new', 'Invoke', 'InvokeReturnAsIs', 'Create', 'TryParse', 'GetNewClosure', 'GetUnresolvedProviderPathFromPSPath'
    )

    # Rule 7.
    $script:ClmInternalWriteCommands = @(
        'Add-Content', 'Set-Content', 'Out-File', 'Copy-Item', 'Move-Item', 'Remove-Item', 'New-Item', 'Export-DnsServerZone'
    )

    # Rules 10 and 11.
    $script:ClmConfirmFilePattern = '(^|[\\/])Private[\\/]Confirm-DnsAction\.ps1$'

    # Rule 12.
    $script:ClmCimNamespacePattern = '^Microsoft\.Management\.Infrastructure\.'
    $script:ClmErrorCategoryPattern = '^((System\.)?Management\.Automation\.)?ErrorCategory$'

    function ConvertTo-ClmViolation {
        param (
            [string]$Rule,
            [string]$Path,
            [System.Management.Automation.Language.Ast]$Ast,
            [string]$Message
        )

        $text = (($Ast.Extent.Text -split "`r?`n")[0]).Trim()
        if ($text.Length -gt 120) {
            $text = $text.Substring(0, 117) + '...'
        }

        [pscustomobject]@{
            Rule    = $Rule
            Path    = $Path
            Line    = $Ast.Extent.StartLineNumber
            Message = $Message
            Text    = $text
        }
    }

    function Format-ClmViolation {
        param ($Violation)

        '{0}:{1}: {2} | {3}' -f $Violation.Path, $Violation.Line, $Violation.Message, $Violation.Text
    }

    function Find-ClmAst {
        param (
            [System.Management.Automation.Language.Ast]$Ast,
            [type]$Type
        )

        foreach ($node in $Ast.FindAll({ $true }, $true)) {
            if ($node -is $Type) {
                $node
            }
        }
    }

    function Get-ClmCommandName {
        param ([System.Management.Automation.Language.CommandAst]$CommandAst)

        $name = $CommandAst.GetCommandName()
        if ([string]::IsNullOrEmpty($name)) {
            return $null
        }

        # Module-qualified calls (Microsoft.PowerShell.Utility\Write-Host) count too.
        $name = $name -replace '^[^\\]+\\', ''
        if ($script:ClmCommandAliases.ContainsKey($name)) {
            return $script:ClmCommandAliases[$name]
        }

        $name
    }

    function Resolve-ClmParameterName {
        param (
            [string]$Name,
            [string[]]$Candidates,
            [hashtable]$Aliases
        )

        foreach ($candidate in $Candidates) {
            if ($candidate -eq $Name) {
                return $candidate
            }
        }

        if ($Aliases -and $Aliases.ContainsKey($Name)) {
            return $Aliases[$Name]
        }

        $prefixMatches = @($Candidates | Where-Object { $_ -like "$Name*" })
        if ($prefixMatches.Count -eq 1) {
            return $prefixMatches[0]
        }

        $Name
    }

    # A minimal static binder: enough to find a named or the first
    # positional argument of a cmdlet whose parameters are known.
    function Get-ClmCommandArgument {
        param (
            [System.Management.Automation.Language.CommandAst]$CommandAst,
            [string[]]$ValueParameters,
            [string[]]$SwitchParameters,
            [hashtable]$ParameterAliases
        )

        $valueNames = @($ValueParameters) + $script:ClmCommonValueParameters
        $allNames = $valueNames + @($SwitchParameters) + $script:ClmCommonSwitchParameters
        $named = @{}
        $positional = New-Object -TypeName System.Collections.Generic.List[System.Management.Automation.Language.Ast]
        $splatted = $false
        $elements = $CommandAst.CommandElements

        for ($i = 1; $i -lt $elements.Count; $i++) {
            $element = $elements[$i]

            if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                $parameterName = Resolve-ClmParameterName -Name $element.ParameterName -Candidates $allNames -Aliases $ParameterAliases

                if ($null -ne $element.Argument) {
                    $named[$parameterName] = $element.Argument
                }
                elseif (($valueNames -contains $parameterName) -and ($i + 1 -lt $elements.Count)) {
                    $named[$parameterName] = $elements[$i + 1]
                    $i++
                }
                else {
                    $named[$parameterName] = $null
                }
            }
            elseif ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and $element.Splatted) {
                $splatted = $true
            }
            else {
                $positional.Add($element)
            }
        }

        @{
            Named      = $named
            Positional = $positional.ToArray()
            Splatted   = $splatted
        }
    }

    # Flattens generic and array type names so every component is checked.
    function Get-ClmTypeNameComponent {
        param ([System.Management.Automation.Language.ITypeName]$TypeName)

        if ($TypeName -is [System.Management.Automation.Language.GenericTypeName]) {
            Get-ClmTypeNameComponent -TypeName $TypeName.TypeName
            foreach ($argument in $TypeName.GenericArguments) {
                Get-ClmTypeNameComponent -TypeName $argument
            }
        }
        elseif ($TypeName -is [System.Management.Automation.Language.ArrayTypeName]) {
            Get-ClmTypeNameComponent -TypeName $TypeName.ElementType
        }
        else {
            $TypeName.FullName
        }
    }

    function Test-ClmForbiddenTypeName {
        param ([string]$Name)

        if ($Name -eq 'ref' -or $Name -eq 'System.Management.Automation.PSReference') {
            return $true
        }

        if ($Name -match $script:ClmRegexNamespacePattern) {
            return $false
        }

        $Name -match $script:ClmForbiddenTypePattern
    }

    # [System.Text.Encoding] is allowed only as the target of a static
    # property read whose result is not then used for a method call.
    function Test-ClmEncodingPropertyRead {
        param ([System.Management.Automation.Language.Ast]$Node)

        if ($Node -isnot [System.Management.Automation.Language.TypeExpressionAst]) {
            return $false
        }

        if ($Node.TypeName -isnot [System.Management.Automation.Language.TypeName]) {
            return $false
        }

        $parent = $Node.Parent
        if ($parent -isnot [System.Management.Automation.Language.MemberExpressionAst] -or
            $parent -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -or
            -not $parent.Static -or
            -not [object]::ReferenceEquals($parent.Expression, $Node)) {
            return $false
        }

        $grandParent = $parent.Parent
        if ($grandParent -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            [object]::ReferenceEquals($grandParent.Expression, $parent)) {
            return $false
        }

        $true
    }

    function Get-ClmRootExpression {
        param ([System.Management.Automation.Language.Ast]$Expression)

        $current = $Expression
        while ($true) {
            if ($current -is [System.Management.Automation.Language.MemberExpressionAst]) {
                $current = $current.Expression
                continue
            }

            if ($current -is [System.Management.Automation.Language.ParenExpressionAst]) {
                $pipeline = $current.Pipeline
                if ($pipeline -is [System.Management.Automation.Language.PipelineAst] -and
                    $pipeline.PipelineElements.Count -eq 1 -and
                    $pipeline.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $current = $pipeline.PipelineElements[0].Expression
                    continue
                }
            }

            break
        }

        $current
    }

    function Get-ClmMemberName {
        param ([System.Management.Automation.Language.MemberExpressionAst]$MemberExpression)

        if ($MemberExpression.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return $MemberExpression.Member.Value
        }

        $null
    }

    function Test-ClmInsideLoop {
        param ([System.Management.Automation.Language.Ast]$Ast)

        $loopTypes = @(
            [System.Management.Automation.Language.ForEachStatementAst],
            [System.Management.Automation.Language.ForStatementAst],
            [System.Management.Automation.Language.WhileStatementAst],
            [System.Management.Automation.Language.DoWhileStatementAst],
            [System.Management.Automation.Language.DoUntilStatementAst],
            [System.Management.Automation.Language.SwitchStatementAst]
        )

        $current = $Ast.Parent
        while ($null -ne $current) {
            foreach ($loopType in $loopTypes) {
                if ($current -is $loopType) {
                    return $true
                }
            }

            if ($current -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                $owner = $current.Parent
                if ($owner -is [System.Management.Automation.Language.CommandParameterAst]) {
                    $owner = $owner.Parent
                }

                if ($owner -is [System.Management.Automation.Language.CommandAst]) {
                    $ownerName = Get-ClmCommandName -CommandAst $owner
                    if ($ownerName -eq 'ForEach-Object' -or $ownerName -eq 'Where-Object') {
                        return $true
                    }
                }

                # The .ForEach({}) and .Where({}) array methods loop as well.
                if ($owner -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                    $memberName = Get-ClmMemberName -MemberExpression $owner
                    if ($memberName -eq 'ForEach' -or $memberName -eq 'Where') {
                        foreach ($argument in @($owner.Arguments)) {
                            if ([object]::ReferenceEquals($argument, $current)) {
                                return $true
                            }
                        }
                    }
                }
            }

            $current = $current.Parent
        }

        $false
    }

    function Test-ClmNumericConstant {
        param ([System.Management.Automation.Language.StatementAst]$Statement)

        if ($Statement -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
            return $false
        }

        $expression = $Statement.Expression
        if ($expression -isnot [System.Management.Automation.Language.ConstantExpressionAst] -or
            $expression -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $null -eq $expression.Value) {
            return $false
        }

        $typeCode = [System.Type]::GetTypeCode($expression.Value.GetType())
        $typeCode -ge [System.TypeCode]::SByte -and $typeCode -le [System.TypeCode]::Decimal
    }

    function Find-ClmCommandViolation {
        param (
            [string]$Rule,
            [System.Management.Automation.Language.Ast]$Ast,
            [string]$Path,
            [string]$CommandName,
            [string]$Message
        )

        foreach ($command in (Find-ClmAst -Ast $Ast -Type ([System.Management.Automation.Language.CommandAst]))) {
            if ((Get-ClmCommandName -CommandAst $command) -eq $CommandName) {
                ConvertTo-ClmViolation -Rule $Rule -Path $Path -Ast $command -Message $Message
            }
        }
    }

    # Rule 1: [PSCustomObject] casts, including [PSCustomObject][ordered]@{}.
    function Find-ClmRule01Violation {
        param ([System.Management.Automation.Language.Ast]$Ast, [string]$Path)

        foreach ($node in (Find-ClmAst -Ast $Ast -Type ([System.Management.Automation.Language.ConvertExpressionAst]))) {
            $name = $node.Type.TypeName.FullName -replace '^System\.Management\.Automation\.', ''
            if ($name -eq 'PSCustomObject') {
                ConvertTo-ClmViolation -Rule '01' -Path $Path -Ast $node -Message '[PSCustomObject] cast; use New-DnsObject'
            }
        }
    }

    # Rule 2: forbidden type names in type literals, casts, constraints,
    # attributes, generic arguments and -is/-isnot/-as string operands.
    # A ConvertExpressionAst is reached through its TypeConstraintAst child,
    # so a cast is reported once.
    function Find-ClmRule02Violation {
        param ([System.Management.Automation.Language.Ast]$Ast, [string]$Path)

        $typeNodes = $Ast.FindAll({
                param ($node)
                $node -is [System.Management.Automation.Language.TypeExpressionAst] -or
                $node -is [System.Management.Automation.Language.AttributeBaseAst]
            }, $true)

        foreach ($node in $typeNodes) {
            foreach ($name in (Get-ClmTypeNameComponent -TypeName $node.TypeName)) {
                if (Test-ClmForbiddenTypeName -Name $name) {
                    ConvertTo-ClmViolation -Rule '02' -Path $Path -Ast $node -Message "forbidden type [$name]"
                }
                elseif ($name -match $script:ClmEncodingPattern -and -not (Test-ClmEncodingPropertyRead -Node $node)) {
                    ConvertTo-ClmViolation -Rule '02' -Path $Path -Ast $node -Message "[$name] is allowed only for static property reads such as [System.Text.Encoding]::UTF8"
                }
            }
        }

        $typeOperators = @(
            [System.Management.Automation.Language.TokenKind]::Is,
            [System.Management.Automation.Language.TokenKind]::IsNot,
            [System.Management.Automation.Language.TokenKind]::As
        )

        foreach ($node in (Find-ClmAst -Ast $Ast -Type ([System.Management.Automation.Language.BinaryExpressionAst]))) {
            if ($typeOperators -contains $node.Operator -and
                $node.Right -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $name = $node.Right.Value
                if ((Test-ClmForbiddenTypeName -Name $name) -or $name -match $script:ClmEncodingPattern) {
                    ConvertTo-ClmViolation -Rule '02' -Path $Path -Ast $node -Message "forbidden type '$name' as -is/-as operand"
                }
            }
        }
    }

    # Rule 3: method calls rooted at $PSCmdlet, $Host, $ExecutionContext, $MyInvocation.
    function Find-ClmRule03Violation {
        param ([System.Management.Automation.Language.Ast]$Ast, [string]$Path)

        $rootNames = @('PSCmdlet', 'Host', 'ExecutionContext', 'MyInvocation', 'PSBoundParameters')

        foreach ($node in (Find-ClmAst -Ast $Ast -Type ([System.Management.Automation.Language.InvokeMemberExpressionAst]))) {
            $root = Get-ClmRootExpression -Expression $node.Expression
            if ($root -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
                continue
            }

            # VariablePath.UnqualifiedPath is not public; strip a scope or drive qualifier by hand.
            $variableName = $root.VariablePath.UserPath -replace '^[A-Za-z]+:', ''
            if ($rootNames -contains $variableName) {
                ConvertTo-ClmViolation -Rule '03' -Path $Path -Ast $node -Message "method call on `$$variableName"
            }
        }
    }

    # Rule 4: static method calls only on allow-listed types.
    function Find-ClmRule04Violation {
        param ([System.Management.Automation.Language.Ast]$Ast, [string]$Path)

        foreach ($node in (Find-ClmAst -Ast $Ast -Type ([System.Management.Automation.Language.InvokeMemberExpressionAst]))) {
            if ($node.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst]) {
                continue
            }

            $typeName = $node.Expression.TypeName
            if ($script:ClmStaticAllowNames.ContainsKey($typeName.FullName)) {
                continue
            }

            $resolved = $null
            try {
                $resolved = $typeName.GetReflectionType()
            }
            catch {
                $resolved = $null
            }

            if ($null -eq $resolved) {
                $resolved = $typeName.FullName -as [type]
            }

            if ($null -ne $resolved -and $script:ClmStaticAllowFullNames.ContainsKey($resolved.FullName)) {
                continue
            }

            ConvertTo-ClmViolation -Rule '04' -Path $Path -Ast $node -Message "static method call on [$($typeName.FullName)], which is not on the allow-list"
        }
    }

    # Rule 5: forbidden member names.
    function Find-ClmRule05Violation {
        param ([System.Management.Automation.Language.Ast]$Ast, [string]$Path)

        foreach ($node in (Find-ClmAst -Ast $Ast -Type ([System.Management.Automation.Language.InvokeMemberExpressionAst]))) {
            $memberName = Get-ClmMemberName -MemberExpression $node
            if ($null -eq $memberName) {
                continue
            }

            if ($script:ClmForbiddenMemberNames -contains $memberName) {
                ConvertTo-ClmViolation -Rule '05' -Path $Path -Ast $node -Message "forbidden method .$memberName()"
                continue
            }

            if ($memberName -eq 'Insert' -and
                $node.Expression -is [System.Management.Automation.Language.MemberExpressionAst] -and
                (Get-ClmMemberName -MemberExpression $node.Expression) -eq 'TypeNames') {
                ConvertTo-ClmViolation -Rule '05' -Path $Path -Ast $node -Message 'TypeNames.Insert(); use Add-Member -TypeName'
            }
        }
    }

    # Rule 6: New-Object (PSObject only), -ComObject, Add-Type, Invoke-Expression, Set-Variable -Scope Global.
    function Find-ClmRule06Violation {
        param ([System.Management.Automation.Language.Ast]$Ast, [string]$Path)

        $allowedTypes = @('PSObject', 'System.Management.Automation.PSObject')

        foreach ($command in (Find-ClmAst -Ast $Ast -Type ([System.Management.Automation.Language.CommandAst]))) {
            $name = Get-ClmCommandName -CommandAst $command

            if ($name -eq 'New-Object') {
                $bound = Get-ClmCommandArgument -CommandAst $command `
                    -ValueParameters @('TypeName', 'ComObject', 'ArgumentList', 'Property') `
                    -SwitchParameters @('Strict') `
                    -ParameterAliases @{ Args = 'ArgumentList' }

                if ($bound.Named.ContainsKey('ComObject')) {
                    ConvertTo-ClmViolation -Rule '06' -Path $Path -Ast $command -Message 'New-Object -ComObject'
                    continue
                }

                $typeArgument = $null
                if ($bound.Named.ContainsKey('TypeName')) {
                    $typeArgument = $bound.Named['TypeName']
                }
                elseif ($bound.Positional.Count -gt 0) {
                    $typeArgument = $bound.Positional[0]
                }

                if ($typeArgument -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $allowedTypes -contains $typeArgument.Value) {
                    continue
                }

                $shown = if ($null -ne $typeArgument) { $typeArgument.Extent.Text } else { '<not determinable>' }
                ConvertTo-ClmViolation -Rule '06' -Path $Path -Ast $command -Message "New-Object with type $shown; only PSObject is allowed"
            }
            elseif ($name -eq 'Add-Type' -or $name -eq 'Invoke-Expression') {
                ConvertTo-ClmViolation -Rule '06' -Path $Path -Ast $command -Message "$name is not allowed"
            }
            elseif ($name -eq 'Set-Variable') {
                $bound = Get-ClmCommandArgument -CommandAst $command `
                    -ValueParameters @('Name', 'Value', 'Include', 'Exclude', 'Description', 'Option', 'Visibility', 'Scope') `
                    -SwitchParameters @('Force', 'PassThru') `
                    -ParameterAliases @{}

                if ($bound.Named.ContainsKey('Scope')) {
                    $scope = $bound.Named['Scope']
                    if ($scope -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $scope.Value -eq 'Global') {
                        ConvertTo-ClmViolation -Rule '06' -Path $Path -Ast $command -Message 'Set-Variable -Scope Global'
                    }
                }
            }
        }
    }

    # True when the command carries -<ParameterName>:$false, spelled out in
    # full (aliases such as -wi and splatted values are deliberately not accepted).
    function Test-ClmSwitchFalse {
        param (
            [System.Management.Automation.Language.CommandAst]$CommandAst,
            [string]$ParameterName
        )

        foreach ($element in $CommandAst.CommandElements) {
            if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
                $element.ParameterName -eq $ParameterName -and
                $element.Argument -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $element.Argument.VariablePath.UserPath -eq 'false') {
                return $true
            }
        }

        $false
    }

    # Rule 7: internal writes must carry -WhatIf:$false and -Confirm:$false.
    function Find-ClmRule07Violation {
        param ([System.Management.Automation.Language.Ast]$Ast, [string]$Path)

        foreach ($command in (Find-ClmAst -Ast $Ast -Type ([System.Management.Automation.Language.CommandAst]))) {
            $name = Get-ClmCommandName -CommandAst $command
            if ($script:ClmInternalWriteCommands -notcontains $name) {
                continue
            }

            $missing = @(
                foreach ($parameterName in @('WhatIf', 'Confirm')) {
                    if (-not (Test-ClmSwitchFalse -CommandAst $command -ParameterName $parameterName)) {
                        "-$($parameterName):`$false"
                    }
                }
            )

            if ($missing.Count -gt 0) {
                ConvertTo-ClmViolation -Rule '07' -Path $Path -Ast $command -Message "$name without $($missing -join ' and ')"
            }
        }
    }

    # Rule 8: += on a variable, index or member inside a loop, unless adding a numeric constant.
    function Find-ClmRule08Violation {
        param ([System.Management.Automation.Language.Ast]$Ast, [string]$Path)

        foreach ($node in (Find-ClmAst -Ast $Ast -Type ([System.Management.Automation.Language.AssignmentStatementAst]))) {
            if ($node.Operator -ne [System.Management.Automation.Language.TokenKind]::PlusEquals) {
                continue
            }

            if ($node.Left -isnot [System.Management.Automation.Language.VariableExpressionAst] -and
                $node.Left -isnot [System.Management.Automation.Language.IndexExpressionAst] -and
                $node.Left -isnot [System.Management.Automation.Language.MemberExpressionAst]) {
                continue
            }

            if ((Test-ClmNumericConstant -Statement $node.Right) -or -not (Test-ClmInsideLoop -Ast $node)) {
                continue
            }

            ConvertTo-ClmViolation -Rule '08' -Path $Path -Ast $node -Message '+= inside a loop; collect with $x = foreach (...) { } instead'
        }
    }

    # Rule 9: class/enum definitions and using statements.
    function Find-ClmRule09Violation {
        param ([System.Management.Automation.Language.Ast]$Ast, [string]$Path)

        foreach ($node in (Find-ClmAst -Ast $Ast -Type ([System.Management.Automation.Language.TypeDefinitionAst]))) {
            ConvertTo-ClmViolation -Rule '09' -Path $Path -Ast $node -Message "type definition '$($node.Name)'"
        }

        foreach ($node in (Find-ClmAst -Ast $Ast -Type ([System.Management.Automation.Language.UsingStatementAst]))) {
            ConvertTo-ClmViolation -Rule '09' -Path $Path -Ast $node -Message 'using statement'
        }
    }

    # Rule 10: Write-Host only in Private\Confirm-DnsAction.ps1.
    function Find-ClmRule10Violation {
        param ([System.Management.Automation.Language.Ast]$Ast, [string]$Path)

        if ($Path -match $script:ClmConfirmFilePattern) {
            return
        }

        Find-ClmCommandViolation -Rule '10' -Ast $Ast -Path $Path -CommandName 'Write-Host' -Message 'Write-Host outside Confirm-DnsAction'
    }

    # Rule 11: Read-Host only in Private\Confirm-DnsAction.ps1.
    function Find-ClmRule11Violation {
        param ([System.Management.Automation.Language.Ast]$Ast, [string]$Path)

        if ($Path -match $script:ClmConfirmFilePattern) {
            return
        }

        Find-ClmCommandViolation -Rule '11' -Ast $Ast -Path $Path -CommandName 'Read-Host' -Message 'Read-Host outside Confirm-DnsAction'
    }

    # Rule 12: CIM type literals (tests use duck-typed stubs) and
    # ErrorCategory type names. ConfirmImpact stays allowed (§10 needs it).
    # Accelerators such as [ciminstance] and [CimSession] are resolved, so
    # they are caught as well as the full names.
    function Find-ClmRule12Violation {
        param ([System.Management.Automation.Language.Ast]$Ast, [string]$Path)

        $typeNodes = $Ast.FindAll({
                param ($node)
                $node -is [System.Management.Automation.Language.TypeExpressionAst] -or
                $node -is [System.Management.Automation.Language.TypeConstraintAst]
            }, $true)

        foreach ($node in $typeNodes) {
            foreach ($name in (Get-ClmTypeNameComponent -TypeName $node.TypeName)) {
                $resolvedName = ''
                $resolved = $name -as [type]
                if ($null -ne $resolved) {
                    $resolvedName = $resolved.FullName
                }

                if ($name -match $script:ClmCimNamespacePattern -or $resolvedName -match $script:ClmCimNamespacePattern) {
                    ConvertTo-ClmViolation -Rule '12' -Path $Path -Ast $node -Message "CIM type [$name]; check `$obj.PSObject.Properties['...'] instead"
                }
                elseif ($name -match $script:ClmErrorCategoryPattern -or $resolvedName -eq 'System.Management.Automation.ErrorCategory') {
                    ConvertTo-ClmViolation -Rule '12' -Path $Path -Ast $node -Message "[$name]; use Write-Error -Category <name>"
                }
            }
        }
    }

    # Rule 13: the ForEach-Object member-name form ('ForEach-Object Name',
    # '-MemberName Name') prompts under Windows PowerShell 5.1 CLM. The first
    # positional argument must be a literal script block. Splatted calls carry
    # no visible arguments and are not judged.
    function Find-ClmRule13Violation {
        param ([System.Management.Automation.Language.Ast]$Ast, [string]$Path)

        foreach ($command in (Find-ClmAst -Ast $Ast -Type ([System.Management.Automation.Language.CommandAst]))) {
            if ((Get-ClmCommandName -CommandAst $command) -ne 'ForEach-Object') {
                continue
            }

            $bound = Get-ClmCommandArgument -CommandAst $command `
                -ValueParameters @('Process', 'Begin', 'End', 'RemainingScripts', 'MemberName', 'ArgumentList', 'InputObject', 'Parallel', 'ThrottleLimit', 'TimeoutSeconds') `
                -SwitchParameters @('AsJob', 'UseNewRunspace') `
                -ParameterAliases @{ Args = 'ArgumentList' }

            if ($bound.Named.ContainsKey('MemberName')) {
                ConvertTo-ClmViolation -Rule '13' -Path $Path -Ast $command -Message 'ForEach-Object -MemberName; use ForEach-Object { $_.<Name> } or a foreach statement'
                continue
            }

            if ($bound.Positional.Count -gt 0 -and
                $bound.Positional[0] -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                ConvertTo-ClmViolation -Rule '13' -Path $Path -Ast $command -Message "ForEach-Object with positional argument $($bound.Positional[0].Extent.Text); use a script block"
            }
        }
    }

    function Get-ClmSnippetAst {
        param ([string]$Snippet)

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Snippet, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) {
            throw "Self-test snippet does not parse: $($errors[0].Message) | $Snippet"
        }

        $ast
    }

    # The module files under test, parsed once. Missing folders are fine:
    # the module is being filled in while this lint already runs.
    $psm1Path = Join-Path -Path $script:ModuleRoot -ChildPath 'DnsLathund.psm1'
    $sourceFiles = @(
        foreach ($folder in @('Private', 'Public')) {
            $folderPath = Join-Path -Path $script:ModuleRoot -ChildPath $folder
            if (Test-Path -LiteralPath $folderPath -PathType Container) {
                Get-ChildItem -LiteralPath $folderPath -Filter '*.ps1' -File -Recurse | Sort-Object -Property FullName
            }
        }

        if (Test-Path -LiteralPath $psm1Path -PathType Leaf) {
            Get-Item -LiteralPath $psm1Path
        }
    )

    $rootLength = $script:ModuleRoot.TrimEnd('\', '/').Length + 1
    $script:ClmModuleFiles = @(
        foreach ($file in $sourceFiles) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            [pscustomobject]@{
                RelativePath = $file.FullName.Substring($rootLength)
                Ast          = $ast
                Errors       = @($errors)
            }
        }
    )
}

Describe 'DnsLathund module code is CLM compliant (CONTRACTS §4.1, §16)' {
    It 'every module source file parses without syntax errors' {
        $messages = @(
            foreach ($file in $script:ClmModuleFiles) {
                foreach ($parseError in $file.Errors) {
                    '{0}:{1}: {2}' -f $file.RelativePath, $parseError.Extent.StartLineNumber, $parseError.Message
                }
            }
        )

        $messages.Count | Should -Be 0 -Because ("the lint cannot see into code that does not parse:`n" + ($messages -join "`n"))
    }

    It 'Rule <Number>: <Title>' -ForEach $script:ClmRuleCases {
        $violations = @(
            foreach ($file in $script:ClmModuleFiles) {
                & $Function -Ast $file.Ast -Path $file.RelativePath
            }
        )

        $messages = @($violations | ForEach-Object { Format-ClmViolation -Violation $_ })
        $violations.Count | Should -Be 0 -Because ("rule $Number found these violations:`n" + ($messages -join "`n"))
    }
}

Describe 'Lint rules detect violations' {
    It 'Rule <Number> fires on: <Snippet>' -ForEach $script:ClmViolationCases {
        $ast = Get-ClmSnippetAst -Snippet $Snippet
        $violations = @(& "Find-ClmRule$($Number)Violation" -Ast $ast -Path $Path)

        $violations.Count | Should -BeGreaterThan 0
        foreach ($violation in $violations) {
            $violation.Rule | Should -Be $Number
        }
    }

    It 'Rule <Number> stays silent on: <Snippet>' -ForEach $script:ClmCompliantCases {
        $ast = Get-ClmSnippetAst -Snippet $Snippet
        $violations = @(& "Find-ClmRule$($Number)Violation" -Ast $ast -Path $Path)

        $messages = @($violations | ForEach-Object { Format-ClmViolation -Violation $_ })
        $violations.Count | Should -Be 0 -Because ($messages -join "`n")
    }

    It 'reports the rule, file and line of a violation' {
        $ast = Get-ClmSnippetAst -Snippet "`$a = 1`r`n`$o = [PSCustomObject]@{ A = 1 }"
        $violations = @(Find-ClmRule01Violation -Ast $ast -Path 'Public\Get-DnsEntry.ps1')

        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be '01'
        Format-ClmViolation -Violation $violations[0] | Should -BeLike 'Public\Get-DnsEntry.ps1:2: *'
    }

    It 'reports a forbidden cast once, not once per AST view of it' {
        $ast = Get-ClmSnippetAst -Snippet '$t = [System.IO.File]$p'

        @(Find-ClmRule02Violation -Ast $ast -Path 'Public\Test-ClmSnippet.ps1').Count | Should -Be 1
    }
}
