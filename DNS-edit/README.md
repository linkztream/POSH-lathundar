# DnsLathund

A PowerShell module for finding and checking DNS records in large Microsoft
DNS (Active Directory-integrated) environments.

## 1. What DnsLathund does

DnsLathund finds A, AAAA and CNAME records and shows, for each one, whether its
PTR (reverse lookup) record is correct. It was built for zones with hundreds of
thousands of records, where DNS Manager and an unfiltered
`Get-DnsServerResourceRecord` time out, by exporting each zone once into a local
snapshot and searching that snapshot. Searching never changes a record.

Status: this version has three commands, and none of them changes DNS.

| Command | What it does |
|---|---|
| `Get-DnsEntry` | Finds A, AAAA and CNAME records by name, address or pattern and reports the PTR status of each. |
| `Get-DnsSnapshot` | Lists the zones in the local snapshot with their export time and age. Contacts no server. |
| `Update-DnsSnapshot` | Exports zones from a DNS server into the local snapshot. Writes local files only. |

The commands that change records are planned (see
[Everyday workflows](#5-everyday-workflows)). The rules below describe how they
are planned to behave. None of them exists in this version.

**What the planned change commands will never do without asking**

- They will never change DNS on their own. A change happens only after you
  previewed it with `-WhatIf`, answered the confirmation prompt, or passed
  `-Force` (`-Force` means "no prompts at all", for unattended runs).
- `Remove-DnsEntry` (planned for phase 2) will refuse to remove a name that an
  NS or SRV record still points at, unless you pass the switch
  `-IncludeInfrastructure`.
- They will never create a PTR record for a dynamic record (one with a
  timestamp, registered by DHCP or by the client itself).
- Every change will be written to the change log (see
  [The change log](#7-the-change-log)).

## 2. Requirements

- **Windows PowerShell 5.1 or PowerShell 7** (check: `$PSVersionTable.PSVersion`).
- **RSAT: DNS Server Tools** (provides the `DnsServer` module). Install it once
  from an elevated (administrator) PowerShell:

  ```powershell
  Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0   # Windows 10 / 11
  Install-WindowsFeature RSAT-DNS-Server                          # Windows Server
  Get-Command Get-DnsServerResourceRecord                         # check: must print a command, not an error
  ```

  DnsLathund installs and imports without RSAT. `Get-DnsEntry` and
  `Update-DnsSnapshot` report a missing `DnsServer` module the first time they
  need it; `Get-DnsSnapshot` never needs it.
- **DNS permissions.** An account that may export zones on the server:
  membership of `DnsAdmins` or `Administrators`. Domain Admins is not required.
  Copying the zone export back from the server is a separate step (next point)
  and may need more than `DnsAdmins`.
- **Network access to the DNS server.** Queries use the DnsServer cmdlets
  (CIM over WinRM, TCP 5985/5986). A zone export is a file that the server
  writes into `%windir%\System32\dns`, so `Update-DnsSnapshot` must also copy
  it back. It tries, in this order: a plain local copy when the server is the
  computer you are on; the `admin$` share of the server
  (`\<server>\admin$\System32\dns`, TCP 445, normally needs local
  administrator rights on the server; not used together with `-Credential`);
  WinRM (`Invoke-Command`, needs permission to open a remote PowerShell
  session). If all of them are blocked for your account, snapshots fail (see
  [Troubleshooting](#8-troubleshooting)).

## 3. Installation, step by step

If you would rather click than type, skip to
[The one-click installer](#the-one-click-installer).

### What a module is, and where PowerShell looks

A PowerShell module is a folder of script files that adds commands to
PowerShell. DnsLathund is the folder `DnsLathund`. Installing it means placing
that folder where PowerShell looks for modules (`$env:PSModulePath -split ';'`
lists them). Two of those folders belong to you and need no administrator rights:
`Documents\WindowsPowerShell\Modules` for Windows PowerShell 5.1 and
`Documents\PowerShell\Modules` for PowerShell 7. Your Documents folder is often
redirected (OneDrive or a network share), for example
`C:\Users\you\OneDrive - Company\Documents`, so do not guess the path; the
commands below ask PowerShell for it.

### Copy the folder

Copy the whole `DnsLathund` folder (the one that contains `DnsLathund.psd1`) into
that module folder. The folder name must be exactly `DnsLathund`, and the result
must be `...\Modules\DnsLathund\DnsLathund.psd1`, not one folder deeper (a common
mistake after unzipping). From the folder that holds the download:

```powershell
$modules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'   # PowerShell 7: 'PowerShell\Modules'
New-Item -ItemType Directory -Path $modules -Force | Out-Null
Copy-Item -Path .\DnsLathund -Destination $modules -Recurse -Force
Test-Path (Join-Path $modules 'DnsLathund\DnsLathund.psd1')    # must print True
```

When upgrading, delete the old `DnsLathund` folder first so no old files remain.

### Unblock the files

Files downloaded from the internet carry a "blocked" mark, and PowerShell may
refuse to run blocked script files. In the same window, remove the mark (or
unblock the downloaded `.zip` in its Properties before extracting it):

```powershell
Get-ChildItem (Join-Path $modules 'DnsLathund') -Recurse | Unblock-File
```

### The execution policy

The *execution policy* decides whether script files may run. A module is made of
script files. Check it, and if it prints `Restricted` (no script file runs, and
`Import-Module` fails with "running scripts is disabled on this system"), change it:

```powershell
Get-ExecutionPolicy
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

`-Scope CurrentUser` makes this a per-user setting: it affects only your account,
needs no administrator rights and leaves the computer's policy alone.
`RemoteSigned` runs local and unblocked scripts and requires a signature on
blocked downloads. Windows PowerShell and PowerShell 7 each have their own
policy; run it in each one you use if it still says `Restricted`. If Group
Policy sets the policy, `Get-ExecutionPolicy -List` shows a value under
`MachinePolicy` or `UserPolicy` and the command has no effect; ask the person
who administers your computers.

### Import and verify

```powershell
Import-Module DnsLathund                                   # or: Import-Module 'C:\path\to\DnsLathund\DnsLathund.psd1'
Get-Command -Module DnsLathund                             # lists the commands
Get-Help Get-DnsEntry -Examples                            # help works
```

### The one-click installer

`Install-DnsLathund.ps1` does the steps above. Keep it next to the `DnsLathund`
folder, right-click it and choose **Run with PowerShell** (on Windows 11 it may
be under *Show more options*). It:

1. checks that the `DnsLathund` folder next to it contains `DnsLathund.psd1`;
2. copies the module into your module folder for Windows PowerShell 5.1 and, if
   installed, PowerShell 7 (an existing copy is renamed to
   `DnsLathund.bak-<timestamp>`, never overwritten), and unblocks every file;
3. starts a fresh PowerShell, imports the module to prove it loads and shows the
   version; if the execution policy blocks that import, it prints the exact
   `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` instruction;
4. prints the four first-run commands and waits for Enter.

From a console you can choose scope and edition:

```powershell
.\Install-DnsLathund.ps1                       # current user, both editions
.\Install-DnsLathund.ps1 -Edition Desktop      # Windows PowerShell 5.1 only
.\Install-DnsLathund.ps1 -Scope AllUsers       # all users; needs an elevated PowerShell
```

### Constrained Language Mode and application control

Some organizations enforce *Constrained Language Mode* (CLM) with Windows
Defender Application Control (WDAC) or AppLocker. DnsLathund is designed to run
in CLM, so its core commands work there. The person who administers the policy
may still need to allow-list the module folder for full functionality (for
example by installing with `-Scope AllUsers` into Program Files and trusting that
location). Details and how to check your session: `Get-Help about_DnsLathund`.

## 4. First run

Four commands. None of them changes a DNS record. Replace `dc01` with one of
your DNS servers (without `-Server`, the server you logged on to is used). Spell
the server name the same way every time: the snapshot is stored per name, so
`dc01` and `dc01.contoso.local` are two separate snapshots.

```powershell
Update-DnsSnapshot -Server dc01 -WhatIf -Verbose   # 1. preview: which zones would be exported
Update-DnsSnapshot -Server dc01                    # 2. export them into the local snapshot
Get-DnsSnapshot -Server dc01                       # 3. what is cached, and how old
Get-DnsEntry -Find srv01 -Server dc01              # 4. search it
```

1. **Preview.** `-WhatIf` contacts the server only to read the zone list and the
   zone settings, prints one "What if" line and exports nothing. `-Verbose` adds
   one line per zone with the file it would be written to:

   ```
   VERBOSE: Zone to export: 'contoso.local' -> 'C:\Users\you\AppData\Local\DnsLathund\snapshot\dc01\contoso.local.txt'.
   VERBOSE: Zone to export: '16.0.10.in-addr.arpa' -> 'C:\Users\you\AppData\Local\DnsLathund\snapshot\dc01\16.0.10.in-addr.arpa.txt'.
   What if: Performing the operation "Export DNS zones to local snapshot" on target "2 zone(s) on dc01".
   ```

   It proves that the module, RSAT, your permissions and the server name work,
   and it creates no folder and no file.
2. **Export.** `Update-DnsSnapshot` exports every exportable zone (primary
   zones that the server did not create itself). For each zone the server writes
   a temporary file into `%windir%\System32\dns`, DnsLathund copies it into the
   snapshot folder and deletes the server copy. A zone with hundreds of thousands
   of records takes minutes; a progress bar shows the zone being worked on. It
   asks nothing by default and returns one object per zone in the snapshot:

   ```
   Server Zone                 ExportedAt               Age ZoneType IsReverse
   ------ ----                 ----------               --- -------- ---------
   dc01   16.0.10.in-addr.arpa 2026-10-10 17:41:51 00:00:00 Primary  True
   dc01   contoso.local        2026-10-10 17:41:51 00:00:00 Primary  False
   ```
3. **Look at the cache.** `Get-DnsSnapshot` reads the local snapshot only: export
   time and age per zone. `Age` grows until the next `Update-DnsSnapshot`.
4. **Search.** `Get-DnsEntry -Find srv01` is a bare name, so it searches every
   name that contains `srv01` in the snapshot.

   ```
   Name                    Type Data       TTL PtrStatus Zone          Source
   ----                    ---- ----       --- --------- ----          ------
   srv01.contoso.local     A    10.0.16.5 3600 Ok        contoso.local Snapshot
   srv01-old.contoso.local A    10.0.16.9 3600 Missing   contoso.local Snapshot
   ```

(Example output; names, addresses and times depend on your zones.) If you skip
step 2, the first pattern or substring search against a server that has no
snapshot exports it automatically, after the warning `No snapshot exists for
'dc01'. Exporting N zone(s) now; this can take several minutes on large zones.`
An existing snapshot is never refreshed automatically.

### Reading the output

One row is one A, AAAA or CNAME record; a name with two A records gives two
rows. `Source` is `Live` (the server was asked just now) or `Snapshot` (read from
the local export). `Format-List *` shows every property, such as `SnapshotAge`,
`SharedWith`, `Aliases` and `ReferencedBy`.

`PtrStatus` compares an A or AAAA record with the reverse (PTR) records. The
*expected* reverse zone is the longest reverse zone hosted on the server that
covers the address (an RFC 2317 classless zone counts as longer than its
parent):

| PtrStatus | Meaning |
|---|---|
| `Ok` | A PTR exists at the expected place and points at this name, or at another name that has an A or AAAA record with the same address. |
| `Missing` | A reverse zone covers the address, but no covering zone holds a PTR for it. |
| `WrongTarget` | A PTR exists at the expected place, but it points at no name that has this address. `PtrTargets` lists what it points at. |
| `Shadowed` | The expected (most specific) zone has no PTR for the address, but a less specific zone has one; `PtrZoneFound` names that zone. Clients ask the most specific zone, so they never see it. |
| `Delegated` | The reverse node is handed on: it is a CNAME into an RFC 2317 (classless) zone (`PtrZoneFound` names that zone when this server hosts it), or an NS delegation points it at another server. |
| `Multiple` | More than one PTR exists at the expected place and at least one of them matches. |
| `NoReverseZone` | No reverse zone hosted on this server covers the address. Stub and conditional forwarder zones do not count. |
| `NotApplicable` | The record is a CNAME; CNAMEs have no PTR. |

Without a snapshot, `Get-DnsEntry` cannot see the other names that share an
address or the NS delegations in reverse zones. A PTR that points at another
name with the same address then shows as `WrongTarget` instead of `Ok`, and a
delegated PTR shows as `Missing`. Run `Update-DnsSnapshot` first when this
matters. `Get-Help about_DnsLathund` gives the usual cause of each value and what
to do about it.

Before using change commands in production (when they exist), rehearse in a test
zone on a test server, run everything with `-WhatIf` first and read the change log.

## 5. Everyday workflows

### Find records: `Get-DnsEntry`

`-Find` takes names, addresses and patterns, one or many, from the command line
or the pipeline. `-Find` is the first positional parameter, so
`Get-DnsEntry srv01.contoso.local` works too. Each value is classified on its own:

| You pass | Treated as | How it is looked up |
|---|---|---|
| `sql*`, `*sql*`, `10.0.16.*` | **Pattern**: contains `*` or `?` | `-like` against the whole FQDN of every name in the snapshot, and also against the addresses when the pattern holds only digits, dots, colons, hex letters and wildcards. A snapshot is needed and is created if none exists. `Source` is `Snapshot`. |
| `10.0.16.5`, `fd00::5` | **Address**: a dotted-quad IPv4 or an IPv6 address | The PTR records of the address are read live in every hosted reverse zone that covers it. When a snapshot exists, every name that has an A/AAAA record for the address is added. Each candidate is confirmed live. No snapshot is created. `Source` is `Live`. |
| `srv01.contoso.local` | **FQDN**: ends with the name of a forward zone hosted on the server | The node is read live (A, AAAA, CNAME). No snapshot is needed. `Source` is `Live`. |
| `srv01` | **Bare name** | Substring search `*srv01*` over the snapshot. A snapshot is needed and is created if none exists. |
| `srv01` with `-Zone contoso.local` | Bare name in a zone | The node `srv01` is read live in that zone. |
| `srv01` with `-Exact` | Bare name, exact | The node is read live in every hosted forward zone (a warning appears above 10 zones). Add `-Zone` to look in one zone. |

Two details. A pattern must match the whole FQDN: `srv*` finds
`srv01.contoso.local`, but `srv0?` does not (use `srv0?*`), and `*` at the end
makes it match any zone. A dotted name that does not end in a zone hosted on the
server, such as `srv01.other.example`, is handled like a bare name.

```powershell
# A full name: asked live from the server
Get-DnsEntry -Find srv01.contoso.local -Server dc01
# A bare name with -Zone: live lookup of that node in that zone
Get-DnsEntry -Find srv01 -Zone contoso.local -Server dc01
# A bare name with -Exact: live lookup in every hosted forward zone, never the snapshot
Get-DnsEntry -Find srv01 -Exact -Server dc01
# An IP address: the A/AAAA records that have it, and their PTR state
Get-DnsEntry -Find 10.0.16.5 -Server dc01
# A pattern (* or ?): matched against the snapshot
Get-DnsEntry -Find 'sql*' -Server dc01
Get-DnsEntry -Find '10.0.16.*' -Server dc01
# A bare name without -Zone or -Exact: substring search ("*sql*"), first 20 hits only
Get-DnsEntry -Find sql -Server dc01 -First 20
# Names or addresses from a file, one per line (blank lines are skipped)
Get-Content .\names.txt | Get-DnsEntry -Server dc01
# A CSV with a column named Name, Identity, HostName, IPAddress or Address
Import-Csv .\hosts.csv | Get-DnsEntry -Server dc01
# The same lookup on several servers
Get-DnsEntry -Find srv01.contoso.local -Server dc01, dc02, dc03 |
    Format-Table Server, Name, Data, PtrStatus, Source
```

Useful parameters:

- `-Zone <zone>` restricts the search to records in that zone. Bare names are read
  live in it; an FQDN is read only if it lies in that zone; patterns and address
  lookups return only records of that zone. A zone that is not hosted on the
  server gives a non-terminating error.
- `-Exact` never searches the snapshot for names. A value with wildcards together
  with `-Exact` gives a non-terminating error.
- `-First <n>` stops after n entries in total, across all values and servers. With
  pipeline input the remaining values are still read, but ignored.
- `-ExcludeNetwork '10.0.50.0/24', 'fd00::/64'` sets `InDhcpRange` to `$true` for
  addresses in those networks. Despite its name it removes nothing; filter with
  `Where-Object { -not $_.InDhcpRange }`.
- `-MaxSnapshotAge (New-TimeSpan -Hours 4)` changes the staleness limit of the
  snapshot (default 24 hours): an older snapshot is still used, with a warning.
- `-Server dc01, dc02` repeats the whole search on every server. Each entry
  carries its `Server`. Every server has its own snapshot.
- `-Credential` runs every DnsServer call through a CIM session as another
  account. If no session can be opened the command stops; it never falls back to
  your own account.

A value that matches nothing gives the warning `No entry matched '<value>' on
'<server>'.`, not an error. An address that has PTR records but no A or AAAA
record gives a more specific warning that names the orphaned PTR records (see
[Troubleshooting](#8-troubleshooting)).

**`$null` versus an empty list.** `SharedWith`, `Aliases`, `ReferencedBy`,
`HasDhcid` and `TargetExists` come from the snapshot. `$null` means *not
evaluated* (there was no snapshot to ask); an empty list `@()` means *evaluated,
nothing found*. `SnapshotAge` is `$null` when no snapshot was used.

```powershell
$e = @(Get-DnsEntry -Find srv01.contoso.local -Server dc01)[0]
if ($null -eq $e.Aliases)        { 'No snapshot: aliases were not checked.' }
elseif ($e.Aliases.Count -eq 0)  { 'Checked: no CNAME points here.' }
else                             { 'Aliases: ' + ($e.Aliases -join ', ') }
```

A live lookup (FQDN, address, `-Zone`, `-Exact`) never creates a snapshot, but it
fills these properties from the snapshot if one exists, of any age. `SnapshotAge`
then tells how old that part is.

### Look at the cache: `Get-DnsSnapshot`

Reads the local snapshot only; it never contacts a server and needs no RSAT.

```powershell
Get-DnsSnapshot                                 # default server
Get-DnsSnapshot -Server dc01, dc02 -Zone contoso.local
Get-DnsSnapshot -Server dc01 -Zone '*.in-addr.arpa'    # -Zone accepts wildcards
Get-DnsSnapshot -Server dc01 | Where-Object Age -gt (New-TimeSpan -Hours 24)   # stale zones
```

`Format-List *` also shows `ReplicationScope`, `DirectoryPartitionName`,
`DynamicUpdate`, `AgingEnabled`, `FileSizeBytes` and `Path` (the local export
file of the zone). These values describe the zone at export time. A server
without a snapshot gives a warning and no output, not an error.

### Refresh the cache: `Update-DnsSnapshot`

Exports zones from the server into the snapshot folder and rebuilds the search
index. Run it when you need current data for pattern searches, address searches
and the `SharedWith`, `Aliases` and `ReferencedBy` properties.

```powershell
Update-DnsSnapshot -Server dc01 -WhatIf -Verbose  # list the zones, export nothing
Update-DnsSnapshot -Server dc01                   # export every exportable zone
Update-DnsSnapshot -Server dc01 -Zone contoso.local, 16.0.10.in-addr.arpa
Update-DnsSnapshot -Server dc01 -Confirm          # ask once before the export
Update-DnsSnapshot -Server dc01 -Force            # never prompts
```

- Its impact is rated Low, so it does not ask by default. `-Confirm` asks once for
  the whole export (not once per zone); `-Force` never asks.
- With `-Zone`, only those zones are exported and the other zones already in the
  snapshot are kept. Without it, zones that are no longer exportable on the
  server are removed from the snapshot.
- A zone that fails to export is reported as an error; the other zones continue
  and that zone keeps its previous snapshot. A new file replaces the old one only
  when its export succeeded.
- Exportable zones are primary zones that the server did not create itself
  (except `TrustAnchors`). Secondary, stub and forwarder zones are never exported.
- The output lists every zone in the snapshot, also those not exported this time.

**Where the snapshot lives.** The folder is `%LOCALAPPDATA%\DnsLathund\snapshot`,
one subfolder per server, so each Windows account has its own snapshot. To keep it
somewhere else (a scheduled task, a shared jump host), set the environment
variable `DNSLATHUND_SNAPSHOTPATH` to the folder before you run any command:

```powershell
$env:DNSLATHUND_SNAPSHOTPATH = 'D:\DnsSnapshots'                                  # this session
[Environment]::SetEnvironmentVariable('DNSLATHUND_SNAPSHOTPATH', 'D:\DnsSnapshots', 'User')   # every new session of this account
```

```
<snapshot folder>\
    dc01\                          one folder per server: the -Server value as typed, in lower case
        meta.json                  when each zone was exported, and the zone settings at that time
        contoso.local.txt          the zone export, one file per zone, in the format of Export-DnsServerZone
        16.0.10.in-addr.arpa.txt
```

Characters outside `A-Z a-z 0-9 . _ -` in a zone name become `_` in the file
name. The `.txt` files are plain text copies of your zones; protect the folder
the way you protect the zones. The search index is built from these files and
kept in memory for the PowerShell session, so the first snapshot search of a new
session reads the files again, with a progress bar on large zones.

### Commands planned for a later phase

#### Remove-DnsEntry
Planned for a later phase.

#### New-DnsEntry
Planned for a later phase.

#### Set-DnsEntry
Planned for a later phase.

#### Test-DnsConsistency
Planned for a later phase.

#### Repair-DnsIssue
Planned for a later phase.

## 6. Automation

A script for Task Scheduler that uses only the commands that exist today. It
refreshes the snapshot of one DNS server, then writes every A or AAAA record whose
PTR record is not in order to a dated CSV file. Save it, for example, as
`C:\Scripts\Get-PtrReport.ps1`.

```powershell
<#
.SYNOPSIS
    Nightly PTR report: refreshes the DnsLathund snapshot of one DNS server and
    writes every A/AAAA record whose PTR record is not in order to a CSV file.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string]$Server,
    [Parameter(Mandatory)] [string]$OutputFolder
)

# A module that is not installed throws here. A missing RSAT or an unreachable
# server throws in the next command. A throw ends the script and makes
# powershell.exe exit with code 1.
Import-Module DnsLathund -ErrorAction Stop

# -Force: never prompt. -ErrorAction Stop: a zone that cannot be exported stops
# the script instead of leaving a half-fresh snapshot behind.
$null = Update-DnsSnapshot -Server $Server -Force -ErrorAction Stop

$null = New-Item -ItemType Directory -Path $OutputFolder -Force
$csv = Join-Path $OutputFolder ('ptr-problems_{0}_{1}.csv' -f $Server, (Get-Date -Format 'yyyyMMdd'))

# '*' matches every A, AAAA and CNAME owner in the snapshot. The entries stream,
# so only the problem rows are kept in memory.
$problems = @(
    Get-DnsEntry -Find '*' -Server $Server -ErrorAction Stop -WarningVariable lathundWarnings |
        Where-Object { $_.PtrStatus -in 'Missing', 'WrongTarget', 'Shadowed', 'Multiple' }
)

if ($problems.Count -gt 0) {
    # Export-Csv writes a list property as 'System.String[]', so join the lists first.
    $problems |
        Select-Object Server, Name, Type, Data, TTL, PtrStatus, Zone, IsStatic, InDhcpRange,
            ReverseZone, PtrZoneFound,
            @{ Name = 'PtrTargets'; Expression = { $_.PtrTargets -join ';' } },
            @{ Name = 'SharedWith'; Expression = { $_.SharedWith -join ';' } } |
        Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
}
if ($lathundWarnings) {
    $lathundWarnings | Set-Content -Path ($csv -replace '\.csv$', '.warnings.txt') -Encoding UTF8
}
'{0} record(s) with a PTR problem on {1}.' -f $problems.Count, $Server
```

Run it from Task Scheduler with, for example:

```
powershell.exe -NoProfile -NonInteractive -File C:\Scripts\Get-PtrReport.ps1 -Server dc01 -OutputFolder D:\Reports
```

Notes on the template:

- **The task's account needs its own snapshot.** Snapshots live under the
  account's `%LOCALAPPDATA%`, so the task refreshes its own snapshot first. To
  keep it in a fixed folder, set `DNSLATHUND_SNAPSHOTPATH` for the task (or in the
  script, before the first DnsLathund command).
- **Always pass `-Server`.** The default is `$env:LOGONSERVER`, which some
  scheduled-task sessions lack; the commands then throw "No default DNS server
  (LOGONSERVER is not set). Specify -Server."
- **The status list is a choice.** `Delegated` is normal for classless reverse
  zones, `NoReverseZone` can be intended (external addresses) and
  `NotApplicable` is a CNAME. Add them to the list if you want them reported.
- **Several servers:** a precondition failure on one server ends the whole call.
  To report on the other servers anyway, run the script (or the two commands) once
  per server and catch the error per server.
- **Warnings** (a stale snapshot, a skipped zone) do not stop the script; the
  template saves them next to the CSV file.

### What the commands guarantee today

- **Preconditions throw.** In this version: no default server
  (`LOGONSERVER` not set) or an invalid server name; the `DnsServer` module is
  missing; the zone list of the server cannot be read (server unreachable, no
  permission); `-Credential` given but no CIM session possible; the snapshot
  metadata cannot be written; a search needs a snapshot and not one zone could
  be exported. The message ends with what to do. These errors are terminating
  whatever `-ErrorAction` you pass: use `try`/`catch`, or let the script end.
- **Per-item problems do not stop the run.** A zone that cannot be exported, a
  `-Zone` that is not hosted, a wildcard together with `-Exact`, a live lookup
  that fails: each gives a non-terminating error (`ErrorId` like
  `DnsLathund.<Function>.<Reason>`) and the command goes on with the next item.
  `-ErrorAction Stop` turns the first such error into a terminating one, which
  makes the script stop at the first failed item.
- **Real lookup failures are errors, a missing record is not.** When
  `Get-DnsEntry` reads a node live and the server answers with a real failure
  (access denied, server unreachable), it writes a non-terminating error with the
  `ErrorId` `DnsLathund.Get-DnsLiveRecord.LookupFailed` and goes on. A record that
  does not exist is silent. PowerShell still records the silenced "not found"
  answers in `$Error` and in a caller's `-ErrorVariable`, so `-ErrorVariable` is
  not a reliable failure signal. Capture the error stream instead:

  ```powershell
  $output  = Get-DnsEntry -Find srv01.contoso.local, srv02.contoso.local -Server dc01 2>&1
  $errors  = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
  $entries = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
  ```
- **Warnings keep going.** A stale snapshot, an unreadable snapshot file or a
  value that matches nothing give a warning and still correct output. Collect them
  with `-WarningVariable`.
- **`-Force` means zero prompts.** Today only `Update-DnsSnapshot` has a
  confirmation, and it asks only with `-Confirm`. In a session that cannot prompt,
  `-Confirm` without `-Force` writes the error "This session cannot prompt.
  Re-run with -Force to confirm all actions, or -WhatIf to preview." and does
  nothing.
- **Output streams** as objects are found, so `Select-Object -First` and
  `Export-Csv` start at once. `-Verbose` shows every server round-trip and the
  resolved defaults (server, snapshot folder).
- **`-Credential`** sends every DnsServer call through a CIM session. If none can
  be opened the command throws; it never falls back to the logged-on user. A
  snapshot export then copies the file over WinRM, because the `admin$` share
  cannot use alternate credentials.

### When the change commands arrive

Planned for a later phase; nothing in this section exists yet. The commands that
change records will follow the same rules and add a result object to them:

- They will emit one `Result` object per sub-operation (for example one for
  removing a PTR and one for removing the A record), all sharing a `BatchId`,
  with the properties `Action`, `Name`, `Type`, `Data`, `Result`, `Error`, `Zone`,
  `NodeName`, `Server`, `Id`, `BatchId` and `Timestamp`. Read these objects, not
  the console text, to see what happened.
- `Result` will be one of `Success`, `Failed`, `Skipped`, `WhatIf`, `AlreadyDone`
  and `Pending`. `AlreadyDone` (for example removing something that is already
  gone) is a success, so re-running a script is safe.
- A per-item failure will be a non-terminating error plus a `Result` object with
  `Result = 'Failed'`; the other items continue. A precondition will throw.
  `-ErrorAction Stop` makes the first per-item failure terminating, so the
  remaining items are not processed.
- `-Force` will mean zero prompts; without it an unattended session gets the
  error "This session cannot prompt" instead of a hang.
- As with `Get-DnsEntry` today, do not decide success or failure from
  `-ErrorVariable`: it also collects the errors the module handled itself. Look at
  the `Result` objects (for example `$results | Where-Object Result -eq 'Failed'`)
  or capture the error stream with `2>&1`.

## 7. The change log

No command in this version writes to the log. `Get-DnsEntry`, `Get-DnsSnapshot`
and `Update-DnsSnapshot` change no DNS record, and none of them has a `-LogPath`
parameter. The log writer is in the module already so that the planned change
commands can use it; this section describes the format they will write.

The change commands will write one line per action to the log, including
`-WhatIf` runs (`Result = 'WhatIf'`), so that you can review what a rehearsal would
have done.

The file is chosen in this order:

1. `-LogPath <file>` (a relative path is taken from the current folder)
2. the environment variable `DNSLATHUND_LOGPATH`
3. `%LOCALAPPDATA%\DnsLathund\log\DnsLathund_<yyyy-MM>.jsonl` (one file per month)

The folder is created when it is missing. The format is JSON Lines, one JSON
object per line. Fields, in this order: `Id`, `BatchId` (shared by one command
run), `Timestamp`, `Operator` (`DOMAIN\user`), `Server`, `Action`, `Zone`,
`NodeName`, `Type`, `Before` (`Data`, `Ttl`, `Timestamp`, `IsStatic`), `After`,
`Result` and `Error`. Every field is always present; `null` means "not
applicable". Dates are ISO 8601 with offset, for example
`2026-10-09T15:00:00.0000000+02:00`.

Writing the log never stops a DNS operation. If the file is locked, the writer
waits 200 milliseconds and tries once more. If that fails too, or the path cannot
be created, the command writes the warning `Could not write the change log
'<path>': <reason> The change was not logged.` and carries on. Read the log with:

```powershell
$log = Join-Path $env:LOCALAPPDATA ('DnsLathund\log\DnsLathund_{0}.jsonl' -f (Get-Date -Format 'yyyy-MM'))
Get-Content -Encoding UTF8 $log | ConvertFrom-Json | Where-Object Result -eq Failed
```

Encoding: Windows PowerShell 5.1 writes a UTF-8 byte-order mark (BOM) when it
*creates* the file; PowerShell 7 does not. A BOM is never written mid-file and
both editions read either, so the log can be shared. Keep `-Encoding UTF8` when
you read it, or Windows PowerShell 5.1 garbles non-ASCII characters.

## 8. Troubleshooting

Messages are quoted as the module writes them; `<server>`, `<zone>` and
`<reason>` stand for the actual values. Warnings appear as `WARNING:` lines and
do not stop the command; errors and the exceptions that stop it appear in red.
Run the command again with `-Verbose` to see every server round-trip and the
folder that is used.

### Setting up and reaching the server

**"The DnsServer PowerShell module (RSAT: DNS Server Tools) is not available.
Install it with: Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0
(Windows 10/11) or Install-WindowsFeature RSAT-DNS-Server (Windows Server)."**
RSAT is not installed on the computer running DnsLathund. Install it as in
[Requirements](#2-requirements) and check with `Get-Command Get-DnsServerResourceRecord`.

**"No default DNS server (LOGONSERVER is not set). Specify -Server."** The
computer is not domain-joined, or the session has no logon server (some scheduled
tasks and remote sessions). Pass `-Server dc01`. The related message "'<name>' is
not a valid DNS server name. Specify -Server." means the `-Server` value is empty
or unusable.

**"Could not read the zone list from '<server>': <reason> Check the server name,
that the DNS Server service is running and that you may read its configuration, or
specify another -Server."** `Get-DnsEntry` and `Update-DnsSnapshot` read the zone
list first. Typical causes: a misspelled or unreachable server, the DNS Server
service is stopped, WinRM/CIM is blocked, or the account may not read the DNS
configuration. The `<reason>` is the text from the DnsServer cmdlet.

**"Could not open a CIM session to '<server>' as '<user>' (tried WSMan and DCOM).
Check that WinRM or DCOM is reachable and that the account may read DNS, or omit
-Credential to run as the logged-on user."** You passed `-Credential` and no CIM
session could be opened with it. DnsLathund never falls back to your own account.

### Snapshots

**Warning "No snapshot exists for '<server>' ('<folder>'). Run Update-DnsSnapshot
-Server <server> to create one."** From `Get-DnsSnapshot`: nothing has been
exported for that server name yet (or the name is spelled differently from the one
you exported with; `dc01` and `dc01.contoso.local` are different snapshots). Run
`Update-DnsSnapshot -Server <server>`.

**Warning "No snapshot exists for '<server>'. Exporting N zone(s) now; this can
take several minutes on large zones."** A pattern or substring search needs a
snapshot and there is none, so it is created now, once. Nothing is wrong. To
choose the moment yourself, run `Update-DnsSnapshot` first. Address, FQDN, `-Zone`
and `-Exact` lookups never trigger this.

**Error "Could not create a snapshot for '<server>'; no zone could be exported
(see the errors above). Fix the cause and run Update-DnsSnapshot -Server
<server>."** The automatic export failed for every zone. Read the errors above it
(next entries), fix the cause and run `Update-DnsSnapshot` yourself.

**Error "Zone '<zone>' on '<server>' could not be exported: <reason>"** (ErrorId
`DnsLathund.Update-DnsSnapshot.ExportFailed`; ends with "The previous snapshot of
this zone is kept." when there was one). The other zones continue. The reason is
one of two messages from the export step:

- "Could not export zone '<zone>' on '<server>': <reason> Check that the zone
  exists on that server, that it is a primary zone, and that your account may
  export it (DnsAdmins or Administrators)." The server refused or failed to write
  the export. Fix the permission, or pick a server that holds the primary copy.
- "Zone '<zone>' was exported on '<server>' but the file
  '%windir%\System32\dns\<file>' on '<server>' (\\<server>\admin$\System32\dns\<file>)
  could not be copied here. [admin$ share] <reason> [WinRM] <reason> Check that
  this computer can reach the admin$ share or WinRM on '<server>'." The export
  worked, but the file could not be brought back. The bracketed parts are the
  Windows error text of each route that was tried: `[admin$ share]` is the
  `\\<server>\admin$` copy (TCP 445; usually "Access is denied" when your account
  is not a local administrator on the server, or "The network path was not
  found" when the port is blocked); `[WinRM]` is the `Invoke-Command` route
  (WinRM disabled, TCP 5985/5986 blocked, or no permission to open a remote
  session). When the server is your own computer the route is `[Local copy]`;
  with `-Credential` only `[WinRM]` is tried. Test each route by hand:
  `Test-Path \\<server>\admin$` and
  `Invoke-Command -ComputerName <server> -ScriptBlock { hostname }`. Fix one of
  them.

**Warning "Could not remove the export file '%windir%\System32\dns\<file>' on
'<server>' (\\<server>\admin$\System32\dns\<file>) from the DNS server: <reason>
Delete it manually."** The snapshot is fine, but the temporary export file is
still on the server, in `%windir%\System32\dns` (name `dnslathund_<zone>_<time>.txt`).
Delete it there.

**Errors "Zone '<zone>' is not hosted on '<server>'. Check the name, or list the
zones with Get-DnsServerZone -ComputerName <server>." and "Zone '<zone>' on
'<server>' cannot be exported because <reason>. Only primary zones are exported;
export it on the server that hosts the primary copy."** (`Update-DnsSnapshot -Zone`;
the first also comes from `Get-DnsEntry -Zone`.) The reason is "it is a Secondary
zone" (or Stub, Forwarder), "it was created automatically by the DNS server" or "it
holds DNSSEC trust anchors". Check the spelling with
`Get-DnsServerZone -ComputerName <server>`. The warning "'<server>' hosts no
exportable zones (only secondary, stub, forwarder or automatically created zones).
Nothing was exported." means a full update found nothing to export.

**Warning "Zone '<zone>' is not in the snapshot of '<server>'. Run
Update-DnsSnapshot -Server <server> -Zone <zone> to add it."** `Get-DnsSnapshot
-Zone` named a zone that was never exported.

**Warning "The snapshot of '<server>' is 2d 3h 4m old (oldest zone export,
exported 2026-10-08 14:38), older than the accepted 1d 0h 0m. It is used anyway;
run Update-DnsSnapshot -Server <server> to refresh it."** The snapshot is used,
but results reflect the moment of its export. Run `Update-DnsSnapshot -Server
<server>`, or raise the limit with `-MaxSnapshotAge`. The warning also appears for
a live lookup that uses an existing snapshot for `SharedWith` and `Aliases`. A
snapshot is never refreshed automatically once one exists.

**Warnings about meta.json** (the file that records what was exported when; it is
in the server's snapshot folder):

- "The snapshot of '<server>' has no meta.json ('<path>'). Run Update-DnsSnapshot
  -Server <server> to recreate the snapshot."
- "The snapshot metadata '<path>' could not be read: <reason> Run
  Update-DnsSnapshot -Server <server> to recreate the snapshot." The file is not
  valid JSON (damaged, or half written).
- "The snapshot metadata '<path>' is not in the expected format. ..." and "The
  snapshot metadata '<path>' has schema version '<n>'; this version of DnsLathund
  reads version 1. ..." The file is from something else or from a newer version.
- "Zone '<zone>' in '<path>' has no details / has no file name / has no valid
  ExportedAt and is ignored. ..." One zone entry is damaged; the other zones stay
  usable.

All of them end with the same fix: run `Update-DnsSnapshot -Server <server>`. If
you do not, a pattern or substring search that finds no usable snapshot starts the
automatic export described above.

**Warnings "The snapshot file '<path>' of zone '<zone>' is missing; the zone is
left out. Run Update-DnsSnapshot -Server <server> -Zone <zone>." and "The snapshot
file '<path>' of zone '<zone>' could not be read: <reason> The zone is left out;
run Update-DnsSnapshot -Server <server> -Zone <zone>."** A zone file was deleted
or is unreadable. Searches work without that zone until you export it again.

**Warning "Zone '<zone>': <note>".** The zone export contained something the
reader could not use, for example "3 line(s) in '<path>' could not be parsed and
were skipped" or "2 PTR record(s) in zone '<zone>' with owner shape '<shape>' do
not map to a single address; ADDR is empty". The records concerned are left out of
the checks. Everything else is unaffected. A related warning, "Zone '<zone>' was
exported to '<path>' but could not be parsed: <reason> It is left out of the
search index.", means the whole zone is missing from searches.

**Error "Could not write the snapshot metadata of '<server>' to '<folder>':
<reason> Check that the folder is writable and run Update-DnsSnapshot again."** The
snapshot folder (or the folder in `DNSLATHUND_SNAPSHOTPATH`) is read-only, full
or not reachable.

### Searching

**Warning "No entry matched '<value>' on '<server>'."** Nothing was found for that
value, which is not an error. Check the spelling. A bare name without `-Zone` or
`-Exact` is a substring search in the snapshot, so it only finds what the snapshot
has. A dotted name that does not end in a zone hosted on the server, such as
`srv01.other.example`, is searched the same way. The warning also follows real
lookup failures (below); read the errors above it.

**Warning "No A/AAAA record has the address '<address>' on '<server>', but <n>
PTR record(s) in '<zone>' point at: <targets>. These PTR records are orphaned
(Test-DnsConsistency in a later phase reports them)."** The address has PTR
records, but no A or AAAA record uses it: the host is gone and its PTR stayed
behind. Decide whether the targets still exist (`Get-DnsEntry -Find <target>`) and,
if not, remove the PTR records in DNS Manager or with the DnsServer cmdlets. Today
no DnsLathund command removes them.

**Error "Lookup of '<node>' (<type>) in zone '<zone>' on '<server>' failed:
<reason>"** (ErrorId `DnsLathund.Get-DnsLiveRecord.LookupFailed`). The server
answered a live lookup with a real failure, such as access denied or an
unreachable server, and `Get-DnsEntry` could not tell whether the record exists.
You see one error per record type (A, AAAA, CNAME) and the search goes on with the
next zone, value and server. A missing record is not an error and prints nothing.
Fix the cause named in `<reason>`. With `-ErrorAction Stop` the first such error
stops the command.

**Error "'<value>' contains wildcards, but -Exact only looks up exact names.
Remove -Exact to search the snapshot with the pattern, or give an exact name."**
(ErrorId `DnsLathund.Get-DnsEntry.PatternWithExact`.) Self-explanatory. A value
with wildcards that PowerShell cannot read, such as `sql[*` (an unbalanced `[`),
gives the error "'<value>' is not a valid wildcard pattern: <reason> Escape a
literal [ or ] with a backtick (`[)." (ErrorId `DnsLathund.Get-DnsEntry.InvalidPattern`).

**Warning "Looking up '<name>' in N forward zones on '<server>' (3N queries per
name). Specify -Zone to look in one zone only."** `-Exact` without `-Zone` reads
the name in every hosted forward zone; with more than 10 zones that is many
queries. Add `-Zone`.

**Warning "'<entry>' is not a valid network in CIDR notation (for example
10.0.50.0/24 or fd00::/8); it is ignored."** A `-ExcludeNetwork` entry is
misspelled. The other entries are still used.

### Prompts, language mode and files

**"This session cannot prompt. Re-run with -Force to confirm all actions, or
-WhatIf to preview."** (ErrorId `DnsLathund.Confirm.NonInteractive`.) The command
needed confirmation and the session is not interactive (scheduled task, remote
command, `-NonInteractive`). Add `-Force` to confirm everything, or `-WhatIf` to
preview. In this version only `Update-DnsSnapshot -Confirm` can ask. If you
answer `S` at a prompt, the command stops with "Operation stopped by the operator."

**"Only core types are supported in this language mode"** (or "Method invocation
is supported only on core types"). Your session is in Constrained Language Mode and
a DnsLathund command tried something that mode forbids. The module is written not
to, so this is a defect, not a fault in your policy: report it to the maintainer
with the full error text and the output of
`$ExecutionContext.SessionState.LanguageMode`.

**Non-ASCII names look garbled.** A file was saved without a BOM and read as ANSI
by Windows PowerShell 5.1. Re-save it as UTF-8 with BOM or read it with
`Get-Content -Encoding UTF8`. This applies to name lists you feed in and to the
log; DnsLathund's own files carry a BOM.

**`Import-Module` cannot find the module, or says "running scripts is disabled
on this system".** The folder is in the wrong place or misnamed
(`Get-Module -ListAvailable DnsLathund` must list it), or the execution policy
blocks it. See [Installation](#3-installation-step-by-step) and
[The execution policy](#the-execution-policy).

## 9. Known limitations

- **Snapshots age.** Pattern and substring searches, the extra names that an
  address search finds through the snapshot, and the `SharedWith`, `Aliases`,
  `ReferencedBy`, `HasDhcid` and `TargetExists` properties are only as current as
  `SnapshotAge`. Full-name, `-Zone` and `-Exact` lookups ask the server live. A
  snapshot is never refreshed automatically once one exists.
- **The snapshot belongs to one Windows account and one spelling of the server
  name.** The folder is under the account's `%LOCALAPPDATA%` unless
  `DNSLATHUND_SNAPSHOTPATH` is set, and `dc01` and `dc01.contoso.local` are
  separate snapshots.
- **The zone list is read once per session.** Zones created or removed on the
  server later are not seen by `Get-DnsEntry` until `Update-DnsSnapshot` runs or
  you start a new session.
- **PtrStatus without a snapshot is less exact.** Names that share an address and
  NS delegations in reverse zones are only known from the snapshot (see
  [Reading the output](#reading-the-output)).
- **An address lookup without a snapshot finds only the host its PTR points at.**
  DNS has no index from an address to the A records that use it; listing every A
  record of an address needs the snapshot.
- **`Get-DnsEntry` returns A, AAAA and CNAME records only.** SRV, NS and MX
  records appear in `ReferencedBy` but not as entries. It does not look up
  reverse names such as `5.16.0.10.in-addr.arpa`; pass the address.
- **Record types in snapshots:** A, AAAA, CNAME, PTR, SRV, NS, MX and DHCID are
  read; SOA, TXT, WINS and other types are ignored.
- **Escapes in names.** Windows writes characters such as a space in an export as
  `\DDD`, and DnsLathund decodes them as octal digits because that is what
  Windows writes (`\040` is a space). A name that really contains a backslash
  followed by three digits is therefore ambiguous and is read as the escape.
- **IPv6 reverse lookups only at nibble boundaries**, and **only the default zone
  scope is exported**; other zone scopes are not in snapshots.
- **Classless (RFC 2317) reverse zones are detected, not repaired.** They are
  classified (`Delegated`); no command creates or fixes their records yet.
- **Live lookup failures are followed by "No entry matched".** The errors say why.
- **`-ErrorVariable` and `$Error` also hold the silenced "not found" answers** of
  the DnsServer cmdlets. Use `2>&1` to tell real errors from them.
- **`Export-Csv` writes list properties as `System.String[]`.** Join `PtrTargets`,
  `SharedWith`, `Aliases` and `ReferencedBy` first (see the template in
  [Automation](#6-automation)).
- **Aging timestamps cannot be restored.** For the planned change commands: a
  record that is deleted and recreated gets a new timestamp; only its data comes
  back. Timestamps in snapshots are as old as the export.
- **`Owner` is always `$null`** in this version. It is reserved for a later phase
  and will need a Full-language session.
- **Constrained Language Mode with the `DnsServer` module is not yet verified**
  on a policy-enforced host. The phase 1 commands are exercised in a constrained
  session against stand-ins for the DnsServer cmdlets.
- The performance figures in the design (for example parsing 550 000 lines in
  under 20 seconds) are targets, not promises, and the duration of a zone export
  and its effect on the server for a zone of that size have not been measured yet.
