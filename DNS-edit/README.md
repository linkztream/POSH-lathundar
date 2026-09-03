# DnsLathund

PowerShell-modul för DNS-administration i **mycket stora** Windows-DNS-miljöer.
Ersätter de tidigare lösa scripten `Remove-DnsRecordsFromFile .ps1` och
`remove-dnsEntry.ps1` i den här mappen.

## Varför modulen finns

- **550 000 poster i en zon.** Ett ofiltrerat `Get-DnsServerResourceRecord
  -ZoneName zon` ger timeout långt innan det returnerar något. Modulen gör
  därför **aldrig** ofiltrerad zon-enumeration. Punktuppslag går via `-Name`,
  mönstersökning och helzonssvep via `Export-DnsServerZone` plus en egen
  BIND-parser som läser filen rad för rad med `[System.IO.File]::ReadLines()`.
  (CIM/WQL används för zonfiltrerade frågor i `Get-DnsOrphanPtr -Method Cim`,
  men inte för mönster — DNS-providern stödjer inte `LIKE`.)
- **Det kosmetiska felet på Server 2022/2025.** Parameteruppsättningen
  `Remove-DnsServerResourceRecord -Name ... -RRType ... -RecordData ...`
  *raderar posten men felrapporterar ändå*. Modulen tar därför bort poster
  uteslutande i pipelineform:

  ```powershell
  $record | Remove-DnsServerResourceRecord -ZoneName $zon -ComputerName $server -Force
  ```

  Det är samma operation, utan det falska felet.
- **Föräldralösa PTR-poster.** När A-posten raderas men PTR ligger kvar (eller
  raderades i fel ordning) blir reverse-zonen full av skräp. `Get-DnsOrphanPtr`
  hittar dem, `Remove-DnsPtrRecord` städar dem — med omverifiering mot servern
  före varje borttagning.
- **Ordningen PTR först, sedan A.** Ett avbrott mitt i lämnar då en ofarlig
  "A utan PTR" som en omkörning självläker. Motsatt ordning skapar exakt de
  föräldralösa PTR-poster modulen är byggd för att jaga.

## Installation och import

Modulen är ren PowerShell — inga DLL:er, inget `Add-Type`, ingen signering att
hantera.

```powershell
Import-Module .\DnsLathund
# eller med full sökväg:
Import-Module 'D:\Development\Powershell\POSH-lathundar\DNS-edit\DnsLathund\DnsLathund.psd1'
```

- Fungerar i **Windows PowerShell 5.1** och **PowerShell 7** (`CompatiblePSEditions
  = Desktop, Core`).
- **RSAT: DNS Server Tools (`DnsServer`-modulen) krävs vid användning, inte vid
  import.** Modulen listar medvetet inte `DnsServer` i `RequiredModules` — den
  ska gå att importera och testa på en utvecklingsmaskin utan RSAT. Saknas
  modulen när ett kommando faktiskt behöver den kommer ett tydligt fel:

  > DnsServer-modulen (RSAT) saknas på den här datorn. Installera RSAT: DNS
  > Server Tools och försök igen.

- `-ComputerName` är **obligatorisk** på samtliga publika funktioner. Modulen
  har inga inbyggda defaults för server eller domän (det hade de gamla scripten,
  och det var en av anledningarna till att de skrevs om).

## De fem funktionerna

### `Find-DnsRecord`

Söker upp A/PTR-par och returnerar `DnsLathund.RecordPair`-objekt med
relationen klassificerad (`1:1`, `PTR saknas`, `PTR pekar på annat namn`,
`Matchande PTR finns, men relationen är inte 1:1`).

Indata kan vara ett namn, en IPv4-adress (reverse-uppslag först) eller ett
wildcardmönster. Wildcard kräver `-ZoneName` och går via zonexport + parsning
(WQL `LIKE` stöds inte av DNS-providern — den returnerar tyst noll rader).

```powershell
Find-DnsRecord -Identity 'srv01.contoso.local' -ComputerName 'dc01'
Find-DnsRecord -Identity '10.0.16.5' -ComputerName 'dc01'
Find-DnsRecord -Identity 'web*' -ZoneName 'contoso.local' -ComputerName 'dc01'
```

### `Get-DnsOrphanPtr`

Letar upp PTR-poster vars målnamn saknar A-post (`Status = 'NoARecord'`) eller
pekar på ett namn vars A-post har en annan adress (`Status = 'IpMismatch'`,
kräver `-IncludeMismatch`).

Standardvägen är `-Method ZoneExport`: forwardzonerna exporteras och indexeras i
en `Dictionary` (FQDN → IP-lista, `OrdinalIgnoreCase`), sedan sveps
reverse-zonerna och jämförelsen görs i .NET. `-Method Cim` finns som alternativ.

```powershell
Get-DnsOrphanPtr -ComputerName 'dc01'
Get-DnsOrphanPtr -ComputerName 'dc01' -ReverseZone '16.0.10.in-addr.arpa' -IncludeMismatch
```

### `Remove-DnsHostRecord`

Tar bort A-post + matchande PTR. Tre parameteruppsättningar:

| Uppsättning | Indata |
|---|---|
| `ByName` | `-Name <string[]>` (även från pipelinen, alias `HostName`) |
| `ByFile` | `-Path <fil>` — en post per rad, blanka rader och `#`-kommentarer hoppas över, listan sorteras unikt |
| `ByInputObject` | `DnsLathund.RecordPair` från `Find-DnsRecord` |

Kör alltid en preflight-rapport först, sedan en `ShouldContinue`-grind (om inte
`-Force`) och därefter `ShouldProcess` per post. `ConfirmImpact = 'High'`.

```powershell
# Fil-baserat: en rad per namn, torrkörning först
Remove-DnsHostRecord -Path .\avvecklade-servrar.txt -ComputerName 'dc01' -WhatIf

# Skarpt, obevakat
Remove-DnsHostRecord -Path .\avvecklade-servrar.txt -ComputerName 'dc01' -Force

# Enstaka namn
Remove-DnsHostRecord -Name 'gammal-srv.contoso.local' -ComputerName 'dc01'
```

Extra växlar: `-KeepPtr` (rör inte PTR), `-IncludeUnmatchedPtr` (ta bort A-posten
även när PTR pekar på ett annat namn — utan den flaggan hoppas posten över).

### `Remove-DnsPtrRecord`

Tar emot `DnsLathund.OrphanPtr` från `Get-DnsOrphanPtr`. Varje post
**omverifieras mot servern** innan den tas bort: PTR-posten hämtas på nytt med
ett punktuppslag och det kontrolleras att A-posten fortfarande saknas.
Exportdata kan vara timmar gammalt, och en post som hunnit återskapas får inte
raderas.

```powershell
# Torrkörning av hela kedjan
Get-DnsOrphanPtr -ComputerName 'dc01' | Remove-DnsPtrRecord -ComputerName 'dc01' -WhatIf

# Skarpt, en zon i taget
Get-DnsOrphanPtr -ComputerName 'dc01' -ReverseZone '16.0.10.in-addr.arpa' |
    Remove-DnsPtrRecord -ComputerName 'dc01' -Force
```

### `Invoke-DnsRecordEditor`

Interaktivt: sök → välj → **Redigera / Ta bort / Avbryt**, eller **Skapa** när
inget matchar. Menyn använder `$Host.UI.PromptForChoice` och fungerar därför
över remoting och på Server Core (`Out-GridView` används medvetet inte).

Fler än 20 träffar ger en uppmaning att förfina sökningen i stället för en
oläslig lista.

```powershell
Invoke-DnsRecordEditor -Identity 'srv01.contoso.local' -ComputerName 'dc01'
Invoke-DnsRecordEditor -Identity '10.0.16.5' -ComputerName 'dc01' -LogPath 'C:\Temp\dns.jsonl'
```

## `-Credential`-regeln

DnsServer-cmdletarna **saknar `-Credential`**. Enda sättet att köra dem som
någon annan än den inloggade användaren är en CIM-session mot
`root\MicrosoftDNS`.

Modulens regel är därför:

> **Anges `-Credential` måste anropet gå via en CIM-session. Går ingen session
> att upprätta FALLERAR operationen** med felet
> `Ingen CIM-session kunde upprättas mot '<server>', vilket krävs när -Credential anges.`

Det finns alltså **ingen tyst nedgradering** till den inloggade användarens
rättigheter. En sådan fallback vore särskilt farlig vid borttagning: man skulle
tro att man kör som tjänstekontot men i själva verket köra som sig själv.

Regeln är samlad i den privata hjälparen `Get-DnsServerParameter`, som
returnerar `@{ CimSession = ... }` eller `@{ ComputerName = ... }` och splattas
in i varje DnsServer-anrop.

`Get-DnsCimSession` provar WSMan först, verifierar sessionen mot
`MicrosoftDNS_Server` med 15 sekunders timeout och gör därefter ett omförsök över
DCOM. Sessioner cachas per server och stängs när modulen tas bort.

## Loggformat

Varje operation — **även `-WhatIf`** — skrivs som exakt en rad komprimerad JSON
(JSONL).

Sökväg väljs i ordningen:

1. `-LogPath <fil>`
2. miljövariabeln `DNSLATHUND_LOGPATH`
3. `%LOCALAPPDATA%\DnsLathund\DnsLathund_<yyyy-MM>.jsonl`

Fält per rad: `Timestamp` (ISO 8601, format `o`), `Operator` (`DOMAIN\user`),
`ComputerName`, `Action` (`RemoveA` | `RemovePtr` | `SetA` | `AddA` | `AddPtr`),
`ZoneName`, `RecordName`, `RecordType`, `RecordData`, `Result`
(`Success` | `Failed` | `Skipped` | `WhatIf`) och `Error`.

Loggfel avbryter aldrig DNS-flödet — de rapporteras med `Write-Warning`.

Läs loggen med:

```powershell
$logg = "$env:LOCALAPPDATA\DnsLathund\DnsLathund_$(Get-Date -Format 'yyyy-MM').jsonl"

Get-Content -LiteralPath $logg | ConvertFrom-Json |
    Where-Object { $_.Result -eq 'Failed' } |
    Format-Table Timestamp, Operator, Action, RecordName, RecordData, Error
```

## Manuell testsekvens mot en riktig miljö

Modulens automatiska tester körs helt offline med stubbade DnsServer-cmdletar.
Innan modulen används skarpt bör den köras igenom mot en riktig server. Gör det
i en **testzon**, aldrig i produktion.

1. **Skapa testzoner** på DNS-servern:

   ```powershell
   Add-DnsServerPrimaryZone -Name 'dnslathund.test' -ZoneFile 'dnslathund.test.dns' -ComputerName 'dc01'
   Add-DnsServerPrimaryZone -NetworkId '10.99.99.0/24' -ZoneFile '99.99.10.in-addr.arpa.dns' -ComputerName 'dc01'
   ```

2. **Seeda 3–4 poster** — ett rent par, ett par utan PTR och en PTR som pekar på
   ett namn utan A-post (den föräldralösa):

   ```powershell
   Add-DnsServerResourceRecordA -Name 'test01' -ZoneName 'dnslathund.test' -IPv4Address '10.99.99.11' -CreatePtr -ComputerName 'dc01'
   Add-DnsServerResourceRecordA -Name 'test02' -ZoneName 'dnslathund.test' -IPv4Address '10.99.99.12' -CreatePtr -ComputerName 'dc01'
   Add-DnsServerResourceRecordA -Name 'test03' -ZoneName 'dnslathund.test' -IPv4Address '10.99.99.13' -ComputerName 'dc01'
   Add-DnsServerResourceRecordPtr -Name '99' -ZoneName '99.99.10.in-addr.arpa' -PtrDomainName 'foraldralos.dnslathund.test.' -ComputerName 'dc01'
   ```

3. **Kör varje funktion med `-WhatIf` först** och läs utdata noga:

   ```powershell
   Find-DnsRecord -Identity 'test01.dnslathund.test' -ComputerName 'dc01'
   Find-DnsRecord -Identity '10.99.99.12' -ComputerName 'dc01'
   Find-DnsRecord -Identity 'test*' -ZoneName 'dnslathund.test' -ComputerName 'dc01'

   Get-DnsOrphanPtr -ComputerName 'dc01' -ReverseZone '99.99.10.in-addr.arpa'

   Remove-DnsHostRecord -Name 'test01.dnslathund.test' -ComputerName 'dc01' -WhatIf
   Get-DnsOrphanPtr -ComputerName 'dc01' -ReverseZone '99.99.10.in-addr.arpa' |
       Remove-DnsPtrRecord -ComputerName 'dc01' -WhatIf
   ```

4. **Verifiera loggen** — `-WhatIf`-körningarna ska ha lämnat rader med
   `Result = 'WhatIf'`:

   ```powershell
   Get-Content -LiteralPath "$env:LOCALAPPDATA\DnsLathund\DnsLathund_$(Get-Date -Format 'yyyy-MM').jsonl" |
       ConvertFrom-Json | Select-Object -Last 20 |
       Format-Table Timestamp, Action, ZoneName, RecordName, Result
   ```

   Kontrollera också att inga poster faktiskt försvann:
   `Get-DnsServerResourceRecord -ZoneName 'dnslathund.test' -ComputerName 'dc01'`.

5. **Kör skarpt** — samma kommandon utan `-WhatIf`. Svara på grindarna första
   gången i stället för att slänga in `-Force`; poängen är att se hur
   preflight-rapporten ser ut.

6. **Avsluta med `Get-DnsOrphanPtr`** för att bekräfta att reverse-zonen är ren
   efter borttagningarna:

   ```powershell
   Get-DnsOrphanPtr -ComputerName 'dc01' -ReverseZone '99.99.10.in-addr.arpa' -IncludeMismatch
   ```

7. **Städa upp** testzonerna när du är klar:

   ```powershell
   Remove-DnsServerZone -Name 'dnslathund.test' -ComputerName 'dc01' -Force
   Remove-DnsServerZone -Name '99.99.10.in-addr.arpa' -ComputerName 'dc01' -Force
   ```

## Kända begränsningar

- **Endast IPv4 / A + PTR.** AAAA och IPv6-reverse (`ip6.arpa`) hanteras inte.
  Det är samma avgränsning som de gamla scripten hade och är uttalat framtida
  arbete.
- **Klasslösa reverse-zoner enligt RFC 2317 stöds inte.** Zoner med `/` i namnet
  (exempelvis `0/25.16.0.10.in-addr.arpa`) hoppas över med en varning i stället
  för att tolkas fel.
- **WQL `LIKE` fungerar inte mot DNS-providern.** Verifierat mot riktig server
  (2026-09-03): `root\MicrosoftDNS` stödjer inte `LIKE`-operatorn och
  returnerar **tyst noll rader** i stället för ett fel. Wildcard-sökning i
  `Find-DnsRecord` går därför alltid via zonexport + parsning. Exakt match
  (`=`) och zonfiltrering (`ContainerName='zon'`) fungerar däremot, så
  `Get-DnsOrphanPtr -Method Cim` är verifierad live, inklusive
  `PTRDomainName`-projektionen.

## Utvecklingsanteckningar

- Alla kodfiler (`.ps1`, `.psm1`, `.psd1`) sparas som **UTF-8 med BOM**. Utan BOM
  läser Windows PowerShell 5.1 filen som ANSI och åäö går sönder. Det finns ett
  test (`Kodningskonvention`) som vaktar detta.
- Testsviten körs offline:

  ```powershell
  Invoke-Pester -Path .\DnsLathund\Tests
  Invoke-ScriptAnalyzer -Path .\DnsLathund -Recurse -Severity Error
  ```
