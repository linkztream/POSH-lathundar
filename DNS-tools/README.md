# DnsTools

A PowerShell module for finding, checking, creating, changing and removing DNS
records in large Microsoft DNS (Active Directory-integrated) environments.

## 1. What DnsTools does

DnsTools finds A, AAAA and CNAME records and shows, for each one, whether its
PTR (reverse lookup) record is correct. It was built for zones with hundreds of
thousands of records, where DNS Manager and an unfiltered
`Get-DnsServerResourceRecord` time out, by exporting each zone once into a local
snapshot and searching that snapshot. Searching never changes a record. The same
module can also remove, create and change records together with their PTR
records, after checking each change live on the server (see
[Everyday workflows](#5-everyday-workflows)).

Status: this version has eight commands. Three of them only read. Five are
*change commands* (they have `-WhatIf`, `-Force` and write the change log):
`Remove-DnsEntry`, `New-DnsEntry`, `Set-DnsEntry` and `New-DnsReverseZone` change
DNS, and `Backup-DnsZone` changes nothing in DNS but writes backup files on your
computer.

| Command | Kind | What it does |
|---|---|---|
| `Get-DnsEntry` | read | Finds A, AAAA and CNAME records by name, address or pattern and reports the PTR status of each. |
| `Get-DnsSnapshot` | read | Lists the zones in the local snapshot with their export time and age. Contacts no server. |
| `Update-DnsSnapshot` | read | Exports zones from a DNS server into the local snapshot. Writes local files only. |
| `Remove-DnsEntry` | **change: DNS** | Removes A, AAAA and CNAME records together with their PTR records, DHCID records and CNAME aliases. |
| `New-DnsEntry` | **change: DNS** | Creates static A, AAAA and CNAME records, with the PTR records of the addresses. |
| `Set-DnsEntry` | **change: DNS** | Changes the TTL, the address, the PTR target or the alias target of existing records, in place. |
| `New-DnsReverseZone` | **change: DNS** | Creates an Active Directory-integrated reverse lookup zone with the settings of an existing zone. |
| `Backup-DnsZone` | **change: files only** | Saves zones as zone files in a new, time-stamped folder, with instructions for restoring them. |

`Get-DnsIssue` (a consistency audit) and `Repair-DnsIssue` are planned for phase 3.
They do not exist in this version.

**What the change commands never do without asking**

- **They never change DNS before a decision.** A change happens only after you
  previewed it with `-WhatIf` (a rehearsal: nothing is changed), answered a
  confirmation prompt with `Y` or `A`, or passed `-Force` or `-Confirm:$false`
  (both mean "no prompts at all", for unattended runs).
- **Which command asks by default.** The default `$ConfirmPreference` is `High`,
  so only High-impact steps ask:
  - `Remove-DnsEntry` asks once for every input item, for example
    `srv01-old.contoso.local: remove 1 PTR, 1 A`. `Y` removes this item, `N`
    skips it, `A` removes this item and every later item without asking again,
    `S` stops the whole run.
  - `New-DnsReverseZone` asks once, and `New-DnsEntry -CreateReverseZone` asks
    once for each zone it would create.
  - `Set-DnsEntry` asks once for every item when it changes an address. For a
    TTL or a target it does not ask unless you add `-Confirm`.
  - `New-DnsEntry` and `Backup-DnsZone` do not ask unless you add `-Confirm`.
    `New-DnsEntry` checks every item first and writes nothing of it until every
    check passed.
- **`A` ("yes to all") is remembered per impact level.** An `A` at a record
  prompt never approves the creation of a reverse zone later in the same run.
- **A session that cannot prompt changes nothing.** A scheduled task or a
  `-NonInteractive` session gets the error `This session cannot prompt. Re-run
  with -Force to confirm all actions, or -WhatIf to preview.` instead of a hang.
- **`-Force` only removes the questions.** Every safety check stays, and each
  check has its own switch: `-AllowReferenced` (a name that NS, SRV or MX records
  point at), `-IncludeDynamic` (a dynamic record), `-ReplacePtr` (a PTR record
  that points at another name) and `-SkipReferenceCheck` (do not look for NS, SRV,
  MX and CNAME records at all).
- **They never touch dynamic records unasked.** A dynamic record is one with an
  aging timestamp, registered by DHCP or by the client itself. `Set-DnsEntry`
  skips it unless you pass `-IncludeDynamic`; `Remove-DnsEntry` removes it with a
  warning, because the client may register it again. Every record that DnsTools
  creates is static.
- **They never take a pattern.** `*` and `?` are refused. Find the entries with
  `Get-DnsEntry`, check the list, and pipe it to the change command.
- **They always leave a trace.** Every step, also a rehearsal, a skipped step and
  a failed step, is written to the change log (see
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

  DnsTools installs and imports without RSAT. `Get-DnsEntry` and
  `Update-DnsSnapshot` report a missing `DnsServer` module the first time they
  need it; `Get-DnsSnapshot` never needs it.
- **DNS permissions.** An account that may export zones on the server:
  membership of `DnsAdmins` or `Administrators`. Domain Admins is not required.
  Copying the zone export back from the server is a separate step (next point)
  and may need more than `DnsAdmins`. The change commands need an account that
  may change records in the zones they touch; a write that the server refuses
  with "access denied" is a `Failed` result, never `AlreadyDone`.
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
- **WMI access for two checks.** `Remove-DnsEntry` asks the server which NS, SRV, MX
  and CNAME records point at a name, and `Set-DnsEntry -TTL` changes TTLs, through
  WMI (the CIM namespace `root\MicrosoftDNS` on the server). `Remove-DnsEntry` can
  use a fresh snapshot instead of the first; without either it skips the item and
  says why. Without WMI, `Set-DnsEntry -TTL` falls back to the DnsServer cmdlet
  (see [Known limitations](#9-known-limitations)).

## 3. Installation, step by step

If you would rather click than type, skip to
[The one-click installer](#the-one-click-installer).

### What a module is, and where PowerShell looks

A PowerShell module is a folder of script files that adds commands to
PowerShell. DnsTools is the folder `DnsTools`. Installing it means placing
that folder where PowerShell looks for modules (`$env:PSModulePath -split ';'`
lists them). Two of those folders belong to you and need no administrator rights:
`Documents\WindowsPowerShell\Modules` for Windows PowerShell 5.1 and
`Documents\PowerShell\Modules` for PowerShell 7. Your Documents folder is often
redirected (OneDrive or a network share), for example
`C:\Users\you\OneDrive - Company\Documents`, so do not guess the path; the
commands below ask PowerShell for it.

### Copy the folder

Copy the whole `DnsTools` folder (the one that contains `DnsTools.psd1`) into
that module folder. The folder name must be exactly `DnsTools`, and the result
must be `...\Modules\DnsTools\DnsTools.psd1`, not one folder deeper (a common
mistake after unzipping). From the folder that holds the download:

```powershell
$modules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'   # PowerShell 7: 'PowerShell\Modules'
New-Item -ItemType Directory -Path $modules -Force | Out-Null
Copy-Item -Path .\DnsTools -Destination $modules -Recurse -Force
Test-Path (Join-Path $modules 'DnsTools\DnsTools.psd1')    # must print True
```

When upgrading, delete the old `DnsTools` folder first so no old files remain.

### Unblock the files

Files downloaded from the internet carry a "blocked" mark, and PowerShell may
refuse to run blocked script files. In the same window, remove the mark (or
unblock the downloaded `.zip` in its Properties before extracting it):

```powershell
Get-ChildItem (Join-Path $modules 'DnsTools') -Recurse | Unblock-File
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
Import-Module DnsTools                                   # or: Import-Module 'C:\path\to\DnsTools\DnsTools.psd1'
Get-Command -Module DnsTools                             # lists the commands
Get-Help Get-DnsEntry -Examples                            # help works
```

### The one-click installer

`Install-DnsTools.ps1` does the steps above. Keep it next to the `DnsTools`
folder, right-click it and choose **Run with PowerShell** (on Windows 11 it may
be under *Show more options*). It:

1. checks that the `DnsTools` folder next to it contains `DnsTools.psd1`;
2. copies the module into your module folder for Windows PowerShell 5.1 and, if
   installed, PowerShell 7 (an existing copy is renamed to
   `DnsTools.bak-<timestamp>`, never overwritten), and unblocks every file;
3. starts a fresh PowerShell, imports the module to prove it loads and shows the
   version; if the execution policy blocks that import, it prints the exact
   `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` instruction;
4. prints the four first-run commands and waits for Enter.

From a console you can choose scope and edition:

```powershell
.\Install-DnsTools.ps1                       # current user, both editions
.\Install-DnsTools.ps1 -Edition Desktop      # Windows PowerShell 5.1 only
.\Install-DnsTools.ps1 -Scope AllUsers       # all users; needs an elevated PowerShell
```

### Constrained Language Mode and application control

Some organizations enforce *Constrained Language Mode* (CLM) with Windows
Defender Application Control (WDAC) or AppLocker. DnsTools is designed to run
in CLM, so its core commands work there. The person who administers the policy
may still need to allow-list the module folder for full functionality (for
example by installing with `-Scope AllUsers` into Program Files and trusting that
location). Details and how to check your session: `Get-Help about_DnsTools`.

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
   VERBOSE: Zone to export: 'contoso.local' -> 'C:\Users\you\AppData\Local\DnsTools\snapshot\dc01\contoso.local.txt'.
   VERBOSE: Zone to export: '16.0.10.in-addr.arpa' -> 'C:\Users\you\AppData\Local\DnsTools\snapshot\dc01\16.0.10.in-addr.arpa.txt'.
   What if: Performing the operation "Export DNS zones to local snapshot" on target "2 zone(s) on dc01".
   ```

   It proves that the module, RSAT, your permissions and the server name work,
   and it creates no folder and no file.
2. **Export.** `Update-DnsSnapshot` exports every exportable zone (primary
   zones that the server did not create itself). For each zone the server writes
   a temporary file into `%windir%\System32\dns`, DnsTools copies it into the
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
matters. `Get-Help about_DnsTools` gives the usual cause of each value and what
to do about it.

Before you use the change commands in production, rehearse in a test zone on a test
server, run everything with `-WhatIf` first and read the change log (see
[Everyday workflows](#5-everyday-workflows) and [The change log](#7-the-change-log)).

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
- `-MarkDhcpRange '10.0.50.0/24', 'fd00::/64'` marks the entries whose address
  lies in those networks: `InDhcpRange` becomes `$true`. Nothing is removed;
  filter with `Where-Object { -not $_.InDhcpRange }`.
- `-MaxSnapshotAge 04:00:00` changes the snapshot age you accept (default 24
  hours): an older snapshot is still used, with a warning. Write the value as
  `d.hh:mm:ss` (`2.00:00:00` is two days) or with `New-TimeSpan`; a bare number
  such as `4` means 4 ticks, not 4 hours.
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

**Where the snapshot lives.** The folder is `%LOCALAPPDATA%\DnsTools\snapshot`,
one subfolder per server, so each Windows account has its own snapshot. To keep it
somewhere else (a scheduled task, a shared jump host), set the environment
variable `DNSTOOLS_SNAPSHOTPATH` to the folder before you run any command:

```powershell
$env:DNSTOOLS_SNAPSHOTPATH = 'D:\DnsSnapshots'                                  # this session
[Environment]::SetEnvironmentVariable('DNSTOOLS_SNAPSHOTPATH', 'D:\DnsSnapshots', 'User')   # every new session of this account
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

### Before you change anything: the habits and the result rows

`Remove-DnsEntry`, `New-DnsEntry`, `Set-DnsEntry`, `New-DnsReverseZone` and
`Backup-DnsZone` work the same way. The examples below use `dc01`, the zone
`contoso.local` and its reverse zone `16.0.10.in-addr.arpa`; replace them with
your own. Every example in this section was run against stand-ins for the DnsServer
cmdlets, and its output is pasted here as it appeared. (Names and addresses are
made up, and GUIDs in the output are shortened to their first eight characters.)

**Habit 1: rehearse with `-WhatIf`.** Add `-WhatIf` to any change command first.
It prints one "What if" line for every item, returns the result rows that the real
run would return, with `WhatIf` in the `Result` column for every step that would
change something, and changes nothing. The rehearsal is written to the change log
too. Then run the same command without `-WhatIf`.

**Habit 2: find, look, then pipe.** The change commands take exact names and
addresses, never patterns. Find the entries with `Get-DnsEntry`, look at the list,
and pipe it to the change command. An entry from `Get-DnsEntry` names exactly one
record: if `db01` has two A records and you pipe only one of them, only that record
is changed.

**Habit 3: read the result rows, not the console text.** Every step of a change
is one row, and one command can make several steps: removing a host is one row for
its PTR record and one for its A record. The default table shows five columns:

| Column | Meaning |
|---|---|
| `Action` | The step: `RemovePtr`, `RemoveA`, `RemoveAAAA`, `RemoveCName`, `RemoveDhcid`, `AddA`, `AddAAAA`, `AddPtr`, `AddCName`, `SetTtl`, `SetAddress`, `SetTarget`, `SetPtrTarget`, `CreateZone`, `SetZoneAging` or `Backup`. |
| `Name` | The owner of the record. For a PTR record it is the reverse name, such as `9.16.0.10.in-addr.arpa`. For a zone it is the zone name. |
| `Data` | The address, or the name the record points at (a PTR or CNAME target). For `CreateZone` it is the network, for `Backup` the file. |
| `Result` | What happened: see the next table. |
| `Error` | Why a step was skipped or failed. Empty otherwise. The table cuts it at the width of the window; `Format-List` shows it whole. |

| `Result` | Meaning |
|---|---|
| `Success` | The step was done. |
| `WhatIf` | You used `-WhatIf`. Nothing was done; this is what would be done. |
| `AlreadyDone` | The wanted state already held: the record is already gone, already there with the same data, already set, or the zone already exists. It counts as a success, so running a command twice is safe. |
| `Skipped` | The step was left out on purpose and `Error` says why (a referenced name, a dynamic record, a read-only zone, you answered `N`). Nothing is wrong, but somebody should look. |
| `Failed` | The checks or the server refused. `Error` says why, and the command also writes an error. The other items go on. |

Every row is a `DnsTools.Result` object with twelve properties. `Format-List` shows
all of them:

```powershell
Remove-DnsEntry srv01-old.contoso.local -Server dc01 -Confirm:$false | Select-Object -First 1 | Format-List
```

```
Action    : RemovePtr
Name      : 9.16.0.10.in-addr.arpa
Type      : PTR
Data      : srv01-old.contoso.local
Result    : Success
Error     :
Zone      : 16.0.10.in-addr.arpa
NodeName  : 9
Server    : dc01
Id        : 620aae59
BatchId   : 880dca60
Timestamp : 2026-10-13 20:25:16
```

`Id` is also the `Id` of the line in the change log, and `BatchId` is the same for
every row of one command run. `Pending` is part of the object but none of the five
commands writes it.

**One server, and the snapshot.** A change command changes one server (`-Server`;
without it, your logon server), and Active Directory replication carries the change
to the other domain controllers. The local snapshot is not updated by a change; run
`Update-DnsSnapshot` before you search it again.

### Remove records: `Remove-DnsEntry`

Takes a host out of DNS the way you would by hand, but checked and logged. For
every name you give it, it removes in this order:

1. the **PTR records** that point at the name,
2. the **A and AAAA records** of the name,
3. the **DHCID record** of the name, when the name has no A or AAAA record left,
4. the **CNAME aliases** that point at the name, when the name has no record left
   (not with `-KeepAlias`).

You can give it an FQDN (`srv01-old.contoso.local`), a bare name with `-Zone`, an
IP address (every A or AAAA record with that address, and the PTR records of the
address), an entry from `Get-DnsEntry` (exactly that record), or a file
(`-InputFile`: one name or address per line, `#` for comments, or a CSV file with a
`Name` column).

It asks once for every input item. The question names what will be removed:

```powershell
Remove-DnsEntry srv01-old.contoso.local -Server dc01
```

```
Remove DNS records
  srv01-old.contoso.local: remove 1 PTR, 1 A
[Y] Yes  [N] No  [A] Yes to all  [S] Stop (default is N): y

Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
RemovePtr     9.16.0.10.in-addr.arpa          srv01-old.contoso.local        Success
RemoveA       srv01-old.contoso.local         10.0.16.9                      Success
```

Run the same command again: the name is gone, nothing is asked, and the answer is
`AlreadyDone`.

**Pipeline from `Get-DnsEntry`.** Find, look, rehearse:

```powershell
Get-DnsEntry '*-old.contoso.local' -Server dc01 | Remove-DnsEntry -Server dc01 -WhatIf
```

```
What if: Performing the operation "Remove DNS records" on target "app01-old.contoso.local: remove 1 PTR, 1 A".

Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
RemovePtr     31.16.0.10.in-addr.arpa         app01-old.contoso.local        WhatIf
RemoveA       app01-old.contoso.local         10.0.16.31                     WhatIf
What if: Performing the operation "Remove DNS records" on target "app02-old.contoso.local: remove 1 PTR, 1 A".
RemovePtr     32.16.0.10.in-addr.arpa         app02-old.contoso.local        WhatIf
RemoveA       app02-old.contoso.local         10.0.16.32                     WhatIf
What if: Performing the operation "Remove DNS records" on target "srv01-old.contoso.local: remove 1 PTR, 1 A".
RemovePtr     9.16.0.10.in-addr.arpa          srv01-old.contoso.local        WhatIf
RemoveA       srv01-old.contoso.local         10.0.16.9                      WhatIf
```

(A pattern search like this one reads the snapshot.) Then run it for real. Here the
first question is answered `n` and the second `a`, so the third name is removed
without a question. A declined item is not an error: both steps of `app01-old` are
`Skipped`.

```powershell
Get-DnsEntry '*-old.contoso.local' -Server dc01 | Remove-DnsEntry -Server dc01
```

```
Remove DNS records
  app01-old.contoso.local: remove 1 PTR, 1 A
[Y] Yes  [N] No  [A] Yes to all  [S] Stop (default is N): n

Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
RemovePtr     31.16.0.10.in-addr.arpa         app01-old.contoso.local        Skipped     Declined at the confirmatio...
RemoveA       app01-old.contoso.local         10.0.16.31                     Skipped     Declined at the confirmatio...
Remove DNS records
  app02-old.contoso.local: remove 1 PTR, 1 A
[Y] Yes  [N] No  [A] Yes to all  [S] Stop (default is N): a
RemovePtr     32.16.0.10.in-addr.arpa         app02-old.contoso.local        Success
RemoveA       app02-old.contoso.local         10.0.16.32                     Success
RemovePtr     9.16.0.10.in-addr.arpa          srv01-old.contoso.local        Success
RemoveA       srv01-old.contoso.local         10.0.16.9                      Success
```

**What `Remove-DnsEntry` refuses.** It will not remove a name that an NS, SRV or MX
record still points at. The whole item is `Skipped`, one row per record that would
have been removed, and `Error` tells which records point at it:

```powershell
Remove-DnsEntry dc01.contoso.local -Server dc01 | Format-List Action, Name, Result, Error
```

```
Action : RemovePtr
Name   : 10.16.0.10.in-addr.arpa
Result : Skipped
Error  : Referenced by 1 SRV and 1 NS records (_ldap._tcp.contoso.local, contoso.local). Add -AllowReferenced to remove
          it anyway.

Action : RemoveA
Name   : dc01.contoso.local
Result : Skipped
Error  : Referenced by 1 SRV and 1 NS records (_ldap._tcp.contoso.local, contoso.local). Add -AllowReferenced to remove
          it anyway.
```

Add `-AllowReferenced` to remove the name anyway (a warning repeats the list, and
those NS, SRV and MX records are left pointing at a name that no longer exists).
Other safety rules, which `-Force` does not switch off:

- Records in a read-only zone (secondary, stub and server-created zones) are
  `Skipped`.
- When a PTR record in a writable zone cannot be removed, the A and AAAA records
  of that name are kept (`Skipped`), so that no orphaned PTR record is left behind.
- A dynamic record is removed with a warning that the client or the DHCP server may
  register it again.
- When neither a fresh snapshot nor WMI access can tell what points at a name, the
  item is `Skipped` and `Error` says so.

A name with CNAME aliases takes its aliases with it, and each alias is checked for
references of its own:

```powershell
Remove-DnsEntry web.contoso.local -Server dc01 -Confirm:$false
```

```
Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
RemovePtr     40.16.0.10.in-addr.arpa         web.contoso.local              Success
RemoveA       web.contoso.local               10.0.16.40                     Success
RemoveCName   www.contoso.local               web.contoso.local              Success
RemoveCName   shop.contoso.local              web.contoso.local              Success
```

**By address.** `Remove-DnsEntry 10.0.16.88 -Server dc01` finds the A and AAAA
records that have the address and removes them with their PTR records. A PTR record
of the address that points at a name without an A or AAAA record (the host is gone
and its PTR record stayed behind) is an orphan, and is removed too. A records are
found through the PTR records of the address and, when a snapshot of the server
exists, through the snapshot; without one a warning says so.

```powershell
Remove-DnsEntry 10.0.16.88 -Server dc01
```

```
WARNING: A records without a PTR cannot be found by address without a snapshot. No snapshot of 'dc01' exists, so only
the names that PTR records point at are removed; run Update-DnsSnapshot -Server dc01 first to find the others too.
Remove DNS records
  10.0.16.88: remove 1 PTR
[Y] Yes  [N] No  [A] Yes to all  [S] Stop (default is N): y

Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
RemovePtr     88.16.0.10.in-addr.arpa         gone01.contoso.local           Success
```

**`-KeepPtr`.** Leaves the PTR records alone. On Windows Server 2025 that cannot be
done: when an A record is removed, by any tool, the server deletes the PTR record
that points at its name (verified on 2026-10-13; older servers keep it). So after
every removal `Remove-DnsEntry -KeepPtr` reads the PTR records again. On Windows
Server 2025 you get a `RemovePtr` row with the explanation and one warning; on an
older server the PTR record stays and there is no row for it.

```powershell
Remove-DnsEntry app01-old.contoso.local -Server dc01 -KeepPtr -Confirm:$false
```

```
Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
RemoveA       app01-old.contoso.local         10.0.16.31                     Success
RemovePtr     31.16.0.10.in-addr.arpa         app01-old.contoso.local        Success     Removed by the DNS server t...
WARNING: Removed by the DNS server together with the A record; -KeepPtr cannot be honoured on this server.
```

The other switches: `-KeepAlias` leaves the aliases; `-SkipReferenceCheck` does
not look for NS, SRV, MX and CNAME records at all (and so leaves aliases behind;
use it only when neither a fresh snapshot nor WMI access is available and you know
the names are unreferenced); `-MaxSnapshotAge` is the oldest snapshot the reference
check trusts; `-Delay 2` waits two seconds after each input item.

### Create records: `New-DnsEntry`

Creates **static** records (they have no aging timestamp, so scavenging never
removes them): a host (`-Name` and `-Address`: one A or AAAA record per address
and the PTR record of each address), an alias (`-Name` and `-Target`: one CNAME
record), or many of them from a CSV file (`-InputFile`) or from the pipeline. A PTR
record gets the same TTL as its A record. Without `-TTL` the zone's default
applies.

Before anything of an item is written, `New-DnsEntry` checks it live: the name must
not be an alias, an alias needs a name without other records, the name must not
lie below a delegation, and (unless you pass `-NoPtr`) a reverse zone must cover
each address. If one check fails, nothing of that item is created. It does not
ask unless you add `-Confirm`.

```powershell
New-DnsEntry -Name srv10.contoso.local -Address 10.0.16.110 -Server dc01
```

```
Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
AddA          srv10.contoso.local             10.0.16.110                    Success
AddPtr        110.16.0.10.in-addr.arpa        srv10.contoso.local            Success
```

Run it again and both rows say `AlreadyDone`. An alias is created the same way:
`New-DnsEntry -Name ftp -Zone contoso.local -Target srv01.contoso.local -TTL 300 -Server dc01`.

**No reverse zone.** If no reverse zone on the server covers the address, the
host is **not** created, so that no host is left without its PTR record:

```powershell
New-DnsEntry -Name srv11.contoso.local -Address 10.0.99.7 -Server dc01
```

```
Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
AddA          srv11.contoso.local             10.0.99.7                      Failed      No reverse lookup zone on '...
New-DnsEntry: No reverse lookup zone on 'dc01' covers 10.0.99.7, so its PTR record cannot be created, and
'srv11.contoso.local' is not created either. Add -NoPtr to create the record without a PTR record, or
-CreateReverseZone to create the zone 99.0.10.in-addr.arpa (10.0.99.0/24) first.
```

The message names both ways out: `-NoPtr` creates the host without a PTR record,
and `-CreateReverseZone` creates the /24 zone first (an IPv6 address gets a /64
zone) with the settings of the forward zone, as part of the same run. Creating a
zone has High impact, so this asks even though `New-DnsEntry` does not ask for the
records; here the question is answered `y`:

```powershell
New-DnsEntry -Name srv11.contoso.local -Address 10.0.99.7 -CreateReverseZone -Server dc01
```

```
Create reverse zone
  99.0.10.in-addr.arpa (10.0.99.0/24) on dc01, settings from contoso.local: replication scope Custom
(DomainDnsZones.contoso.local), dynamic update Secure
[Y] Yes  [N] No  [A] Yes to all  [S] Stop (default is N): y

Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
CreateZone    99.0.10.in-addr.arpa            10.0.99.0/24                   Success
SetZoneAging  99.0.10.in-addr.arpa            Aging=True, NoRefreshInterv... Success
WARNING: Zone '99.0.10.in-addr.arpa' was created on 'dc01'. Other domain controllers see it only after Active Directory
replication plus their DsPollingInterval (180 seconds by default); until then, create its records on 'dc01'.
AddA          srv11.contoso.local             10.0.99.7                      Success
AddPtr        7.99.0.10.in-addr.arpa          srv11.contoso.local            Success
```

**Pipeline from `Get-DnsEntry`.** `New-DnsEntry` binds `Name`, `Address`, `Target`,
`TTL` and `Zone` from the pipeline by property name. An entry has `Data`, not
`Address`, so name it with `Select-Object`. This gives the address of `srv01-old` a
second name, `srv02`:

```powershell
Get-DnsEntry srv01-old.contoso.local -Server dc01 |
    Select-Object @{ Name = 'Name'; Expression = { 'srv02.contoso.local' } }, @{ Name = 'Address'; Expression = { $_.Data } }, TTL |
    New-DnsEntry -Server dc01 -WhatIf
```

```
What if: Performing the operation "Add DNS records" on target "srv02.contoso.local: add 1 A".

Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
AddA          srv02.contoso.local             10.0.16.9                      WhatIf
AddPtr        9.16.0.10.in-addr.arpa          srv02.contoso.local            Skipped     10.0.16.9 already has a PTR...
```

The A record can be created, but the address already has a PTR record that points
at the old name. That record is left alone (`Skipped`) unless you add
`-ReplacePtr`, which removes it and adds the PTR record of the new name:

```powershell
Get-DnsEntry srv01-old.contoso.local -Server dc01 |
    Select-Object @{ Name = 'Name'; Expression = { 'srv02.contoso.local' } }, @{ Name = 'Address'; Expression = { $_.Data } }, TTL |
    New-DnsEntry -Server dc01 -ReplacePtr -WhatIf
```

```
What if: Performing the operation "Add DNS records" on target "srv02.contoso.local: add 1 A, 1 PTR; remove 1 PTR
pointing elsewhere".

Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
AddA          srv02.contoso.local             10.0.16.9                      WhatIf
RemovePtr     9.16.0.10.in-addr.arpa          srv01-old.contoso.local        WhatIf
AddPtr        9.16.0.10.in-addr.arpa          srv02.contoso.local            WhatIf
```

**From a CSV file.** The columns are `Name` and `Address` (a host) or `Name` and
`Target` (an alias), and optionally `TTL` (seconds) and `Zone`. Comma or semicolon
both work (Excel in a European locale writes semicolons), and the file is read as
UTF-8. With the file

```
Name,Address,Target,TTL
srv20.contoso.local,10.0.16.120,,
srv21.contoso.local,10.0.16.121,,600
files.contoso.local,,srv20.contoso.local,
```

```powershell
New-DnsEntry -InputFile .\new-hosts.csv -Server dc01 -WhatIf
```

```
What if: Performing the operation "Add DNS records" on target "srv20.contoso.local: add 1 A, 1 PTR".

Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
AddA          srv20.contoso.local             10.0.16.120                    WhatIf
AddPtr        120.16.0.10.in-addr.arpa        srv20.contoso.local            WhatIf
What if: Performing the operation "Add DNS records" on target "srv21.contoso.local: add 1 A, 1 PTR".
AddA          srv21.contoso.local             10.0.16.121                    WhatIf
AddPtr        121.16.0.10.in-addr.arpa        srv21.contoso.local            WhatIf
What if: Performing the operation "Add DNS records" on target "files.contoso.local: add 1 CNAME".
AddCName      files.contoso.local             srv20.contoso.local            WhatIf
```

### Change records: `Set-DnsEntry`

Changes existing records **in place**; it does not delete and re-create them. At
least one of:

- `-TTL`: the TTL of every A, AAAA and CNAME record of the name and of every PTR
  record that points at it (only the exact record when you pipe an entry).
- `-Address`: moves one A or AAAA record to a new address. The PTR follows: the old
  PTR record is removed, the address is changed, and a PTR record for the new
  address is added. Exactly one record must be named, so a name with two A records
  needs a piped entry.
- `-PtrTarget`: the target of the PTR record of an IP address. If the address has
  no PTR record, one is added.
- `-Target`: the target of an alias (CNAME). The server accepts an alias that
  points at itself and `Set-DnsEntry` does not detect it, so check the name.

`-Address`, `-PtrTarget` and `-Target` exclude each other; `-TTL` combines with any
of them. A value that is already as requested gives `AlreadyDone` and is not
written. `Set-DnsEntry` asks once for every item with `-Address` (High impact) and
does not ask for the others unless you add `-Confirm`.

```powershell
Set-DnsEntry srv01.contoso.local -TTL 300 -Server dc01
```

```
Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
SetTtl        srv01.contoso.local             10.0.16.5                      Success
SetTtl        5.16.0.10.in-addr.arpa          srv01.contoso.local            Success
```

(The TTL of the PTR record is changed too. Run it again and both rows are
`AlreadyDone`.)

**Pipeline from `Get-DnsEntry`.** `db01` has two A records. The piped entry names the
one to move. Without `-WhatIf` the command asks once, and the question lists the
three steps:

```powershell
Get-DnsEntry db01.contoso.local -Server dc01 | Where-Object Data -eq '10.0.16.21' | Set-DnsEntry -Address 10.0.16.25 -Server dc01 -WhatIf
```

```
What if: Performing the operation "Change DNS records" on target "db01.contoso.local: remove PTR
21.16.0.10.in-addr.arpa -> db01.contoso.local; change A db01.contoso.local from 10.0.16.21 to 10.0.16.25; add PTR
25.16.0.10.in-addr.arpa -> db01.contoso.local".

Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
RemovePtr     21.16.0.10.in-addr.arpa         db01.contoso.local             WhatIf
SetAddress    db01.contoso.local              10.0.16.25                     WhatIf
AddPtr        25.16.0.10.in-addr.arpa         db01.contoso.local             WhatIf
```

**Dynamic records.** A record with an aging timestamp belongs to the client or the
DHCP server, so `Set-DnsEntry` skips it. With `-IncludeDynamic` it is changed, with a
warning for each record:

```powershell
Set-DnsEntry laptop07.contoso.local -TTL 600 -IncludeDynamic -Server dc01 -Confirm:$false
```

```
WARNING: Changing the dynamic A record 'laptop07.contoso.local' (10.0.16.200) because of -IncludeDynamic; the client or
the DHCP server may register the old value again.
WARNING: Changing the dynamic PTR record '200.16.0.10.in-addr.arpa' (laptop07.contoso.local) because of
-IncludeDynamic; the client or the DHCP server may register the old value again.

Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
SetTtl        laptop07.contoso.local          10.0.16.200                    Success
SetTtl        200.16.0.10.in-addr.arpa        laptop07.contoso.local         Success
```

**Every change makes a record static.** The server clears the aging timestamp of a
record that is changed, also with `-IncludeDynamic` (verified on Windows Server
2025 on 2026-10-13). The client or the DHCP server may register the old value
again. `Before.Timestamp` in the change log keeps the old timestamp.

```powershell
Get-DnsEntry laptop07.contoso.local -Server dc01 | Select-Object Name, Type, Data, Timestamp, IsStatic
$null = Set-DnsEntry laptop07.contoso.local -TTL 600 -IncludeDynamic -Server dc01 -Confirm:$false 3>$null
Get-DnsEntry laptop07.contoso.local -Server dc01 | Select-Object Name, Type, Data, Timestamp, IsStatic
```

```
Name      : laptop07.contoso.local
Type      : A
Data      : 10.0.16.200
Timestamp : 2026-10-10 02:00:00
IsStatic  : False

Name      : laptop07.contoso.local
Type      : A
Data      : 10.0.16.200
Timestamp :
IsStatic  : True
```

### Create a reverse zone: `New-DnsReverseZone`

Creates the reverse lookup zone for one network, so that PTR records can be
created. The name follows from `-NetworkId`: an IPv4 /8, /16 or /24 network, or an
IPv6 network whose prefix is a multiple of 4. The new zone is stored in Active
Directory, in the same partition as the zone named in `-CopySettingsFrom`, with that
zone's dynamic update and aging settings. It asks once (High impact).

```powershell
New-DnsReverseZone -NetworkId 10.0.99.0/24 -CopySettingsFrom contoso.local -Server dc01 -WhatIf
```

```
What if: Performing the operation "Create reverse zone" on target "99.0.10.in-addr.arpa (10.0.99.0/24) on dc01,
settings from contoso.local: replication scope Custom (DomainDnsZones.contoso.local), dynamic update Secure".

Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
CreateZone    99.0.10.in-addr.arpa            10.0.99.0/24                   WhatIf
SetZoneAging  99.0.10.in-addr.arpa            Aging=True, NoRefreshInterv... WhatIf
```

Without `-WhatIf` the command asks and creates the zone. A zone that already exists
is left exactly as it is and reported as `AlreadyDone`. The warning after a
creation is true: other domain controllers see the zone only after Active
Directory replication, so create its PTR records on the same `-Server` until then.

```powershell
New-DnsReverseZone -NetworkId 10.0.99.0/24 -CopySettingsFrom contoso.local -Server dc01
```

```
Create reverse zone
  99.0.10.in-addr.arpa (10.0.99.0/24) on dc01, settings from contoso.local: replication scope Custom
(DomainDnsZones.contoso.local), dynamic update Secure
[Y] Yes  [N] No  [A] Yes to all  [S] Stop (default is N): y

Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
CreateZone    99.0.10.in-addr.arpa            10.0.99.0/24                   Success
SetZoneAging  99.0.10.in-addr.arpa            Aging=True, NoRefreshInterv... Success
WARNING: Zone '99.0.10.in-addr.arpa' was created on 'dc01'. Other domain controllers see it only after Active Directory
replication plus their DsPollingInterval (180 seconds by default); until then, create its records on 'dc01'.
```

**Pipeline from `Get-DnsEntry`.** The entries that report `NoReverseZone` tell which
networks lack a zone. This rehearsal derives the /24 networks from their addresses:

```powershell
Get-DnsEntry '*' -Server dc01 | Where-Object PtrStatus -eq 'NoReverseZone' |
    ForEach-Object { $_.Data -replace '\.\d+$', '.0/24' } | Select-Object -Unique |
    ForEach-Object { New-DnsReverseZone -NetworkId $_ -CopySettingsFrom contoso.local -Server dc01 -WhatIf }
```

```
What if: Performing the operation "Create reverse zone" on target "17.0.10.in-addr.arpa (10.0.17.0/24) on dc01,
settings from contoso.local: replication scope Custom (DomainDnsZones.contoso.local), dynamic update Secure".

Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
CreateZone    17.0.10.in-addr.arpa            10.0.17.0/24                   WhatIf
SetZoneAging  17.0.10.in-addr.arpa            Aging=True, NoRefreshInterv... WhatIf
```

It does not create classless (RFC 2317) zones or zones for prefixes such as /23 or
/25.

### Back up zones: `Backup-DnsZone`

Saves zones from a server as zone files in a new folder on your computer, before a
risky clean-up. It changes nothing in DNS. It asks once for the whole run, but only
with `-Confirm` (its impact is Low). Without `-Zone` it saves every exportable zone
(primary zones the server did not create itself).

```powershell
Backup-DnsZone -Server dc01 -Path .\backup
```

```
Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
Backup        contoso.local                   C:\Users\you\AppData\Local\... Success
Backup        16.0.10.in-addr.arpa            C:\Users\you\AppData\Local\... Success
```

`Data` is the file; the table cuts it at the window width. The folder is
`<server>-<yyyyMMdd-HHmmss>` below `-Path` (default `%LOCALAPPDATA%\DnsTools\backup`)
and is never reused:

```powershell
Get-ChildItem .\backup -Recurse -File | Select-Object @{ Name = 'File'; Expression = { $_.FullName.Substring($_.FullName.IndexOf('\backup\') + 8) } }, Length
```

```
File                                                                 Length
----                                                                 ------
dc01-20261013-202518\backup_16.0.10.in-addr.arpa_20261013-202518.txt    786
dc01-20261013-202518\backup_contoso.local_20261013-202518.txt           850
dc01-20261013-202518\RESTORE.md                                        2918
```

`RESTORE.md` in the folder lists the files and says how to put back a single record
with `New-DnsEntry`, or a whole Active Directory-integrated zone with `dnscmd`. The
SOA serial number and the aging timestamps are not restored, and zone settings
(dynamic update, aging, replication scope, security) are not in a zone file. The
files are plain text and list every name and address of the zone: protect the
folder like the zone.

**With `Get-DnsEntry`: back up first, then remove.** The zones of the entries are
saved, then the removal is rehearsed (run it without `-WhatIf` once you have read
the rows):

```powershell
$entries = Get-DnsEntry '*-old.contoso.local' -Server dc01
Backup-DnsZone -Zone ($entries.Zone | Select-Object -Unique) -Server dc01 -Path .\backup
$entries | Remove-DnsEntry -Server dc01 -WhatIf
```

```
Action        Name                            Data                           Result      Error
------        ----                            ----                           ------      -----
Backup        contoso.local                   C:\Users\you\AppData\Local\... Success
What if: Performing the operation "Remove DNS records" on target "app01-old.contoso.local: remove 1 PTR, 1 A".
RemovePtr     31.16.0.10.in-addr.arpa         app01-old.contoso.local        WhatIf
RemoveA       app01-old.contoso.local         10.0.16.31                     WhatIf
What if: Performing the operation "Remove DNS records" on target "app02-old.contoso.local: remove 1 PTR, 1 A".
RemovePtr     32.16.0.10.in-addr.arpa         app02-old.contoso.local        WhatIf
RemoveA       app02-old.contoso.local         10.0.16.32                     WhatIf
What if: Performing the operation "Remove DNS records" on target "srv01-old.contoso.local: remove 1 PTR, 1 A".
RemovePtr     9.16.0.10.in-addr.arpa          srv01-old.contoso.local        WhatIf
RemoveA       srv01-old.contoso.local         10.0.16.9                      WhatIf
```

`Backup-DnsZone -WhatIf` creates no folder and shows the files that would be
written. A zone that is not hosted on the server, or is not exportable, gives a
`Failed` row and an error for that zone; the other zones go on.

### Planned for phase 3: `Get-DnsIssue` and `Repair-DnsIssue`

`Get-DnsIssue` (a consistency audit) and `Repair-DnsIssue` do not exist in this
version. Phase 4 plans `Undo-DnsChange`, which will read the change log.

## 6. Automation

DnsTools is written to be called from scheduled scripts. Two templates follow: a
nightly report that changes nothing, and a removal from an input file. In both, the
script passes `-Server`, never waits for a prompt, and decides from objects and exit
codes, not from console text.

### A nightly report that changes nothing

A script for Task Scheduler that only reads. It refreshes the snapshot of one DNS
server, then writes every A or AAAA record whose PTR record is not in order to a
dated CSV file. Save it, for example, as `C:\Scripts\Get-PtrReport.ps1`.

```powershell
<#
.SYNOPSIS
    Nightly PTR report: refreshes the DnsTools snapshot of one DNS server and
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
Import-Module DnsTools -ErrorAction Stop

# -Force: never prompt. -ErrorAction Stop: a zone that cannot be exported stops
# the script instead of leaving a half-fresh snapshot behind.
$null = Update-DnsSnapshot -Server $Server -Force -ErrorAction Stop

$null = New-Item -ItemType Directory -Path $OutputFolder -Force
$csv = Join-Path $OutputFolder ('ptr-problems_{0}_{1}.csv' -f $Server, (Get-Date -Format 'yyyyMMdd'))

# '*' matches every A, AAAA and CNAME owner in the snapshot. The entries stream,
# so only the problem rows are kept in memory.
$problems = @(
    Get-DnsEntry -Find '*' -Server $Server -ErrorAction Stop -WarningVariable dnsToolsWarnings |
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
if ($dnsToolsWarnings) {
    $dnsToolsWarnings | Set-Content -Path ($csv -replace '\.csv$', '.warnings.txt') -Encoding UTF8
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
  keep it in a fixed folder, set `DNSTOOLS_SNAPSHOTPATH` for the task (or in the
  script, before the first DnsTools command).
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

### A removal from an input file

A script that removes the names listed in a text file, writes the change log to a
fixed file and sets the exit code from the result rows. Save it, for example, as
`C:\Scripts\Remove-DecommissionedHosts.ps1`. The text file is the kind described in
[Remove records](#remove-records-remove-dnsentry): one name or address per line,
`#` for comments.

```powershell
<#
.SYNOPSIS
    Removes the DNS entries listed in a text file and sets the exit code from the Results.

.DESCRIPTION
    Exit code 0: every entry was removed or was already gone.
    Exit code 1: the run stopped at a failure, or could not start.
    Exit code 2: the run finished, but some entries were skipped and need a person.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string]$Server,
    [Parameter(Mandatory)] [string]$InputFile,
    [Parameter(Mandatory)] [string]$LogPath
)

Import-Module DnsTools -ErrorAction Stop

# -Force: never prompt. -ErrorAction Stop: the first entry that fails ends the run,
# after its Failed Result and its log line were written. -OutVariable keeps the
# Results that were produced up to that point. A precondition (input file missing,
# server unreachable) throws whatever -ErrorAction says, and is caught here too.
$stopped = $null
try {
    Remove-DnsEntry -InputFile $InputFile -Server $Server -Force -LogPath $LogPath -ErrorAction Stop -OutVariable results | Out-Null
}
catch {
    $stopped = $_.Exception.Message
}

$removed = @($results | Where-Object Result -eq 'Success').Count
$gone    = @($results | Where-Object Result -eq 'AlreadyDone').Count
$skipped = @($results | Where-Object Result -eq 'Skipped')
$failed  = @($results | Where-Object Result -eq 'Failed')

'{0} removed, {1} already gone, {2} skipped, {3} failed. Change log: {4}' -f $removed, $gone, $skipped.Count, $failed.Count, $LogPath
foreach ($result in $skipped) {
    'Skipped {0} {1}: {2}' -f $result.Name, $result.Data, $result.Error
}
if ($stopped) {
    "The run stopped: $stopped"
}

if ($stopped -or $failed.Count -gt 0) { exit 1 }
if ($skipped.Count -gt 0) { exit 2 }
exit 0
```

Run it from Task Scheduler with, for example:

```
powershell.exe -NoProfile -NonInteractive -File C:\Scripts\Remove-DecommissionedHosts.ps1 -Server dc01 -InputFile D:\Dns\decommissioned.txt -LogPath D:\Dns\Logs\changes.jsonl
```

Rehearse it first at a prompt: `Remove-DnsEntry -InputFile D:\Dns\decommissioned.txt
-Server dc01 -WhatIf` shows every row the script would produce. Below, the script is
run in five situations (the command is the same each time; the last line prints the
exit code). The texts after a colon, such as "Stub failure", come from the stand-ins
for the DnsServer cmdlets that were used here; a real server words them its own way.

```powershell
.\Remove-DecommissionedHosts.ps1 -Server dc01 -InputFile .\decommissioned.txt -LogPath .\changes.jsonl
"exit code: $LASTEXITCODE"
```

**Everything removed.** Exit code 0:

```
6 removed, 0 already gone, 0 skipped, 0 failed. Change log: .\changes.jsonl
exit code: 0
```

**A name is referenced** (the file lists `app01-old` and `dc01`). The run finishes,
the two records of `dc01` are `Skipped`, and exit code 2 tells a person to look:

```
2 removed, 0 already gone, 2 skipped, 0 failed. Change log: .\changes.jsonl
Skipped 10.16.0.10.in-addr.arpa dc01.contoso.local: Referenced by 1 SRV and 1 NS records (_ldap._tcp.contoso.local,
contoso.local). Add -AllowReferenced to remove it anyway.
Skipped dc01.contoso.local 10.0.16.10: Referenced by 1 SRV and 1 NS records (_ldap._tcp.contoso.local, contoso.local).
Add -AllowReferenced to remove it anyway.
exit code: 2
```

**The server refuses a write** (access denied). `-ErrorAction Stop` ends the run at
the first failed item, after its `Failed` row and its log line were written. The PTR
record of `srv01-old` was removed before its A record, and the A record is still
there. Exit code 1:

```
1 removed, 0 already gone, 0 skipped, 1 failed. Change log: .\changes.jsonl
The run stopped: Could not remove the A record '10.0.16.9' of 'srv01-old' in zone 'contoso.local': Stub failure: failed
to remove the resource record srv01-old in zone contoso.local on server dc01.
exit code: 1
```

**The server cannot be reached.** One terminating error ends the run. Exit code 1:

```
0 removed, 0 already gone, 0 skipped, 0 failed. Change log: .\changes.jsonl
The run stopped: Lookup of 'srv01-old' (A) in zone 'contoso.local' on 'dc01' failed: Stub failure: could not read
records of zone contoso.local on server dc01.
exit code: 1
```

**The input file is missing.** The same:

```
0 removed, 0 already gone, 0 skipped, 0 failed. Change log: .\changes.jsonl
The run stopped: The input file '.\missing.txt' does not exist. Check the path; a relative path is resolved from the
current folder 'C:\Users\you\AppData\Local\Temp\DnsToolsReadmeDemo'.
exit code: 1
```

Notes on the template:

- **`-Force` is what makes it unattended.** Without it, and without a console, the
  first item that needs an answer ends the run with the error `This session cannot
  prompt. Re-run with -Force to confirm all actions, or -WhatIf to preview.` and
  nothing is removed. This is `Remove-DnsEntry -InputFile .\decommissioned.txt
  -Server dc01` in a session that cannot prompt:

  ```
  Remove-DnsEntry: This session cannot prompt. Re-run with -Force to confirm all actions, or -WhatIf to preview.
  ```

- **`-ErrorAction Stop` stops at the first failed item.** That is the cautious
  choice for removals: the log shows exactly where the run ended, and running the
  script again does only what is not done yet (`AlreadyDone` for the rest).
  Without it a failed item gives an error and a `Failed` row and the run goes on.
- **`-OutVariable results` keeps the rows.** `$results = @(Remove-DnsEntry ...)` would
  lose them all when `-ErrorAction Stop` ends the run, because the assignment never
  completes. The `catch` also takes preconditions that throw whatever `-ErrorAction`
  says (a missing input file, an unreachable server).
- **Exit codes are yours to choose.** Here 0 means nothing needs a person, 1 means
  the run stopped or could not start, 2 means a person should read the `Skipped`
  lines. A `Skipped` row is not an error, so `-ErrorAction Stop` does not stop for
  it.
- **The task's account** needs permission to change records, WMI access to
  `root\MicrosoftDNS` on the server (or a fresh snapshot, see
  [Requirements](#2-requirements)) for the reference check, and a writable folder for
  the log. Always pass `-Server` and `-LogPath`.
- **Keep the log.** Read it with the commands in [The change log](#7-the-change-log).
  The local snapshot is not updated by the removal.

### What the commands guarantee

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
  `DnsTools.<Function>.<Reason>`) and the command goes on with the next item.
  `-ErrorAction Stop` turns the first such error into a terminating one, which
  makes the script stop at the first failed item.
- **Real lookup failures are errors, a missing record is not.** When
  `Get-DnsEntry` reads a node live and the server answers with a real failure
  (access denied, server unreachable), it writes a non-terminating error with the
  `ErrorId` `DnsTools.Get-DnsLiveRecord.LookupFailed` and goes on. A record that
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
- **`-Force` means zero prompts.** `Update-DnsSnapshot` and the change commands
  have a confirmation. `Update-DnsSnapshot` asks only with `-Confirm`; the change
  commands ask as described in [section 1](#1-what-dnstools-does). In a session
  that cannot prompt, a command that needs an answer and has no `-Force` writes the
  error "This session cannot prompt. Re-run with -Force to confirm all actions, or
  -WhatIf to preview." and does nothing.
- **Output streams** as objects are found, so `Select-Object -First` and
  `Export-Csv` start at once. `-Verbose` shows every server round-trip and the
  resolved defaults (server, snapshot folder).
- **`-Credential`** sends every DnsServer call through a CIM session. If none can
  be opened the command throws; it never falls back to the logged-on user. A
  snapshot export then copies the file over WinRM, because the `admin$` share
  cannot use alternate credentials.

### What the change commands guarantee

`Remove-DnsEntry`, `New-DnsEntry`, `Set-DnsEntry`, `New-DnsReverseZone` and
`Backup-DnsZone` keep the rules above and add these:

- **One result row for every step, as it happens.** Each step (removing a PTR
  record, adding an A record, creating a zone) writes exactly one `DnsTools.Result`
  object, immediately, and one line to the change log. The properties are `Action`,
  `Name`, `Type`, `Data`, `Result`, `Error`, `Zone`, `NodeName`, `Server`, `Id`,
  `BatchId` and `Timestamp`. Read these objects, not the console text, to see what
  happened.
- **`Result` is one of `Success`, `Failed`, `Skipped`, `WhatIf` and `AlreadyDone`.**
  `AlreadyDone` is a success: the record is already gone, already there with the
  same data, the value is already set, or the zone is already hosted. `Skipped`
  carries its reason in `Error` (a referenced name, a dynamic record, a read-only
  zone, a reference check that could not run, a declined prompt). `Pending` is
  reserved and is not written by these commands.
- **A failure in one item does not stop the run.** It is a non-terminating error
  (`ErrorId` `DnsTools.<Command>.<Reason>`, for example
  `DnsTools.Remove-DnsEntry.PatternNotAllowed`) plus a `Failed` row. The row and its
  log line are written before the error, so `-ErrorAction Stop` still leaves the
  line in the log. `-ErrorAction Stop` turns the first such error into a terminating
  one, which stops the script at the first failed item.
- **Access denied is `Failed`, never `AlreadyDone`.**
- **Three things end the whole run** with one terminating error, after the row of
  the item concerned; it is not repeated for every item: a server that cannot be reached
  (`ErrorId` `DnsTools.<Command>.ServerUnreachable`), a session that cannot prompt
  (`DnsTools.Confirm.NonInteractive`) and the answer `S` at a prompt (`Operation
  stopped by the operator.`). A parameter combination that cannot work (for example
  `Set-DnsEntry` with nothing to change) is a terminating error before anything is
  read.
- **`-Force` means zero prompts, and nothing else.** The safety overrides are
  separate switches: `-AllowReferenced`, `-IncludeDynamic`, `-ReplacePtr` and
  `-SkipReferenceCheck`.
- **A step that is already in place never asks.** The question is shown only when
  something is to be written. If you answer `N`, every pending step of that item is
  `Skipped` with `Declined at the confirmation prompt.` and is logged.
- **A rehearsal never counts as a change.** `-WhatIf` creates no folder, writes no
  record, and does not become the session's "writer server" (see the warning in
  [Troubleshooting](#8-troubleshooting)). The rows say `WhatIf` and are logged.
- **`-Delay <seconds>` waits once per input item**, after all of its steps, also
  after a failed item and never under `-WhatIf` (`Remove-DnsEntry`, `New-DnsEntry`
  and `Set-DnsEntry`). It is whole seconds.
- **Do not decide success from `-ErrorVariable`.** As with `Get-DnsEntry`, it also
  collects errors that the module handled itself. Look at the rows
  (`$results | Where-Object Result -eq 'Failed'`) or capture the error stream with
  `2>&1`.
- **The local snapshot is not patched after a change.** With `-Verbose`,
  `Remove-DnsEntry`, `New-DnsEntry` and `Set-DnsEntry` end a run with a reminder to
  run `Update-DnsSnapshot`.
- **Running a batch again is safe.** A step that was done reports `AlreadyDone`;
  only what is left is done.

## 7. The change log

The five change commands write one line to the change log for every step, so you
can see afterwards what was changed, by whom, and what the record looked like
before. A step is logged whatever its result: `Success`, `AlreadyDone`, `Skipped`,
`Failed`, and also `-WhatIf` rehearsals (`Result` = `WhatIf`), so you can review
what a rehearsal would have done. `Get-DnsEntry`, `Get-DnsSnapshot` and
`Update-DnsSnapshot` change no DNS record, write no log and have no `-LogPath`.

**Which file.** The file is chosen in this order:

1. `-LogPath <file>` (a relative path is taken from the current folder)
2. the environment variable `DNSTOOLS_LOGPATH`
3. `%LOCALAPPDATA%\DnsTools\log\DnsTools_<yyyy-MM>.jsonl` (one file per month)

The folder is created when it is missing. The file only grows; nothing deletes old
lines.

**One line per step.** The format is JSON Lines: one JSON object per line. This is the
last line of a removal, with line breaks added by `ConvertTo-Json`:

```powershell
$null = Remove-DnsEntry srv01-old.contoso.local -Server dc01 -Confirm:$false -LogPath .\changes.jsonl
Get-Content -Path .\changes.jsonl -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json | ConvertTo-Json -Depth 4
```

```
{
  "Id": "8a479c22",
  "BatchId": "4830e1d3",
  "Timestamp": "2026-10-13T20:25:19.2212599+02:00",
  "Operator": "CONTOSO\\admin",
  "Server": "dc01",
  "Action": "RemoveA",
  "Zone": "contoso.local",
  "NodeName": "srv01-old",
  "Name": "srv01-old.contoso.local",
  "Type": "A",
  "Data": "10.0.16.9",
  "Before": {
    "Data": "10.0.16.9",
    "Ttl": 3600,
    "Timestamp": null,
    "IsStatic": true
  },
  "After": null,
  "Result": "Success",
  "Error": null
}
```

The fields, always in this order and always all present (`null` means "not
applicable"):

| Field | Holds |
|---|---|
| `Id` | A GUID for this line. It is also the `Id` of the result object that the command returned. |
| `BatchId` | A GUID shared by every line of one command run. |
| `Timestamp` | When the result was written, ISO 8601 with offset, for example `2026-10-09T15:00:00.0000000+02:00`. |
| `Operator` | `DOMAIN\user` who ran the command. |
| `Server` | The DNS server that was changed. |
| `Action` | The step, as in the result table of [section 5](#before-you-change-anything-the-habits-and-the-result-rows). |
| `Zone` | The zone that holds the record (for `CreateZone` the new zone). |
| `NodeName` | The node within the zone (`@` for the apex). |
| `Name` | The owner of the record as an FQDN; for a PTR record the reverse name. |
| `Type` | `A`, `AAAA`, `CNAME`, `PTR`, `DHCID` or `Zone` (for `Backup`); `null` for the other zone steps. |
| `Data` | The address or target the step is about. `Name` and `Data` are on every line, so even a `WhatIf` or `Failed` line without `Before` and `After` says which record it concerns. |
| `Before` | The record before the step: `Data`, `Ttl`, `Timestamp` (`null` for a static record) and `IsStatic`. |
| `After` | The record after the step, with the same four keys. |
| `Result` | `Success`, `Failed`, `Skipped`, `WhatIf` or `AlreadyDone`. |
| `Error` | Why the step was skipped or failed. |

**What `Before` and `After` hold.** They are the whole record, so that a change can
be put back by hand:

| Steps | `Before` | `After` |
|---|---|---|
| `RemovePtr`, `RemoveA`, `RemoveAAAA`, `RemoveCName`, `RemoveDhcid` | The record that was removed (`Success` only). | `null` |
| `AddA`, `AddAAAA`, `AddPtr`, `AddCName` | `null`, except for `AlreadyDone`: the record that was already there. | The new record, read back from the server (`Success` only). |
| `SetTtl`, `SetAddress`, `SetPtrTarget`, `SetTarget` | The record as it was read before the change. Also on `WhatIf`, `Skipped`, `Failed` and `AlreadyDone`. | The record read back after the change (`Success` only). `After.Timestamp` is `null` on Windows Server 2025: a changed record is static (see [Known limitations](#9-known-limitations)). |
| `CreateZone`, `SetZoneAging`, `Backup` | `null` | `null` |

For a `RemovePtr` that `New-DnsEntry -ReplacePtr` or `Set-DnsEntry -Address` does,
`Before` is the PTR record that was removed. `AddPtr` has `After` as above.

**Reading the log.** Always read it with `-Encoding UTF8` (see below). The monthly
file of the default location:

```powershell
$null = Remove-DnsEntry srv01-old.contoso.local -Server dc01 -Confirm:$false
$log = Join-Path $env:LOCALAPPDATA ('DnsTools\log\DnsTools_{0}.jsonl' -f (Get-Date -Format 'yyyy-MM'))
Get-Content -Encoding UTF8 $log | ConvertFrom-Json | Format-Table Timestamp, Action, Name, Result
```

```
Timestamp           Action    Name                    Result
---------           ------    ----                    ------
2026-10-13 20:25:19 RemovePtr 9.16.0.10.in-addr.arpa  Success
2026-10-13 20:25:19 RemoveA   srv01-old.contoso.local Success
```

Read a file with `-LogPath` the same way and turn it into objects with
`ConvertFrom-Json`:

```powershell
$null = Remove-DnsEntry srv01-old.contoso.local, app01-old.contoso.local -Server dc01 -Confirm:$false -LogPath .\changes.jsonl
$null = New-DnsEntry -Name srv10.contoso.local -Address 10.0.16.110 -Server dc01 -LogPath .\changes.jsonl
$log = Get-Content -Path .\changes.jsonl -Encoding UTF8 | ConvertFrom-Json
$log | Format-Table Timestamp, Action, Name, Result
```

```
Timestamp           Action    Name                     Result
---------           ------    ----                     ------
2026-10-13 20:25:19 RemovePtr 9.16.0.10.in-addr.arpa   Success
2026-10-13 20:25:19 RemoveA   srv01-old.contoso.local  Success
2026-10-13 20:25:19 RemovePtr 31.16.0.10.in-addr.arpa  Success
2026-10-13 20:25:19 RemoveA   app01-old.contoso.local  Success
2026-10-13 20:25:19 AddA      srv10.contoso.local      Success
2026-10-13 20:25:19 AddPtr    110.16.0.10.in-addr.arpa Success
```

**Find one run, with `BatchId`.** Every row that a command returns has the
`BatchId` of its lines in the log. This shows the last batch of the file:

```powershell
$null = Remove-DnsEntry srv01-old.contoso.local, app01-old.contoso.local -Server dc01 -Confirm:$false -LogPath .\changes.jsonl
$null = New-DnsEntry -Name srv10.contoso.local -Address 10.0.16.110 -Server dc01 -LogPath .\changes.jsonl
$log = Get-Content -Path .\changes.jsonl -Encoding UTF8 | ConvertFrom-Json
$batchId = $log[-1].BatchId
$log | Where-Object BatchId -eq $batchId | Format-Table Action, Name, Result
```

```
Action Name                     Result
------ ----                     ------
AddA   srv10.contoso.local      Success
AddPtr 110.16.0.10.in-addr.arpa Success
```

**Find what was skipped or failed:**

```powershell
$null = Remove-DnsEntry dc01.contoso.local, srv01-old.contoso.local -Server dc01 -Confirm:$false -LogPath .\changes.jsonl
Get-Content -Path .\changes.jsonl -Encoding UTF8 | ConvertFrom-Json | Where-Object Result -in 'Skipped', 'Failed' | Format-List Action, Name, Result, Error
```

```
Action : RemovePtr
Name   : 10.16.0.10.in-addr.arpa
Result : Skipped
Error  : Referenced by 1 SRV and 1 NS records (_ldap._tcp.contoso.local, contoso.local). Add -AllowReferenced to remove
          it anyway.

Action : RemoveA
Name   : dc01.contoso.local
Result : Skipped
Error  : Referenced by 1 SRV and 1 NS records (_ldap._tcp.contoso.local, contoso.local). Add -AllowReferenced to remove
          it anyway.
```

**When the log cannot be written.** Writing the log never stops a DNS change. If
the file is locked, the writer waits 200 milliseconds and tries once more. If that
fails too, or the path cannot be created, the command writes the warning `Could not
write the change log '<path>': <reason> The change was not logged.` (once for every
line that could not be written) and carries on. The change is done; only the line
is missing. See [Troubleshooting](#8-troubleshooting).

**Encoding.** Windows PowerShell 5.1 writes a UTF-8 byte-order mark (BOM) when it
*creates* the file; PowerShell 7 does not. A BOM is never written mid-file and
both editions read either, so the log can be shared. Keep `-Encoding UTF8` when
you read it, or Windows PowerShell 5.1 garbles non-ASCII characters.

**Undoing a change.** `Undo-DnsChange`, which will read these lines and put the
`Before` records back, is planned for phase 4. It does not exist in this version.
Until then the log tells you what to put back by hand, and `Backup-DnsZone` before a
clean-up gives you the whole zone as it was.

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
RSAT is not installed on the computer running DnsTools. Install it as in
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
session could be opened with it. DnsTools never falls back to your own account.

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
`DnsTools.Update-DnsSnapshot.ExportFailed`; ends with "The previous snapshot of
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
still on the server, in `%windir%\System32\dns` (name `dnstools_<zone>_<time>.txt`).
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
  snapshot metadata '<path>' has schema version '<n>'; this version of DnsTools
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
snapshot folder (or the folder in `DNSTOOLS_SNAPSHOTPATH`) is read-only, full
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
(Get-DnsIssue in a later phase reports them)."** The address has PTR
records, but no A or AAAA record uses it: the host is gone and its PTR stayed
behind. Decide whether the targets still exist (`Get-DnsEntry -Find <target>`) and,
if not, remove the PTR records: `Remove-DnsEntry <address>` removes the PTR records
of an address that point at names without an A or AAAA record (see
[Remove records](#remove-records-remove-dnsentry)).

**Error "Lookup of '<node>' (<type>) in zone '<zone>' on '<server>' failed:
<reason>"** (ErrorId `DnsTools.Get-DnsLiveRecord.LookupFailed`). The server
answered a live lookup with a real failure, such as access denied or an
unreachable server, and `Get-DnsEntry` could not tell whether the record exists.
You see one error per record type (A, AAAA, CNAME) and the search goes on with the
next zone, value and server. A missing record is not an error and prints nothing.
Fix the cause named in `<reason>`. With `-ErrorAction Stop` the first such error
stops the command.

**Error "'<value>' contains wildcards, but -Exact only looks up exact names.
Remove -Exact to search the snapshot with the pattern, or give an exact name."**
(ErrorId `DnsTools.Get-DnsEntry.PatternWithExact`.) Self-explanatory. A value
with wildcards that PowerShell cannot read, such as `sql[*` (an unbalanced `[`),
gives the error "'<value>' is not a valid wildcard pattern: <reason> Escape a
literal [ or ] with a backtick (`[)." (ErrorId `DnsTools.Get-DnsEntry.InvalidPattern`).

**Warning "Looking up '<name>' in N forward zones on '<server>' (3N queries per
name). Specify -Zone to look in one zone only."** `-Exact` without `-Zone` reads
the name in every hosted forward zone; with more than 10 zones that is many
queries. Add `-Zone`.

**Warning "'<entry>' is not a valid network in CIDR notation (for example
10.0.50.0/24 or fd00::/8); it is ignored."** A `-MarkDhcpRange` entry is
misspelled. The other entries are still used.

### Changing records

These are the messages of `Remove-DnsEntry`, `New-DnsEntry`, `Set-DnsEntry`,
`New-DnsReverseZone` and `Backup-DnsZone`. `<name>`, `<server>`, `<zone>`,
`<address>` and similar stand for the actual values. A `Skipped` or `Failed` row
carries the text in its `Error` column (`Format-List Action, Name, Result, Error`
shows it whole). A `Failed` row also gives an error with an `ErrorId` of the form
`DnsTools.<Command>.<Reason>`, for example `DnsTools.New-DnsEntry.NoReverseZone`.
Warnings appear as `WARNING:` lines. Where the commands word the same problem
differently, each wording is quoted.

#### An item was skipped

**Skipped: "Referenced by <counts> <records> (<owners>). Add -AllowReferenced to
remove it anyway."**
(`Remove-DnsEntry`.) NS, SRV or MX records point at the name; typically a domain
controller or a mail server. A real text reads `Referenced by 1 SRV and 1 NS records
(_ldap._tcp.contoso.local, contoso.local). Add -AllowReferenced to remove it
anyway.` At most three owners are listed, then `...`. The whole item is skipped, one
row for every record that would have been removed. Leave the name alone, or remove
the records that point at it first. If you are sure, add `-AllowReferenced`; it
removes the name and writes the warning "'<name>': <the text above, without its last
sentence> It is removed anyway (-AllowReferenced); those records will point at a
missing name."

**Skipped: "The reference check could not run (root\MicrosoftDNS on '<server>' is not
reachable). Run Update-DnsSnapshot first, or pass -SkipReferenceCheck."**
(`Remove-DnsEntry`.) To know what points at a name, the command reads a snapshot
that is younger than `-MaxSnapshotAge` (24 hours by default) and otherwise asks the
server over WMI. Neither worked. Run `Update-DnsSnapshot -Server <server>` and try
again, or make WMI reachable (CIM over WinRM or DCOM, and permission to read
`root\MicrosoftDNS`). `-AllowReferenced` does not help here. `-SkipReferenceCheck`
removes the names without looking and writes the warning "-SkipReferenceCheck: SRV,
NS, MX and CNAME records that point at the names in this run are not looked for on
'<server>'. Referenced names are changed anyway and their CNAME aliases stay
behind."

**Skipped: "Dynamic record, owned by the client or the DHCP server; re-register it
instead, or pass -IncludeDynamic."**
(`Set-DnsEntry`.) The record has an aging timestamp, so a client or the DHCP server
owns it. Let the client register it again, or add `-IncludeDynamic`. Every dynamic
record that is then changed gives the warning "Changing the dynamic <type> record
'<name>' (<data>) because of -IncludeDynamic; the client or the DHCP server may
register the old value again." (`<type>` is `A`, `AAAA` or `PTR`), and the record
becomes static. `Remove-DnsEntry` does not skip dynamic records. It removes them and
writes the warning "'<name>' (<type> <data>) is a dynamic record. The client or the
DHCP server may register it again; see the notes in Get-Help Remove-DnsEntry
-Full." In an Active Directory-integrated zone the removed name stays as a
tombstoned object for about 7 days, and that object keeps the old permissions: with
secure dynamic updates only the previous owner can register the name again until
the tombstone is gone.

**Skipped: the zone is read-only.** The server holds the zone as a secondary or stub
zone, or the server created it itself. The text differs by command:

- `Remove-DnsEntry`: "Zone '<zone>' is not writable on this server ('<server>' holds
  it as a <type> zone). Remove the record on the server that hosts the primary
  zone." (`<type>` is `Secondary`, `Stub` or `automatically created`. A PTR record in
  a read-only reverse zone does not stop the A record from being removed; a
  read-only forward zone skips the whole name.) For a stub or forwarder zone: "Zone
  '<zone>' is a <type> zone on '<server>'; its records are not hosted there. Remove
  the record on the server that hosts the zone."
- `Set-DnsEntry`: "Zone '<zone>' is not writable on '<server>' (zone type <type>);
  change the record on a server that hosts the primary zone."
- `New-DnsEntry`: "Zone '<zone>' is read-only on '<server>' (not a primary copy).
  Create the record on the server that hosts the primary zone." (For a step that
  removes a PTR record it ends "Change it on the server that hosts the primary
  zone.")

Run the command with `-Server` set to a server that hosts the primary copy. (An
Active Directory-integrated zone is primary on every domain controller that hosts it.)

**Skipped: "Declined at the confirmation prompt."** You answered `N`, or just pressed
Enter, at the question. Every pending step of that item is skipped and logged. Run
the command again to be asked again.

**Skipped: "Kept to avoid an orphaned PTR: a PTR record that points at '<name>' could
not be removed."** (`Remove-DnsEntry`, on the row of the A or AAAA record.) The row
above it, `RemovePtr` with `Failed`, says why (often access denied). The A record is
kept so that no PTR record is left without its host. Fix the cause and run the same
command again. Two related texts on later steps: "Kept because '<name>' still has an
A or AAAA record." (the DHCID record) and "Kept because '<name>' was not removed."
(an alias).

**Skipped: "<address> already has a PTR record for '<names>'. Add -ReplacePtr to
replace it with one for '<name>'."** (`New-DnsEntry`.) The A record was created (or
already existed), but the address already has a PTR record that points at another
name. It is left alone. If that PTR record is stale, add `-ReplacePtr` and run the
command again. `Set-DnsEntry -Address` says "The PTR record <reverse name> already
points at <names>. Add -ReplacePtr to replace it."

**"Removed by the DNS server together with the A record; -KeepPtr cannot be honoured
on this server."** (`Remove-DnsEntry -KeepPtr`: a `RemovePtr` row with `Success`,
plus the same text as one warning per run.) Windows Server 2025 deletes the PTR
record when its A record is removed. It is not an error. DnsTools never re-creates
the PTR record. A similar text from `Set-DnsEntry`: "Removed by the DNS server
together with the A record change." It appears when `root\MicrosoftDNS` is not
available, so the TTL is changed with `Set-DnsServerResourceRecord`, which makes the
server delete the PTR record; `Set-DnsEntry` adds it again (an `AddPtr` row) and
writes the warning "root\MicrosoftDNS on '<server>' is not available; TTL changes of
A/AAAA records re-create their PTR records." Make WMI reachable to avoid it.

#### An item failed before anything was written

**"'<value>' is a pattern. Change commands take exact names or addresses; find the
entries with Get-DnsEntry -Find '<value>', check them, and pipe them to this
command."** (`PatternNotAllowed`.) The value has `*` or `?`. Do what the message
says.

**ZoneNotFound.** The change command could not tell which zone the name belongs to:

- "'<value>' is not a fully qualified name. Use the FQDN (for example
  <name>.contoso.local), or specify -Zone."
- "'<value>' is not in any forward zone hosted on '<server>'. Check the spelling, or
  specify the -Server that hosts its zone." (For a reverse name such as
  `5.16.0.10.in-addr.arpa` the hint is "Reverse lookup names are not accepted; give
  the IP address instead.")
- "Zone '<zone>' is not hosted on '<server>'. Check -Zone (or the Zone column), or
  specify another -Server."
- "'<value>' is not inside zone '<zone>'. Remove -Zone (or the Zone column) to use
  the zone the name belongs to."
- "The zone '<zone>' of entry '<name>' is not hosted on '<server>'. Run the command
  against the server the entry came from (-Server), or read the entry again from
  this server with Get-DnsEntry." (A piped entry names a zone that this server does
  not host.)

**NoReverseZone: "No reverse lookup zone on '<server>' covers <address>, so its PTR
record cannot be created, and '<name>' is not created either. Add -NoPtr to create
the record without a PTR record, or -CreateReverseZone to create the zone <zone>
(<network>) first."** (`New-DnsEntry`.) No reverse zone on the server covers the
address, so the host is not created. If the host already has its A record, the middle
reads "although '<name>' already has its <type> record". Choose `-NoPtr`, or
`-CreateReverseZone`, or create the zone yourself with `New-DnsReverseZone` (a
file-backed or Legacy forward zone needs that: `-CreateReverseZone` cannot pass
`-ReplicationScope`). `Set-DnsEntry -Address` does not fail for this: it removes the
old PTR record, changes the address, skips the new PTR record and writes the warning
"No reverse zone for <address> is hosted on '<server>', so no PTR record was added.
Create the zone with New-DnsReverseZone and run Set-DnsEntry again."

**NodeIsCname: "'<name>' is an alias (CNAME for '<target>'). A name with an alias
cannot have other records; remove the alias first, or choose another name."**
(`New-DnsEntry -Address`.) A name that is an alias cannot also have an A record.
Remove the alias with `Remove-DnsEntry`, or pick another name.

**CnameCollision: "'<name>' already has <types> record(s). An alias (CNAME) cannot
share its name with other records; remove them first, or choose another name."**
(`New-DnsEntry -Target`; `<types>` is for example `A`.) The alias name is already
used by other records.

**Delegated: "'<name>' lies below '<label>.<zone>', which is delegated to other name
servers (<servers>). Create the record in the delegated zone, on a server that hosts
it."** (`New-DnsEntry`.) An NS record between the name and the zone hands the part
below it to other servers. Another `Delegated` text: "The PTR record of <address> is
delegated (RFC 2317): '<reverse name>' is an alias for '<target>', whose zone is not
hosted on '<server>'. Create the PTR record on the server that hosts that zone, or
add -NoPtr."

**"'<name>' already has <type> <address>, with a TTL of <n> s instead of the requested
<m> s. Change it with Set-DnsEntry -TTL <m>."** (A warning from `New-DnsEntry`; the
row is `AlreadyDone`.) The record exists with another TTL. `New-DnsEntry` does not
change existing records.

**"Nothing to change. Specify at least one of -TTL, -Address, -PtrTarget or -Target."**
and **"-Address, -PtrTarget and -Target change different records. Give only one of
them per call; -TTL can be combined with any of them."** (`Set-DnsEntry`,
terminating errors, nothing was read.)

**Ambiguous: "'<name>' has <n> A/AAAA records (<addresses>); -Address changes exactly
one. Pipe the entry to change from Get-DnsEntry, for example: Get-DnsEntry '<name>'
-Server <server> | Where-Object Data -eq '<address>' | Set-DnsEntry -Address
<new address> -Server <server>"** (`Set-DnsEntry`.) The name has several A records.
Pipe the one you mean. A similar text: "-Target changes the target of an alias
(CNAME), but '<name>' has A/AAAA records and no CNAME." (`NotACname`).

**"-NoPtr cannot be combined with -CreateReverseZone or -ReplacePtr: with -NoPtr no
PTR record is created, replaced or given a zone. Remove one of them."**
(`New-DnsEntry`, terminating.)

**New-DnsReverseZone:**

- "An IPv4 reverse zone covers a /8, /16 or /24 network; '<network>' has prefix
  /<prefix>. Use <allowed> instead." (`InvalidNetworkId`, terminating, before the
  server is contacted. An IPv6 prefix must be a multiple of 4.)
- "Zone '<zone>' (-CopySettingsFrom) is not hosted on '<server>'. Give a zone hosted
  on that server; the new zone copies its replication, dynamic update and aging
  settings." (`ZoneNotFound`; a `Failed` `CreateZone` row.)
- "Zone '<zone>' is not stored in Active Directory (file-backed), so the new zone
  cannot copy its directory partition. Specify -ReplicationScope (Domain, Forest,
  Legacy or Custom)." (`ReplicationScopeRequired`; for a Legacy source zone the
  middle reads "uses the Legacy replication scope".)
- The warning "Zone '<zone>' was created on '<server>'. Other domain controllers see
  it only after Active Directory replication plus their DsPollingInterval (180
  seconds by default); until then, create its records on '<server>'." appears after
  every creation. It is not an error: use the same `-Server` until the zone has
  replicated.

**Backup-DnsZone:**

- "Zone '<zone>' is not hosted on '<server>'. Check the name, or list the zones with
  Get-DnsServerZone -ComputerName <server>." (`ZoneNotFound`; a `Failed` row, the
  other zones go on.)
- "Zone '<zone>' on '<server>' cannot be exported because <reason>. Only primary
  zones are exported; export it on the server that hosts the primary copy."
  (`ZoneNotExportable`; `<reason>` is for example "it is a Secondary zone".)
- "The backup folder '<folder>' already exists and is never reused, so that an
  earlier backup is not overwritten. Wait a second and run the command again, or
  specify another -Path."

**Input files (`-InputFile`).** The command stops before it changes anything, with
one of: "The input file '<path>' does not exist. Check the path; a relative path is
resolved from the current folder '<folder>'." / "The input file '<path>' is empty
(only blank lines or '#' comments). Put one name or address per line, or a CSV
header with a Name column and one row per entry." / "The input file '<path>' has a
CSV header but no rows. Add one row per entry below the header." A CSV column
that the command does not know gives the warning "The input file '<path>' has
column(s) that are ignored: <columns>. Known columns: Name, Address, Target, TTL,
Zone." Save the file as UTF-8 (with a BOM from Windows PowerShell 5.1) for names
with non-ASCII characters.

#### The run, the session and the server

**Warning "This session already changed DNS on '<server 1>'; changes on '<server 2>'
may be lost if both touch the same node before replication."** A change command ran
on a second server in the same PowerShell session. Active Directory replicates
changes between domain controllers, and two changes to the same node on two servers
can overwrite each other. Stay on one server (`-Server`) for a batch, and start a
new session for the other server. A `-WhatIf` run does not count.

**Error "This session cannot prompt. Re-run with -Force to confirm all actions, or
-WhatIf to preview."** (`DnsTools.Confirm.NonInteractive`; see also
[Prompts, language mode and files](#prompts-language-mode-and-files).) A change
command needed an answer and the session has no console: a scheduled task,
`-NonInteractive`, a remote command. The run ends at the first item and changes
nothing. Add `-Force` (or `-Confirm:$false`) for an unattended run, or `-WhatIf` to
preview.

**ServerUnreachable.** The server could not be reached (RPC 1722, or a WinRM or CIM
transport failure). The row of the item concerned is `Failed`, then one terminating
error ends the run, and the rest of the input is not processed. The text differs a
little by command:

- `Remove-DnsEntry` and `New-DnsReverseZone`: "The DNS server '<server>' cannot be
  reached: <reason> The run was stopped; the remaining input was not processed.
  Check the server and run the command again."
- `New-DnsEntry` and `Set-DnsEntry`: the same text as `Remove-DnsEntry`.

Check the server name, that the DNS Server service runs and that WinRM or CIM is
reachable, then run the same command again; what was done reports `AlreadyDone`.

**A lookup failed.** The command could not read the records of an item, so it does
not guess. `Remove-DnsEntry`: "'<name>' was not changed because a lookup failed:
<reason>" (`LookupFailed`). `Set-DnsEntry`: "Could not read the records of '<name>'
on '<server>': <reason>". `New-DnsEntry`: "Lookup of '<node>' (<type>) in zone
'<zone>' on '<server>' failed: <reason>". The `<reason>` is the text of the
DnsServer cmdlet, for example access denied. Fix the cause and run the command
again.

**A write failed.** "Could not remove the <type> record '<data>' of '<node>' in zone
'<zone>': <reason>", "Could not create <type> record '<name>' -> '<data>' in zone
'<zone>': <reason>", "Could not change the <type> record '<node>' -> '<data>' in zone
'<zone>': <reason>" and "Could not create zone '<zone>' on '<server>': <reason>". The
`<reason>` is the DnsServer cmdlet's text. Access denied (Win32 error 5) is
`Failed`, never `AlreadyDone`: your account may not change that zone.

**Warning "Could not write the change log '<path>': <reason> The change was not
logged."** The change was made, but its line could not be written: the folder is not
writable, the file is locked for longer than 200 milliseconds, or the path is not
valid. You get one warning for every line. Fix the path (`-LogPath`, or
`DNSTOOLS_LOGPATH`) and read the rows of the command to see what was done.

**Warning "A records without a PTR cannot be found by address without a snapshot. No
snapshot of '<server>' exists, so only the names that PTR records point at are
removed; run Update-DnsSnapshot -Server <server> first to find the others too."**
(`Remove-DnsEntry` with an IP address.) Without a snapshot the command finds A
records only through the PTR records of the address.

**Warning "The entry '<name>' was read from '<server 1>', but this command changes
'<server 2>'. It is read again and removed on '<server 2>'."** A piped entry came from
another server than `-Server`. `Set-DnsEntry` says "The entry '<name>' was read from
'<server 1>' but is changed on '<server 2>'." Check that you meant this.

**Warning "Zone '<zone>' on '<server>' has zone scopes besides the default
(<scopes>). Remove-DnsEntry changes the default scope only; records in the other
scopes stay."** The zone has extra zone scopes. Only the default scope is changed.

### Prompts, language mode and files

**"This session cannot prompt. Re-run with -Force to confirm all actions, or
-WhatIf to preview."** (ErrorId `DnsTools.Confirm.NonInteractive`.) The command
needed confirmation and the session is not interactive (scheduled task, remote
command, `-NonInteractive`). Add `-Force` to confirm everything, or `-WhatIf` to
preview. `Update-DnsSnapshot -Confirm` and the change commands can ask (see
[Changing records](#changing-records)). If you answer `S` at a prompt, the command
stops with "Operation stopped by the operator."

**"Only core types are supported in this language mode"** (or "Method invocation
is supported only on core types"). Your session is in Constrained Language Mode and
a DnsTools command tried something that mode forbids. The module is written not
to, so this is a defect, not a fault in your policy: report it to the maintainer
with the full error text and the output of
`$ExecutionContext.SessionState.LanguageMode`.

**Non-ASCII names look garbled.** A file was saved without a BOM and read as ANSI
by Windows PowerShell 5.1. Re-save it as UTF-8 with BOM or read it with
`Get-Content -Encoding UTF8`. This applies to name lists you feed in and to the
log; DnsTools's own files carry a BOM.

**`Import-Module` cannot find the module, or says "running scripts is disabled
on this system".** The folder is in the wrong place or misnamed
(`Get-Module -ListAvailable DnsTools` must list it), or the execution policy
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
  `DNSTOOLS_SNAPSHOTPATH` is set, and `dc01` and `dc01.contoso.local` are
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
  `\DDD`, and DnsTools decodes them as octal digits because that is what
  Windows writes (`\040` is a space). A name that really contains a backslash
  followed by three digits is therefore ambiguous and is read as the escape.
- **IPv6 reverse lookups only at nibble boundaries**, and **only the default zone
  scope is exported**; other zone scopes are not in snapshots.
- **Classless (RFC 2317) reverse zones are detected, not created or repaired.** They
  are classified (`Delegated`). `New-DnsEntry` puts a PTR record into a classless
  zone that the server hosts, but no command creates such a zone or repairs its
  records. `New-DnsReverseZone`, and so `New-DnsEntry -CreateReverseZone`, make IPv4
  zones for /8, /16 and /24 networks and IPv6 zones on a nibble boundary only.
- **Live lookup failures are followed by "No entry matched".** The errors say why.
- **`-ErrorVariable` and `$Error` also hold the silenced "not found" answers** of
  the DnsServer cmdlets. Use `2>&1` to tell real errors from them.
- **`Export-Csv` writes list properties as `System.String[]`.** Join `PtrTargets`,
  `SharedWith`, `Aliases` and `ReferencedBy` first (see the template in
  [Automation](#6-automation)).
- **Every change makes a record static, and aging timestamps cannot be restored.**
  On the Windows Server 2025 server of the live test (2026-10-13), every change of
  a record clears its aging timestamp: `Set-DnsEntry` leaves a changed record
  static, also one that was dynamic and changed with `-IncludeDynamic`, and
  `Before.Timestamp` in the change log keeps the old timestamp. A record that is
  removed and created again is static too; only its data comes back. The client or
  the DHCP server may register a dynamic record again. Timestamps in snapshots are
  as old as the export.
- **The snapshot is not patched after a change, and snapshot searches show the state
  at export time.** `Remove-DnsEntry`, `New-DnsEntry` and `Set-DnsEntry` do not
  change the local snapshot, so pattern and substring searches, address lookups
  through the snapshot and the `SharedWith`, `Aliases` and `ReferencedBy` properties
  show the old state until you run `Update-DnsSnapshot`. `Remove-DnsEntry` uses a
  snapshot for its reference check only if it is younger than `-MaxSnapshotAge`.
- **The server may delete a PTR record by itself, depending on its version.** On the
  tested Windows Server 2025, the server deletes the PTR record that points at an A
  record's name whenever that A record is removed or changed, by any method; older
  servers commonly leave it. DnsTools removes PTR records first itself, reads them
  again afterwards and reports what the server did (`-KeepPtr` may be overruled by
  the server). Check what your own servers do before you rely on either behaviour.
- **TTL changes go through WMI.** `Set-DnsEntry -TTL` uses the WMI method `Modify` in
  `root\MicrosoftDNS`, because `Set-DnsServerResourceRecord` makes the server delete
  the PTR record. Without WMI access it uses the DnsServer cmdlet, adds the PTR
  records again and warns. That fallback is covered by the stub tests; it was not
  tried against a live server.
- **A CNAME that points at itself is accepted.** The server accepts it, and DnsTools
  does not detect alias loops in this version. Check the target of `New-DnsEntry
  -Target` and `Set-DnsEntry -Target`.
- **`-Delay` is whole seconds**, as with `Restart-Computer -Delay`. It waits once for
  every input item, not for every record.
- **What the change commands leave alone.** `Remove-DnsEntry` removes only A, AAAA,
  CNAME, PTR and DHCID records. It does not remove the NS, SRV or MX records that
  point at a name, does not follow an alias of an alias and does not remove the
  parent-zone CNAME of an RFC 2317 delegation. `New-DnsEntry` and `Set-DnsEntry`
  accept no wildcard names and no other record types. All change commands change one
  server at a time (Active Directory replication carries the change to the other
  domain controllers), and `Remove-DnsEntry` changes the default zone scope only (it
  warns when a zone has other zone scopes).
- **Verified live on Windows Server 2025 only.** The change commands were tested
  against a domain controller running Windows Server 2025 on 2026-10-13 (a test
  zone and two test reverse zones). Other server versions were not.
- **`Owner` is always `$null`** in this version. It is reserved for a later phase
  and will need a Full-language session.
- **Constrained Language Mode with the `DnsServer` module is not yet verified**
  on a policy-enforced host. The read commands, and `Remove-DnsEntry`,
  `New-DnsEntry`, `Set-DnsEntry` and `Backup-DnsZone` under `-WhatIf`, are exercised
  in a constrained session against stand-ins for the DnsServer cmdlets.
- The performance figures in the design (for example parsing 550 000 lines in
  under 20 seconds) are targets, not promises, and the duration of a zone export
  and its effect on the server for a zone of that size have not been measured yet.
- **Do not merge streams into the output** (`*>&1`, `3>&1`) when a script captures
  the Result objects of a change command: the warning and information records
  would be mixed into the objects the script reads. Use `-WarningVariable`,
  `-InformationVariable` and `-ErrorVariable` instead, as the automation template
  in section 6 does.