# DnsTools – Engineering Contracts

**Status:** Phase 1 (foundation + `Get-DnsEntry`). Owned by the lead developer.
Agents implement against this document. If something here is wrong,
ambiguous or impossible, **stop and report back** – do not silently deviate.

This document is the single source of truth for: file layout, coding rules,
Constrained Language Mode (CLM) rules, object shapes, function signatures,
on-disk formats and test conventions. Everything not covered here is the
implementer's call, as long as it stays inside these rules.

---

## 1. Purpose

A PowerShell module for finding, auditing, repairing, creating and removing
A/AAAA/PTR/CNAME records in large, messy Microsoft DNS (AD-integrated)
environments. Reference environment: ~44 domain controllers running DNS, one
zone with > 550 000 records. The DNS Manager GUI times out there.

Design principles (decided, not negotiable):

1. **The core works in Constrained Language Mode.** Automations will call it
   from locked-down hosts. See §4.
2. **Snapshot-first for searching, live-first for changing.** Anything that
   needs a whole zone reads a cached zone export. Anything that writes first
   re-reads the record live with `-Node`.
3. **Objects out, never text.** Every command emits typed objects. `Write-Host`
   is allowed only in `Confirm-DnsAction` ("What if:" lines) and in
   interactive preflight tables (phase 2+).
4. **No surprises for automations.** `-Force` means zero prompts. Per-item
   failures are non-terminating errors plus a `Result` object. Idempotent
   outcomes (`AlreadyDone`) are successes.
5. **English everywhere**: help, comments, messages, prompts, README.

---

## 2. Repository layout

```
DNS-tools/
  README.md                         User documentation (English, beginner-first)
  dns_edit.md                       General PowerShell DNS cheat sheet (kept)
  Install-DnsTools.ps1            One-click installer for beginners
  docs/CONTRACTS.md                 This file
  DnsTools/                       The module (this folder is what gets installed)
    DnsTools.psd1
    DnsTools.psm1
    DnsTools.Format.ps1xml
    PSScriptAnalyzerSettings.psd1
    en-US/about_DnsTools.help.txt
    Private/<Verb-DnsNoun>.ps1       One function per file, file name = function name
    Public/<Verb-DnsNoun>.ps1        One function per file, exported
    Tests/
      *.Tests.ps1                    Pester 5
      Fixtures/                      Zone file samples
      Stubs/DnsServerStubs.ps1       Duck-typed stand-ins for DnsServer cmdlets
      Clm/Invoke-ClmSmokeTest.ps1    Child-process CLM smoke runner
      Tools/New-SyntheticZoneFile.ps1
```

`DnsTools.psm1` dot-sources every `Private\*.ps1` then every `Public\*.ps1`
(sorted by name), exports exactly the functions listed in the manifest, and
initialises script-scope state (§7.1). Adding a file to `Private\` must be
enough to make a helper available – no registration lists.

---

## 3. Coding conventions

- **Encoding:** UTF-8 **with BOM**, CRLF line endings, for every `.ps1`,
  `.psm1`, `.psd1`, `.ps1xml`, `.help.txt`. Windows PowerShell 5.1 reads a
  BOM-less file as ANSI and breaks non-ASCII characters. A Pester test
  enforces this.
- **Syntax level:** Windows PowerShell 5.1. No `??`, no ternary, no
  `ForEach-Object -Parallel`, no `using namespace`, no classes, no `enum`
  in module code (enums are CLM-legal but add nothing here).
- **Strict mode:** `Set-StrictMode -Version Latest` at the top of the psm1.
  Code must not read undefined variables or missing properties. Use
  `$obj.PSObject.Properties['Name']` checks where a property may be absent.
- Indentation 4 spaces. `Verb-Noun` with approved verbs, singular nouns.
  `[CmdletBinding()]` and `[OutputType()]` on every function.
- One function per file; the file name equals the function name. No nested
  function definitions in module code (tests may define helpers).
- Parameters: `[Parameter(Mandatory)]` where required, `ValidateNotNullOrEmpty`
  on strings, explicit `[string]`/`[string[]]` types. Never
  `ValueFromPipelineByPropertyName` on a parameter named `Name` in a command
  that also accepts objects by value (binding precedence trap).
- Comments explain **why**, never what the line does. Every function has
  comment-based help (§13). Private functions need `.SYNOPSIS` and
  `.DESCRIPTION` at minimum.
- Names: `$script:` for module state; no `$global:`. Private helpers are
  prefixed `Dns` (`Get-DnsZoneTable`), public commands use noun `DnsEntry`,
  `DnsSnapshot`, `DnsZone`, `DnsIssue`, `DnsChange`.
- **Naming rules (user decision 2026-10-10):** a command or parameter name
  must say what happens without reading the help, and one concept has one
  word across the module. The verb carries the effect: `-MarkDhcpRange`
  marks; a name that implies filtering or removal is wrong for a parameter
  that only annotates. A parameter shares its word with the property it
  sets (`-MarkDhcpRange` sets `InDhcpRange`); rename both or neither. Do
  not import another product's term for a concept the module already
  names (`ReplicationScope` and zone scope are taken, so DHCP networks are
  "Range", never "Scope").
- **Established PowerShell names win when they pass the first rule**
  (`-Path` on Backup-*, `-Delay` in seconds like Restart-Computer, `-Name`
  for a record owner, `-ComputerName`); when they do not, they become
  aliases (`-ZoneName` for `-Zone`, `-TimeToLive` for `-TTL`, `-FilePath`
  for `-InputFile`). Timespan parameters are documented in `d.hh:mm:ss`
  form, because a bare integer converts to ticks. Guiding spirit for all
  of it: PEP 20, explicit over implicit, readability counts, practicality
  beats purity.
- **No `Write-Host`** outside `Confirm-DnsAction`. `Write-Verbose` for
  diagnostics, `Write-Warning` for degraded-but-continuing, `Write-Progress`
  for anything over a few seconds (throttled, see §15).
- Internal writes always carry `-WhatIf:$false -Confirm:$false`:
  `Add-Content`, `Set-Content`, `Out-File`, `Copy-Item`, `Remove-Item`,
  `New-Item`, `Export-DnsServerZone`. Otherwise a caller's `-WhatIf`
  silently disables logging and snapshotting. The lint test enforces this.

---

## 4. Constrained Language Mode rules (the law)

Verified 2026-10-09 on Windows PowerShell 5.1.26100 and PowerShell 7.6.6.
Sources: Microsoft `about_Language_Modes`, PowerShell issues #20767 and
#28128. A Pester AST test (`ClmCompliance.Tests.ps1`) enforces this for every
file under `Private\` and `Public\` and the psm1.

### 4.1 Forbidden anywhere in module code

| Construct | Why | Use instead |
|---|---|---|
| `[PSCustomObject]@{...}` (and `[PSCustomObject][ordered]@{}`) | Blocked in CLM despite the allow-list; one failure poisons every later cast in the process (#28128) | `New-DnsObject` (§7.2), which wraps `New-Object PSObject -Property` |
| `$PSCmdlet.<AnyMethod>()` incl. `ShouldProcess`, `ShouldContinue`, `WriteError`, `ThrowTerminatingError` | Method call on a non-core type | `Confirm-DnsAction` (§10); `Write-Error -Message -Category -ErrorId`; `throw` |
| `$Host.UI.<AnyMethod>()`, `$Host.UI.RawUI.<AnyMethod>()` | Same | `Read-Host`, `Write-Host`, `Write-Warning` |
| `System.Collections.Generic.*`, `System.Collections.ArrayList`, `System.Collections.Queue/Stack` | Cannot create type | `[hashtable]`, `[ordered]`, arrays collected with a `foreach` statement |
| `[System.IO.*]`, `[System.Text.*]` except reading `[System.Text.Encoding]::UTF8` | Method/ctor on non-core type | `Get-Content`, `Set-Content`, `Add-Content`, `Join-Path`, `Test-Path`, `Split-Path`, `Convert-Path` |
| `[math]::*`, `[System.BitConverter]`, `[System.Convert]` | Not allowed types | integer arithmetic, `[int]`/`[long]`/`[uint32]` casts, `-shl`/`-shr`/`-band` |
| `[ref]$x` (so every `TryParse` pattern) | `[ref]` cast is explicitly blocked | `try { [ipaddress]$x } catch {}`, `-as [int]`, `-match` |
| `[scriptblock]::Create()`, `$sb.Invoke()`, `Invoke-Expression`, `Add-Type`, `New-Object -ComObject` | Blocked or security-sensitive | `& $sb`, plain functions |
| `[System.Management.Automation.ErrorRecord]::new`, `[ErrorCategory]` casts | Cannot create type | `Write-Error -Category <name> -ErrorId <id>` |
| `$obj.PSObject.TypeNames.Insert()` | Method on non-core type | `Add-Member -TypeName` |
| `$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath()` | Method on non-core type | `Convert-Path` / `Join-Path $PWD` |
| `class` keyword | Not permitted in CLM | hashtables / `New-DnsObject` |
| `-is [Microsoft.Management.Infrastructure.CimInstance]` or any CIM type literal in module code | Tests use duck-typed stubs | check `$obj.PSObject.Properties['RecordData']` |
| `$array += $item` inside any loop (`foreach`/`for`/`while`/`do`/`switch`/`ForEach-Object`) | O(n²); 20k iterations took 6.4 s on 5.1 | `$result = foreach (...) { ... }`, or §9 three-pass build |
| Any function or cmdlet call per line/record inside the parser and index loops | 50–200 µs per call × 550k = minutes | inline the logic |
| `$PSBoundParameters.ContainsKey()` or any other method on `$PSBoundParameters` | It is a `Dictionary<string,object>`, not a core type (verified, both engines) | `$PSBoundParameters.Keys -contains 'Name'`, or test the parameter variable itself |
| Methods on `[ordered]` dictionaries (`.Contains()`, `.Add()`, `.Remove()`) | Blocked on 5.1 (allowed on 7) | `$ordered.Keys -contains $k`; `$ordered[$k] = $v`; use a plain `[hashtable]` when you need `.ContainsKey()` |
| `ForEach-Object <MemberName>` / `% Property` (the string member form) | Prompts for confirmation under 5.1 CLM | `ForEach-Object { $_.Property }` |
| `$ExecutionContext.SessionState.Module.OnRemove = {}` without try/catch | Property set on a non-core type fails in CLM | Wrap in try/catch; under CLM cached CIM sessions close with the process |
| `$hashtable.MissingKey` / `$null.Count` under strict mode | Throws under `Set-StrictMode -Version Latest` | `$hashtable['Key']` (returns `$null`), `@($x).Count` |
| `$cimInstance.Clone()`, `[ciminstance]::new($x)` | Method/ctor on a non-core type; `.Clone()` is also missing on PowerShell 7 | Fetch the record twice (two independent `Get-DnsServerResourceRecord -Node` calls) and set properties on the second copy (§7.5 `Set-DnsLiveRecord`); lint rule 14 |
| Assigning an `[ipaddress]` into `RecordData.IPv4Address` / `IPv6Address` | The CIM property type is `string` | Assign the normalised string |

### 4.2 Allowed and relied upon

`New-Object PSObject -Property <IDictionary>` · `Add-Member -NotePropertyName`
/ `-TypeName` · `[PSTypeName('DnsTools.Entry')]` parameter attribute ·
`[CmdletBinding(SupportsShouldProcess)]` as a declaration (gives `-WhatIf`
/`-Confirm` and sets `$WhatIfPreference`/`$ConfirmPreference` in the function
scope, which helper functions see through dynamic scoping) · `Write-Error`,
`throw`, `try/catch/finally` · `[hashtable]` (case-insensitive keys by
default – ideal for DNS names) · `[ordered]@{}` · `switch -Regex -File`
(reads UTF-8 with BOM sniffing) · `Get-Content -ReadCount` · string methods
including `StringComparison` overloads · `[ipaddress]` cast and its members
(`.AddressFamily`, `.IPAddressToString`, `.GetAddressBytes()`) ·
`[regex]` including `RegexOptions` and `[regex]::Escape/Replace/Match` ·
`[WildcardPattern]::ContainsWildcardCharacters` · `[timespan]`, `[datetime]`
members including `[datetime]::FromFileTime` · `[guid]::NewGuid()` ·
`[version]` · `[pscredential]` · `[Environment]::NewLine`,
`[Environment]::UserInteractive`, `[Environment]::MachineName` ·
`Get-CimInstance -Query`, `New-CimSession`, `New-CimSessionOption`,
`Remove-CimSession` · `Invoke-Command`, `$using:` · `& $scriptblock` ·
array `.Where({})`/`.ForEach({})` · `Write-Progress` · `ConvertTo-Json
-Compress`, `ConvertFrom-Json` · `Out-File`, `Add-Content`, `Set-Content`,
`Export-Csv`, `Import-Csv` · `Read-Host` · `[SuppressMessageAttribute]`,
`[System.Management.Automation.Credential()]`, `[ValidateScript]`.

DnsServer cmdlets return CIM instances. In CLM you may read their properties,
set properties in memory, pipe them to typed parameters and to
`Remove-/Set-/Add-DnsServerResourceRecord`. `.Clone()` exists on 5.1 only –
never rely on it.

### 4.3 Language mode detection

`DnsTools.psm1` sets `$script:LanguageMode = [string]$ExecutionContext.SessionState.LanguageMode`
once at import. Only features explicitly marked "Full-language only" may
branch on it (phase 4: `-IncludeOwner`). Phase 1 code never branches on it.

---

## 5. Error, output and interaction contract

1. **Terminating errors (`throw`)** only for preconditions that make the
   whole call pointless: server unreachable, DnsServer module missing,
   `-Credential` given but no CIM session possible, an automatic snapshot
   export (§9.4) in which no zone at all could be exported, invalid parameter
   combinations. Messages end with a hint of what to do (`"... Specify
   -Server."`). A zone that fails to export in `Update-DnsSnapshot` is a
   per-item failure (rule 2, §13.3), not a precondition.
2. **Per-item failures:** `Write-Error -Message <text> -Category <cat>
   -ErrorId <DnsTools.<Function>.<Reason>> -TargetObject <name>`
   (non-terminating) **and** a `Result` object with `Result = 'Failed'`.
   Callers choose `-ErrorAction Stop`.
2b. **Live lookups** (`Get-DnsLiveRecord`) call the DnsServer cmdlet with
   `-ErrorAction SilentlyContinue -ErrorVariable <local>` and classify each
   error: a `FullyQualifiedErrorId` containing `9714`
   (DNS_ERROR_NAME_DOES_NOT_EXIST) or category `ObjectNotFound` means "no
   record" (no output, no error, one Verbose line); anything else becomes a
   non-terminating `Write-Error` with the original category (replaced by
   `ConnectionError` when `Test-DnsConnectionError` recognises the error, so
   change commands can end the batch per §5.8; added 2026-10-11) and ErrorId
   `DnsTools.Get-DnsLiveRecord.LookupFailed`, and the lookup yields
   nothing. Measured 2026-10-09: `-ErrorAction Stop` + catch multiplies the
   records that reach a caller's `-ErrorVariable` (35 instead of 5 for one
   missing name), and `Ignore` is rejected by advanced functions on 5.1; so
   the silenced "not found" answers do remain in `$Error`/`-ErrorVariable`,
   which the help states.
3. **Warnings** (`Write-Warning`) for degraded operation that still
   produces correct output: stale snapshot used, zone skipped, CIM
   unavailable and fallback taken.
4. **Verbose** for every server round-trip (what was queried where) and for
   the resolved defaults (`-Server`, log path, snapshot path).
5. **Progress** for operations expected to exceed ~3 s (exports, parsing,
   index builds), updated at most every 10 000 rows or every 500 ms.
6. **Prompts** only through `Confirm-DnsAction` (§10). Nothing else may call
   `Read-Host`.
7. **Output objects** are emitted as they are produced (streamed), never
   collected into an array first. `Get-DnsEntry -Find '*'` on a 550k zone
   must start emitting within seconds.
8. **Batch abort (change commands).** The first
   `DnsTools.Confirm.NonInteractive` error, or an unreachable server (RPC
   1722, WinRM/CIM transport failure), ends the batch with one terminating
   error; it is never repeated per item. Access denied (Win32 error 5) on a
   write is a per-item `Failed`, never `AlreadyDone`.
9. **Idempotency.** `AlreadyDone` is a success: the wanted state already
   holds (record already gone, record already present with the same data,
   value already set, zone already hosted). `Skipped` carries its reason in
   `Error` (referenced name, dynamic record, read-only zone, reference check
   unavailable).

---

## 6. Common parameters (every public command)

| Parameter | Type | Semantics |
|---|---|---|
| `-Server` | `[string[]]` on `Get-*`, `[string]` on everything else; alias `ComputerName` | DNS server(s) to talk to. Default: `$env:LOGONSERVER` with leading `\\` removed. If that is empty, the parameter is effectively mandatory: throw `"No default DNS server (LOGONSERVER is not set). Specify -Server."` Resolved value is written to Verbose. |
| `-Credential` | `[pscredential]`, attribute `[System.Management.Automation.Credential()]`, `[AllowNull()]` | Alternate credentials. DnsServer cmdlets lack `-Credential`, so when it is given **every** DnsServer call goes through a CIM session (`Get-DnsServerParameter`). If no session can be opened the call **throws**. Never fall back to the logged-on user silently. |
| `-TimeoutSec` | `[int]`, default 300 | Operation timeout for CIM queries and remote commands where the underlying cmdlet supports it. |
| `-LogPath` | `[string]` | Change-log file (§11). On every command that writes: `Remove-DnsEntry`, `New-DnsEntry`, `Set-DnsEntry`, `New-DnsReverseZone`, `Backup-DnsZone`. Not on `Get-DnsEntry` (reserved for `-IncludeOwner`, phase 4). |
| `-WhatIf` / `-Confirm` / `-Force` | via `SupportsShouldProcess` + `[switch]$Force` | On every command that changes state. `-Force` means **zero prompts** (§10 rule 2) and nothing else; safety overrides have their own switches (`-AllowReferenced`, `-IncludeDynamic`, `-ReplacePtr`, `-SkipReferenceCheck`). `Get-DnsEntry` and `Get-DnsSnapshot` do not declare `SupportsShouldProcess`. `Update-DnsSnapshot` writes local files only, impact `Low`. |
| `-Delay` | `[int]` seconds, default 0 | `Remove-DnsEntry`, `New-DnsEntry`, `Set-DnsEntry`: `Start-Sleep -Seconds` once per input item after its sub-operations (not per write). Whole seconds, like `Restart-Computer -Delay`. |
| Aliases for established names | | `-Server` ← `ComputerName`; `-Zone` ← `ZoneName`; `-TTL` ← `TimeToLive`; `-InputFile` ← `FilePath`; `Backup-DnsZone -Path` ← `BackupPath`; `Get-DnsEntry -Find` ← `Name`, `Identity`, `HostName`, `IPAddress`, `Address`. See the naming rules in §3. |

---

## 7. Module state and shared helpers

### 7.1 Script-scope state (initialised in the psm1)

```powershell
$script:ModuleRoot          = $PSScriptRoot
$script:LanguageMode        = [string]$ExecutionContext.SessionState.LanguageMode
$script:ZoneTableCache      = @{}   # key: server (lower-case) -> zone table object (§8)
$script:CimSessionCache     = @{}   # key: server (lower-case) -> CimSession or 'Unavailable'
$script:SnapshotIndexCache  = @{}   # key: server (lower-case) -> index hashtable (§9.3)
$script:DnsServerModuleChecked = $false
$script:WriterServer        = $null # server that received this session's first change (§7.5 Test-DnsWriterServer, §13.9)
```

`$ExecutionContext.SessionState.Module.OnRemove` closes cached CIM sessions
(wrapped in try/catch; property assignment is allowed in CLM).

### 7.2 `New-DnsObject`

```powershell
New-DnsObject -TypeName <string> -Property <System.Collections.IDictionary>
```
Returns one `PSObject` whose `PSObject.TypeNames[0]` is `DnsTools.<TypeName>`
and whose properties are exactly the dictionary entries, **in dictionary
order** (callers pass `[ordered]@{}`). Implementation:
`New-Object -TypeName PSObject -Property $Property`, then
`Add-Member -InputObject $obj -TypeName "DnsTools.$TypeName"`, return
`$obj`. This is the **only** way module code creates output objects.

### 7.3 Server context

```powershell
Resolve-DnsServerName [-Server <string>]            # -> lower-case server name, or throws (§6)
Import-DnsServerModule                               # no-op after first success; throws with install hint if DnsServer is missing
Get-DnsCimSession -Server <string> [-Credential <pscredential>] [-TimeoutSec <int>]
                                                     # -> CimSession or $null; tries WSMan then DCOM; verifies root\MicrosoftDNS\MicrosoftDNS_Server; caches
Get-DnsServerParameter -Server <string> [-Credential <pscredential>] [-TimeoutSec <int>]
                                                     # -> @{ ComputerName = <s> }  or  @{ CimSession = <session> }; throws if Credential given and no session
```
`Import-DnsServerModule` must consider the commands present if
`Get-Command Get-DnsServerResourceRecord -ErrorAction SilentlyContinue`
succeeds (that is how test stubs satisfy it); otherwise
`Import-Module DnsServer -ErrorAction Stop` inside try/catch and rethrow
with: `"The DnsServer PowerShell module (RSAT: DNS Server Tools) is not
available. Install it with: Add-WindowsCapability -Online -Name
Rsat.Dns.Tools~~~~0.0.1.0 (Windows 10/11) or Install-WindowsFeature
RSAT-DNS-Server (Windows Server)."`

### 7.4 Name and address helpers

```powershell
ConvertTo-DnsNormalizedName -Name <string>           # -> lower-case, trailing dot removed, \DDD escapes decoded as OCTAL BYTES, a run of them as one UTF-8 sequence (\040 -> ' ', r\303\244k -> 'räk'; an invalid byte -> one char, never throws; live fact 2026-10-13), surrounding whitespace trimmed; '' -> ''
                                                     # Windows DNS writes \DDD in OCTAL, not the decimal of RFC 1035. Verified 2026-10-09: a live PTR target
                                                     # 'iO Sense.lab.example.' was exported as 'iO\040Sense.lab.example.'. Decode d1*64 + d2*8 + d3 (no [Convert], it is blocked in CLM).
ConvertTo-DnsNormalizedAddress -Address <string>     # -> canonical string or $null if not an IP. IPv4: dotted quad only, octets read as DECIMAL ('010.0.0.1' -> '10.0.0.1'; note the [ipaddress] cast would read it as octal 8.0.0.1 and would accept '10.1' and '12345'). IPv6: through [ipaddress], compressed lower-case
ConvertTo-DnsReverseName -Address <string>           # -> @{ Address='10.0.16.5'; Family='IPv4'|'IPv6'; ReverseName='5.16.0.10.in-addr.arpa' } ; IPv6 = 32 nibbles + '.ip6.arpa'; $null if invalid
Get-DnsReverseNodeName -ReverseName <string> -ZoneName <string> [-ClasslessHostLabel]
                                                     # -> relative node name ('@' when equal). For classless zones (§8.3) the node is the host octet only
Test-DnsAddressInNetwork -Address <string> -Network <string[]>   # CIDR list ('10.0.50.0/24', 'fd00::/8'); -> $true/$false; invalid entries -> Write-Warning once, treated as no match
Find-DnsZoneForName -Name <string> -ZoneTable <object> [-Reverse]
                                                     # -> string[] of hosted zone names that contain the name, longest first; @() if none.
                                                     # For -Reverse with an in-addr.arpa name also returns classless zones that cover the address (§8.3)
```
`Find-DnsZoneForName` strips labels from the left and probes
`$ZoneTable.ZoneLookup` (hashtable) – O(labels), no `Where-Object`/`Sort-Object`.

### 7.5 Write helpers (phase 2)

Write helpers take `-ServerParameter <hashtable>` from `Get-DnsServerParameter`
unless stated. They never prompt, never log and never emit objects: the
public command does that through `Confirm-DnsAction` (§10) and
`Write-DnsResult`. Every DnsServer write cmdlet call carries
`-WhatIf:$false -Confirm:$false` (lint rule 7, §16).

```powershell
New-DnsBatch -Server <string> [-LogPath <string>] [-Delay <int>] [-Force]
# -> @{ BatchId=<guid string>; Server; LogPath; Delay; Force=[bool]; Confirm=@{ All=@{} }; StartedAt=[datetime]; References=@{}; CimSession=$null; Counts=@{} }
# Created once in begin {} of every change command. Confirm is the -State hashtable for Confirm-DnsAction (§10).

Write-DnsResult -Batch <hashtable> -Action <string> -Name <string> -Type <string> -Data <string> -Zone <string> -NodeName <string> -Result <string> [-ErrorMessage <string>] [-Before <hashtable>] [-After <hashtable>]
# -> DnsTools.Result (§12.2). Also writes exactly one change-log line (§11) with Id, BatchId, Server, Operator, Timestamp, Name and Data filled in.
# -ErrorMessage has the alias -Error (a parameter named Error would shadow $Error). Empty strings for Type, Data, Zone, NodeName and the error text become $null.
# Before/After: @{ Data; Ttl; Timestamp; IsStatic } or $null; only those four keys reach the log, IsStatic defaults to ($null -eq Timestamp).
# Action and Result are validated against §12.2. Every Result value is counted in $Batch.Counts[<Result>]. The ONLY way module code creates a Result object or a log line.

Read-DnsInputFile -Path <string> [-Csv]
# -> string[] (trimmed lines; '#' comments and blank lines skipped; duplicates removed, case-insensitive), or
#    hashtable[] with keys Name, Address, Target, TTL, Zone ($null when absent; TTL stays a string, the caller converts) with -Csv or when the
#    first line that is neither blank nor a '#' comment has a field named 'Name' (a lone Name line counts, so Export-Csv output is recognised).
# Delimiter ',' or ';' when the header has semicolons and no comma (Swedish Excel). CSV rows are not de-duplicated.
# Get-Content -Encoding UTF8 (BOM-less files read as UTF-8 too). Missing or empty file -> throw. Unknown CSV columns -> one warning, ignored.

Get-DnsReferenceTable -Zone <string> -CimSession <object> [-TimeoutSec <int>]
# -> @{ Cname=@{ target -> @(owner) }; Srv=@{}; Ns=@{}; Mx=@{} } or $null when any query fails (no session, access denied, timeout -> one Verbose line).
# Four Get-CimInstance -CimSession -Namespace root\MicrosoftDNS -OperationTimeoutSec calls:
#   SELECT OwnerName, <prop> FROM MicrosoftDNS_<CNAME|SRV|NS|MX>Type WHERE ContainerName='<zone>'
# <prop> = PrimaryName | SRVDomainName | NSHost | MailExchange. Values carry a trailing dot (verified 2026-10-11) -> ConvertTo-DnsNormalizedName. OwnerName has no dot.

Get-DnsReference -Name <string> -ZoneTable <object> -Batch <hashtable> [-Credential] [-TimeoutSec <int>] [-MaxSnapshotAge <timespan>] [-SkipReferenceCheck]
# -> @{ Cname=[string[]]; Srv=[string[]]; Ns=[string[]]; Mx=[string[]]; Source='Snapshot'|'Wql'|'Skipped'|'Unavailable'; Age=[timespan]|$null }
# Source order: (1) $script:SnapshotIndexCache[server], or a snapshot on disk whose OldestExportedAt is younger than -MaxSnapshotAge (default 24 h) — checked with
#   Get-DnsSnapshotMeta and loaded with Get-DnsSnapshotIndex only when the age check passed (never the auto-export path) -> RefBy index.
# (2) otherwise WQL: one CIM session per batch ($Batch.CimSession from Get-DnsCimSession; $null -> Unavailable); Get-DnsReferenceTable for EVERY hosted
#   forward zone (SRV/NS/MX may live in another zone than the name), cached in $Batch.References[zone]; any table $null -> Unavailable.
# (3) -SkipReferenceCheck -> Source='Skipped', empty lists, one warning per batch (counted in $Batch.Counts['ReferenceCheckSkipped']).
# The age limit applies to the cached index too; the disk is probed only when nothing is cached for the server. Every hosted forward zone is queried
# (secondary, stub and forwarder zones included); a zone whose table failed stays $null in $Batch.References for the rest of the batch.
# Owners are DISTINCT FQDNs (a count in a message counts owners, not records); 'Skipped' and 'Unavailable' return empty lists. The caller decides the consequence (§13.4).

Remove-DnsLiveRecord -ServerParameter <hashtable> -ZoneName <string> -NodeName <string> -RRType <string> -Data <string>
# -> @{ Removed=[bool]; AlreadyGone=[bool]; Error=<string>|$null; ErrorId=<FullyQualifiedErrorId>|$null; Unreachable=[bool] }
# Get-DnsServerResourceRecord -Node -RRType, keep the record whose normalised Data equals -Data, pipe it to
# Remove-DnsServerResourceRecord -ZoneName -Force -WhatIf:$false -Confirm:$false. Pipeline form ONLY: the -Name/-RRType/-RecordData form
# removes the record but reports a false error on Server 2022/2025. No matching record, or 9701 / 9714 from the cmdlet -> AlreadyGone.
# LIVE FACT (labdc01, Server 2025, 2026-10-13): removing an A/AAAA record by ANY path (this cmdlet, WMI Remove-CimInstance, dnscmd
#   /recorddelete) makes the server delete the PTR record that points at the record's name; a PTR pointing at another name survives.
#   The helper does nothing about it; the callers order PTR before A (§13.4) and Remove-DnsEntry re-checks after -KeepPtr.
# Unreachable = Test-DnsConnectionError on the failing error record (§13.9: the caller ends the batch).

Add-DnsLiveRecord -ServerParameter <hashtable> -ZoneName <string> -NodeName <string> -RRType <A|AAAA|CNAME|PTR> -Data <string> [-Ttl <int>]
# -> @{ Record=<hashtable from Get-DnsLiveRecord>|$null; Reason='Added'|'AlreadyExists'|'CnameConflict'|'Failed'; Error; ErrorId; Unreachable=[bool] }
# Typed cmdlets only (Add-DnsServerResourceRecordA/AAAA/CName/Ptr), -TimeToLive (New-TimeSpan -Seconds $Ttl) only when -Ttl is given,
# never -CreatePtr, never -AgeRecord (records are static). Throws when -NodeName ends with -ZoneName (the cmdlet would create x.zone.zone).
# Re-reads the record after the add. FullyQualifiedErrorId (winerror.h, §13.9): 9711 -> AlreadyExists (Record = the existing record);
# 9708 or 9709 -> CnameConflict; anything else -> Failed with the cmdlet's message, Unreachable set by Test-DnsConnectionError.

Set-DnsLiveRecord -ServerParameter <hashtable> -ZoneName <string> -NodeName <string> -RRType <string> -Data <string> [-NewTtl <int>] [-NewData <string>] [-CimSession <object>]
# -> @{ Record=<hashtable>|$null; Error; ErrorId; Unreachable=[bool] }
# LIVE FACTS (labdc01, 2026-10-13): Set-DnsServerResourceRecord on an A/AAAA record (TTL or data) DELETES the PTR record that points at
#   the record's name (a PTR pointing elsewhere survives); the WMI method MicrosoftDNS_<Type>.Modify(TTL) in root\MicrosoftDNS changes
#   the TTL without touching the PTR, but Modify(IPAddress) deletes it like the cmdlet. Neither method keeps the aging Timestamp: every
#   change makes the record static. Therefore:
#   - -NewTtl alone: Invoke-CimMethod -MethodName Modify -Arguments @{ TTL = [uint32]$NewTtl } on the instance selected with
#     SELECT * FROM MicrosoftDNS_<AType|AAAAType|CNAMEType|PTRType> WHERE ContainerName='<zone>' AND OwnerName='<fqdn>' [AND <prop>='<data>']
#     over -CimSession (Get-DnsCimSession; the batch caches it in $Batch.CimSession). No session, or the provider refuses -> Error with
#     ErrorId DnsTools.Set-DnsLiveRecord.WmiUnavailable and nothing changed. With -UseDnsServerCmdlet the TTL goes through
#     Set-DnsServerResourceRecord instead (the server then deletes the matching PTR; the caller re-creates it, §13.6), so the module
#     works without root\MicrosoftDNS too (WMIC is deprecated, WMI/CIM is not, but a namespace ACL can still block it).
#   - -NewData (with or without -NewTtl): Set-DnsServerResourceRecord as below; the CALLER removes the old PTR first and adds the new one
#     afterwards (§13.6), so the server's implicit deletion never hits a PTR that is still wanted or unlogged.
# Fetches the record TWICE with Get-DnsServerResourceRecord -Node -RRType (two independent CimInstances; .Clone() is blocked in CLM and missing on 7),
# picks the one whose Data matches, sets TimeToLive (New-TimeSpan -Seconds) and/or RecordData.IPv4Address | IPv6Address | HostNameAlias | PtrDomainName
# as a STRING on the second copy, then Set-DnsServerResourceRecord -ZoneName -OldInputObject $old -NewInputObject $new -WhatIf:$false -Confirm:$false.
# Target names are written with the trailing dot (the form the server returns); addresses in canonical form; -NewData is validated against the type.
# Re-reads and returns the record; the caller logs After.Timestamp. A change that succeeded but cannot be read back gives Record = $null and Error = $null.

Resolve-DnsChangeTarget -InputObject <object> -ZoneTable <object> [-Zone <string>]
# -> @{ Kind='Name'|'Address'|'Cname'; Fqdn; Zone; NodeName; Address; Type; Data; Server } or throws (Write-Error -ErrorAction Stop with ErrorId
#   DnsTools.Resolve-DnsChangeTarget.<Reason>, Reason = PatternNotAllowed | ZoneNotFound | InvalidInput; the caller catches per item and re-raises
#   it non-terminating as DnsTools.<Cmd>.<Reason> with the same message and category, plus the item's Result).
# Entry object (PSTypeName DnsTools.Entry or Deserialized.DnsTools.Entry): identity from Name/Type/Data/Zone/NodeName/Server; wildcard owners are real
#   names and accepted; Kind 'Cname' for a CNAME entry, else 'Name' with Type/Data filled (Address = Data for A/AAAA); zone not hosted -> ZoneNotFound. Server is set only here.
# String: address (ConvertTo-DnsNormalizedAddress) -> Address; FQDN in a hosted forward zone (Find-DnsZoneForName, longest wins; with -Zone it must lie inside it) -> Name;
#   bare name + -Zone -> Name ('@' = apex); any * or ? -> PatternNotAllowed; dotted name outside every hosted zone, or bare name without -Zone -> ZoneNotFound;
#   empty item -> InvalidInput. Type, Data and Server are $null.
# CSV row hashtable (Read-DnsInputFile -Csv): Name (or Address when Name is empty) resolved like a string, the Zone column overrides -Zone; Address column ->
#   Type A|AAAA + Data (invalid address -> InvalidInput); Target column -> Kind 'Cname', Type CNAME, Data; Address and Target together -> InvalidInput; TTL left to the caller.

Get-DnsReverseZoneName -NetworkId <string>
# -> @{ ZoneName; Family='IPv4'|'IPv6'; Prefix=[int]; Network=<string> }
# IPv4: prefix 8, 16 or 24 only -> 'a.in-addr.arpa', 'b.a.in-addr.arpa', 'c.b.a.in-addr.arpa'. IPv6: prefix a multiple of 4 in 4..124 -> reversed nibbles + '.ip6.arpa'.
# Any other prefix -> throw naming the nearest allowed ones. Must equal the name Add-DnsServerPrimaryZone -NetworkId derives (checked in the live test).

Test-DnsWriterServer -Server <string>
# Warning when $script:WriterServer is set and differs: "This session already changed DNS on 'dc01'; changes on 'dc02' may be lost if both touch the same node before replication."
# The first server of the session is remembered in $script:WriterServer and kept (§7.1); later servers only warn. Case-insensitive. No output.

Test-DnsConnectionError -ErrorRecord <object>
# -> [bool]: $true when the error says the server cannot be reached: Category 'ConnectionError', or FullyQualifiedErrorId containing '1722'
#   (RPC server unavailable), '0x800706BA' (the same as an HRESULT) or '0x8033' (WSMan transport). Used by the live write helpers to fill Unreachable (§13.9).
# Measured 2026-10-11: an unreachable -ComputerName gives Category NotSpecified and ErrorId 'WIN32 1722,<Cmd>' from the local provider, in 0.35 s.

New-DnsLiveReverseZone -Batch <hashtable> -NetworkId <string> -CopySettingsFrom <string> -ZoneTable <object> -ServerParameter <hashtable> [-ReplicationScope <string>] [-DynamicUpdate <string>] [-Credential] [-TimeoutSec <int>]
# -> emits the DnsTools.Result objects CreateZone and SetZoneAging through Write-DnsResult with the GIVEN batch (same BatchId as the caller's run);
#    no other output. Everything §13.7 describes happens here: Get-DnsReverseZoneName, AlreadyDone when hosted or on 9609, Custom + partition, the
#    gate (Confirm-DnsAction -Impact High -State $Batch.Confirm, so [A]ll at High carries across a New-DnsEntry run; declined -> Skipped
#    'Declined at the confirmation prompt.'), Set-DnsServerZoneAging, Get-DnsZoneTable -Refresh (not under -WhatIf), the replication warning.
# The caller reads the CreateZone Result: Success, AlreadyDone or WhatIf = zone present for the PTR step. An invalid -NetworkId or a
#    -CopySettingsFrom zone that is not hosted is a Failed CreateZone Result plus a terminating Write-Error -ErrorAction Stop with ErrorId
#    DnsTools.New-DnsLiveReverseZone.<InvalidNetworkId|ZoneNotFound|ServerUnreachable>; the public caller re-raises it under its own name
#    (per item and non-terminating for the first two, terminating for ServerUnreachable), as with Resolve-DnsChangeTarget.
# Public New-DnsReverseZone is a thin wrapper (batch, Test-DnsWriterServer unless -WhatIf, zone table, this helper); New-DnsEntry calls the
#    helper with its own batch when -CreateReverseZone is set.
```

---

## 8. Zone table

```powershell
Get-DnsZoneTable -Server <string> [-Credential <pscredential>] [-TimeoutSec <int>] [-Refresh]
```
Returns (and caches per server) a `DnsTools.ZoneTable` object:

| Property | Type | Content |
|---|---|---|
| `Server` | string | lower-case |
| `RetrievedAt` | datetime | |
| `Zones` | object[] | one `DnsTools.ZoneInfo` per zone (below) |
| `ZoneLookup` | hashtable | zone name (lower) → ZoneInfo |
| `ForwardZones` | string[] | lower-case names, all zone types |
| `ReverseZones` | string[] | lower-case names, all zone types |
| `ClasslessZones` | object[] | ZoneInfo of RFC 2317 zones (§8.3) |
| `ServerScavenging` | object | `ScavengingState`, `ScavengingInterval`, `LastScavengeTime` from `Get-DnsServerScavenging` ($null if the call fails, with a warning) |

`DnsTools.ZoneInfo`: `ZoneName` (lower) · `IsReverse` · `ZoneType`
(Primary/Secondary/Stub/Forwarder) · `IsDsIntegrated` · `ReplicationScope` ·
`DirectoryPartitionName` · `DynamicUpdate` · `IsAutoCreated` · `IsReadOnly`
(`$true` for anything but Primary, and for auto-created zones) ·
`IsExportable` (Primary, not auto-created, not `TrustAnchors`) ·
`AgingEnabled` · `NoRefreshInterval` · `RefreshInterval` · `ScavengeServers`
(aging fields from `Get-DnsServerZoneAging`, called once per exportable
zone; failures → `$null` fields + one Verbose line) · `IsClassless` ·
`ClasslessNetwork` (`'10.0.16.0/25'` or `$null`) · `ClasslessHostRange`
(`@(0,127)` or `$null`).

Reverse detection: `IsReverseLookupZone` from the cmdlet, or name ends with
`.in-addr.arpa` / `.ip6.arpa`.

### 8.3 Classless (RFC 2317) reverse zones

A reverse zone whose first label matches `^(\d+)[/-](\d+)$` (e.g.
`0/25.16.0.10.in-addr.arpa`, `0-25.16.0.10.in-addr.arpa` or the range form
`64-127.16.0.10.in-addr.arpa`) is classless. `$matches[1]` is the first host
octet. Slash form: `$matches[2]` is always a prefix length (25–32) and the
zone covers `upper.first` … `upper.(first + 2^(32-prefix) - 1)`. Hyphen
form: 25–32 is read as a prefix length by convention; any other value is
the last host octet (range form, valid when `first ≤ last ≤ 255`) and the
zone covers `upper.first` … `upper.last`. `0-31` is therefore /31, not the
range 0–31 – an accepted ambiguity, logged to Verbose, to be checked
against real classless zones in phase 5. `ClasslessHostRange` is
`@(first, last)` for both forms; `ClasslessNetwork` is CIDR when the range
is an aligned power-of-two block, otherwise `'10.0.16.10-20'`. The
remaining labels are the reversed upper three octets. Owner names
inside such a zone are the host octet only (`5` → `10.0.16.5`). In the
parent zone, a `CNAME` at `5.16.0.10.in-addr.arpa` pointing into the
classless zone means "PTR delegated". Phase 1 detects and classifies; it
does not repair.

---

## 9. Zone export, parser and index

### 9.1 Export

```powershell
Export-DnsZoneFile -ZoneName <string> -Server <string> -DestinationPath <string> [-Credential] [-TimeoutSec] [-KeepRemoteFile]
```
Runs `Export-DnsServerZone -Name <zone> -FileName <unique>` (file lands in
`%windir%\System32\dns` **on the server**), retrieves it to
`DestinationPath` (full local file path), removes the server copy in
`finally`, returns the local path. Retrieval order: local path (when the
server is this machine) → `\\server\admin$\System32\dns\<file>` →
`Invoke-Command` streaming `Get-Content -ReadCount 2000 -Encoding UTF8`
and appending locally with `Add-Content -Encoding UTF8` (never one giant
string). With `-Credential` the UNC path is skipped (no credential support)
and `Invoke-Command -Credential` is used. All file writes carry
`-WhatIf:$false -Confirm:$false`. Throws (§5.1) if the zone cannot be
exported or retrieved; a failed server-side cleanup is a warning with the
exact remote path.

### 9.2 Parser

```powershell
ConvertFrom-DnsZoneFile -Path <string> -ZoneName <string> [-ZoneInfo <object>]
```
Returns a **hashtable**:

```powershell
@{
    ZoneName     = 'contoso.local'       # lower-case
    IsReverse    = $false
    DefaultTtl   = 3600                  # from $TTL directive, else SOA minimum TTL, else 3600
    Rows         = [string[]]            # see below
    RecordCount  = 1234                  # Rows.Count
    SkippedLines = 12                    # comments/blank/directives are NOT counted; only unparseable record lines
    IgnoredTypes = @{ SOA=1; WINS=1; TXT=5 }   # type -> count of records deliberately not emitted
    Warnings     = [string[]]
}
```

Each **Row** is one resource record as a tab-separated string with exactly
six fields (`"`t"` joined):

```
OWNER   TYPE   DATA   TTL   AGE   ADDR
```
- `OWNER`: owner FQDN, lower-case, no trailing dot, `\DDD` decoded as
  **octal bytes**, a run of them as UTF-8 (Windows writes `\040` for a space and
  `r\303\244k` for `räk`; see §7.4). Apex
  = the zone name. Continuation lines (leading whitespace, no owner)
  inherit the previous owner. `$ORIGIN` switches the suffix; relative names
  get the current origin appended; absolute names (trailing dot) are used
  as-is.
- `TYPE`: upper-case. **Emitted types:** `A`, `AAAA`, `CNAME`, `PTR`, `SRV`,
  `NS`, `MX`, `DHCID`. Everything else (SOA, TXT, WINS, WINSR, DNSKEY, …)
  is counted in `IgnoredTypes` and skipped.
- `DATA`: for `A`/`AAAA` the address, canonical form (IPv4 as written when
  it matches `^\d{1,3}(\.\d{1,3}){3}$` without leading zeros, otherwise
  normalised through `[ipaddress]`; IPv6 always through `[ipaddress]`).
  For `CNAME`, `PTR`, `NS`: target FQDN normalised like OWNER. For `SRV`:
  the target FQDN only (priority/weight/port dropped). For `MX`: the
  exchange FQDN only. For `DHCID`: the base64 string as-is.
- `TTL`: integer seconds; when the line has no TTL use `DefaultTtl`.
- `AGE`: integer hours from `[AGE:n]`, or `0` when absent (static).
- `ADDR`: for `PTR` rows only, the address derived from the owner name
  (`5.16.0.10.in-addr.arpa` → `10.0.16.5`; classless zones per §8.3; ip6.arpa
  → 32 nibbles reversed → normalised through `[ipaddress]`). Empty for other
  types. A PTR owner that does not yield exactly one address (e.g. `16` in
  a `/16` zone, which is a /24 node, or a wildcard) is still emitted with
  empty ADDR and counted in `Warnings` once per distinct shape, never per
  line.

Grammar facts (verified against a real Windows export, see fixture):
line = `[owner] [\[AGE:n\]] [ttl] [IN] TYPE rdata`; separators are runs of
spaces and/or tabs (`[ \t]+`), owner column is padded to 24 chars; `@` is
the apex; `;` starts a comment; `(` … `)` spans the SOA across lines (skip
until the closing parenthesis); `$TTL n`, `$ORIGIN name.`, `$INCLUDE` are
directives; the file has **no BOM** and CRLF endings, UTF-8 content.

Implementation rules (performance, §4.1): `switch -Regex -File $Path` with
all logic inline; `continue`, never `break` (it exits the file loop); no
`-CaseSensitive`; hoist every constant (`$fileTimeEpoch`, regexes) out of
the loop; collect rows with a `foreach`/`switch` statement assigned to a
variable, never `+=`; no function calls per line. Target: 550 000 lines in
< 20 s on Windows PowerShell 5.1 on a developer laptop.

### 9.3 Index

```powershell
New-DnsSnapshotIndex -Server <string> -ParseResult <hashtable[]> -ZoneTable <object> [-KeepRows]
```
The caller adds an optional `ExportedAt` ([datetime]) key to each parse
result before passing it (the parser never sees meta.json). To stay under
the memory budget the builder **sets each parse result's `Rows` to `$null`
as soon as it has consumed them** (measured: ~85 MB lower peak); pass
`-KeepRows` to keep them. Returns a hashtable (not a typed object – it is
internal and large):

```powershell
@{
    Server     = 'dc01'
    BuiltAt    = [datetime]
    Name       = @{}   # fqdn      -> string[] of "TYPE`tDATA`tTTL`tAGE`tZONE"        (A, AAAA, CNAME, DHCID, NS, SRV, MX owners)
    Addr       = @{}   # address   -> string[] of fqdn                               (A/AAAA only)
    Ptr        = @{}   # address   -> string[] of "ZONE`tTARGET`tTTL`tAGE`tOWNER"    (PTR rows with ADDR)
    RefBy      = @{}   # target    -> string[] of "TYPE`tOWNER`tZONE"                (CNAME, SRV, NS, MX)
    Dhcid      = @{}   # fqdn      -> $true
    Delegation = @{}   # fqdn      -> $true   (NS owners that are not a zone apex of a hosted zone)
    Names      = [string[]]   # unique forward owners that have A, AAAA or CNAME
    Addrs      = [string[]]   # unique addresses in Addr
    Zones      = @{}   # zone -> @{ ExportedAt=[datetime]; DefaultTtl=; RecordCount=; IsReverse= }
    OldestExportedAt = [datetime]
}
```
Build in three passes, O(n), CLM-legal (§4.1): (1) split rows into flat
arrays with a `foreach` statement; (2) count per key into a hashtable of
ints; (3) pre-allocate `$h[$key] = @($null) * $count[$key]` and fill through
a position hashtable. Never `$h[$k] += $x`. Reuse the same string instance
as key and value where possible. Memory budget: ≤ 500 MB for 550k forward +
200k reverse rows on 5.1. Target: index build < 10 s on top of parsing.

### 9.4 Snapshot storage

Root: `$env:LOCALAPPDATA\DnsTools\snapshot\<server>\` (server lower-case).
Per zone: `<safeZoneName>.txt` where `safeZoneName` replaces any character
outside `[A-Za-z0-9._-]` with `_`. Plus `meta.json`:

```json
{
  "Server": "dc01",
  "SchemaVersion": 1,
  "Zones": {
    "contoso.local": {
      "File": "contoso.local.txt",
      "ExportedAt": "2026-10-09T15:00:00.0000000+02:00",
      "IsReverse": false,
      "ZoneType": "Primary",
      "ReplicationScope": "Domain",
      "DirectoryPartitionName": "DomainDnsZones.contoso.local",
      "DynamicUpdate": "Secure",
      "AgingEnabled": true,
      "FileSizeBytes": 123456
    }
  }
}
```
`meta.json` is written with `ConvertTo-Json -Depth 5` and
`Set-Content -Encoding UTF8 -WhatIf:$false`. Read with
`Get-Content -Raw -Encoding UTF8 | ConvertFrom-Json`.

```powershell
Get-DnsSnapshotIndex -Server <string> [-Credential] [-TimeoutSec] [-MaxSnapshotAge <timespan>]
```
Internal. Returns the index for a server: from `$script:SnapshotIndexCache`;
else parses the files listed in `meta.json` and builds it; else (no
snapshot at all) calls `Update-DnsSnapshot` after a warning
(`"No snapshot exists for 'dc01'. Exporting N zone(s) now; this can take
several minutes on large zones."`). A snapshot older than `MaxSnapshotAge`
(default 24 h) is **used** with a warning that names the age and
`Update-DnsSnapshot`. Never auto-refreshes.

---

## 10. `Confirm-DnsAction` (replaces ShouldProcess)

```powershell
Confirm-DnsAction -Target <string> -Action <string> -Impact <Low|Medium|High> -State <hashtable> [-Force]
# -> [bool]
```
Rules, in order:
1. `$WhatIfPreference` is `$true` → `Write-Host "What if: Performing the
   operation ""$Action"" on target ""$Target""."` → return `$false`.
2. `-Force`, or `$State.All[$Impact]` is `$true` → return `$true`.
3. Prompt **only if** `$ConfirmPreference -ne 'None'` **and**
   `[int][System.Management.Automation.ConfirmImpact]$Impact -ge [int]$ConfirmPreference`.
   (`$ConfirmPreference` is already a `ConfirmImpact` enum value; `-Confirm:$false`
   sets it to `None` = 0, which never prompts; `-Confirm` sets it to `Low`.)
   Otherwise return `$true`.
4. Prompt: `Read-Host "$Action`n  $Target`n[Y] Yes  [N] No  [A] Yes to all  [S] Stop (default is N)"`.
   `y`/`yes` → `$true`; `a`/`all` → `$State.All[$Impact] = $true`, `$true`; `s`/`stop`
   → `throw "Operation stopped by the operator."`; anything else → `$false`.
5. If `Read-Host` throws (non-interactive host) → `Write-Error -Category
   InvalidOperation -ErrorId DnsTools.Confirm.NonInteractive -Message "This
   session cannot prompt. Re-run with -Force to confirm all actions, or
   -WhatIf to preview."` → return `$false`.

The public function creates `$State = @{ All = @{} }` in `begin {}` (phase 2:
`$Batch.Confirm` from `New-DnsBatch`) and passes it to every call; `-Force`
is the public function's own switch. "Yes to all" is remembered **per
impact level** (changed in phase 2), so an `A` on a Medium prompt never
approves a later High action such as `CreateZone`.
`$WhatIfPreference` and `$ConfirmPreference` reach the helper by dynamic
scoping from the public function that bound `-WhatIf`/`-Confirm`.

---

## 11. Change log (`Write-DnsChangeLog`)

```powershell
Write-DnsChangeLog -Entry <hashtable> [-LogPath <string>]
```
Appends exactly one line of compact JSON to the log. Path resolution:
`-LogPath` → `$env:DNSTOOLS_LOGPATH` → `$env:LOCALAPPDATA\DnsTools\log\DnsTools_<yyyy-MM>.jsonl`.
Creates the directory. Writes with `Add-Content -Encoding UTF8 -WhatIf:$false
-Confirm:$false`; on `IOException` waits 200 ms and retries once; on any
failure `Write-Warning` with the path and reason – **never throws**.
`-WhatIf` runs are logged too (`Result = 'WhatIf'`).

Line schema (all keys always present, `null` when not applicable):

```json
{"Id":"<guid>","BatchId":"<guid>","Timestamp":"2026-10-09T15:00:00.0000000+02:00",
 "Operator":"DOMAIN\\user","Server":"dc01","Action":"RemoveA","Zone":"contoso.local",
 "NodeName":"srv01","Name":"srv01.contoso.local","Type":"A","Data":"10.0.16.5",
 "Before":{"Data":"10.0.16.5","Ttl":3600,"Timestamp":null,"IsStatic":true},
 "After":null,"Result":"Success","Error":null}
```
`Name` (owner FQDN) and `Data` (the address or target the sub-operation is
about) are on every line (added 2026-10-11), so a `WhatIf` or `Failed` line
without `Before`/`After` still says which record it concerns.
Encoding facts (verified): 5.1 writes a BOM when it creates the file, 7 does
not; both read either; a BOM is never written mid-file. Readers use
`Get-Content -Encoding UTF8 <file> | ConvertFrom-Json`.

---

## 12. Objects

All created through `New-DnsObject`. Property **order is the contract**
(tables and CSV exports depend on it). `[string[]]` properties are `@()`
when evaluated and empty, `$null` when **not evaluated** (e.g. no snapshot
available to compute `Aliases` for a live hit).

### 12.1 `DnsTools.Entry`

| # | Property | Type | Notes |
|---|---|---|---|
| 1 | `Name` | string | FQDN, lower-case, no trailing dot, `\DDD` decoded |
| 2 | `Type` | string | `A`, `AAAA`, `CNAME` |
| 3 | `Data` | string | canonical address, or CNAME target FQDN |
| 4 | `TTL` | int | seconds |
| 5 | `PtrStatus` | string | `Ok`, `Missing`, `WrongTarget`, `Shadowed`, `Delegated`, `Multiple`, `NoReverseZone`, `NotApplicable` (CNAME) |
| 6 | `Zone` | string | lower-case |
| 7 | `NodeName` | string | exactly as stored (`@`, `srv01`, `5`) |
| 8 | `Timestamp` | datetime / $null | $null = static |
| 9 | `IsStatic` | bool | |
| 10 | `HasDhcid` | bool / $null | a DHCID record exists at the node; $null when no snapshot was available to tell |
| 11 | `InDhcpRange` | bool | address matches `-MarkDhcpRange` |
| 12 | `ReverseZone` | string / $null | expected (longest hosted) reverse zone for `Data`; $null for CNAME or when none |
| 13 | `PtrTargets` | string[] / $null | targets of PTR records found at the expected node |
| 14 | `PtrZoneFound` | string / $null | zone where a PTR was actually found (differs from `ReverseZone` when `Shadowed`/`Delegated`) |
| 15 | `SharedWith` | string[] / $null | other names with an A/AAAA for the same address |
| 16 | `Aliases` | string[] / $null | CNAME owners pointing at `Name` |
| 17 | `ReferencedBy` | string[] / $null | `"SRV:_ldap._tcp.contoso.local"`, `"NS:contoso.local"`, `"MX:contoso.local"` |
| 18 | `Target` | string / $null | CNAME target |
| 19 | `TargetExists` | bool / $null | CNAME only: target has A/AAAA/CNAME in the snapshot |
| 20 | `DistinguishedName` | string / $null | from live record |
| 21 | `Owner` | string / $null | phase 4 |
| 22 | `Server` | string | |
| 23 | `Source` | string | `Live` or `Snapshot` |
| 24 | `SnapshotAge` | timespan / $null | age of the oldest zone export used to populate snapshot-derived fields; $null when none used |

**PtrStatus rules** (A/AAAA only), evaluated against the server's zone table:
- No hosted reverse zone covers the address → `NoReverseZone`.
- Expected zone = longest covering zone (classless zones count as longer
  than their parent). Look at that zone's node first:
  - CNAME at the node (RFC 2317 parent) → `Delegated`; `PtrZoneFound` =
    the zone that hosts the CNAME target if hosted (one hop), else `$null`.
  - No PTR there → look in each shorter covering zone; PTR found →
    `Shadowed` with `PtrZoneFound`; none anywhere → `Missing`.
  - PTR(s) there: if any target equals `Name`, or equals another name that
    has an A/AAAA with this address (`SharedWith`) → `Ok` (if more than one
    PTR exists → `Multiple`); otherwise `WrongTarget`.
- Live entries evaluate PTR with live lookups; snapshot entries use the
  `Ptr` index. `SharedWith` needs the `Addr` index; without a snapshot it
  is `$null` and the "equals a SharedWith name" clause is skipped.

### 12.2 `DnsTools.Result`

| # | Property | Type |
|---|---|---|
| 1 | `Action` | string: `RemovePtr`, `RemoveA`, `RemoveAAAA`, `RemoveCName`, `RemoveDhcid`, `AddA`, `AddAAAA`, `AddPtr`, `AddCName`, `SetTtl`, `SetAddress`, `SetTarget`, `SetPtrTarget`, `CreateZone`, `SetZoneAging`, `ExportZone`, `Backup` |
| 2 | `Name` | string (FQDN) |
| 3 | `Type` | string |
| 4 | `Data` | string / $null |
| 5 | `Result` | string: `Success`, `Failed`, `Skipped`, `WhatIf`, `AlreadyDone`, `Pending` |
| 6 | `Error` | string / $null |
| 7 | `Zone` | string |
| 8 | `NodeName` | string |
| 9 | `Server` | string |
| 10 | `Id` | string (guid) |
| 11 | `BatchId` | string (guid) |
| 12 | `Timestamp` | datetime |

`Error` holds the reason for `Skipped` as well as for `Failed` (§5.9).
`Data` for `CreateZone` is the NetworkId, for `Backup` the local file path.

### 12.3 `DnsTools.Snapshot`

`Server` · `Zone` · `ExportedAt` (datetime) · `Age` (timespan) · `IsReverse`
· `ZoneType` · `ReplicationScope` · `DirectoryPartitionName` ·
`DynamicUpdate` · `AgingEnabled` · `FileSizeBytes` · `Path` (local file).

### 12.4 `DnsTools.ZoneTable`, `DnsTools.ZoneInfo` – §8. `DnsTools.Issue` – phase 3, reserved.

---

## 13. Public commands

### 13.1 `Get-DnsEntry`

```powershell
Get-DnsEntry [-Find] <string[]> [-Server <string[]>] [-Zone <string>] [-Exact] [-First <int>]
             [-MarkDhcpRange <string[]>] [-MaxSnapshotAge <timespan>] [-Credential <pscredential>] [-TimeoutSec <int>]
```
- `-Find`: positional 0, `ValueFromPipeline`, `ValueFromPipelineByPropertyName`,
  `[Alias('Name','Identity','HostName','IPAddress','Address')]`. Each value
  is classified independently:
  1. contains `*` or `?` → **pattern**: `-like` over the snapshot `Names`
     (and `Addrs` when the pattern contains only digits, dots, colons, hex
     and wildcards). Requires a snapshot (auto-export on first use, §9.4).
     `-Zone` restricts to owners in that zone.
  2. `ConvertTo-DnsNormalizedAddress` returns non-null (dotted-quad IPv4
     or IPv6 only; a bare `[ipaddress]` cast would accept `12345` and read
     `010.0.0.1` as octal) → **address**: live PTR lookup in every
     covering reverse zone (longest first) + snapshot `Addr` index when a
     snapshot exists (no auto-export for this path). Emits one Entry per
     A/AAAA that has this address; if no snapshot and the PTR target is
     resolvable live, emits the Entry for the PTR target's A record.
  3. ends with a hosted forward zone name → **FQDN**: live
     `Get-DnsServerResourceRecord -ZoneName <zone> -Name <node> -Node`
     for `A`, `AAAA`, `CNAME`.
  4. otherwise (bare label) → with `-Exact` or `-Zone`: live `-Node`
     lookup in `-Zone` (or in every hosted forward zone when `-Zone` is
     absent and `-Exact` is set; warn if more than 10 zones); without both:
     **substring** search `*<label>*` over the snapshot `Names`.
- `-Exact` forces live lookups for cases 3–4 and rejects patterns with an
  error.
- Each hit becomes one `Entry` per A/AAAA/CNAME record (a name with two A
  records yields two entries). Live hits set `Source = Live` and fill
  `SharedWith`/`Aliases`/`ReferencedBy`/`HasDhcid`/`TargetExists` from the
  cached or on-disk snapshot **if one exists** (any age, with `SnapshotAge`
  set); otherwise those are `$null`. Snapshot hits set `Source = Snapshot`
  and `SnapshotAge`.
- `-Server <string[]>`: repeat the whole evaluation per server; entries
  carry `Server`.
- `-First`: stop after N entries in total.
- Nothing found for a value → `Write-Warning "No entry matched '<value>' on
  '<server>'."`, no error.
- Streams output. Uses `Get-DnsZoneTable` once per server.
- `-MarkDhcpRange` is validated once in `begin {}` (invalid CIDR → one
  warning and the entry is dropped), so `Test-DnsAddressInNetwork` never
  warns per entry.

### 13.2 `Get-DnsSnapshot`

```powershell
Get-DnsSnapshot [-Server <string[]>] [-Zone <string[]>]
```
Reads `meta.json` for each server (default server as §6) and emits one
`DnsTools.Snapshot` per zone. No server contact. Missing snapshot folder
→ `Write-Warning`, no output, no error.

### 13.3 `Update-DnsSnapshot`

```powershell
Update-DnsSnapshot [-Server <string>] [-Zone <string[]>] [-Credential] [-TimeoutSec] [-Force] [-WhatIf] [-Confirm]
```
Exports every exportable zone (§8) or the given zones, writes files and
`meta.json`, rebuilds and caches the index, emits one `DnsTools.Snapshot`
per zone. `Confirm-DnsAction` with impact `Low` guards the export as a
whole (one prompt, not one per zone; `-WhatIf` lists the zones). A zone
that fails to export is a non-terminating error (§5.2) and the remaining
zones continue; the index is still rebuilt from what succeeded, and
`meta.json` keeps the previous entry for the failed zone if one existed.
`-Zone` entries not hosted → non-terminating error. Progress per zone.

### 13.4 `Remove-DnsEntry` (phase 2)

```powershell
Remove-DnsEntry [-Identity <object[]>] [-InputFile <string>] [-Zone <string>] [-KeepPtr] [-KeepAlias] [-AllowReferenced] [-SkipReferenceCheck]
                [-MaxSnapshotAge <timespan>] [-Delay <int>] [-Server <string>] [-Credential] [-TimeoutSec] [-LogPath] [-Force] [-WhatIf] [-Confirm]
# pipeline: DnsTools.Entry objects or strings (ValueFromPipeline), or objects with Name/Identity/HostName/IPAddress/Address (ByPropertyName) -> -Identity
```
Impact `High`, one gate per input item; `[A]ll` sticks for the batch per
impact (§10). Streams: each item is resolved and processed in `process {}`
(§5.7), nothing is collected first. `-Delay` sleeps once per item after
its sub-operations.

Per item:
1. **Resolve** (`Resolve-DnsChangeTarget`), then read live
   (`Get-DnsLiveRecord -Node`). Name → A, AAAA, CNAME, DHCID at the node.
   Address → candidate names from the PTR targets at the expected node of
   every covering reverse zone (`Find-DnsZoneForName -Reverse`, classless
   hop as in §12.1) **and** from `$index.Addr` when a snapshot exists (any
   age; without one, warn once per batch: "A records without a PTR cannot
   be found by address without a snapshot"); keep only the A/AAAA records
   that hold the address. Cname (an Entry of type CNAME) → only that
   record. Nothing found at all → one Result `AlreadyDone` (Action
   `RemoveA`, Data = the identity). PTRs found but no A → they are orphans:
   `RemovePtr` for each (through the gate).
2. **References** (`Get-DnsReference`): any NS, SRV or MX owner pointing at
   the name → the whole item is `Skipped`, one Result per record that would
   have been touched, Error = `"Referenced by 12 SRV, 2 NS and 1 MX records
   (_ldap._tcp.contoso.local, ...). Add -AllowReferenced to remove it
   anyway."` (first three owners listed). `Source = Unavailable` →
   `Skipped` with `"The reference check could not run (root\MicrosoftDNS
   on '<server>' is not reachable). Run Update-DnsSnapshot first, or pass
   -SkipReferenceCheck."` CNAME owners pointing at the name are removed
   last unless `-KeepAlias`; each alias gets its own reference check first
   (an alias that SRV/NS/MX point at is `Skipped`).
3. **PTRs**: the expected node in every covering reverse zone (shadowed
   ones too), only PTRs whose target equals the name. A PTR in a zone with
   `IsReadOnly` → `Skipped` ("not writable on this server") and it does not
   block the A. `-KeepPtr` skips PTR removal entirely (Verbose, no
   Result).
4. **Order** per item: `RemovePtr`* → `RemoveA`/`RemoveAAAA`* →
   `RemoveDhcid` (only when the last A/AAAA at the node was removed and a
   DHCID exists) → `RemoveCName`* (aliases). A **write failure** on a PTR in
   a writable zone → the A/AAAA records are `Skipped` with Error "kept to
   avoid an orphaned PTR". A failed alias blocks nothing.
5. **Gate**: `Confirm-DnsAction -Impact High -Action 'Remove DNS records'
   -Target "srv01.contoso.local: remove 2 PTR, 1 A, 1 CNAME alias"`. Under
   `-WhatIf` the gate prints one line per item and every sub-operation
   yields a Result `WhatIf`, logged.
6. **Execute**: each sub-operation re-reads the record (still present with
   the same Data) → `Remove-DnsLiveRecord` → `Write-DnsResult` with
   `Before`. `AlreadyGone` → `AlreadyDone`. A dynamic record (Timestamp
   set) → `Write-Warning` per record and a count in the end-of-batch
   Verbose summary; the help explains that the client or DHCP may
   re-register it and that the dnsNode tombstone (about 7 days) keeps the
   old ACL.
7. Entry objects whose `Server` differs from `-Server` → one warning per
   item. `-InputFile`: lines, or CSV with a `Name` column. A zone with more
   than the default zone scope (`Get-DnsServerZoneScope`, once per zone per
   batch) → one warning per zone.

Errors: `PatternNotAllowed`, `ZoneNotFound` per item (non-terminating);
unreachable server or `Confirm.NonInteractive` → terminating after the
first occurrence (§5.8).

`-KeepPtr` on a server that deletes the PTR with the A record (live fact,
§13.9): after `RemoveA`/`RemoveAAAA` the expected PTR is read again; when it
is gone, one Result `RemovePtr` with `Result = Success` and Error
`"Removed by the DNS server together with the A record; -KeepPtr cannot be
honoured on this server."` is written (Before from the read before the
removal) and one warning per run says the same. DnsTools never re-creates
the PTR.

### 13.5 `New-DnsEntry` (phase 2)

```powershell
New-DnsEntry -Name <string> -Address <string[]> [-TTL <int>] [-NoPtr] [-CreateReverseZone] [-ReplacePtr] [-Zone <string>] [common]   # set Host
New-DnsEntry -Name <string> -Target <string> [-TTL <int>] [-Zone <string>] [common]                                                  # set Alias (CNAME)
New-DnsEntry -InputFile <string> [-NoPtr] [-CreateReverseZone] [-ReplacePtr] [-Zone <string>] [common]                               # set File (CSV: Name, Address|Target[, TTL][, Zone])
# common: [-Delay <int>] [-Server <string>] [-Credential] [-TimeoutSec] [-LogPath] [-Force] [-WhatIf] [-Confirm]; pipeline by property name into Host/Alias
```
Impact `Medium`; the `CreateZone` step is `High`. `-TTL` in seconds (alias
`TimeToLive`); without it the zone default applies (no `-TimeToLive`
passed). Records are static. `-Name` is the record owner for both sets
(DnsServer's `-HostNameAlias` names the *target*, so "alias" is never a
parameter name here).

Preflight per item, nothing written until every check passed: zone from
the FQDN (`Find-DnsZoneForName`) or `-Zone` + bare name; the node has a
CNAME → `Failed` (`NodeIsCname`); Alias set and the node has any record →
`Failed` (`CnameCollision`); an NS record on any ancestor label inside the
zone (live, one `Get-DnsLiveRecord -RRType NS` per label) → `Failed`
(`Delegated`); reverse zone for the address missing and neither `-NoPtr`
nor `-CreateReverseZone` → `Failed` (`NoReverseZone`, the message names
both switches) **and the A is not created**; the expected reverse node is
an RFC 2317 CNAME → the PTR goes into the classless zone when hosted, else
`Failed` (`Delegated`).

Then: `AddA`/`AddAAAA` per address (identical record → `AlreadyDone`;
same address with another TTL → `AlreadyDone` plus a warning); `AddPtr`
(PTR with the same target → `AlreadyDone`; PTR with another target →
`Skipped` unless `-ReplacePtr`, which does `RemovePtr` + `AddPtr`). With
`-CreateReverseZone` the /24 (IPv4) or /64 (IPv6) zone around the address
is created through `New-DnsLiveReverseZone -Batch $batch -CopySettingsFrom
<forward zone>` (§7.5: same BatchId, [A]ll at High carries to the next item)
before `AddPtr`; under `-WhatIf` a `CreateZone` with `Result = WhatIf`
counts as created for the PTR step and `Get-DnsZoneTable -Refresh` is
skipped. A write that fails with 9709 (CNAME collision: another record type at the node) →
`Failed` (`CnameCollision`).

### 13.6 `Set-DnsEntry` (phase 2)

```powershell
Set-DnsEntry [-Identity <object[]>] [-Zone <string>] [-TTL <int>] [-Address <string>] [-PtrTarget <string>] [-Target <string>]
             [-ReplacePtr] [-IncludeDynamic] [-Delay <int>] [-Server <string>] [-Credential] [-TimeoutSec] [-LogPath] [-Force] [-WhatIf] [-Confirm]
# pipeline as in 13.4. At least one of -TTL, -Address, -PtrTarget, -Target, else a terminating error.
```
Impact: `-Address` `High`, the others `Medium`.
- Requested value equals the current value → `AlreadyDone`.
- `-TTL` on an A/AAAA record without WMI (`WmiUnavailable`): retry with
  `Set-DnsLiveRecord -UseDnsServerCmdlet`; afterwards the PTR that pointed
  at the name is gone (live fact), so the PTR's `SetTtl` becomes `RemovePtr`
  (`Success`, Error `"Removed by the DNS server together with the A record
  change."`, Before from the earlier read) plus `AddPtr` with the new TTL.
  One warning per run: `"root\MicrosoftDNS on '<server>' is not available;
  TTL changes of A/AAAA records re-create their PTR records."`
- Order for `-Address`: `RemovePtr` (the old PTR, when it points at the
  name) → `SetAddress` → `AddPtr`, because the server deletes the matching
  PTR as a side effect of the address change (live fact in §7.5); the
  explicit removal first keeps the log complete.
- `-TTL`: every A/AAAA/CNAME at the node (the exact record when the input
  is an Entry) and every PTR that points at the name → `SetTtl` each, in
  place (`Set-DnsLiveRecord`).
- `-Address`: exactly one record must be addressed (an Entry, or
  `-Identity` naming a node with a single A/AAAA); several → per-item
  error `Ambiguous` telling the user to pipe the entry from `Get-DnsEntry`.
  `SetAddress` in place, then PTR sync: `RemovePtr` for the old PTR when it
  points at the name, `AddPtr` in the new address's reverse zone (missing
  → `Skipped` + warning; existing PTR with another target → `Skipped`
  unless `-ReplacePtr`).
- `-PtrTarget`: the identity must be an address; the PTR at the expected
  node → `SetPtrTarget`; no PTR → `AddPtr`.
- `-Target`: the identity must be a CNAME → `SetTarget` (9707 CNAME loop →
  `Failed`).
- Dynamic records (A, AAAA or PTR with a Timestamp) → `Skipped` with Error
  `"Dynamic record, owned by the client or the DHCP server; re-register it
  instead, or pass -IncludeDynamic."` unless `-IncludeDynamic` → warning
  and proceed. After every Set the record is re-read and `After.Timestamp`
  is logged; the help states what the server does to the timestamp
  (decided by the live test).

### 13.7 `New-DnsReverseZone` (phase 2)

```powershell
New-DnsReverseZone -NetworkId <string> -CopySettingsFrom <string> [-ReplicationScope <Domain|Forest|Legacy|Custom>] [-DynamicUpdate <None|NonsecureAndSecure|Secure>]
                   [-Server <string>] [-Credential] [-TimeoutSec] [-LogPath] [-Force] [-WhatIf] [-Confirm]
```
Impact `High`. A thin wrapper: `New-DnsBatch`, `Test-DnsWriterServer` (not
under `-WhatIf`), `Get-DnsZoneTable`, then `New-DnsLiveReverseZone` (§7.5),
which does everything below. Zone name from `Get-DnsReverseZoneName` (an
invalid `-NetworkId` → terminating `InvalidNetworkId`; a `-CopySettingsFrom`
zone that is not hosted → `Failed` `ZoneNotFound`). Already hosted on the
server, or 9609 (`DNS_ERROR_ZONE_ALREADY_EXISTS`) from the cmdlet →
`AlreadyDone`. Settings come from the `-CopySettingsFrom`
forward zone (`Get-DnsZoneTable`): `Add-DnsServerPrimaryZone -NetworkId
<id> -ReplicationScope Custom -DirectoryPartitionName <forward zone's
partition> -DynamicUpdate <forward zone's value>` (same result as
Domain/Forest, and right from a child domain too). Forward zone without a
partition (file-backed) or `Legacy` → `Failed` `"... specify
-ReplicationScope"` unless `-ReplicationScope` is given (then that scope is
used as given, with `-DirectoryPartitionName` only for `Custom`). Then
`Set-DnsServerZoneAging -Name <zone> -Aging <bool> -RefreshInterval
-NoRefreshInterval -ScavengeServers ([ipaddress[]])` from the forward zone;
aging fields `$null` → step skipped with a warning. Results: `CreateZone`
(Data = NetworkId), `SetZoneAging` (only when the zone was created, or would
be under `-WhatIf`). Afterwards `Get-DnsZoneTable -Refresh`
(not under `-WhatIf`) and a warning that other DCs see the zone only after
AD replication plus DsPollingInterval (default 180 s).

### 13.8 `Backup-DnsZone` (phase 2)

```powershell
Backup-DnsZone [-Zone <string[]>] [-Path <string>] [-Server <string>] [-Credential] [-TimeoutSec] [-LogPath] [-Force] [-WhatIf] [-Confirm]
# -Path alias BackupPath; default $env:LOCALAPPDATA\DnsTools\backup
```
Impact `Low`, one gate for the run (declined → no output). `Test-DnsWriterServer`
is not called: nothing changes in DNS. Folder `<Path>\<server>-<yyyyMMdd-HHmmss>\`
(never reused: an existing folder → terminating error; the stamp is taken after the gate),
one `backup_<zone>_<yyyyMMdd-HHmmss>.txt` per zone through
`Export-DnsZoneFile`, plus one `RESTORE.md` (English: restore a single
record with `New-DnsEntry`; restore a whole AD-integrated zone with
`dnscmd /zoneadd <zone> /primary /file <file> /load` followed by
`ConvertTo-DnsServerPrimaryZone -ReplicationScope`; note that the SOA
serial and aging timestamps are not restored). Default: every exportable
zone (§8). A requested zone that is not hosted or not exportable → a
`Failed` Result (Data `$null`) and a non-terminating error with the texts of
`Update-DnsSnapshot` (`ZoneNotFound`, `ZoneNotExportable`), written before
the gate; the rest continue. One Result per zone: Action `Backup`, Data =
local file path, `Failed` with the export error (ErrorId `ExportFailed`)
otherwise. `RESTORE.md` is written in `finally` and lists only the files that
exist, so a stop after some zones still leaves instructions; nothing saved →
the empty folder is removed. Known gap: `Export-DnsZoneFile` re-throws as a
plain string, so a server lost mid-run gives per-zone `Failed`, not the §5.8
abort (acceptable: the command only reads).

### 13.9 Shared rules for the change commands

- `New-DnsBatch` in `begin {}`; `Test-DnsWriterServer`; `Import-DnsServerModule`
  through `Get-DnsZoneTable`. Every sub-operation → exactly one
  `Write-DnsResult` call, emitted immediately (streaming).
- `-Force` = zero prompts (§10 rule 2), nothing else. Safety overrides have
  their own switches: `-AllowReferenced`, `-IncludeDynamic`, `-ReplacePtr`,
  `-SkipReferenceCheck`.
- After writes the snapshot index is not patched; one Verbose line per run
  reminds about `Update-DnsSnapshot`.
- `Confirm.NonInteractive` or an unreachable server on the first item →
  terminating error (§5.8); no per-item repetition.
- Live facts 2026-10-13 (labdc01, Windows Server 2025): a change OR a
  removal of an A/AAAA record by any path deletes the PTR that points at
  the name (§7.5 Remove-/Set-DnsLiveRecord). This is VERSION-DEPENDENT:
  older servers commonly leave the PTR behind (the operator's production
  domains are full of such orphans), so the code never assumes either
  way: after a removal or a cmdlet-path change of an A/AAAA record it
  re-reads the expected PTR and acts on what is there (§13.4, §13.6); the server accepted a CNAME
  that points at itself (no 9707), so loops are not detected in phase 2;
  a change of an A/AAAA record through
  `Set-DnsServerResourceRecord` deletes the PTR that points at the name;
  TTL changes therefore go through WMI `Modify` (§7.5). Every change
  clears the aging timestamp: a dynamic record changed with
  `-IncludeDynamic` becomes static, and the help says so.
- Error codes (classified on `FullyQualifiedErrorId`; values checked
  against winerror.h 2026-10-11, which cmdlet raises which is confirmed in
  the live test): 9701 record missing and 9714 name missing (removal →
  `AlreadyDone`), 9711 record exists (add → `AlreadyDone`), 9708 node is a
  CNAME, 9709 CNAME collision, 9707 CNAME loop, 9710 allowed only at the
  apex, 9706 name outside the zone (all `Failed`), 9712 secondary
  (read-only) data → `Skipped`, 9601 zone missing, 5 access denied →
  `Failed`, never `AlreadyDone`, 1722 RPC server unavailable → batch abort.
- The live write helpers return `ErrorId` and `Unreachable`
  (`Test-DnsConnectionError`). `Unreachable = $true` → the command writes
  the item's `Failed` Result, then throws the terminating error of §5.8
  (ErrorId `DnsTools.<Cmd>.ServerUnreachable`, text `"The DNS server '<s>'
  cannot be reached: <error> The run was stopped; the remaining input was
  not processed. Check the server and run the command again."`).
- Aligned 2026-10-11 after the wave-2 review:
  - `-Identity` is `[object[]]`, `ValueFromPipeline` only (never
    `ByPropertyName`): Entry objects, strings, `[ipaddress]`, and objects
    with `Identity`/`Name`/`HostName`/`IPAddress`/`Address` read by hand.
    `[string[]]` would coerce a piped Entry to text and lose the record.
  - `Test-DnsWriterServer` runs only when not under `-WhatIf`: a preview
    never becomes the session's writer server.
  - `-Delay` sleeps once per input item after its sub-operations, failed
    items included, never under `-WhatIf`.
  - The gate is shown only when something is to be written; an item that
    is already in place never prompts. Answer No → every pending
    sub-operation of the item is `Skipped` with Error `"Declined at the
    confirmation prompt."` (logged). `Confirm.NonInteractive` is raised once
    as a terminating error; no Result for the item.
  - PTR sub-operations (`RemovePtr`, `AddPtr`, `SetPtrTarget`, `SetTtl` on a
    PTR): `Name` = the PTR owner FQDN (`20.16.0.10.in-addr.arpa`), `Zone` =
    the reverse zone, `NodeName` = `20`, `Data` = the target name.
  - A Result and its log line are written before the matching `Write-Error`,
    so `-ErrorAction Stop` still leaves the line.
  - `Set-DnsEntry`: `-Address`, `-PtrTarget` and `-Target` exclude each other
    (`ConflictingChanges`); `-TTL` combines with any of them and its `SetTtl`
    runs after the value change; `-Address` equal to the current address →
    `AlreadyDone` and the PTR sync still runs; `-PtrTarget` accepts an A/AAAA
    Entry (its address).
  - `New-DnsEntry`: default parameter set `File` (needed for pipeline
    binding of CSV rows); `-NoPtr` with `-CreateReverseZone` or
    `-ReplacePtr` → terminating error; a preflight failure gives one `Failed`
    Result per requested record and no PTR Results; a PTR that already
    points at this name and at another stays as it is (`AlreadyDone`).
  - `Remove-DnsEntry`: a reference blocks the whole item; with Source
    `Unavailable` the item is skipped even with `-AllowReferenced`
    (`-SkipReferenceCheck` is the override); a read-only forward zone skips
    the whole name including its PTRs; a blank string is skipped with a
    Verbose line; `Before` is logged on `Success`.

---

## 14. Formatting (`DnsTools.Format.ps1xml`)

- `DnsTools.Entry` default table: `Name`, `Type`, `Data`, `TTL`, `PtrStatus`, `Zone`, `Source`.
- `DnsTools.Snapshot` default table: `Server`, `Zone`, `ExportedAt`, `Age`, `ZoneType`, `IsReverse`.
- `DnsTools.Result` default table: `Action`, `Name`, `Data`, `Result`, `Error`.
- `DnsTools.ZoneInfo` default table: `ZoneName`, `ZoneType`, `IsReverse`, `ReplicationScope`, `DynamicUpdate`, `AgingEnabled`.
No `DefaultDisplayPropertySet` via types files (needs a `PSPropertySet`,
blocked in CLM); the format file is enough.

---

## 15. Performance targets (Windows PowerShell 5.1, developer laptop)

| Operation | Target |
|---|---|
| Parse 550 000-line forward zone file | < 20 s |
| Build index from 550k forward + 200k reverse rows | < 10 s additional |
| Peak private memory after index build | < 500 MB |
| `Get-DnsEntry -Find '*sql*'` against built index | first object < 1 s |
| `Get-DnsEntry -Find srv01.contoso.local` (live, snapshot cached) | < 2 s on LAN |
| `Write-Progress` frequency | ≤ 1 update per 10 000 rows and ≤ 1 per 500 ms |

The synthetic generator (`Tests\Tools\New-SyntheticZoneFile.ps1`) must
produce files in the exact export grammar of §9.2, including `[AGE:n]`,
continuation lines, `$ORIGIN`, SOA with parentheses, SRV/MX/NS/CNAME/DHCID/
WINS/TXT, names with `\DDD` escapes and non-ASCII (`åäö`), a delegated
sub-zone block, and a wildcard owner.

---

## 16. Tests

- Pester **5.7.1**, run on **both** `powershell.exe` (5.1) and `pwsh` (7).
  `Invoke-Pester -Path .\DnsTools\Tests` must be green on both.
- Every test file starts with
  `BeforeAll { Import-Module "$PSScriptRoot\..\DnsTools.psd1" -Force }`
  except pure-unit files that dot-source a single `Private\` file.
- **Stubs** (`Tests\Stubs\DnsServerStubs.ps1`): functions with the same
  names and parameters as the DnsServer cmdlets the module calls
  (`Get-DnsServerZone`, `Get-DnsServerZoneAging`, `Get-DnsServerScavenging`,
  `Get-DnsServerResourceRecord` incl. `-Node`, `Export-DnsServerZone`, and in
  later phases `Add-/Remove-/Set-DnsServerResourceRecord*`), backed by a
  script-scope in-memory store. Records are built with `New-Object PSObject`
  and mimic CIM instances: `HostName`, `RecordType`, `RecordData` (object
  with `IPv4Address` / `IPv6Address` / `PtrDomainName` / `HostNameAlias`),
  `TimeToLive` (timespan), `Timestamp` (datetime or $null),
  `DistinguishedName`, `DnsServerZone` properties as needed. Zones mimic
  `Get-DnsServerZone` output. Stubs are loaded **into the module scope**
  (`InModuleScope DnsTools { . "<path>\DnsServerStubs.ps1" }`, or
  `. $module { . $args[0] } $path` in the CLM smoke runner) so that module
  code calls them without `Mock`. Because both forms run in a child scope,
  every stub function is declared as `function script:Name` – later-phase
  stubs must follow the same pattern. Tests must pass with and without
  RSAT installed.
- **Phase-2 stubs** (same file, same `function script:` pattern):
  `Add-DnsServerResourceRecordA/AAAA/CName/Ptr` (`-ZoneName -Name`,
  `-IPv4Address|-IPv6Address|-HostNameAlias|-PtrDomainName`, `-TimeToLive`,
  `-AgeRecord`, `-CreatePtr`, `-PassThru`), `Remove-DnsServerResourceRecord`
  (`-InputObject` from the pipeline, `-Force`), `Set-DnsServerResourceRecord`
  (`-OldInputObject -NewInputObject`), `Add-DnsServerPrimaryZone` (both the
  `-Name` and the `-NetworkId` sets, `-ReplicationScope`,
  `-DirectoryPartitionName`, `-DynamicUpdate`), `Set-DnsServerZoneAging`,
  `Get-DnsServerZoneScope`, and `Get-CimInstance` (`-Namespace
  root\MicrosoftDNS -Query`, with a minimal WQL reader: `FROM <class> WHERE
  ContainerName='z' [AND <prop>='v']`, targets with a trailing dot). Every
  writing stub declares `SupportsShouldProcess`, skips the change when
  `$WhatIfPreference` is set, counts calls, supports `Fail` injection per
  command and zone, returns **copies** of records (so the "fetch twice"
  pattern of `Set-DnsLiveRecord` works), gives records a stable `Id` so
  that `-OldInputObject` can be matched, and raises the error codes of
  §13.9 as `WIN32 <code>` in the FullyQualifiedErrorId.
- **File format tool:** `build\Set-SourceFileFormat.ps1` normalises `.ps1`,
  `.psm1`, `.psd1`, `.ps1xml` and `*.help.txt` only. Zone-file fixtures
  (`Tests\Fixtures\*.txt`) must stay BOM-less with CRLF, like a real export.
- **`ClmCompliance.Tests.ps1`**: parses every module file with
  `[System.Management.Automation.Language.Parser]::ParseFile` (tests run in
  Full language) and asserts zero hits for the §4.1 list using AST node
  types: `ConvertExpressionAst`/`TypeExpressionAst`/`TypeConstraintAst`
  type names; `InvokeMemberExpressionAst` whose root variable is `PSCmdlet`,
  `Host`, `ExecutionContext` or `MyInvocation`, or whose member is `new`,
  `Invoke`, `Create`, `TryParse`, `GetNewClosure`, or a static call on a
  type outside an allow-list; `CommandAst` for `New-Object` (anything but
  `PSObject`), `Add-Type`, `Invoke-Expression`, and the internal write
  cmdlets without `-WhatIf:$false` (from phase 2 also the DnsServer write cmdlets `Add-DnsServerResourceRecordA|AAAA|CName|Ptr`, `Remove-DnsServerResourceRecord`, `Set-DnsServerResourceRecord`, `Add-DnsServerPrimaryZone`, `Set-DnsServerZoneAging`); rule 14: `InvokeMemberExpressionAst` with member `Clone`, and `[ciminstance]::new`; `AssignmentStatementAst` `PlusEquals`
  inside loops/`ForEach-Object`; `TypeDefinitionAst`; `UsingStatementAst`;
  `[ref]`.
- **`ClmSmoke.Tests.ps1`**: starts `powershell.exe -NoProfile
  -NonInteractive -ExecutionPolicy Bypass -File Tests\Clm\Invoke-ClmSmokeTest.ps1`
  as a **child process** (never in the Pester process – one failed cast
  poisons the process, #28128). The runner creates a runspace with
  `InitialSessionState.LanguageMode = 'ConstrainedLanguage'`, imports the
  module, loads the stubs, runs `Get-DnsSnapshot`, `Update-DnsSnapshot -WhatIf`,
  `Get-DnsEntry` and, from phase 2, `Remove-DnsEntry -WhatIf`, `Backup-DnsZone -WhatIf`, `New-DnsEntry
  -WhatIf` and `Set-DnsEntry -WhatIf` (every Result must have `Result =
  WhatIf`) against stub data, and exits non-zero on any error or
  any output containing `Only core types` / `Method invocation is supported
  only on core types`. The Pester test asserts on exit code and output.
  Also run it with `pwsh`.
- **`Help.Tests.ps1`**: for every exported command: `Get-Help -Full` has
  non-empty Synopsis, Description, at least three Examples with remarks,
  Inputs, Outputs, Notes, and a `.PARAMETER` entry for every parameter
  (excluding common parameters).
- **`Encoding.Tests.ps1`**: every `.ps1`/`.psm1`/`.psd1`/`.ps1xml`/`.help.txt`
  starts with the UTF-8 BOM and contains no bare `\n`.
- **`Performance.Tests.ps1`**: tagged `Performance`, excluded by default
  (`-ExcludeTag Performance`), asserts §15 against a generated 550k file.
- **ScriptAnalyzer**: `Invoke-ScriptAnalyzer -Path .\DnsTools -Recurse
  -Settings .\DnsTools\PSScriptAnalyzerSettings.psd1` → zero errors and
  zero warnings. The settings file excludes `PSShouldProcess`
  (ShouldProcess is deliberately not called) and
  `PSUseShouldProcessForStateChangingFunctions` for `New-DnsObject`.

---

## 17. Help and documentation

- Comment-based help in English on every public function: `.SYNOPSIS`,
  `.DESCRIPTION` (what it does, when to use it, what it does **not** do),
  `.PARAMETER` for every parameter, at least three `.EXAMPLE` blocks each
  followed by a prose explanation (one simple, one pipeline, one
  unattended/automation), `.INPUTS`, `.OUTPUTS` (list the object's
  properties), `.NOTES` (limitations: CLM, snapshot age, BOM, aging).
- `en-US\about_DnsTools.help.txt`: concepts (snapshot vs live, PtrStatus
  values and what to do about each, the confirmation gate, the change log),
  everyday workflows, the automation contract, troubleshooting.
- `README.md`: beginner-first, order fixed by the plan: what it does →
  requirements → step-by-step installation (what a module is, where to put
  it, `Unblock-File`, execution policy, `Import-Module`, verification,
  `Install-DnsTools.ps1`, CLM/WDAC note) → first run with `-WhatIf` →
  everyday workflows → automation template → the log → troubleshooting →
  known limitations.

---

## 18. Things to measure, not assume (tracked by the lead)

- Parse and index timings on 5.1 with the synthetic 550k file (§15).
- Whether `[PSTypeName('DnsTools.Entry')]` accepts
  `Deserialized.DnsTools.Entry` (phase 2).
- Exact WQL property names for CNAME/SRV/NS/MX target queries and their
  cost on a 550k zone (phase 2).
- `Export-DnsServerZone` duration and locking on the 550k zone (phase 5).
- DnsServer import under policy-driven CLM (phase 5).
