#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# Detectors.psm1
#
# Responsibilities:
#   - Read enabled rules from rules.json
#   - Read configured source files through ZipTools
#   - Inspect standalone .log / .txt files
#   - Search Contains / Regex patterns
#   - Return matched-rule and category-level detection results
#
# This module MUST NOT contain:
#   - ZIP path definitions
#   - Host / Proxy / SG extraction logic
#   - Final operational decision logic
# ============================================================

function Get-RulePropertyValue {
    param(
        [Parameter(Mandatory = $false)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $Property = $Object.PSObject.Properties[$Name]

    if ($null -eq $Property) {
        return $null
    }

    return $Property.Value
}

function Convert-ToBooleanValue {
    param(
        [Parameter(Mandatory = $false)]
        $Value,

        [Parameter(Mandatory = $true)]
        [bool]$Default
    )

    if ($null -eq $Value) {
        return $Default
    }

    try {
        return [System.Convert]::ToBoolean($Value)
    }
    catch {
        return $Default
    }
}

function Get-ContainsMatchCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    if ([string]::IsNullOrEmpty($Pattern)) {
        return 0
    }

    $Count = 0
    $StartIndex = 0

    while ($StartIndex -lt $Text.Length) {
        $Index = $Text.IndexOf(
            $Pattern,
            $StartIndex,
            [System.StringComparison]::OrdinalIgnoreCase
        )

        if ($Index -lt 0) {
            break
        }

        $Count++
        $StartIndex = $Index + $Pattern.Length
    }

    return $Count
}

function Get-RegexMatchCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    if ([string]::IsNullOrEmpty($Pattern)) {
        return 0
    }

    try {
        $Regex = New-Object System.Text.RegularExpressions.Regex(
            $Pattern,
            (
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                [System.Text.RegularExpressions.RegexOptions]::Multiline -bor
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
            )
        )

        $MatchCollection = $Regex.Matches($Text)
        $Count = 0

        foreach ($Match in $MatchCollection) {
            if ($null -ne $Match) {
                $Count++
            }
        }

        return $Count
    }
    catch {
        throw "정규식이 올바르지 않습니다. Pattern='$Pattern' / $($_.Exception.Message)"
    }
}

function Get-CategoryDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category
    )

    switch ($Category.ToUpperInvariant()) {
        "RPM_DB" {
            return "RPM DB"
        }

        "XBC_CONFIG" {
            return "XBC Config"
        }

        default {
            return ($Category.Replace("_", " "))
        }
    }
}

function Get-SourceTextRecord {
    param(
        [Parameter(Mandatory = $true)]
        $Archive,

        [Parameter(Mandatory = $true)]
        $FileConfig,

        [Parameter(Mandatory = $true)]
        [string]$SourceId,

        [Parameter(Mandatory = $true)]
        [hashtable]$Cache
    )

    if ($Cache.ContainsKey($SourceId)) {
        return $Cache[$SourceId]
    }

    $Entry = Get-DiagnosticEntryById `
        -Archive $Archive `
        -FileConfig $FileConfig `
        -Id $SourceId

    if ($null -eq $Entry) {
        $Record = [PSCustomObject]@{
            SourceId  = $SourceId
            Found     = $false
            EntryPath = $null
            Text      = $null
        }

        $Cache[$SourceId] = $Record
        return $Record
    }

    $Text = Read-DiagnosticEntryText -Entry $Entry

    $Record = [PSCustomObject]@{
        SourceId  = $SourceId
        Found     = $true
        EntryPath = [string]$Entry.FullName
        Text      = $Text
    }

    $Cache[$SourceId] = $Record
    return $Record
}

function Read-StandaloneDiagnosticText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "단일 검사 파일을 찾을 수 없습니다: $Path"
    }

    $Stream = $null
    $Reader = $null

    try {
        $Stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )

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

function Get-ConfiguredFileBaseName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfiguredPath
    )

    $Normalized = $ConfiguredPath.Replace('\', '/').Trim()

    if ([string]::IsNullOrWhiteSpace($Normalized)) {
        return $null
    }

    $LastSlash = $Normalized.LastIndexOf('/')

    if ($LastSlash -ge 0) {
        return $Normalized.Substring($LastSlash + 1)
    }

    return $Normalized
}

function Test-StandaloneNamePattern {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ActualFileName,

        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    if ([string]::IsNullOrWhiteSpace($ActualFileName)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        return $false
    }

    # PowerShell -like is case-insensitive by default and supports
    # wildcard patterns such as:
    #   tmxbc*.log
    #   *_tmxbc*.log
    return ($ActualFileName -like $Pattern)
}

function Get-StandaloneSourceDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $FileConfig
    )

    if ($null -eq $FileConfig) {
        throw "files.json 설정이 전달되지 않았습니다."
    }

    $FilesProperty = $FileConfig.PSObject.Properties["Files"]

    if ($null -eq $FilesProperty) {
        throw "files.json에 'Files' 항목이 없습니다."
    }

    $ActualFileName = [System.IO.Path]::GetFileName($Path)
    $Matches = New-Object System.Collections.Generic.List[object]

    foreach ($Definition in @($FilesProperty.Value)) {
        if ($null -eq $Definition) {
            continue
        }

        $Id = [string](
            Get-RulePropertyValue `
                -Object $Definition `
                -Name "Id"
        )

        $ConfiguredPath = [string](
            Get-RulePropertyValue `
                -Object $Definition `
                -Name "Path"
        )

        if ([string]::IsNullOrWhiteSpace($Id)) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) {
            continue
        }

        $ConfiguredFileName = Get-ConfiguredFileBaseName `
            -ConfiguredPath $ConfiguredPath

        $StandaloneNames = Get-RulePropertyValue `
            -Object $Definition `
            -Name "StandaloneNames"

        $CandidatePatterns = New-Object System.Collections.Generic.List[string]

        foreach ($StandaloneName in @($StandaloneNames)) {
            if ($null -eq $StandaloneName) {
                continue
            }

            $Pattern = [string]$StandaloneName

            if ([string]::IsNullOrWhiteSpace($Pattern)) {
                continue
            }

            $CandidatePatterns.Add($Pattern)
        }

        # Backward compatibility:
        # If StandaloneNames is not configured, use the original file name
        # from Path as an exact standalone-file pattern.
        if (@($CandidatePatterns.ToArray()).Count -eq 0) {
            if (-not [string]::IsNullOrWhiteSpace($ConfiguredFileName)) {
                $CandidatePatterns.Add($ConfiguredFileName)
            }
        }

        $MatchedPattern = $null

        foreach ($CandidatePattern in $CandidatePatterns.ToArray()) {
            $IsMatch = Test-StandaloneNamePattern `
                -ActualFileName $ActualFileName `
                -Pattern $CandidatePattern

            if ($IsMatch) {
                $MatchedPattern = $CandidatePattern
                break
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($MatchedPattern)) {
            $Matches.Add(
                [PSCustomObject]@{
                    Id                 = $Id
                    ConfiguredPath     = $ConfiguredPath
                    ConfiguredFileName = $ConfiguredFileName
                    MatchedPattern     = $MatchedPattern
                }
            )
        }
    }

    $MatchArray = @($Matches.ToArray())

    if (@($MatchArray).Count -eq 0) {
        return $null
    }

    if (@($MatchArray).Count -gt 1) {
        $MatchedDescriptions = New-Object System.Collections.Generic.List[string]

        foreach ($Match in $MatchArray) {
            if ($null -eq $Match) {
                continue
            }

            $MatchedDescriptions.Add(
                ("{0}({1})" -f $Match.Id, $Match.MatchedPattern)
            )
        }

        throw (
            "단일 파일명이 files.json의 여러 Source와 일치합니다. " +
            "파일='$ActualFileName' / 일치='$($MatchedDescriptions.ToArray() -join ", ")'"
        )
    }

    return $MatchArray[0]
}

function Test-DiagnosticRule {
    param(
        [Parameter(Mandatory = $true)]
        $Rule,

        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $RuleId = [string](Get-RulePropertyValue -Object $Rule -Name "Id")
    $MatchType = [string](Get-RulePropertyValue -Object $Rule -Name "MatchType")
    $PatternMode = [string](Get-RulePropertyValue -Object $Rule -Name "PatternMode")
    $Patterns = Get-RulePropertyValue -Object $Rule -Name "Patterns"

    if ([string]::IsNullOrWhiteSpace($RuleId)) {
        throw "rules.json에 Id가 없는 규칙이 있습니다."
    }

    if ([string]::IsNullOrWhiteSpace($MatchType)) {
        throw "규칙 '$RuleId'에 MatchType이 없습니다."
    }

    if ([string]::IsNullOrWhiteSpace($PatternMode)) {
        $PatternMode = "Any"
    }

    if (
        $PatternMode -ine "Any" -and
        $PatternMode -ine "All"
    ) {
        throw "규칙 '$RuleId'의 PatternMode는 Any 또는 All이어야 합니다."
    }

    if (
        $MatchType -ine "Contains" -and
        $MatchType -ine "Regex"
    ) {
        throw "규칙 '$RuleId'의 MatchType은 Contains 또는 Regex여야 합니다."
    }

    $PatternResults = New-Object System.Collections.Generic.List[object]
    $PatternTotal = 0
    $MatchedPatternTotal = 0
    $OccurrenceTotal = 0
    $FirstMatchedPattern = $null

    foreach ($PatternValue in @($Patterns)) {
        if ($null -eq $PatternValue) {
            continue
        }

        $Pattern = [string]$PatternValue

        if ([string]::IsNullOrWhiteSpace($Pattern)) {
            continue
        }

        $PatternTotal++

        $OccurrenceCount = 0

        if ($MatchType -ieq "Contains") {
            $OccurrenceCount = Get-ContainsMatchCount `
                -Text $Text `
                -Pattern $Pattern
        }
        elseif ($MatchType -ieq "Regex") {
            $OccurrenceCount = Get-RegexMatchCount `
                -Text $Text `
                -Pattern $Pattern
        }

        $IsMatched = ($OccurrenceCount -gt 0)

        if ($IsMatched) {
            $MatchedPatternTotal++
            $OccurrenceTotal += $OccurrenceCount

            if ([string]::IsNullOrWhiteSpace($FirstMatchedPattern)) {
                $FirstMatchedPattern = $Pattern
            }
        }

        $PatternResults.Add(
            [PSCustomObject]@{
                Pattern         = $Pattern
                Matched         = $IsMatched
                OccurrenceCount = $OccurrenceCount
            }
        )
    }

    if ($PatternTotal -eq 0) {
        throw "규칙 '$RuleId'에 검색할 Patterns가 없습니다."
    }

    $RuleMatched = $false

    if ($PatternMode -ieq "All") {
        $RuleMatched = ($MatchedPatternTotal -eq $PatternTotal)
    }
    else {
        $RuleMatched = ($MatchedPatternTotal -gt 0)
    }

    return [PSCustomObject]@{
        Matched             = $RuleMatched
        PatternTotal        = $PatternTotal
        MatchedPatternTotal = $MatchedPatternTotal
        OccurrenceTotal     = $OccurrenceTotal
        FirstMatchedPattern = $FirstMatchedPattern
        PatternResults      = @($PatternResults.ToArray())
    }
}

function New-RuleResult {
    param(
        [Parameter(Mandatory = $true)]
        $Rule,

        [Parameter(Mandatory = $true)]
        [bool]$SourceFound,

        [Parameter(Mandatory = $false)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [bool]$Evaluated,

        [Parameter(Mandatory = $false)]
        $TestResult
    )

    $Priority = 0
    $PriorityRaw = Get-RulePropertyValue `
        -Object $Rule `
        -Name "Priority"

    if ($null -ne $PriorityRaw) {
        try {
            $Priority = [int]$PriorityRaw
        }
        catch {
            $Priority = 0
        }
    }

    $Matched = $false
    $OccurrenceTotal = 0
    $FirstMatchedPattern = $null
    $PatternResults = @()

    if ($null -ne $TestResult) {
        $Matched = [bool]$TestResult.Matched
        $OccurrenceTotal = [int]$TestResult.OccurrenceTotal
        $FirstMatchedPattern = $TestResult.FirstMatchedPattern
        $PatternResults = @($TestResult.PatternResults)
    }

    return [PSCustomObject]@{
        Id                  = [string](Get-RulePropertyValue -Object $Rule -Name "Id")
        Category            = [string](Get-RulePropertyValue -Object $Rule -Name "Category")
        Source              = [string](Get-RulePropertyValue -Object $Rule -Name "Source")
        SourceFound         = $SourceFound
        SourcePath          = $SourcePath
        Evaluated           = $Evaluated
        Matched             = $Matched
        Priority            = $Priority
        QuickResponse       = Convert-ToBooleanValue `
                                -Value (Get-RulePropertyValue -Object $Rule -Name "QuickResponse") `
                                -Default $false
        DecisionCode        = Get-RulePropertyValue -Object $Rule -Name "DecisionCode"
        DecisionText        = Get-RulePropertyValue -Object $Rule -Name "DecisionText"
        ActionCode          = Get-RulePropertyValue -Object $Rule -Name "ActionCode"
        ActionText          = Get-RulePropertyValue -Object $Rule -Name "ActionText"
        OccurrenceTotal     = $OccurrenceTotal
        FirstMatchedPattern = $FirstMatchedPattern
        PatternResults      = $PatternResults
    }
}

function New-DiagnosticDetectionResult {
    param(
        [Parameter(Mandatory = $true)]
        $RuleResults,

        [Parameter(Mandatory = $true)]
        $CategoryOrder,

        [Parameter(Mandatory = $false)]
        [string]$StandaloneSourceId,

        [Parameter(Mandatory = $false)]
        [string]$StandaloneFileName
    )

    $MatchedRules = New-Object System.Collections.Generic.List[object]

    foreach ($RuleResult in @($RuleResults)) {
        if ($null -eq $RuleResult) {
            continue
        }

        if ($RuleResult.Matched) {
            $MatchedRules.Add($RuleResult)
        }
    }

    $CategoryResults = New-Object System.Collections.Generic.List[object]
    $Output = [ordered]@{}

    if (-not [string]::IsNullOrWhiteSpace($StandaloneFileName)) {
        $Output["단일 파일 Source"] = $StandaloneSourceId
    }

    foreach ($Category in @($CategoryOrder)) {
        if ([string]::IsNullOrWhiteSpace([string]$Category)) {
            continue
        }

        $DisplayName = Get-CategoryDisplayName `
            -Category ([string]$Category)

        $AnyEvaluated = $false
        $AnyMatched = $false
        $OccurrenceTotal = 0

        foreach ($RuleResult in @($RuleResults)) {
            if ($null -eq $RuleResult) {
                continue
            }

            if ($RuleResult.Category -ine $Category) {
                continue
            }

            if ($RuleResult.Evaluated) {
                $AnyEvaluated = $true
            }

            if ($RuleResult.Matched) {
                $AnyMatched = $true
                $OccurrenceTotal += [int]$RuleResult.OccurrenceTotal
            }
        }

        $StatusCode = "SOURCE_MISSING"
        $StatusText = "검사 파일 없음"

        if ($AnyMatched) {
            $StatusCode = "DETECTED"
            $StatusText = "$DisplayName 오류 탐지"
        }
        elseif ($AnyEvaluated) {
            $StatusCode = "NOT_DETECTED"
            $StatusText = "오류 미탐지"
        }

        $CategoryResult = [PSCustomObject]@{
            Category        = [string]$Category
            DisplayName     = $DisplayName
            StatusCode      = $StatusCode
            StatusText      = $StatusText
            OccurrenceTotal = $OccurrenceTotal
        }

        $CategoryResults.Add($CategoryResult)
        $Output["$DisplayName 상태"] = $StatusText
    }

    $HasAnyMatch = $false
    $HasQuickResponseMatch = $false

    foreach ($MatchedRule in @($MatchedRules.ToArray())) {
        if ($null -eq $MatchedRule) {
            continue
        }

        $HasAnyMatch = $true

        if ($MatchedRule.QuickResponse) {
            $HasQuickResponseMatch = $true
        }
    }

    $Data = [PSCustomObject]@{
        HasAnyMatch           = $HasAnyMatch
        HasQuickResponseMatch = $HasQuickResponseMatch
        RuleResults           = @($RuleResults)
        MatchedRules          = @($MatchedRules.ToArray())
        CategoryResults       = @($CategoryResults.ToArray())
        StandaloneSourceId    = $StandaloneSourceId
        StandaloneFileName    = $StandaloneFileName
    }

    return [PSCustomObject]@{
        Output = $Output
        Data   = $Data
    }
}

function Invoke-DiagnosticRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Archive,

        [Parameter(Mandatory = $true)]
        $FileConfig,

        [Parameter(Mandatory = $true)]
        $RuleConfig,

        [Parameter(Mandatory = $false)]
        $Inventory
    )

    if ($null -eq $RuleConfig) {
        throw "rules.json 설정이 전달되지 않았습니다."
    }

    $RulesProperty = $RuleConfig.PSObject.Properties["Rules"]

    if ($null -eq $RulesProperty) {
        throw "rules.json에 'Rules' 항목이 없습니다."
    }

    $SourceCache = @{}
    $RuleResults = New-Object System.Collections.Generic.List[object]
    $CategoryOrder = New-Object System.Collections.Generic.List[string]

    foreach ($Rule in @($RulesProperty.Value)) {
        if ($null -eq $Rule) {
            continue
        }

        $Enabled = Convert-ToBooleanValue `
            -Value (Get-RulePropertyValue -Object $Rule -Name "Enabled") `
            -Default $true

        if (-not $Enabled) {
            continue
        }

        $RuleId = [string](Get-RulePropertyValue -Object $Rule -Name "Id")
        $SourceId = [string](Get-RulePropertyValue -Object $Rule -Name "Source")
        $Category = [string](Get-RulePropertyValue -Object $Rule -Name "Category")

        if ([string]::IsNullOrWhiteSpace($RuleId)) {
            throw "rules.json에 Id가 없는 활성 규칙이 있습니다."
        }

        if ([string]::IsNullOrWhiteSpace($SourceId)) {
            throw "규칙 '$RuleId'에 Source가 없습니다."
        }

        if ([string]::IsNullOrWhiteSpace($Category)) {
            throw "규칙 '$RuleId'에 Category가 없습니다."
        }

        if (-not $CategoryOrder.Contains($Category)) {
            $CategoryOrder.Add($Category)
        }

        $SourceRecord = Get-SourceTextRecord `
            -Archive $Archive `
            -FileConfig $FileConfig `
            -SourceId $SourceId `
            -Cache $SourceCache

        if (
            -not $SourceRecord.Found -or
            [string]::IsNullOrWhiteSpace([string]$SourceRecord.Text)
        ) {
            $RuleResults.Add(
                (New-RuleResult `
                    -Rule $Rule `
                    -SourceFound $false `
                    -SourcePath $SourceRecord.EntryPath `
                    -Evaluated $false)
            )

            continue
        }

        $TestResult = Test-DiagnosticRule `
            -Rule $Rule `
            -Text ([string]$SourceRecord.Text)

        $RuleResults.Add(
            (New-RuleResult `
                -Rule $Rule `
                -SourceFound $true `
                -SourcePath $SourceRecord.EntryPath `
                -Evaluated $true `
                -TestResult $TestResult)
        )
    }

    return New-DiagnosticDetectionResult `
        -RuleResults @($RuleResults.ToArray()) `
        -CategoryOrder @($CategoryOrder.ToArray())
}

function Invoke-DiagnosticStandaloneRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $FileConfig,

        [Parameter(Mandatory = $true)]
        $RuleConfig
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "단일 검사 파일을 찾을 수 없습니다: $Path"
    }

    $Extension = [System.IO.Path]::GetExtension($Path)

    if (
        $Extension -ine ".log" -and
        $Extension -ine ".txt"
    ) {
        throw "단일 검사에서 지원하지 않는 확장자입니다: $Extension"
    }

    $SourceDefinition = Get-StandaloneSourceDefinition `
        -Path $Path `
        -FileConfig $FileConfig

    $FileName = [System.IO.Path]::GetFileName($Path)

    if ($null -eq $SourceDefinition) {
        throw (
            "files.json에 등록되지 않은 단일 파일입니다: $FileName"
        )
    }

    $SourceId = [string]$SourceDefinition.Id

    $Text = Read-StandaloneDiagnosticText `
        -Path $Path

    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw "단일 검사 파일이 비어 있습니다: $FileName"
    }

    if ($null -eq $RuleConfig) {
        throw "rules.json 설정이 전달되지 않았습니다."
    }

    $RulesProperty = $RuleConfig.PSObject.Properties["Rules"]

    if ($null -eq $RulesProperty) {
        throw "rules.json에 'Rules' 항목이 없습니다."
    }

    $RuleResults = New-Object System.Collections.Generic.List[object]
    $CategoryOrder = New-Object System.Collections.Generic.List[string]
    $ApplicableRuleFound = $false

    foreach ($Rule in @($RulesProperty.Value)) {
        if ($null -eq $Rule) {
            continue
        }

        $Enabled = Convert-ToBooleanValue `
            -Value (Get-RulePropertyValue -Object $Rule -Name "Enabled") `
            -Default $true

        if (-not $Enabled) {
            continue
        }

        $RuleId = [string](
            Get-RulePropertyValue `
                -Object $Rule `
                -Name "Id"
        )

        $RuleSourceId = [string](
            Get-RulePropertyValue `
                -Object $Rule `
                -Name "Source"
        )

        $Category = [string](
            Get-RulePropertyValue `
                -Object $Rule `
                -Name "Category"
        )

        if ([string]::IsNullOrWhiteSpace($RuleId)) {
            throw "rules.json에 Id가 없는 활성 규칙이 있습니다."
        }

        if ([string]::IsNullOrWhiteSpace($RuleSourceId)) {
            throw "규칙 '$RuleId'에 Source가 없습니다."
        }

        if ([string]::IsNullOrWhiteSpace($Category)) {
            throw "규칙 '$RuleId'에 Category가 없습니다."
        }

        # Standalone files are intentionally evaluated only against
        # rules for the matched Source ID.
        if ($RuleSourceId -ine $SourceId) {
            continue
        }

        $ApplicableRuleFound = $true

        if (-not $CategoryOrder.Contains($Category)) {
            $CategoryOrder.Add($Category)
        }

        $TestResult = Test-DiagnosticRule `
            -Rule $Rule `
            -Text $Text

        $RuleResults.Add(
            (New-RuleResult `
                -Rule $Rule `
                -SourceFound $true `
                -SourcePath $Path `
                -Evaluated $true `
                -TestResult $TestResult)
        )
    }

    if (-not $ApplicableRuleFound) {
        throw (
            "단일 파일 Source '$SourceId'에 연결된 활성 규칙이 없습니다. " +
            "rules.json을 확인하십시오."
        )
    }

    return New-DiagnosticDetectionResult `
        -RuleResults @($RuleResults.ToArray()) `
        -CategoryOrder @($CategoryOrder.ToArray()) `
        -StandaloneSourceId $SourceId `
        -StandaloneFileName $FileName
}

Export-ModuleMember -Function @(
    "Invoke-DiagnosticRules",
    "Invoke-DiagnosticStandaloneRules"
)
