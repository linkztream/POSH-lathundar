#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
# Performance targets of CONTRACTS.md section 15 for the parser and the snapshot
# index. Excluded by default; run on Windows PowerShell 5.1 (the production engine):
#   Invoke-Pester -Path .\Tests\Performance.Tests.ps1 -Tag Performance -Output Detailed
# The synthetic files are generated once into $env:TEMP\DnsLathund-perf and reused.

Describe 'Parser and index performance (CONTRACTS.md section 15)' -Tag 'Performance' {
    BeforeAll {
        Set-StrictMode -Version Latest
        . (Join-Path $PSScriptRoot '..\Private\ConvertFrom-DnsZoneFile.ps1')
        . (Join-Path $PSScriptRoot '..\Private\New-DnsSnapshotIndex.ps1')

        $generator = Join-Path $PSScriptRoot 'Tools\New-SyntheticZoneFile.ps1'
        $perfRoot = Join-Path $env:TEMP 'DnsLathund-perf'
        $script:ForwardRows = 550000
        $script:ReverseRows = 200000
        # The seed is part of the file name so that a changed generator setting never
        # reuses a stale file.
        $forwardPath = Join-Path $perfRoot "forward-$ForwardRows-seed20261009.txt"
        $reversePath = Join-Path $perfRoot "reverse-$ReverseRows-seed20261009.txt"
        # Generated in a child process of the same engine: generating in this process
        # would leave its heap in a different state than a run that reuses the files,
        # and the memory delta below would then depend on whether the files existed.
        $engine = (Get-Process -Id $PID).Path
        if (-not (Test-Path -LiteralPath $forwardPath)) {
            & $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $generator -Path $forwardPath -RecordCount $ForwardRows -Seed 20261009 -IncludeDelegatedSubZone | Out-Null
        }
        if (-not (Test-Path -LiteralPath $reversePath)) {
            & $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $generator -Path $reversePath -RecordCount $ReverseRows -Seed 20261009 -Reverse -Network '10.0.0.0/8' -IncludeDelegatedSubZone | Out-Null
        }
        if (-not (Test-Path -LiteralPath $forwardPath) -or -not (Test-Path -LiteralPath $reversePath)) {
            throw "The synthetic zone files could not be generated into '$perfRoot'."
        }

        $zoneTable = @{
            ZoneLookup = @{
                'contoso.local'   = @{ IsReverse = $false }
                '10.in-addr.arpa' = @{ IsReverse = $true }
            }
        }

        $process = [System.Diagnostics.Process]::GetCurrentProcess()
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        $process.Refresh()
        $baselineBytes = $process.PrivateMemorySize64
        $baselineManagedBytes = [GC]::GetTotalMemory($true)

        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $forward = ConvertFrom-DnsZoneFile -Path $forwardPath -ZoneName 'contoso.local'
        $script:ForwardSeconds = $watch.Elapsed.TotalSeconds
        $script:ForwardCount = $forward.RecordCount
        $script:ForwardSkipped = $forward.SkippedLines

        $watch.Restart()
        $reverse = ConvertFrom-DnsZoneFile -Path $reversePath -ZoneName '10.in-addr.arpa'
        $script:ReverseSeconds = $watch.Elapsed.TotalSeconds
        $script:ReverseCount = $reverse.RecordCount
        $script:ReverseSkipped = $reverse.SkippedLines

        $process.Refresh()
        $script:AfterParseMB = ($process.PrivateMemorySize64 - $baselineBytes) / 1MB

        $forward['ExportedAt'] = (Get-Date).AddHours(-1)
        $reverse['ExportedAt'] = (Get-Date).AddHours(-2)
        $watch.Restart()
        $index = New-DnsSnapshotIndex -Server 'dc01' -ParseResult $forward, $reverse -ZoneTable $zoneTable
        $script:IndexSeconds = $watch.Elapsed.TotalSeconds
        $watch.Stop()

        # The caller still holds the parse-result hashtables here, as Get-DnsSnapshotIndex
        # does; by default the builder has already released their Rows (section 9.3).
        $process.Refresh()
        $script:AfterIndexMB = ($process.PrivateMemorySize64 - $baselineBytes) / 1MB
        $script:PeakCommitMB = ($process.PeakPagedMemorySize64 - $baselineBytes) / 1MB
        $script:IndexCounts = @{
            Name  = $index.Name.Count
            Addr  = $index.Addr.Count
            Ptr   = $index.Ptr.Count
            Names = $index.Names.Count
        }

        $script:RowsReleased = ($null -eq $forward['Rows']) -and ($null -eq $reverse['Rows'])
        $script:RecordCountKept = $forward['RecordCount']

        # What a session keeps once Get-DnsSnapshotIndex has dropped the parse results.
        Remove-Variable -Name forward, reverse
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        $process.Refresh()
        $script:RetainedMB = ($process.PrivateMemorySize64 - $baselineBytes) / 1MB
        $script:RetainedManagedMB = ([GC]::GetTotalMemory($true) - $baselineManagedBytes) / 1MB

        Write-Host ''
        Write-Host ("  Engine                    : PowerShell {0}" -f $PSVersionTable.PSVersion)
        Write-Host ("  Parse forward ({0:N0} rows): {1:N2} s (target < 20 s)" -f $ForwardCount, $ForwardSeconds)
        Write-Host ("  Parse reverse ({0:N0} rows): {1:N2} s" -f $ReverseCount, $ReverseSeconds)
        Write-Host ("  Index build               : {0:N2} s (target < 10 s)" -f $IndexSeconds)
        Write-Host ("  Index entries             : Name {0:N0}, Addr {1:N0}, Ptr {2:N0}, Names {3:N0}" -f $IndexCounts.Name, $IndexCounts.Addr, $IndexCounts.Ptr, $IndexCounts.Names)
        Write-Host ("  Private memory delta      : {0:N0} MB after parsing, {1:N0} MB after the index build (target < 500 MB)" -f $AfterParseMB, $AfterIndexMB)
        Write-Host ("  Peak commit delta         : {0:N0} MB (PeakPagedMemorySize64)" -f $PeakCommitMB)
        Write-Host ("  Retained after release+GC : {0:N0} MB private delta, {1:N0} MB managed-heap delta" -f $RetainedMB, $RetainedManagedMB)
        Write-Host ''
    }

    It 'parses the 550 000-row forward zone in under 20 s' {
        $ForwardCount | Should -Be $ForwardRows
        $ForwardSkipped | Should -Be 0
        $ForwardSeconds | Should -BeLessThan 20
    }

    It 'parses the 200 000-row reverse zone completely' {
        $ReverseCount | Should -Be $ReverseRows
        $ReverseSkipped | Should -Be 0
    }

    It 'builds the index from 550 000 + 200 000 rows in under 10 s' {
        $IndexCounts.Ptr | Should -BeGreaterThan 190000
        $IndexSeconds | Should -BeLessThan 10
    }

    It 'stays under 500 MB private memory after the index build' {
        $RowsReleased | Should -BeTrue
        $RecordCountKept | Should -Be $ForwardRows
        $AfterIndexMB | Should -BeLessThan 500
    }
}
