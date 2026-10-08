<#
.SYNOPSIS
    Skapar en HTML-rapport med alla datorobjekt (servrar) i ett OU och dess under-OU:n,
    presenterade som ett klickbart träd.

.DESCRIPTION
    Hämtar alla OU:n och datorobjekt under angivet OU och bygger en fristående HTML-sida
    (ingen extern CSS/JS) där OU:n kan fällas ut och ihop, ungefär som i dsa.msc.

    Sidan innehåller:
      - Sammanfattning: antal servrar, OU:n, inaktiverade konton samt fördelning per OS
      - Sökfält som filtrerar på namn, DNS-namn, OS, IP, beskrivning och OU-namn
      - Knappar för "Expandera alla" / "Fäll ihop alla"
      - Kolumner: Namn, Operativsystem, IPv4, Senast inloggad, Status, Beskrivning

    Datorer som ligger i containrar (CN=...) under OU:t tas också med.

    Scriptet använder bara PowerShell-kärntyper och fungerar därför även i
    Constrained Language Mode (t.ex. under AppLocker/WDAC).

    Kräver modulen ActiveDirectory (RSAT).

.PARAMETER SearchBase
    Distinguished name (DN) för det OU som ska vara trädets rot.

.PARAMETER Server
    Domänkontrollant att fråga. Utelämnas för att använda standard.

.PARAMETER OutFile
    Sökväg till HTML-filen som ska skapas. Standard: AdServerTree_<datum-tid>.html i aktuell katalog.

.PARAMETER Title
    Rubrik på sidan. Standard: "Servrar i <OU-namn>".

.PARAMETER Collapsed
    Starta med alla OU:n ihopfällda. Standard är att allt visas utfällt.

.PARAMETER ExcludeDisabled
    Hoppa över inaktiverade datorkonton.

.PARAMETER ServersOnly
    Ta bara med objekt vars operativsystem innehåller "Server".

.PARAMETER Show
    Öppna HTML-filen i standardwebbläsaren när den är skapad.

.EXAMPLE
    .\Get-AdServerTreeHtml.ps1 -Show

    Skapar rapporten för standard-OU:t och öppnar den i webbläsaren.

.EXAMPLE
    .\Get-AdServerTreeHtml.ps1 -SearchBase 'OU=servers,OU=SE,OU=Europe,DC=acme,DC=com' -OutFile .\servrar.html -Collapsed

    Skapar servrar.html med alla OU:n ihopfällda från start.
#>
[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$SearchBase = 'OU=servers,OU=SE,OU=Europe,OU=Acme,OU=com',

    [Parameter()]
    [string]$Server,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutFile = "AdServerTree_$(Get-Date -Format 'yyyyMMdd-HHmm').html",

    [Parameter()]
    [string]$Title,

    [Parameter()]
    [switch]$Collapsed,

    [Parameter()]
    [switch]$ExcludeDisabled,

    [Parameter()]
    [switch]$ServersOnly,

    [Parameter()]
    [switch]$Show
)

Import-Module ActiveDirectory -ErrorAction Stop

#region Hjälpfunktioner för DN och träd

function Get-ParentDn {
    param (
        [Parameter(Mandatory)]
        [string]$DistinguishedName
    )

    # Tar bort första RDN:et, med hänsyn till escapade kommatecken (\,)
    return ($DistinguishedName -replace '^(?:[^,\\]|\\.)+,', '')
}

function Get-RdnValue {
    param (
        [Parameter(Mandatory)]
        [string]$DistinguishedName
    )

    $rdn = if ($DistinguishedName -match '^(?:[^,\\]|\\.)+') { $Matches[0] } else { $DistinguishedName }
    $value = $rdn -replace '^[^=]+=', ''

    # Ta bort escape-tecken, t.ex. "Test\, Lab" -> "Test, Lab"
    return ($value -replace '\\(.)', '$1')
}

function New-TreeNode {
    param (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$DistinguishedName,

        [Parameter(Mandatory)]
        [ValidateSet('OU', 'Container')]
        [string]$Type
    )

    # New-Object i stället för [PSCustomObject]@{} och vanliga arrayer i stället för List<T>,
    # eftersom båda de senare stoppas i Constrained Language Mode
    return New-Object -TypeName PSObject -Property @{
        Name              = $Name
        DistinguishedName = $DistinguishedName
        Type              = $Type
        Children          = @()
        Computers         = @()
    }
}

function Resolve-ParentNode {
    <#
        Returnerar noden som ett objekt med angivet DN ska ligga under.
        Saknas föräldern (t.ex. en container, CN=...) skapas den och kopplas
        in i trädet rekursivt uppåt tills en känd nod hittas.
    #>
    param (
        [Parameter(Mandatory)]
        [hashtable]$Nodes,

        [Parameter(Mandatory)]
        [string]$DistinguishedName,

        [Parameter(Mandatory)]
        [object]$Root
    )

    $parentDn = Get-ParentDn -DistinguishedName $DistinguishedName

    if ($Nodes.ContainsKey($parentDn)) {
        return $Nodes[$parentDn]
    }

    $rootDn      = $Root.DistinguishedName
    $isBelowRoot = $parentDn.Length -gt $rootDn.Length -and
        $parentDn.ToLower().EndsWith(",$rootDn".ToLower())

    if (-not $isBelowRoot) {
        # Säkerhetsnät: objekt som inte hör hemma under roten läggs direkt på roten
        return $Root
    }

    $type = if ($parentDn -match '^OU=') { 'OU' } else { 'Container' }
    $node = New-TreeNode -Name (Get-RdnValue -DistinguishedName $parentDn) `
        -DistinguishedName $parentDn -Type $type
    $Nodes[$parentDn] = $node

    $grandParent = Resolve-ParentNode -Nodes $Nodes -DistinguishedName $parentDn -Root $Root
    $grandParent.Children += $node

    return $node
}

function Get-TreeComputers {
    # Plockar ut alla datorer under en nod, rekursivt
    param (
        [Parameter(Mandatory)]
        [object]$Node
    )

    foreach ($computer in $Node.Computers) {
        $computer
    }

    foreach ($child in $Node.Children) {
        Get-TreeComputers -Node $child
    }
}

function Get-TreeNodeCount {
    # Räknar antal under-OU:n/containrar under en nod, rekursivt
    param (
        [Parameter(Mandatory)]
        [object]$Node
    )

    $count = $Node.Children.Count

    foreach ($child in $Node.Children) {
        $count += Get-TreeNodeCount -Node $child
    }

    return $count
}

#endregion

#region Hämta data från AD

function Get-AdServerTree {
    param (
        [Parameter(Mandatory)]
        [string]$SearchBase,

        [Parameter()]
        [string]$Server,

        [Parameter()]
        [switch]$ExcludeDisabled,

        [Parameter()]
        [switch]$ServersOnly
    )

    $adParams = @{ ErrorAction = 'Stop' }
    if ($Server) {
        $adParams.Server = $Server
    }

    try {
        $baseObject = Get-ADObject -Identity $SearchBase -Properties Name @adParams
    }
    catch {
        throw "Hittade inte OU:t '$SearchBase': $($_.Exception.Message)"
    }

    $rootType = if ($baseObject.ObjectClass -eq 'organizationalUnit') { 'OU' } else { 'Container' }
    $root     = New-TreeNode -Name $baseObject.Name -DistinguishedName $baseObject.DistinguishedName -Type $rootType
    $nodes    = @{}
    $nodes[$root.DistinguishedName] = $root

    $ous = @(
        Get-ADOrganizationalUnit -SearchBase $SearchBase -SearchScope Subtree -Filter * @adParams |
            Where-Object { $_.DistinguishedName -ne $root.DistinguishedName }
    )

    foreach ($ou in $ous) {
        $nodes[$ou.DistinguishedName] = New-TreeNode -Name $ou.Name -DistinguishedName $ou.DistinguishedName -Type 'OU'
    }

    foreach ($ou in $ous) {
        $parent = Resolve-ParentNode -Nodes $nodes -DistinguishedName $ou.DistinguishedName -Root $root
        $parent.Children += $nodes[$ou.DistinguishedName]
    }

    $filter = if ($ServersOnly) { 'OperatingSystem -like "*Server*"' } else { '*' }

    $computers = @(
        Get-ADComputer -SearchBase $SearchBase -SearchScope Subtree -Filter $filter `
            -Properties OperatingSystem, IPv4Address, Description, LastLogonDate @adParams
    )

    if ($ExcludeDisabled) {
        $computers = @($computers | Where-Object { $_.Enabled })
    }

    foreach ($computer in $computers) {
        $parent = Resolve-ParentNode -Nodes $nodes -DistinguishedName $computer.DistinguishedName -Root $root

        $parent.Computers += New-Object -TypeName PSObject -Property @{
            Name            = $computer.Name
            DnsHostName     = $computer.DNSHostName
            OperatingSystem = $computer.OperatingSystem
            IPv4Address     = $computer.IPv4Address
            Enabled         = [bool]$computer.Enabled
            Description     = $computer.Description
            LastLogonDate   = $computer.LastLogonDate
        }
    }

    return $root
}

#endregion

#region Bygg HTML

function ConvertTo-HtmlText {
    # Egen HTML-escapning; [System.Net.WebUtility] är inte tillåten i Constrained Language Mode
    param (
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    return ([string]$Value) -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&#39;'
}

function Get-TreeNodeHtml {
    # Returnerar HTML-raderna för en nod och allt under den, rekursivt, via pipelinen
    param (
        [Parameter(Mandatory)]
        [object]$Node,

        [Parameter()]
        [string]$Path = '',

        [Parameter()]
        [int]$Depth = 0,

        [Parameter()]
        [bool]$Open = $true
    )

    $count    = @(Get-TreeComputers -Node $Node).Count
    $name     = ConvertTo-HtmlText -Value $Node.Name
    $dn       = ConvertTo-HtmlText -Value $Node.DistinguishedName
    $iconId   = if ($Node.Type -eq 'OU') { 'i-ou' } else { 'i-container' }
    $openAttr = if ($Open) { ' open' } else { '' }
    $nodePath = if ($Path) { "$Path / $($Node.Name)" } else { $Node.Name }

    "<details class=""ou""$openAttr>"
    "<summary class=""row"" style=""--depth:$Depth"" title=""$dn"">" +
        "<span class=""cell name""><span class=""caret""></span>" +
        "<svg class=""ico""><use href=""#$iconId""/></svg>" +
        "<span class=""label"">$name</span><span class=""count"">$count</span></span>" +
        "</summary>"
    "<div class=""children"" style=""--depth:$Depth"">"

    foreach ($child in ($Node.Children | Sort-Object Name)) {
        Get-TreeNodeHtml -Node $child -Path $nodePath -Depth ($Depth + 1) -Open $Open
    }

    foreach ($computer in ($Node.Computers | Sort-Object Name)) {
        $rowClass   = if ($computer.Enabled) { 'row server' } else { 'row server disabled' }
        $badge      = if ($computer.Enabled) { '<span class="badge on">Aktiv</span>' } else { '<span class="badge off">Inaktiverad</span>' }
        $lastLogon  = if ($computer.LastLogonDate) { Get-Date -Date $computer.LastLogonDate -Format 'yyyy-MM-dd' } else { '&ndash;' }
        $os         = if ($computer.OperatingSystem) { ConvertTo-HtmlText -Value $computer.OperatingSystem } else { '&ndash;' }
        $ip         = if ($computer.IPv4Address) { ConvertTo-HtmlText -Value $computer.IPv4Address } else { '&ndash;' }
        $desc       = ConvertTo-HtmlText -Value $computer.Description
        $dnsName    = ConvertTo-HtmlText -Value $computer.DnsHostName
        $searchText = ConvertTo-HtmlText -Value (
            @(
                $computer.Name
                $computer.DnsHostName
                $computer.OperatingSystem
                $computer.IPv4Address
                $computer.Description
                $nodePath
            ) -join ' '
        ).ToLower()

        "<div class=""$rowClass"" style=""--depth:$($Depth + 1)"" data-search=""$searchText"">" +
            "<span class=""cell name""><svg class=""ico""><use href=""#i-server""/></svg>" +
            "<span class=""label"" title=""$dnsName"">$(ConvertTo-HtmlText -Value $computer.Name)</span></span>" +
            "<span class=""cell os"">$os</span>" +
            "<span class=""cell ip"">$ip</span>" +
            "<span class=""cell logon"">$lastLogon</span>" +
            "<span class=""cell status"">$badge</span>" +
            "<span class=""cell desc"" title=""$desc"">$desc</span>" +
            "</div>"
    }

    if ($Node.Children.Count -eq 0 -and $Node.Computers.Count -eq 0) {
        "<div class=""row empty"" style=""--depth:$($Depth + 1)""><span class=""cell name"">(tomt)</span></div>"
    }

    '</div></details>'
}

$style = @'
:root {
    --bg: #f3f4f6; --panel: #ffffff; --text: #1f2937; --muted: #6b7280;
    --line: #d1d5db; --hover: #eff6ff; --accent: #2563eb;
    --on: #15803d; --on-bg: #dcfce7; --off: #b91c1c; --off-bg: #fee2e2;
    --indent: 22px;
}
@media (prefers-color-scheme: dark) {
    :root {
        --bg: #111827; --panel: #1f2937; --text: #e5e7eb; --muted: #9ca3af;
        --line: #374151; --hover: #273449; --accent: #60a5fa;
        --on: #4ade80; --on-bg: #14532d; --off: #fca5a5; --off-bg: #7f1d1d;
    }
}
* { box-sizing: border-box; }
body {
    margin: 0; font: 14px/1.4 "Segoe UI", system-ui, sans-serif;
    background: var(--bg); color: var(--text);
}
header { padding: 22px 28px 14px; }
h1 { margin: 0 0 4px; font-size: 22px; font-weight: 600; }
.meta { color: var(--muted); font-size: 13px; }
.meta code { font-family: Consolas, "Cascadia Mono", monospace; font-size: 12px; }
.stats { display: flex; gap: 10px; margin-top: 14px; flex-wrap: wrap; }
.stat {
    background: var(--panel); border: 1px solid var(--line); border-radius: 8px;
    padding: 8px 16px; min-width: 110px;
}
.stat b { display: block; font-size: 22px; font-weight: 600; }
.stat span { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .05em; }
.os-summary { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 10px; }
.chip {
    font-size: 12px; color: var(--muted); border: 1px solid var(--line);
    border-radius: 12px; padding: 2px 10px; background: var(--panel);
}
.chip b { color: var(--text); }
.toolbar { display: flex; gap: 8px; margin-top: 16px; align-items: center; flex-wrap: wrap; }
.toolbar input {
    flex: 1 1 260px; max-width: 440px; padding: 7px 10px; font: inherit;
    border: 1px solid var(--line); border-radius: 6px; background: var(--panel); color: var(--text);
}
.toolbar button {
    padding: 7px 12px; font: inherit; cursor: pointer;
    border: 1px solid var(--line); border-radius: 6px; background: var(--panel); color: var(--text);
}
.toolbar button:hover { border-color: var(--accent); color: var(--accent); }
#hits { color: var(--muted); font-size: 13px; }
main {
    margin: 0 28px 40px; background: var(--panel);
    border: 1px solid var(--line); border-radius: 10px;
}
.tree { min-width: 1000px; padding-bottom: 6px; }
.row {
    display: grid;
    grid-template-columns: minmax(280px, 1.4fr) minmax(210px, 1fr) 120px 110px 110px minmax(160px, 1fr);
    align-items: center; column-gap: 12px; padding: 0 16px; min-height: 30px;
}
.row:hover { background: var(--hover); }
.head {
    position: sticky; top: 0; z-index: 2; background: var(--panel);
    border-bottom: 1px solid var(--line); border-radius: 10px 10px 0 0;
    font-size: 11px; text-transform: uppercase; letter-spacing: .05em; color: var(--muted);
}
.head:hover { background: var(--panel); }
.cell { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.cell.name { display: flex; align-items: center; gap: 6px; padding-left: calc(var(--depth, 0) * var(--indent)); }
.server .cell.name, .empty .cell.name { padding-left: calc(var(--depth, 0) * var(--indent) + 14px); }
summary { cursor: pointer; list-style: none; user-select: none; }
summary::-webkit-details-marker { display: none; }
summary .label { font-weight: 600; }
.caret {
    flex: none; width: 0; height: 0; margin-right: 2px;
    border: 4px solid transparent; border-left: 6px solid var(--muted);
    transition: transform .12s;
}
details[open] > summary .caret { transform: rotate(90deg); }
.ico { flex: none; width: 16px; height: 16px; }
.count {
    font-size: 11px; color: var(--muted); background: var(--bg);
    border: 1px solid var(--line); border-radius: 10px; padding: 0 7px;
}
.children { position: relative; }
.children::before {
    content: ''; position: absolute; top: 0; bottom: 0; z-index: 1; pointer-events: none;
    left: calc(16px + var(--depth, 0) * var(--indent) + 3px);
    border-left: 1px solid var(--line);
}
.label { font-weight: 500; }
.server.disabled .label, .server.disabled .cell { color: var(--muted); }
.empty .cell.name { color: var(--muted); font-style: italic; }
.badge { font-size: 11px; font-weight: 600; padding: 1px 8px; border-radius: 10px; }
.badge.on { color: var(--on); background: var(--on-bg); }
.badge.off { color: var(--off); background: var(--off-bg); }
.hidden { display: none !important; }
@media print {
    body { background: #fff; }
    .toolbar, #hits { display: none; }
    main { border: none; margin: 0; }
    .tree { min-width: 0; }
    .row { break-inside: avoid; }
}
'@

$script = @'
(function () {
    var input = document.getElementById('filter');
    var hits = document.getElementById('hits');
    var servers = Array.prototype.slice.call(document.querySelectorAll('.server'));
    var empties = Array.prototype.slice.call(document.querySelectorAll('.empty'));
    var ous = Array.prototype.slice.call(document.querySelectorAll('details.ou'));
    var total = servers.length;

    function setAll(open) {
        ous.forEach(function (d) { d.open = open; });
    }

    function applyFilter() {
        var q = input.value.trim().toLowerCase();
        var shown = 0;

        servers.forEach(function (row) {
            var hit = !q || row.getAttribute('data-search').indexOf(q) !== -1;
            row.classList.toggle('hidden', !hit);
            if (hit) { shown++; }
        });

        empties.forEach(function (row) { row.classList.toggle('hidden', !!q); });

        ous.forEach(function (ou) {
            var visible = ou.querySelector('.server:not(.hidden)') !== null;
            ou.classList.toggle('hidden', !!q && !visible);
            if (q && visible) { ou.open = true; }
        });

        hits.textContent = q ? 'Visar ' + shown + ' av ' + total + ' servrar' : '';
    }

    input.addEventListener('input', applyFilter);
    document.getElementById('expand').addEventListener('click', function () { setAll(true); });
    document.getElementById('collapse').addEventListener('click', function () { setAll(false); });
    window.addEventListener('beforeprint', function () { setAll(true); });
})();
'@

$icons = @'
<svg style="display:none" xmlns="http://www.w3.org/2000/svg">
  <symbol id="i-ou" viewBox="0 0 16 16">
    <path d="M1.5 4A1.5 1.5 0 0 1 3 2.5h3.3l1.5 1.5H13A1.5 1.5 0 0 1 14.5 5.5v7A1.5 1.5 0 0 1 13 14H3a1.5 1.5 0 0 1-1.5-1.5z" fill="#f4c542" stroke="#b8860b"/>
    <path d="M1.5 6.5h13" stroke="#b8860b"/>
    <circle cx="8" cy="9.2" r="1.1" fill="#b8860b"/>
    <path d="M5.5 12.2v-.6a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1v.6" stroke="#b8860b" fill="none"/>
  </symbol>
  <symbol id="i-container" viewBox="0 0 16 16">
    <path d="M1.5 4A1.5 1.5 0 0 1 3 2.5h3.3l1.5 1.5H13A1.5 1.5 0 0 1 14.5 5.5v7A1.5 1.5 0 0 1 13 14H3a1.5 1.5 0 0 1-1.5-1.5z" fill="#d1d5db" stroke="#6b7280"/>
    <path d="M1.5 6.5h13" stroke="#6b7280"/>
  </symbol>
  <symbol id="i-server" viewBox="0 0 16 16">
    <rect x="2" y="2" width="12" height="5" rx="1" fill="#e5e7eb" stroke="#4b5563"/>
    <rect x="2" y="9" width="12" height="5" rx="1" fill="#e5e7eb" stroke="#4b5563"/>
    <circle cx="11.5" cy="4.5" r="1" fill="#22c55e"/>
    <circle cx="11.5" cy="11.5" r="1" fill="#22c55e"/>
    <path d="M4 4.5h4M4 11.5h4" stroke="#9ca3af"/>
  </symbol>
</svg>
'@

#endregion

#region Huvudflöde

$tree = Get-AdServerTree -SearchBase $SearchBase -Server $Server `
    -ExcludeDisabled:$ExcludeDisabled -ServersOnly:$ServersOnly

$allComputers  = @(Get-TreeComputers -Node $tree)
$disabledCount = @($allComputers | Where-Object { -not $_.Enabled }).Count
$ouCount       = Get-TreeNodeCount -Node $tree
$generated     = Get-Date -Format 'yyyy-MM-dd HH:mm'

if (-not $Title) {
    $Title = "Servrar i $($tree.Name)"
}

$osChips = $allComputers |
    Group-Object { if ($_.OperatingSystem) { $_.OperatingSystem } else { 'Okänt OS' } } |
    Sort-Object Count -Descending |
    ForEach-Object {
        "<span class=""chip""><b>$($_.Count)</b> $(ConvertTo-HtmlText -Value $_.Name)</span>"
    }

$sourceText = if ($Server) { " &middot; K&auml;lla: <code>$(ConvertTo-HtmlText -Value $Server)</code>" } else { '' }

$treeHtml = (Get-TreeNodeHtml -Node $tree -Depth 0 -Open (-not $Collapsed)) -join "`r`n"

$html = @"
<!DOCTYPE html>
<html lang="sv">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(ConvertTo-HtmlText -Value $Title)</title>
<style>
$style
</style>
</head>
<body>
$icons
<header>
  <h1>$(ConvertTo-HtmlText -Value $Title)</h1>
  <div class="meta">
    <code>$(ConvertTo-HtmlText -Value $tree.DistinguishedName)</code>
    &middot; Genererad $generated$sourceText
  </div>
  <div class="stats">
    <div class="stat"><b>$($allComputers.Count)</b><span>Servrar</span></div>
    <div class="stat"><b>$ouCount</b><span>Under-OU:n</span></div>
    <div class="stat"><b>$disabledCount</b><span>Inaktiverade</span></div>
  </div>
  <div class="os-summary">
$($osChips -join "`n")
  </div>
  <div class="toolbar">
    <input type="search" id="filter" placeholder="Filtrera på namn, OS, IP, beskrivning eller OU..." autocomplete="off">
    <button type="button" id="expand">Expandera alla</button>
    <button type="button" id="collapse">Fäll ihop alla</button>
    <span id="hits"></span>
  </div>
</header>
<main>
  <div class="tree">
    <div class="row head">
      <span class="cell">Namn</span>
      <span class="cell">Operativsystem</span>
      <span class="cell">IPv4</span>
      <span class="cell">Senast inloggad</span>
      <span class="cell">Status</span>
      <span class="cell">Beskrivning</span>
    </div>
$treeHtml
  </div>
</main>
<script>
$script
</script>
</body>
</html>
"@

# Set-Content i stället för [System.IO.File] så att scriptet fungerar i Constrained Language Mode
Set-Content -LiteralPath $OutFile -Value $html -Encoding UTF8 -NoNewline
$fullPath = (Resolve-Path -LiteralPath $OutFile).ProviderPath

Write-Host "Skrev $($allComputers.Count) servrar i $ouCount under-OU:n till $fullPath"

if ($Show) {
    Invoke-Item -LiteralPath $fullPath
}

#endregion
