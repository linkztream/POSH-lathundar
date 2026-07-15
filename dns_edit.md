# Windows AD-integrerad DNS – PowerShell Lathund

En praktisk lathund för administration och felsökning av Microsoft DNS Server med PowerShell.

---

# Slå upp DNS-poster

## Standarduppslag

```powershell
Resolve-DnsName contoso.local
```

Slår upp `contoso.local` med datorns konfigurerade DNS-server.

---

## Ange specifik DNS-server

```powershell
Resolve-DnsName contoso.local -Server 10.0.16.2
```

Slår upp `www.poe-vault.com` hos DNS-servern `10.0.16.2`.

---

## A-post

```powershell
Resolve-DnsName dc01.contoso.local -Type A
```

Visar endast A-poster.

---

## AAAA-post

```powershell
Resolve-DnsName dc01.contoso.local -Type AAAA
```

Visar endast IPv6-adresser.

---

## MX-poster

```powershell
Resolve-DnsName contoso.local -Type MX
```

Visar domänens mailservrar.

---

## NS-poster

```powershell
Resolve-DnsName contoso.local -Type NS
```

Visar domänens namnservrar.

---

## SRV-poster (Domain Controllers)

```powershell
Resolve-DnsName _ldap._tcp.dc._msdcs.contoso.local -Type SRV
```

Visar vilka Domain Controllers som annonserar LDAP.

---

## PTR (Reverse Lookup)

```powershell
Resolve-DnsName 10.0.16.25 -Type PTR
```

Slår upp reverse DNS.

---

# Hantera DNS-zoner

## Lista alla zoner

```powershell
Get-DnsServerZone
```

---

## Lista zoner på annan server

```powershell
Get-DnsServerZone -ComputerName DC01
```

---

## Visa replikeringsscope

```powershell
Get-DnsServerZone contoso.local |
Select ZoneName,ReplicationScope
```

Exempel på replikeringsscope:

- Forest
- Domain
- Legacy
- Custom

---

# Visa DNS-poster

## Alla poster

```powershell
Get-DnsServerResourceRecord -ZoneName contoso.local
```

---

## Endast A-poster

```powershell
Get-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -RRType A
```

---

## Endast PTR-poster

```powershell
Get-DnsServerResourceRecord `
    -ZoneName 16.0.10.in-addr.arpa `
    -RRType PTR
```

---

## Visa en specifik post

```powershell
Get-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -Name server01
```

---

# Skapa poster

## Skapa A-post

```powershell
Add-DnsServerResourceRecordA `
    -ZoneName contoso.local `
    -Name server01 `
    -IPv4Address 10.0.16.100
```

---

## Skapa A-post + PTR

```powershell
Add-DnsServerResourceRecordA `
    -ZoneName contoso.local `
    -Name server01 `
    -IPv4Address 10.0.16.100 `
    -CreatePtr
```

Skapar både A- och PTR-post.

---

## Skapa PTR

```powershell
Add-DnsServerResourceRecordPtr `
    -ZoneName 16.0.10.in-addr.arpa `
    -Name 100 `
    -PtrDomainName server01.contoso.local
```

---

## Skapa CNAME

```powershell
Add-DnsServerResourceRecordCName `
    -ZoneName contoso.local `
    -Name files `
    -HostNameAlias server01.contoso.local
```

---

# Ändra poster

## Ändra IP-adress

```powershell
$old = Get-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -Name server01

$new = $old.Clone()
$new.RecordData.IPv4Address = [IPAddress]"10.0.16.150"

Set-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -OldInputObject $old `
    -NewInputObject $new
```

---

## Ändra IP-adress och uppdatera PTR

(Motsvarar GUI-valet **Update associated pointer (PTR) record**.)

```powershell
$old = Get-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -Name server01

$new = $old.Clone()
$new.RecordData.IPv4Address = [IPAddress]"10.0.16.150"

Set-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -OldInputObject $old `
    -NewInputObject $new `
    -CreatePtr
```

> **OBS!**
>
> Det finns inget kommando som enbart aktiverar "Update associated PTR record" på en befintlig post.
>
> `-CreatePtr` används endast när posten skapas eller uppdateras.

---

# Ta bort poster

## Ta bort A-post

```powershell
Remove-DnsServerResourceRecord `
    -ZoneName contoso.local `
    -Name server01 `
    -RRType A
```

---

## Ta bort PTR

```powershell
Remove-DnsServerResourceRecord `
    -ZoneName 16.0.10.in-addr.arpa `
    -Name 100 `
    -RRType PTR
```

---

# DNS-cache

## Rensa DNS-cache

```powershell
Clear-DnsClientCache
```

eller

```cmd
ipconfig /flushdns
```

---

## Registrera DNS igen

```powershell
Register-DnsClient
```

eller

```cmd
ipconfig /registerdns
```

---

# DNS-servrar

## Visa DNS-servrar

```powershell
Get-DnsClientServerAddress
```

---

## Ändra DNS-servrar

```powershell
Set-DnsClientServerAddress `
    -InterfaceAlias Ethernet `
    -ServerAddresses 10.0.16.2,10.0.16.3
```

---

# DNS Server-konfiguration

## Visa Forwarders

```powershell
Get-DnsServerForwarder
```

---

## Lägg till Forwarders

```powershell
Add-DnsServerForwarder `
    -IPAddress 1.1.1.1,8.8.8.8
```

---

## Visa Scavenging

```powershell
Get-DnsServerScavenging
```

---

## Kör Scavenging

```powershell
Start-DnsServerScavenging
```

---

# Testa DNS

## Testa DNS-port

```powershell
Test-NetConnection dc01.contoso.local -Port 53
```

---

## Testa namnuppslag

```powershell
Test-Connection dc01
```

---

# Active Directory

## Lista Domain Controllers

```powershell
Get-ADDomainController -Filter * |
Select Name,IPv4Address
```

---

# Loggar

## Visa DNS-loggen

```powershell
Get-WinEvent `
    -LogName "DNS Server" `
    -MaxEvents 20
```

---

# Felsökning

## DNS-test

```cmd
dcdiag /test:dns
```

Kontrollerar:

- DNS-registrering
- SRV-poster
- Replikering
- Delegationer
- Zonstatus

---

## Replikeringsöversikt

```cmd
repadmin /replsummary
```

---

## Visa replikeringsstatus

```cmd
repadmin /showrepl
```

---

## Tvinga AD-replikering

```cmd
repadmin /syncall /AdeP
```

---

# Mina 10 viktigaste kommandon

```powershell
Resolve-DnsName namn -Server dnsserver
Resolve-DnsName ip -Type PTR

Get-DnsServerZone
Get-DnsServerResourceRecord -ZoneName zon

Add-DnsServerResourceRecordA -CreatePtr

Register-DnsClient

Clear-DnsClientCache

Get-DnsServerForwarder

dcdiag /test:dns

repadmin /replsummary
```

---

# Vanliga RRType-värden

| Typ | Beskrivning |
|------|-------------|
| A | IPv4-adress |
| AAAA | IPv6-adress |
| PTR | Reverse Lookup |
| CNAME | Alias |
| MX | Mailserver |
| NS | Namnserver |
| SOA | Start of Authority |
| SRV | Active Directory-tjänster |
| TXT | Textposter (SPF, DKIM m.m.) |

---

# Tips

### Visa hjälp

```powershell
Get-Help Resolve-DnsName -Full
```

---

### Exempel

```powershell
Get-Help Add-DnsServerResourceRecordA -Examples
```

---

### Sök cmdlets

```powershell
Get-Command *Dns*
```

---

### Sök parametrar

```powershell
Get-Command Set-DnsServerResourceRecord -Syntax
```

---

> **Tips:** De flesta `DnsServer`-cmdlets kräver att modulen **DnsServer** finns installerad (ingår på Windows Server med DNS-rollen eller via RSAT på klienter). Kör vid behov:
>
> ```powershell
> Import-Module DnsServer
> ```
