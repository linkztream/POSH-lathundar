#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }

# Windows PowerShell 5.1 reads a source file without a BOM as ANSI, which breaks
# every non-ASCII character in help text, messages and test data. CONTRACTS.md
# section 3 therefore requires UTF-8 with BOM and CRLF for every source file.
# Zone file fixtures (*.txt other than *.help.txt) are exports and stay as they are.

BeforeAll {
    Import-Module "$PSScriptRoot\..\DnsLathund.psd1" -Force
}

BeforeDiscovery {
    $moduleRoot = Split-Path -Path $PSScriptRoot -Parent
    $sourceFiles = @(
        Get-ChildItem -LiteralPath $moduleRoot -Recurse -File |
            Where-Object { $_.Name -match '\.(ps1|psm1|psd1|ps1xml)$' -or $_.Name -like '*.help.txt' } |
            Sort-Object -Property FullName
    )

    $script:EncodingTestCases = @(
        foreach ($sourceFile in $sourceFiles) {
            @{
                Path         = $sourceFile.FullName
                RelativePath = $sourceFile.FullName.Substring($moduleRoot.Length + 1)
            }
        }
    )
}

Describe 'Source file encoding' {
    It 'finds source files to check' -TestCases @(@{ FileCount = $script:EncodingTestCases.Count }) {
        $FileCount | Should -BeGreaterThan 0
    }

    It '<RelativePath> starts with the UTF-8 BOM' -TestCases $script:EncodingTestCases {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $bytes = @(Get-Content -LiteralPath $Path -AsByteStream -TotalCount 3)
        }
        else {
            $bytes = @(Get-Content -LiteralPath $Path -Encoding Byte -TotalCount 3)
        }

        $bytes.Count | Should -Be 3 -Because 'an empty file has no BOM'
        ('{0:X2}{1:X2}{2:X2}' -f $bytes[0], $bytes[1], $bytes[2]) | Should -Be 'EFBBBF'
    }

    It '<RelativePath> has CRLF line endings only (no bare LF)' -TestCases $script:EncodingTestCases {
        $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $bareLineFeeds = [regex]::Matches($content, '(?<!\r)\n').Count
        $bareLineFeeds | Should -Be 0
    }
}
