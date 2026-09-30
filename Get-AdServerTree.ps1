<#
.SYNOPSIS
    Listar alla datorobjekt (servrar) i ett OU och dess under-OU:n som ett träd i ren text.

.DESCRIPTION
    Hämtar alla OU:n och datorobjekt under angivet OU och ritar upp dem i trädform,
    ungefär som i Active Directory Users and Computers (dsa.msc).
    Under-OU:n listas först (alfabetiskt), därefter servrarna i respektive OU.

    För varje server visas operativsystem, IPv4-adress och om kontot är inaktiverat.
    Datorer som ligger i containrar (CN=...) under OU:t tas också med.

    Kräver modulen ActiveDirectory (RSAT).

.PARAMETER SearchBase
    Distinguished name (DN) för det OU som ska vara trädets rot.

.PARAMETER Server
    Domänkontrollant att fråga. Utelämnas för att använda standard.

.PARAMETER OutFile
    Sökväg till en textfil att skriva resultatet till (UTF-8).
    Utelämnas för att skriva till konsolen.

.PARAMETER Ascii
    Använd +-- och | i stället för Unicode-linjer. Bra om konsolen eller
    mottagaren inte klarar av box-drawing-tecken.

.PARAMETER ExcludeDisabled
    Hoppa över inaktiverade datorkonton.

.PARAMETER ServersOnly
    Ta bara med objekt vars operativsystem innehåller "Server".

.EXAMPLE
    .\Get-AdServerTree.ps1

    Ritar trädet för standard-OU:t i konsolen.

.EXAMPLE
    .\Get-AdServerTree.ps1 -SearchBase 'OU=servers,OU=SE,OU=Europe,DC=acme,DC=com' -OutFile .\servrar.txt

    Skriver trädet till servrar.txt.

.EXAMPLE
    .\Get-AdServerTree.ps1 -Ascii | Set-Clipboard

    Kopierar ett rent ASCII-träd till urklipp.
#>
[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$SearchBase = 'OU=servers,OU=SE,OU=Europe,OU=Acme,OU=com',

    [Parameter()]
    [string]$Server,

    [Parameter()]
    [string]$OutFile,

    [Parameter()]
    [switch]$Ascii,

    [Parameter()]
    [switch]$ExcludeDisabled,

    [Parameter()]
    [switch]$ServersOnly
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

    $rdn   = [regex]::Match($DistinguishedName, '^(?:[^,\\]|\\.)+').Value
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

    return [PSCustomObject]@{
        Name              = $Name
        DistinguishedName = $DistinguishedName
        Type              = $Type
        Children          = [System.Collections.Generic.List[object]]::new()
        Computers         = [System.Collections.Generic.List[object]]::new()
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
        $parentDn.EndsWith(",$rootDn", [StringComparison]::OrdinalIgnoreCase)

    if (-not $isBelowRoot) {
        # Säkerhetsnät: objekt som inte hör hemma under roten läggs direkt på roten
        return $Root
    }

    $type = if ($parentDn -match '^OU=') { 'OU' } else { 'Container' }
    $node = New-TreeNode -Name (Get-RdnValue -DistinguishedName $parentDn) `
        -DistinguishedName $parentDn -Type $type
    $Nodes[$parentDn] = $node

    $grandParent = Resolve-ParentNode -Nodes $Nodes -DistinguishedName $parentDn -Root $Root
    $grandParent.Children.Add($node)

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
        $parent.Children.Add($nodes[$ou.DistinguishedName])
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

        $parent.Computers.Add([PSCustomObject]@{
            Name            = $computer.Name
            DnsHostName     = $computer.DNSHostName
            OperatingSystem = $computer.OperatingSystem
            IPv4Address     = $computer.IPv4Address
            Enabled         = [bool]$computer.Enabled
            Description     = $computer.Description
            LastLogonDate   = $computer.LastLogonDate
        })
    }

    return $root
}

#endregion

#region Rita trädet

function Add-TreeLine {
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Lines,

        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter()]
        [string[]]$Columns
    )

    $Lines.Add([PSCustomObject]@{ Text = $Text; Columns = $Columns })
}

function Add-TreeNodeLines {
    param (
        [Parameter(Mandatory)]
        [object]$Node,

        [Parameter()]
        [string]$Prefix = '',

        [Parameter(Mandatory)]
        [hashtable]$Glyphs,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Lines
    )

    # Under-OU:n först, sedan datorer - som i dsa.msc
    $items = @(
        foreach ($child in ($Node.Children | Sort-Object Name)) {
            [PSCustomObject]@{ IsNode = $true; Item = $child }
        }
        foreach ($computer in ($Node.Computers | Sort-Object Name)) {
            [PSCustomObject]@{ IsNode = $false; Item = $computer }
        }
    )

    for ($i = 0; $i -lt $items.Count; $i++) {
        $isLast     = ($i -eq $items.Count - 1)
        $connector  = if ($isLast) { $Glyphs.Last } else { $Glyphs.Branch }
        $nextPrefix = $Prefix + $(if ($isLast) { $Glyphs.Space } else { $Glyphs.Pipe })
        $item       = $items[$i].Item

        if ($items[$i].IsNode) {
            $count = @(Get-TreeComputers -Node $item).Count
            Add-TreeLine -Lines $Lines -Text "$Prefix$connector$($item.Name) ($count)"
            Add-TreeNodeLines -Node $item -Prefix $nextPrefix -Glyphs $Glyphs -Lines $Lines
        }
        else {
            $status = if ($item.Enabled) { '' } else { 'INAKTIVERAD' }

            Add-TreeLine -Lines $Lines -Text "$Prefix$connector$($item.Name)" -Columns @(
                [string]$item.OperatingSystem
                [string]$item.IPv4Address
                $status
            )
        }
    }
}

function Format-TreeLines {
    # Justerar kolumnerna så att OS, IP och status hamnar i raka spalter
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Lines,

        [Parameter(Mandatory)]
        [string[]]$Headers
    )

    $nameWidth = ($Lines | ForEach-Object { $_.Text.Length } | Measure-Object -Maximum).Maximum
    $nameWidth = [Math]::Max($nameWidth, 'Namn'.Length)

    $columnWidths = @(
        for ($c = 0; $c -lt $Headers.Count; $c++) {
            $widest = $Headers[$c].Length
            foreach ($line in $Lines) {
                if ($line.Columns -and $line.Columns[$c].Length -gt $widest) {
                    $widest = $line.Columns[$c].Length
                }
            }
            $widest
        }
    )

    $headerCells = @('Namn'.PadRight($nameWidth))
    for ($c = 0; $c -lt $Headers.Count; $c++) {
        $headerCells += $Headers[$c].PadRight($columnWidths[$c])
    }

    $headerLine = ($headerCells -join '  ').TrimEnd()
    $headerLine
    '-' * $headerLine.Length

    foreach ($line in $Lines) {
        if (-not $line.Columns) {
            $line.Text
            continue
        }

        $cells = @($line.Text.PadRight($nameWidth))
        for ($c = 0; $c -lt $line.Columns.Count; $c++) {
            $cells += $line.Columns[$c].PadRight($columnWidths[$c])
        }

        ($cells -join '  ').TrimEnd()
    }
}

#endregion

#region Huvudflöde

$glyphs = if ($Ascii) {
    @{ Branch = '+-- '; Last = '\-- '; Pipe = '|   '; Space = '    ' }
}
else {
    # Byggs med teckenkoder så att scriptet fungerar oavsett filens teckenkodning
    $h = [char]0x2500                           # ─
    @{
        Branch = "$([char]0x251C)$h$h "         # ├──
        Last   = "$([char]0x2514)$h$h "         # └──
        Pipe   = "$([char]0x2502)   "           # │
        Space  = '    '
    }
}

$tree = Get-AdServerTree -SearchBase $SearchBase -Server $Server `
    -ExcludeDisabled:$ExcludeDisabled -ServersOnly:$ServersOnly

$allComputers  = @(Get-TreeComputers -Node $tree)
$disabledCount = @($allComputers | Where-Object { -not $_.Enabled }).Count
$ouCount       = Get-TreeNodeCount -Node $tree

$lines = [System.Collections.Generic.List[object]]::new()
Add-TreeLine -Lines $lines -Text "$($tree.Name) ($($allComputers.Count))"
Add-TreeNodeLines -Node $tree -Prefix '' -Glyphs $glyphs -Lines $lines

$output = @(
    "Servrar i OU: $($tree.Name)"
    "DN:           $($tree.DistinguishedName)"
    "Genererad:    $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    "Antal:        $($allComputers.Count) servrar i $ouCount under-OU:n ($disabledCount inaktiverade)"
    ''
    Format-TreeLines -Lines $lines -Headers @('Operativsystem', 'IPv4', 'Status')
)

if ($OutFile) {
    $output | Out-File -FilePath $OutFile -Encoding utf8
    Write-Host "Skrev $($allComputers.Count) servrar till $OutFile"
}
else {
    $output
}

#endregion
