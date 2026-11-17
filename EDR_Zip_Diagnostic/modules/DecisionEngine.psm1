#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# DecisionEngine.psm1
#
# Responsibilities:
#   - Convert detector results into SM operational decisions
#   - Select the highest-priority matched rule
#   - Decide whether a quick response is possible
#   - Return Korean console / CSV fields
#
# This module MUST NOT contain:
#   - ZIP path definitions
#   - Error-message search patterns
#   - Host / Proxy / SG extraction logic
# ============================================================

function Get-DecisionPropertyValue {
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

function Get-HighestPriorityMatchedRule {
    param(
        [Parameter(Mandatory = $false)]
        $MatchedRules
    )

    $SelectedRule = $null
    $SelectedPriority = [int]::MinValue

    foreach ($Rule in @($MatchedRules)) {
        if ($null -eq $Rule) {
            continue
        }

        $Priority = 0
        $PriorityValue = Get-DecisionPropertyValue `
            -Object $Rule `
            -Name "Priority"

        if ($null -ne $PriorityValue) {
            try {
                $Priority = [int]$PriorityValue
            }
            catch {
                $Priority = 0
            }
        }

        if ($null -eq $SelectedRule) {
            $SelectedRule = $Rule
            $SelectedPriority = $Priority
            continue
        }

        if ($Priority -gt $SelectedPriority) {
            $SelectedRule = $Rule
            $SelectedPriority = $Priority
        }
    }

    return $SelectedRule
}

function Test-AnyRuleEvaluated {
    param(
        [Parameter(Mandatory = $false)]
        $RuleResults
    )

    foreach ($Rule in @($RuleResults)) {
        if ($null -eq $Rule) {
            continue
        }

        $Evaluated = Get-DecisionPropertyValue `
            -Object $Rule `
            -Name "Evaluated"

        if ($Evaluated -eq $true) {
            return $true
        }
    }

    return $false
}

function Test-AnyMatchedRule {
    param(
        [Parameter(Mandatory = $false)]
        $MatchedRules
    )

    foreach ($Rule in @($MatchedRules)) {
        if ($null -ne $Rule) {
            return $true
        }
    }

    return $false
}

function Test-AnyQuickResponseMatch {
    param(
        [Parameter(Mandatory = $false)]
        $MatchedRules
    )

    foreach ($Rule in @($MatchedRules)) {
        if ($null -eq $Rule) {
            continue
        }

        $QuickResponse = Get-DecisionPropertyValue `
            -Object $Rule `
            -Name "QuickResponse"

        if ($QuickResponse -eq $true) {
            return $true
        }
    }

    return $false
}

function Get-DetectedCategoryText {
    param(
        [Parameter(Mandatory = $false)]
        $CategoryResults
    )

    $Detected = New-Object System.Collections.Generic.List[string]

    foreach ($Category in @($CategoryResults)) {
        if ($null -eq $Category) {
            continue
        }

        $StatusCode = [string](
            Get-DecisionPropertyValue `
                -Object $Category `
                -Name "StatusCode"
        )

        if ($StatusCode -ine "DETECTED") {
            continue
        }

        $DisplayName = [string](
            Get-DecisionPropertyValue `
                -Object $Category `
                -Name "DisplayName"
        )

        if ([string]::IsNullOrWhiteSpace($DisplayName)) {
            continue
        }

        if (-not $Detected.Contains($DisplayName)) {
            $Detected.Add($DisplayName)
        }
    }

    if ($Detected.ToArray()) {
        return ($Detected.ToArray() -join " + ")
    }

    return $null
}

function Get-DiagnosticDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $Inventory,

        [Parameter(Mandatory = $true)]
        $DetectionResult,

        [Parameter(Mandatory = $false)]
        $RuleConfig
    )

    if ($null -eq $DetectionResult) {
        throw "탐지 결과가 전달되지 않았습니다."
    }

    $DetectionDataProperty = $DetectionResult.PSObject.Properties["Data"]

    if ($null -eq $DetectionDataProperty) {
        throw "탐지 결과에 Data 항목이 없습니다."
    }

    $DetectionData = $DetectionDataProperty.Value

    if ($null -eq $DetectionData) {
        throw "탐지 결과 Data가 비어 있습니다."
    }

    $MatchedRules = Get-DecisionPropertyValue `
        -Object $DetectionData `
        -Name "MatchedRules"

    $RuleResults = Get-DecisionPropertyValue `
        -Object $DetectionData `
        -Name "RuleResults"

    $CategoryResults = Get-DecisionPropertyValue `
        -Object $DetectionData `
        -Name "CategoryResults"

    $HasAnyMatch = Test-AnyMatchedRule `
        -MatchedRules $MatchedRules

    $HasQuickResponseMatch = Test-AnyQuickResponseMatch `
        -MatchedRules $MatchedRules

    $HasAnyEvaluatedRule = Test-AnyRuleEvaluated `
        -RuleResults $RuleResults

    $PrimaryRule = Get-HighestPriorityMatchedRule `
        -MatchedRules $MatchedRules

    $QuickResponseText = "아니요"
    $DecisionCode = "REVIEW_REQUIRED"
    $DecisionText = "추가 분석 필요"
    $ActionCode = "ADDITIONAL_ANALYSIS_REQUIRED"
    $ActionText = "추가 분석 또는 벤더 확인 필요"
    $PrimaryRuleId = $null
    $DetectedCategories = Get-DetectedCategoryText `
        -CategoryResults $CategoryResults

    # --------------------------------------------------------
    # Case 1: At least one known quick-response rule matched.
    # Use the highest-priority matched rule as the primary
    # operational decision.
    # --------------------------------------------------------

    if ($HasQuickResponseMatch -and $null -ne $PrimaryRule) {
        $QuickResponseText = "예"

        $PrimaryRuleId = [string](
            Get-DecisionPropertyValue `
                -Object $PrimaryRule `
                -Name "Id"
        )

        $RuleDecisionCode = Get-DecisionPropertyValue `
            -Object $PrimaryRule `
            -Name "DecisionCode"

        $RuleDecisionText = Get-DecisionPropertyValue `
            -Object $PrimaryRule `
            -Name "DecisionText"

        $RuleActionCode = Get-DecisionPropertyValue `
            -Object $PrimaryRule `
            -Name "ActionCode"

        $RuleActionText = Get-DecisionPropertyValue `
            -Object $PrimaryRule `
            -Name "ActionText"

        if (-not [string]::IsNullOrWhiteSpace([string]$RuleDecisionCode)) {
            $DecisionCode = [string]$RuleDecisionCode
        }
        else {
            $DecisionCode = "KNOWN_QUICK_ACTION"
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$RuleDecisionText)) {
            $DecisionText = [string]$RuleDecisionText
        }
        else {
            $DecisionText = "등록된 신속 판정 오류 탐지"
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$RuleActionCode)) {
            $ActionCode = [string]$RuleActionCode
        }
        else {
            $ActionCode = "QUICK_ACTION_REQUIRED"
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$RuleActionText)) {
            $ActionText = [string]$RuleActionText
        }
        else {
            $ActionText = "등록된 운영 조치 수행"
        }
    }

    # --------------------------------------------------------
    # Case 2: A rule matched, but it is not approved as a
    # quick-response rule.
    # --------------------------------------------------------

    elseif ($HasAnyMatch) {
        $QuickResponseText = "아니요"
        $DecisionCode = "KNOWN_PATTERN_REVIEW_REQUIRED"
        $DecisionText = "알려진 패턴 탐지 - 추가 분석 필요"
        $ActionCode = "ADDITIONAL_ANALYSIS_REQUIRED"
        $ActionText = "추가 분석 또는 벤더 확인 필요"

        if ($null -ne $PrimaryRule) {
            $PrimaryRuleId = [string](
                Get-DecisionPropertyValue `
                    -Object $PrimaryRule `
                    -Name "Id"
            )
        }
    }

    # --------------------------------------------------------
    # Case 3: Rules were actually checked, but no registered
    # pattern matched.
    # This MUST NOT mean "healthy".
    # --------------------------------------------------------

    elseif ($HasAnyEvaluatedRule) {
        $QuickResponseText = "아니요"
        $DecisionCode = "NO_KNOWN_QUICK_PATTERN"
        $DecisionText = "등록된 신속 판정 오류 없음"
        $ActionCode = "ADDITIONAL_ANALYSIS_REQUIRED"
        $ActionText = "추가 분석 또는 벤더 확인 필요"
    }

    # --------------------------------------------------------
    # Case 4: No rule could be evaluated because the configured
    # evidence files were not present/readable.
    # --------------------------------------------------------

    else {
        $QuickResponseText = "아니요"
        $DecisionCode = "INSUFFICIENT_EVIDENCE"
        $DecisionText = "판정 자료 부족"
        $ActionCode = "REVIEW_REQUIRED"
        $ActionText = "진단자료 확인 후 추가 분석 필요"
    }

    $Output = [ordered]@{
        "10분 내 답변 가능" = $QuickResponseText
        "판정"              = $DecisionText
        "권장 조치"         = $ActionText
    }

    $Data = [PSCustomObject]@{
        QuickResponse       = $HasQuickResponseMatch
        QuickResponseText   = $QuickResponseText
        DecisionCode        = $DecisionCode
        DecisionText        = $DecisionText
        ActionCode          = $ActionCode
        ActionText          = $ActionText
        PrimaryRuleId       = $PrimaryRuleId
        DetectedCategories  = $DetectedCategories
    }

    return [PSCustomObject]@{
        Output = $Output
        Data   = $Data
    }
}

Export-ModuleMember -Function @(
    "Get-DiagnosticDecision"
)
