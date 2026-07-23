# Windows AD-integrerad DNS – PowerShell-lathund

En praktisk lathund för administration och felsökning av Microsoft DNS Server med PowerShell.

> De flesta serverkommandon kräver modulen `DnsServer`, som finns på en DNS-server eller installeras via RSAT.

```powershell
Import-Module DnsServer
```

---

## Slå upp DNS-poster

### Standarduppslag

```powershell
Resolve-DnsName www.poe-vault.com
```

Slår upp `www.poe-vault.com` med datorns konfigurerade DNS-server.

### Ange specifik DNS-server

```powershell
Resolve-DnsName www.poe-vault.com -Server 10.0.16.2
```

Slår upp `www.poe-vault.com` hos DNS-servern `10.0.16.2`.

### A-post

```powershell
Resolve-DnsName dc01.contoso.local -Type A
```

Visar endast IPv4-adresser.

### AAAA-post

```powershell
Resolve-DnsName dc01.contoso.local -Type AAAA
```

Visar endast IPv6-adresser.

### MX-poster

```powershell
Resolve-DnsName contoso.local -Type MX
```

Visar domänens e-postservrar.

### NS-poster

```powershell
Resolve-DnsName contoso.local -Type NS
```

Visar domänens namnservrar.

### SRV-poster för Domain Controllers

```powershell
Resolve-DnsName _ldap._tcp.dc._msdcs.contoso.local -Type SRV
```

Visar vilka Domain Controllers som annonserar LDAP-tjänsten.

### PTR – reverse lookup

```powershell
Resolve-DnsName 10.0.16.25 -Type PTR
```

Slår upp motsvarande PTR-post.

---

## Hantera DNS-zoner

### Lista alla zoner

```powershell
Get-DnsServerZone
```

### Lista zoner på en annan DNS-server

```powershell
Get-DnsServerZone -ComputerName DC01
```

### Visa replikeringsscope

```powershell
Get-DnsServerZone -Name contoso.local |
    Select-Object ZoneName, ReplicationScope
```

Vanliga replikeringsscope:

| Scope | Betydelse |
|---|---|
| `Forest` | Alla DNS-servrar i skogen |
| `Domain` | Alla DNS-servrar i domänen |
| `Legacy` | Äldre domänomfattande replikering |
| `Custom` | Egen application directory partition |

---

## Visa DNS-poster

### Alla poster i en zon

```powershell
Get-DnsServerResourceRecord -ZoneName contoso.local
```

### Endast A-poster

```powershell
Get-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -RRType A
```

### Endast PTR-poster

```powershell
Get-DnsServerResourceRecord `
    -ZoneName 16.0.10.in-addr.arpa `
    -RRType PTR
```

### En specifik post

```powershell
Get-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -Name server01
```

### Från en annan DNS-server

```powershell
Get-DnsServerResourceRecord `
    -ComputerName DC01 `
    -ZoneName contoso.local `
    -Name server01
```

---

## Skapa DNS-poster

### Skapa A-post

```powershell
Add-DnsServerResourceRecordA `
    -ZoneName contoso.local `
    -Name server01 `
    -IPv4Address 10.0.16.100
```

### Skapa A-post och tillhörande PTR-post

```powershell
Add-DnsServerResourceRecordA `
    -ZoneName contoso.local `
    -Name server01 `
    -IPv4Address 10.0.16.100 `
    -CreatePtr
```

Motsvarar GUI-valet **Create associated pointer (PTR) record**.

### Skapa PTR-post manuellt

```powershell
Add-DnsServerResourceRecordPtr `
    -ZoneName 16.0.10.in-addr.arpa `
    -Name 100 `
    -PtrDomainName server01.contoso.local
```

### Skapa CNAME

```powershell
Add-DnsServerResourceRecordCName `
    -ZoneName contoso.local `
    -Name files `
    -HostNameAlias server01.contoso.local
```

---

## Ändra DNS-poster

### Ändra IP-adress

```powershell
$oldRecord = Get-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -Name server01 `
    -RRType A

$newRecord = $oldRecord.Clone()
$newRecord.RecordData.IPv4Address = [IPAddress]'10.0.16.150'

Set-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -OldInputObject $oldRecord `
    -NewInputObject $newRecord
```

### Ändra IP-adress och skapa eller uppdatera PTR

```powershell
$oldRecord = Get-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -Name server01 `
    -RRType A

$newRecord = $oldRecord.Clone()
$newRecord.RecordData.IPv4Address = [IPAddress]'10.0.16.150'

Set-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -OldInputObject $oldRecord `
    -NewInputObject $newRecord `
    -CreatePtr
```

> `-CreatePtr` används när A-posten skapas eller uppdateras. Det är inte en permanent egenskap eller kryssruta som lagras på själva A-posten.

---

## Ta bort DNS-poster

### Ta bort en A-post

```powershell
Remove-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -Name server01 `
    -RRType A
```

### Hämta och pipe:a till borttagning

```powershell
Get-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -Name server01 `
    -RRType A |
Remove-DnsServerResourceRecord `
    -ZoneName contoso.local
```

### Utan extra bekräftelse från cmdleten

```powershell
Get-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -Name server01 `
    -RRType A |
Remove-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -Force
```

### Filtrera poster före borttagning

```powershell
Get-DnsServerResourceRecord `
    -ZoneName contoso.local |
Where-Object HostName -Like 'TEST*'
```

Kontrollera resultatet först. Lägg därefter till borttagningen:

```powershell
Get-DnsServerResourceRecord `
    -ZoneName contoso.local |
Where-Object HostName -Like 'TEST*' |
Remove-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -Force
```

> En vanlig DNS-administratör kör filtret först. En modig DNS-administratör kör allt direkt. En erfaren DNS-administratör har blivit den förstnämnda.

---

## DNS-cache

### Rensa klientens DNS-cache

```powershell
Clear-DnsClientCache
```

Alternativt:

```cmd
ipconfig /flushdns
```

### Registrera klientens DNS-poster igen

```powershell
Register-DnsClient
```

Alternativt:

```cmd
ipconfig /registerdns
```

---

## Klientens DNS-servrar

### Visa konfigurerade DNS-servrar

```powershell
Get-DnsClientServerAddress
```

### Ändra DNS-servrar

```powershell
Set-DnsClientServerAddress `
    -InterfaceAlias Ethernet `
    -ServerAddresses 10.0.16.2, 10.0.16.3
```

---

## DNS-serverkonfiguration

### Visa forwarders

```powershell
Get-DnsServerForwarder
```

### Lägg till forwarders

```powershell
Add-DnsServerForwarder `
    -IPAddress 1.1.1.1, 8.8.8.8
```

### Visa scavenging-inställningar

```powershell
Get-DnsServerScavenging
```

### Starta scavenging

```powershell
Start-DnsServerScavenging
```

---

## Testa DNS

### Testa TCP-port 53

```powershell
Test-NetConnection dc01.contoso.local -Port 53
```

> Normal DNS-trafik använder vanligtvis UDP 53. `Test-NetConnection` testar här enbart TCP-porten.

### Testa namnuppslag via ping

```powershell
Test-Connection dc01
```

---

## Active Directory

### Lista Domain Controllers

```powershell
Get-ADDomainController -Filter * |
    Select-Object Name, IPv4Address
```

---

## Loggar

### Visa de senaste DNS Server-händelserna

```powershell
Get-WinEvent `
    -LogName 'DNS Server' `
    -MaxEvents 20
```

---

## Felsökning

### Kör DNS-diagnostik på en Domain Controller

```cmd
dcdiag /test:dns
```

### Visa replikeringsöversikt

```cmd
repadmin /replsummary
```

### Visa detaljerad replikeringsstatus

```cmd
repadmin /showrepl
```

### Tvinga AD-replikering

```cmd
repadmin /syncall /AdeP
```

---

## Tio användbara vardagskommandon

```powershell
Resolve-DnsName namn -Server dnsserver
Resolve-DnsName ip-adress -Type PTR

Get-DnsServerZone
Get-DnsServerResourceRecord -ZoneName zon

Add-DnsServerResourceRecordA -CreatePtr

Remove-DnsARecordWithPtr -Name namn -ZoneName zon -WhatIf

Register-DnsClient
Clear-DnsClientCache

Get-DnsServerForwarder

dcdiag /test:dns
repadmin /replsummary
```

---

## Vanliga RRType-värden

| Typ | Beskrivning |
|---|---|
| `A` | IPv4-adress |
| `AAAA` | IPv6-adress |
| `PTR` | Reverse lookup |
| `CNAME` | Alias |
| `MX` | E-postserver |
| `NS` | Namnserver |
| `SOA` | Start of Authority |
| `SRV` | Tjänstepost, bland annat för Active Directory |
| `TXT` | Textdata, exempelvis SPF och verifieringsposter |

---

## Hjälp och syntax

### Fullständig hjälp

```powershell
Get-Help Resolve-DnsName -Full
```

### Exempel

```powershell
Get-Help Add-DnsServerResourceRecordA -Examples
```

### Sök DNS-kommandon

```powershell
Get-Command *Dns*
```

### Visa syntax

```powershell
Get-Command Set-DnsServerResourceRecord -Syntax
```
