#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# ZipTools.psm1
#
# Responsibilities:
#   - Open diagnostic ZIP files in read-only mode
#   - Resolve file definitions from files.json
#   - Find ZIP entries using Exact / Suffix / WildcardSuffix
#   - Read entry text without extracting or modifying the ZIP
#
# This module MUST NOT contain:
#   - Error-message detection rules
#   - Host / Proxy / SG parsing logic
#   - Operational decision logic
# ============================================================

if (-not ("System.IO.Compression.ZipFile" -as [type])) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}

function Convert-ToDiagnosticZipPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Normalized = $Path.Replace('\', '/').Trim()

    while ($Normalized.StartsWith('/')) {
        $Normalized = $Normalized.Substring(1)
    }

    return $Normalized
}

function Open-DiagnosticArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "ZIP 파일을 찾을 수 없습니다: $Path"
    }

    $ResolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path

    try {
        # OpenRead keeps the source ZIP read-only.
        return [System.IO.Compression.ZipFile]::OpenRead($ResolvedPath)
    }
    catch {
        throw "ZIP 파일을 열 수 없습니다: $ResolvedPath / $($_.Exception.Message)"
    }
}

function Close-DiagnosticArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Archive
    )

    if ($null -eq $Archive) {
        return
    }

    if ($Archive -is [System.IDisposable]) {
        $Archive.Dispose()
    }
}

function Get-DiagnosticFileDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $FileConfig,

        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    if ($null -eq $FileConfig) {
        throw "files.json 설정이 전달되지 않았습니다."
    }

    $FilesProperty = $FileConfig.PSObject.Properties["Files"]

    if ($null -eq $FilesProperty) {
        throw "files.json에 'Files' 항목이 없습니다."
    }

    foreach ($Definition in @($FilesProperty.Value)) {
        if ($null -eq $Definition) {
            continue
        }

        $IdProperty = $Definition.PSObject.Properties["Id"]

        if ($null -eq $IdProperty) {
            continue
        }

        if ([string]$IdProperty.Value -ieq $Id) {
            return $Definition
        }
    }

    throw "files.json에서 파일 ID를 찾을 수 없습니다: $Id"
}

function Find-DiagnosticEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Archive,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Exact", "Suffix", "WildcardSuffix")]
        [string]$MatchMode
    )

    if ($null -eq $Archive) {
        throw "열린 ZIP Archive가 전달되지 않았습니다."
    }

    $TargetPath = Convert-ToDiagnosticZipPath -Path $Path

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        throw "검색할 ZIP 내부 경로가 비어 있습니다."
    }

    $Matches = New-Object System.Collections.ArrayList

    foreach ($Entry in $Archive.Entries) {
        if ($null -eq $Entry) {
            continue
        }

        $EntryPath = Convert-ToDiagnosticZipPath -Path ([string]$Entry.FullName)

        if ([string]::IsNullOrWhiteSpace($EntryPath)) {
            continue
        }

        # Skip directory entries.
        if ($EntryPath.EndsWith('/')) {
            continue
        }

        $IsMatch = $false

        switch ($MatchMode) {
            "Exact" {
                if ($EntryPath -ieq $TargetPath) {
                    $IsMatch = $true
                }
            }

            "Suffix" {
                if ($EntryPath -ieq $TargetPath) {
                    $IsMatch = $true
                }
                elseif ($EntryPath.EndsWith(
                    "/" + $TargetPath,
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                    $IsMatch = $true
                }
            }

            "WildcardSuffix" {
                if ($EntryPath -like $TargetPath) {
                    $IsMatch = $true
                }
                elseif ($EntryPath -like ("*/" + $TargetPath)) {
                    $IsMatch = $true
                }
            }
        }

        if ($IsMatch) {
            [void]$Matches.Add($Entry)
        }
    }

    return @($Matches.ToArray())
}

function Get-DiagnosticEntriesById {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Archive,

        [Parameter(Mandatory = $true)]
        $FileConfig,

        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $Definition = Get-DiagnosticFileDefinition `
        -FileConfig $FileConfig `
        -Id $Id

    $PathProperty = $Definition.PSObject.Properties["Path"]
    $ModeProperty = $Definition.PSObject.Properties["MatchMode"]

    if ($null -eq $PathProperty) {
        throw "파일 정의 '$Id'에 Path가 없습니다."
    }

    if ($null -eq $ModeProperty) {
        throw "파일 정의 '$Id'에 MatchMode가 없습니다."
    }

    return @(
        Find-DiagnosticEntries `
            -Archive $Archive `
            -Path ([string]$PathProperty.Value) `
            -MatchMode ([string]$ModeProperty.Value)
    )
}

function Get-DiagnosticEntryById {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Archive,

        [Parameter(Mandatory = $true)]
        $FileConfig,

        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    foreach ($Entry in @(
        Get-DiagnosticEntriesById `
            -Archive $Archive `
            -FileConfig $FileConfig `
            -Id $Id
    )) {
        return $Entry
    }

    return $null
}

function Test-DiagnosticEntryExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Archive,

        [Parameter(Mandatory = $true)]
        $FileConfig,

        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $Entry = Get-DiagnosticEntryById `
        -Archive $Archive `
        -FileConfig $FileConfig `
        -Id $Id

    return ($null -ne $Entry)
}

function Read-DiagnosticEntryText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Entry
    )

    if ($null -eq $Entry) {
        return $null
    }

    $Stream = $null
    $Reader = $null

    try {
        $Stream = $Entry.Open()

        # UTF-8 is the default fallback.
        # detectEncodingFromByteOrderMarks = true allows BOM-based UTF-8/
        # UTF-16 detection when the diagnostic file contains a BOM.
        $Reader = New-Object System.IO.StreamReader(
            $Stream,
            [System.Text.Encoding]::UTF8,
            $true
        )

        return $Reader.ReadToEnd()
    }
    finally {
        if ($null -ne $Reader) {
            $Reader.Dispose()
        }
        elseif ($null -ne $Stream) {
            $Stream.Dispose()
        }
    }
}

function Get-DiagnosticTextById {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Archive,

        [Parameter(Mandatory = $true)]
        $FileConfig,

        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $Entry = Get-DiagnosticEntryById `
        -Archive $Archive `
        -FileConfig $FileConfig `
        -Id $Id

    if ($null -eq $Entry) {
        return $null
    }

    return Read-DiagnosticEntryText -Entry $Entry
}

Export-ModuleMember -Function @(
    "Open-DiagnosticArchive",
    "Close-DiagnosticArchive",
    "Get-DiagnosticFileDefinition",
    "Find-DiagnosticEntries",
    "Get-DiagnosticEntriesById",
    "Get-DiagnosticEntryById",
    "Test-DiagnosticEntryExists",
    "Read-DiagnosticEntryText",
    "Get-DiagnosticTextById"
)
