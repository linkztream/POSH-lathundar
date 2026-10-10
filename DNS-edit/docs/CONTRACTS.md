# DnsLathund – Engineering Contracts

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
DNS-edit/
  README.md                         User documentation (English, beginner-first)
  dns_edit.md                       General PowerShell DNS cheat sheet (kept)
  Install-DnsLathund.ps1            One-click installer for beginners
  docs/CONTRACTS.md                 This file
  DnsLathund/                       The module (this folder is what gets installed)
    DnsLathund.psd1
    DnsLathund.psm1
    DnsLathund.Format.ps1xml
    PSScriptAnalyzerSettings.psd1
    en-US/about_DnsLathund.help.txt
    Private/<Verb-DnsNoun>.ps1       One function per file, file name = function name
    Public/<Verb-DnsNoun>.ps1        One function per file, exported
    Tests/
      *.Tests.ps1                    Pester 5
      Fixtures/                      Zone file samples
      Stubs/DnsServerStubs.ps1       Duck-typed stand-ins for DnsServer cmdlets
      Clm/Invoke-ClmSmokeTest.ps1    Child-process CLM smoke runner
      Tools/New-SyntheticZoneFile.ps1
```

`DnsLathund.psm1` dot-sources every `Private\*.ps1` then every `Public\*.ps1`
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

### 4.2 Allowed and relied upon

`New-Object PSObject -Property <IDictionary>` · `Add-Member -NotePropertyName`
/ `-TypeName` · `[PSTypeName('DnsLathund.Entry')]` parameter attribute ·
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

`DnsLathund.psm1` sets `$script:LanguageMode = [string]$ExecutionContext.SessionState.LanguageMode`
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
   -ErrorId <DnsLathund.<Function>.<Reason>> -TargetObject <name>`
   (non-terminating) **and** a `Result` object with `Result = 'Failed'`.
   Callers choose `-ErrorAction Stop`.
2b. **Live lookups** (`Get-DnsLiveRecord`) call the DnsServer cmdlet with
   `-ErrorAction SilentlyContinue -ErrorVariable <local>` and classify each
   error: a `FullyQualifiedErrorId` containing `9714`
   (DNS_ERROR_NAME_DOES_NOT_EXIST) or category `ObjectNotFound` means "no
   record" (no output, no error, one Verbose line); anything else becomes a
   non-terminating `Write-Error` with the original category and ErrorId
   `DnsLathund.Get-DnsLiveRecord.LookupFailed`, and the lookup yields
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

---

## 6. Common parameters (every public command)

| Parameter | Type | Semantics |
|---|---|---|
| `-Server` | `[string[]]` on `Get-*`, `[string]` on everything else; alias `ComputerName` | DNS server(s) to talk to. Default: `$env:LOGONSERVER` with leading `\\` removed. If that is empty, the parameter is effectively mandatory: throw `"No default DNS server (LOGONSERVER is not set). Specify -Server."` Resolved value is written to Verbose. |
| `-Credential` | `[pscredential]`, attribute `[System.Management.Automation.Credential()]`, `[AllowNull()]` | Alternate credentials. DnsServer cmdlets lack `-Credential`, so when it is given **every** DnsServer call goes through a CIM session (`Get-DnsServerParameter`). If no session can be opened the call **throws**. Never fall back to the logged-on user silently. |
| `-TimeoutSec` | `[int]`, default 300 | Operation timeout for CIM queries and remote commands where the underlying cmdlet supports it. |
| `-LogPath` | `[string]` | Change-log file (§11). Phase 1 commands accept it only where they log (none do in phase 1 except reserved for `-IncludeOwner` in phase 4); do not add it to `Get-DnsEntry` yet. |
| `-WhatIf` / `-Confirm` / `-Force` | via `SupportsShouldProcess` + `[switch]$Force` | On commands that change state (phase 2+). Phase 1 public commands do not change DNS, so they do not declare `SupportsShouldProcess`. `Update-DnsSnapshot` writes local files only; it declares `SupportsShouldProcess` and uses `Confirm-DnsAction` with impact `Low` for the export. |

---

## 7. Module state and shared helpers (phase 1)

### 7.1 Script-scope state (initialised in the psm1)

```powershell
$script:ModuleRoot          = $PSScriptRoot
$script:LanguageMode        = [string]$ExecutionContext.SessionState.LanguageMode
$script:ZoneTableCache      = @{}   # key: server (lower-case) -> zone table object (§8)
$script:CimSessionCache     = @{}   # key: server (lower-case) -> CimSession or 'Unavailable'
$script:SnapshotIndexCache  = @{}   # key: server (lower-case) -> index hashtable (§9.3)
$script:DnsServerModuleChecked = $false
```

`$ExecutionContext.SessionState.Module.OnRemove` closes cached CIM sessions
(wrapped in try/catch; property assignment is allowed in CLM).

### 7.2 `New-DnsObject`

```powershell
New-DnsObject -TypeName <string> -Property <System.Collections.IDictionary>
```
Returns one `PSObject` whose `PSObject.TypeNames[0]` is `DnsLathund.<TypeName>`
and whose properties are exactly the dictionary entries, **in dictionary
order** (callers pass `[ordered]@{}`). Implementation:
`New-Object -TypeName PSObject -Property $Property`, then
`Add-Member -InputObject $obj -TypeName "DnsLathund.$TypeName"`, return
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
ConvertTo-DnsNormalizedName -Name <string>           # -> lower-case, trailing dot removed, \DDD escapes decoded as OCTAL (\040 -> ' ', \050 -> '('), surrounding whitespace trimmed; '' -> ''
                                                     # Windows DNS writes \DDD in OCTAL, not the decimal of RFC 1035. Verified 2026-10-09: a live PTR target
                                                     # 'iO Sense.pangkaka.com.' was exported as 'iO\040Sense.pangkaka.com.'. Decode d1*64 + d2*8 + d3 (no [Convert], it is blocked in CLM).
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

---

## 8. Zone table

```powershell
Get-DnsZoneTable -Server <string> [-Credential <pscredential>] [-TimeoutSec <int>] [-Refresh]
```
Returns (and caches per server) a `DnsLathund.ZoneTable` object:

| Property | Type | Content |
|---|---|---|
| `Server` | string | lower-case |
| `RetrievedAt` | datetime | |
| `Zones` | object[] | one `DnsLathund.ZoneInfo` per zone (below) |
| `ZoneLookup` | hashtable | zone name (lower) → ZoneInfo |
| `ForwardZones` | string[] | lower-case names, all zone types |
| `ReverseZones` | string[] | lower-case names, all zone types |
| `ClasslessZones` | object[] | ZoneInfo of RFC 2317 zones (§8.3) |
| `ServerScavenging` | object | `ScavengingState`, `ScavengingInterval`, `LastScavengeTime` from `Get-DnsServerScavenging` ($null if the call fails, with a warning) |

`DnsLathund.ZoneInfo`: `ZoneName` (lower) · `IsReverse` · `ZoneType`
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
  **octal** (Windows writes `\040` for a space; see §7.4). Apex
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

Root: `$env:LOCALAPPDATA\DnsLathund\snapshot\<server>\` (server lower-case).
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
2. `-Force` or `$State.All` → return `$true`.
3. Prompt **only if** `$ConfirmPreference -ne 'None'` **and**
   `[int][System.Management.Automation.ConfirmImpact]$Impact -ge [int]$ConfirmPreference`.
   (`$ConfirmPreference` is already a `ConfirmImpact` enum value; `-Confirm:$false`
   sets it to `None` = 0, which never prompts; `-Confirm` sets it to `Low`.)
   Otherwise return `$true`.
4. Prompt: `Read-Host "$Action`n  $Target`n[Y] Yes  [N] No  [A] Yes to all  [S] Stop (default is N)"`.
   `y`/`yes` → `$true`; `a`/`all` → `$State.All = $true`, `$true`; `s`/`stop`
   → `throw "Operation stopped by the operator."`; anything else → `$false`.
5. If `Read-Host` throws (non-interactive host) → `Write-Error -Category
   InvalidOperation -ErrorId DnsLathund.Confirm.NonInteractive -Message "This
   session cannot prompt. Re-run with -Force to confirm all actions, or
   -WhatIf to preview."` → return `$false`.

The public function creates `$State = @{ All = $false }` in `begin {}` and
passes it to every call; `-Force` is the public function's own switch.
`$WhatIfPreference` and `$ConfirmPreference` reach the helper by dynamic
scoping from the public function that bound `-WhatIf`/`-Confirm`.

---

## 11. Change log (`Write-DnsChangeLog`)

```powershell
Write-DnsChangeLog -Entry <hashtable> [-LogPath <string>]
```
Appends exactly one line of compact JSON to the log. Path resolution:
`-LogPath` → `$env:DNSLATHUND_LOGPATH` → `$env:LOCALAPPDATA\DnsLathund\log\DnsLathund_<yyyy-MM>.jsonl`.
Creates the directory. Writes with `Add-Content -Encoding UTF8 -WhatIf:$false
-Confirm:$false`; on `IOException` waits 200 ms and retries once; on any
failure `Write-Warning` with the path and reason – **never throws**.
`-WhatIf` runs are logged too (`Result = 'WhatIf'`).

Line schema (all keys always present, `null` when not applicable):

```json
{"Id":"<guid>","BatchId":"<guid>","Timestamp":"2026-10-09T15:00:00.0000000+02:00",
 "Operator":"DOMAIN\\user","Server":"dc01","Action":"RemoveA","Zone":"contoso.local",
 "NodeName":"srv01","Type":"A","Before":{"Data":"10.0.16.5","Ttl":3600,"Timestamp":null,"IsStatic":true},
 "After":null,"Result":"Success","Error":null}
```
Encoding facts (verified): 5.1 writes a BOM when it creates the file, 7 does
not; both read either; a BOM is never written mid-file. Readers use
`Get-Content -Encoding UTF8 <file> | ConvertFrom-Json`.

---

## 12. Objects

All created through `New-DnsObject`. Property **order is the contract**
(tables and CSV exports depend on it). `[string[]]` properties are `@()`
when evaluated and empty, `$null` when **not evaluated** (e.g. no snapshot
available to compute `Aliases` for a live hit).

### 12.1 `DnsLathund.Entry`

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
| 11 | `InDhcpRange` | bool | address matches `-ExcludeNetwork` |
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

### 12.2 `DnsLathund.Result`

| # | Property | Type |
|---|---|---|
| 1 | `Action` | string: `RemovePtr`, `RemoveA`, `RemoveAAAA`, `RemoveCName`, `RemoveDhcid`, `AddA`, `AddAAAA`, `AddPtr`, `AddCName`, `SetTtl`, `SetAddress`, `SetTarget`, `SetPtrTarget`, `CreateZone`, `ExportZone`, `Backup` |
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

### 12.3 `DnsLathund.Snapshot`

`Server` · `Zone` · `ExportedAt` (datetime) · `Age` (timespan) · `IsReverse`
· `ZoneType` · `ReplicationScope` · `DirectoryPartitionName` ·
`DynamicUpdate` · `AgingEnabled` · `FileSizeBytes` · `Path` (local file).

### 12.4 `DnsLathund.ZoneTable`, `DnsLathund.ZoneInfo` – §8. `DnsLathund.Issue` – phase 3, reserved.

---

## 13. Public commands – phase 1

### 13.1 `Get-DnsEntry`

```powershell
Get-DnsEntry [-Find] <string[]> [-Server <string[]>] [-Zone <string>] [-Exact] [-First <int>]
             [-ExcludeNetwork <string[]>] [-MaxSnapshotAge <timespan>] [-Credential <pscredential>] [-TimeoutSec <int>]
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
- `-ExcludeNetwork` is validated once in `begin {}` (invalid CIDR → one
  warning and the entry is dropped), so `Test-DnsAddressInNetwork` never
  warns per entry.

### 13.2 `Get-DnsSnapshot`

```powershell
Get-DnsSnapshot [-Server <string[]>] [-Zone <string[]>]
```
Reads `meta.json` for each server (default server as §6) and emits one
`DnsLathund.Snapshot` per zone. No server contact. Missing snapshot folder
→ `Write-Warning`, no output, no error.

### 13.3 `Update-DnsSnapshot`

```powershell
Update-DnsSnapshot [-Server <string>] [-Zone <string[]>] [-Credential] [-TimeoutSec] [-Force] [-WhatIf] [-Confirm]
```
Exports every exportable zone (§8) or the given zones, writes files and
`meta.json`, rebuilds and caches the index, emits one `DnsLathund.Snapshot`
per zone. `Confirm-DnsAction` with impact `Low` guards the export as a
whole (one prompt, not one per zone; `-WhatIf` lists the zones). A zone
that fails to export is a non-terminating error (§5.2) and the remaining
zones continue; the index is still rebuilt from what succeeded, and
`meta.json` keeps the previous entry for the failed zone if one existed.
`-Zone` entries not hosted → non-terminating error. Progress per zone.

---

## 14. Formatting (`DnsLathund.Format.ps1xml`)

- `DnsLathund.Entry` default table: `Name`, `Type`, `Data`, `TTL`, `PtrStatus`, `Zone`, `Source`.
- `DnsLathund.Snapshot` default table: `Server`, `Zone`, `ExportedAt`, `Age`, `ZoneType`, `IsReverse`.
- `DnsLathund.Result` default table: `Action`, `Name`, `Data`, `Result`, `Error`.
- `DnsLathund.ZoneInfo` default table: `ZoneName`, `ZoneType`, `IsReverse`, `ReplicationScope`, `DynamicUpdate`, `AgingEnabled`.
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
  `Invoke-Pester -Path .\DnsLathund\Tests` must be green on both.
- Every test file starts with
  `BeforeAll { Import-Module "$PSScriptRoot\..\DnsLathund.psd1" -Force }`
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
  (`InModuleScope DnsLathund { . "<path>\DnsServerStubs.ps1" }`, or
  `. $module { . $args[0] } $path` in the CLM smoke runner) so that module
  code calls them without `Mock`. Because both forms run in a child scope,
  every stub function is declared as `function script:Name` – later-phase
  stubs must follow the same pattern. Tests must pass with and without
  RSAT installed.
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
  cmdlets without `-WhatIf:$false`; `AssignmentStatementAst` `PlusEquals`
  inside loops/`ForEach-Object`; `TypeDefinitionAst`; `UsingStatementAst`;
  `[ref]`.
- **`ClmSmoke.Tests.ps1`**: starts `powershell.exe -NoProfile
  -NonInteractive -ExecutionPolicy Bypass -File Tests\Clm\Invoke-ClmSmokeTest.ps1`
  as a **child process** (never in the Pester process – one failed cast
  poisons the process, #28128). The runner creates a runspace with
  `InitialSessionState.LanguageMode = 'ConstrainedLanguage'`, imports the
  module, loads the stubs, runs `Get-DnsSnapshot`, `Update-DnsSnapshot -WhatIf`
  and `Get-DnsEntry` against stub data, and exits non-zero on any error or
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
- **ScriptAnalyzer**: `Invoke-ScriptAnalyzer -Path .\DnsLathund -Recurse
  -Settings .\DnsLathund\PSScriptAnalyzerSettings.psd1` → zero errors and
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
- `en-US\about_DnsLathund.help.txt`: concepts (snapshot vs live, PtrStatus
  values and what to do about each, the confirmation gate, the change log),
  everyday workflows, the automation contract, troubleshooting.
- `README.md`: beginner-first, order fixed by the plan: what it does →
  requirements → step-by-step installation (what a module is, where to put
  it, `Unblock-File`, execution policy, `Import-Module`, verification,
  `Install-DnsLathund.ps1`, CLM/WDAC note) → first run with `-WhatIf` →
  everyday workflows → automation template → the log → troubleshooting →
  known limitations.

---

## 18. Things to measure, not assume (tracked by the lead)

- Parse and index timings on 5.1 with the synthetic 550k file (§15).
- Whether `[PSTypeName('DnsLathund.Entry')]` accepts
  `Deserialized.DnsLathund.Entry` (phase 2).
- Exact WQL property names for CNAME/SRV/NS/MX target queries and their
  cost on a 550k zone (phase 2).
- `Export-DnsServerZone` duration and locking on the 550k zone (phase 5).
- DnsServer import under policy-driven CLM (phase 5).
