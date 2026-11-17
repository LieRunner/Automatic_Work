#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# ============================================================
# Main runner only
#
# Responsibilities:
#   1. Validate folders / module / config files
#   2. Load modules and configuration
#   3. Iterate supported input files (.zip / .log / .txt)
#   4. Route ZIP and standalone text/log files to the proper flow
#   5. Call detector -> decision engine
#   6. Print results and save CSV
#
# Diagnostic paths, parsing logic and error patterns MUST NOT
# be added to this file.
# ============================================================

$RootPath   = $PSScriptRoot
$InputPath  = Join-Path $RootPath "input"
$OutputPath = Join-Path $RootPath "output"
$ConfigPath = Join-Path $RootPath "config"
$ModulePath = Join-Path $RootPath "modules"

$FilesConfigPath = Join-Path $ConfigPath "files.json"
$RulesConfigPath = Join-Path $ConfigPath "rules.json"

$ModuleFiles = @(
    (Join-Path $ModulePath "ZipTools.psm1"),
    (Join-Path $ModulePath "Extractors.psm1"),
    (Join-Path $ModulePath "Detectors.psm1"),
    (Join-Path $ModulePath "DecisionEngine.psm1")
)

$SupportedExtensions = @(
    ".zip",
    ".log",
    ".txt"
)

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ResultCsv = Join-Path $OutputPath ("EDR_진단패키지_신속판정_{0}.csv" -f $Timestamp)

function New-RequiredDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-MissingDependency {
    $Missing = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $FilesConfigPath -PathType Leaf)) {
        $Missing.Add($FilesConfigPath)
    }

    if (-not (Test-Path -LiteralPath $RulesConfigPath -PathType Leaf)) {
        $Missing.Add($RulesConfigPath)
    }

    foreach ($ModuleFile in $ModuleFiles) {
        if (-not (Test-Path -LiteralPath $ModuleFile -PathType Leaf)) {
            $Missing.Add($ModuleFile)
        }
    }

    return @($Missing.ToArray())
}

function Import-DiagnosticModules {
    foreach ($ModuleFile in $ModuleFiles) {
        Import-Module -Name $ModuleFile -Force -ErrorAction Stop
    }
}

function Read-JsonConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Raw = [System.IO.File]::ReadAllText(
        $Path,
        [System.Text.Encoding]::UTF8
    )

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "설정 파일이 비어 있습니다: $Path"
    }

    return ($Raw | ConvertFrom-Json)
}

function Add-OutputFields {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary]$Target,

        [Parameter(Mandatory = $false)]
        $Source
    )

    if ($null -eq $Source) {
        return
    }

    $OutputProperty = $Source.PSObject.Properties["Output"]

    if ($null -eq $OutputProperty) {
        return
    }

    $OutputData = $OutputProperty.Value

    if ($null -eq $OutputData) {
        return
    }

    if ($OutputData -is [System.Collections.IDictionary]) {
        foreach ($Key in $OutputData.Keys) {
            $Target[$Key] = $OutputData[$Key]
        }
        return
    }

    foreach ($Property in $OutputData.PSObject.Properties) {
        $Target[$Property.Name] = $Property.Value
    }
}

function Convert-OrderedDictionaryToObject {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary]$Data
    )

    $ObjectData = [ordered]@{}

    foreach ($Key in $Data.Keys) {
        $ObjectData[$Key] = $Data[$Key]
    }

    return [PSCustomObject]$ObjectData
}

function Write-ModuleOutput {
    param(
        [Parameter(Mandatory = $false)]
        $Source
    )

    if ($null -eq $Source) {
        return
    }

    $OutputProperty = $Source.PSObject.Properties["Output"]

    if ($null -eq $OutputProperty) {
        return
    }

    $OutputData = $OutputProperty.Value

    if ($null -eq $OutputData) {
        return
    }

    if ($OutputData -is [System.Collections.IDictionary]) {
        foreach ($Key in $OutputData.Keys) {
            Write-Host ("  {0,-22}: {1}" -f $Key, $OutputData[$Key])
        }
        return
    }

    foreach ($Property in $OutputData.PSObject.Properties) {
        Write-Host ("  {0,-22}: {1}" -f $Property.Name, $Property.Value)
    }
}

function Save-ResultCsv {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Results,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # Mixed input can produce different fields:
    #   - ZIP      : host / proxy / process + detection + decision
    #   - LOG/TXT  : detection + decision only
    #
    # ConvertTo-Csv follows the property set of the objects it receives.
    # Normalize every row to the union of all discovered columns first,
    # so ZIP-only fields are not lost when a standalone file is processed
    # before a ZIP file.
    $ColumnNames = New-Object System.Collections.Generic.List[string]

    foreach ($Result in @($Results)) {
        if ($null -eq $Result) {
            continue
        }

        foreach ($Property in $Result.PSObject.Properties) {
            if (-not $ColumnNames.Contains($Property.Name)) {
                $ColumnNames.Add($Property.Name)
            }
        }
    }

    $NormalizedResults = New-Object System.Collections.Generic.List[object]

    foreach ($Result in @($Results)) {
        if ($null -eq $Result) {
            continue
        }

        $Row = [ordered]@{}

        foreach ($ColumnName in $ColumnNames.ToArray()) {
            $Property = $Result.PSObject.Properties[$ColumnName]

            if ($null -ne $Property) {
                $Row[$ColumnName] = $Property.Value
            }
            else {
                $Row[$ColumnName] = ""
            }
        }

        $NormalizedResults.Add(
            [PSCustomObject]$Row
        )
    }

    $CsvLines = @(
        $NormalizedResults.ToArray() |
            ConvertTo-Csv -NoTypeInformation
    )

    $Utf8Bom = New-Object System.Text.UTF8Encoding($true)

    [System.IO.File]::WriteAllLines(
        $Path,
        $CsvLines,
        $Utf8Bom
    )
}

function Get-InputTypeText {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $Extension = $File.Extension.ToLowerInvariant()

    switch ($Extension) {
        ".zip" {
            return "진단 ZIP"
        }

        ".log" {
            return "단일 LOG"
        }

        ".txt" {
            return "단일 TXT"
        }

        default {
            return "지원하지 않는 형식"
        }
    }
}

New-RequiredDirectory -Path $InputPath
New-RequiredDirectory -Path $OutputPath
New-RequiredDirectory -Path $ConfigPath
New-RequiredDirectory -Path $ModulePath

$MissingDependencies = @(Get-MissingDependency)

if (@($MissingDependencies).Count -gt 0) {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host " EDR 진단패키지 신속 판정 - 초기 구성 필요"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "아직 생성되지 않은 파일이 있습니다."
    Write-Host ""

    foreach ($MissingItem in $MissingDependencies) {
        Write-Host "  - $MissingItem"
    }

    Write-Host ""
    Write-Host "필요한 파일을 모두 생성한 뒤 다시 실행하십시오."
    Write-Host ""
    exit 1
}

try {
    Import-DiagnosticModules

    $FileConfig = Read-JsonConfig -Path $FilesConfigPath
    $RuleConfig = Read-JsonConfig -Path $RulesConfigPath
}
catch {
    Write-Host ""
    Write-Host "초기화 실패"
    Write-Host "오류: $($_.Exception.Message)"
    Write-Host ""
    exit 1
}

$InputFiles = @(
    Get-ChildItem `
        -LiteralPath $InputPath `
        -File `
        -Recurse `
        -ErrorAction Stop |
        Where-Object {
            $SupportedExtensions -contains $_.Extension.ToLowerInvariant()
        } |
        Sort-Object FullName
)

if (@($InputFiles).Count -eq 0) {
    Write-Host ""
    Write-Host "검사 가능한 입력 파일이 없습니다."
    Write-Host "지원 형식: .zip, .log, .txt"
    Write-Host "입력 경로: $InputPath"
    Write-Host ""
    exit 0
}

$ZipFiles = @(
    $InputFiles |
        Where-Object {
            $_.Extension -ieq ".zip"
        }
)

$LogFiles = @(
    $InputFiles |
        Where-Object {
            $_.Extension -ieq ".log"
        }
)

$TextFiles = @(
    $InputFiles |
        Where-Object {
            $_.Extension -ieq ".txt"
        }
)

Write-Host ""
Write-Host "============================================================"
Write-Host " EDR 진단패키지 신속 판정"
Write-Host "============================================================"
Write-Host "입력 경로 : $InputPath"
Write-Host "전체 파일 : $(@($InputFiles).Count)"
Write-Host "ZIP       : $(@($ZipFiles).Count)"
Write-Host "LOG       : $(@($LogFiles).Count)"
Write-Host "TXT       : $(@($TextFiles).Count)"
Write-Host ""

$Results = New-Object System.Collections.Generic.List[object]

foreach ($InputFile in $InputFiles) {
    $Archive = $null
    $Inventory = $null
    $DetectionResult = $null
    $DecisionResult = $null

    $InputType = Get-InputTypeText -File $InputFile
    $Extension = $InputFile.Extension.ToLowerInvariant()
    $CurrentStage = "입력 파일 확인"

    Write-Host "검사 파일: $($InputFile.Name)"
    Write-Host "입력 형식: $InputType"

    try {
        # ====================================================
        # ZIP diagnostic package
        # ====================================================
        if ($Extension -eq ".zip") {
            $CurrentStage = "ZIP 열기"

            $Archive = Open-DiagnosticArchive `
                -Path $InputFile.FullName

            $CurrentStage = "기본 정보 추출"

            $Inventory = Get-DiagnosticInventory `
                -Archive $Archive `
                -FileConfig $FileConfig

            $CurrentStage = "오류 규칙 검사"

            $DetectionResult = Invoke-DiagnosticRules `
                -Archive $Archive `
                -FileConfig $FileConfig `
                -RuleConfig $RuleConfig `
                -Inventory $Inventory
        }

        # ====================================================
        # Standalone .log / .txt file
        #
        # The detector module will:
        #   1. Match the standalone file name to files.json
        #   2. Resolve the corresponding Source ID
        #   3. Evaluate only rules that use that Source
        #
        # Host / Proxy / SG inventory extraction is intentionally
        # skipped because a standalone log does not contain the
        # complete diagnostic package.
        # ====================================================
        elseif (
            $Extension -eq ".log" -or
            $Extension -eq ".txt"
        ) {
            $CurrentStage = "단일 파일 규칙 검사"

            $DetectionResult = Invoke-DiagnosticStandaloneRules `
                -Path $InputFile.FullName `
                -FileConfig $FileConfig `
                -RuleConfig $RuleConfig
        }
        else {
            throw "지원하지 않는 입력 형식입니다: $Extension"
        }

        $CurrentStage = "운영 판정"

        $DecisionResult = Get-DiagnosticDecision `
            -Inventory $Inventory `
            -DetectionResult $DetectionResult `
            -RuleConfig $RuleConfig

        if ($null -ne $Inventory) {
            Write-Host ""
            Write-ModuleOutput -Source $Inventory
        }

        Write-Host ""
        Write-ModuleOutput -Source $DetectionResult

        Write-Host ""
        Write-ModuleOutput -Source $DecisionResult

        $Row = [ordered]@{
            "입력 파일명" = $InputFile.Name
            "입력 경로"   = $InputFile.FullName
            "입력 형식"   = $InputType
            "검사 상태"   = "성공"
        }

        Add-OutputFields -Target $Row -Source $Inventory
        Add-OutputFields -Target $Row -Source $DetectionResult
        Add-OutputFields -Target $Row -Source $DecisionResult

        $Row["오류 단계"] = ""
        $Row["오류 내용"] = ""

        $Results.Add(
            (Convert-OrderedDictionaryToObject -Data $Row)
        )
    }
    catch {
        Write-Host ""
        Write-Host "  입력 파일 검사 실패"
        Write-Host "  실패 단계: $CurrentStage"
        Write-Host "  오류: $($_.Exception.Message)"

        if ($null -ne $_.InvocationInfo) {
            $PositionMessage = $_.InvocationInfo.PositionMessage

            if (-not [string]::IsNullOrWhiteSpace($PositionMessage)) {
                Write-Host "  위치: $PositionMessage"
            }
        }

        $ErrorRow = [ordered]@{
            "입력 파일명" = $InputFile.Name
            "입력 경로"   = $InputFile.FullName
            "입력 형식"   = $InputType
            "검사 상태"   = "실패"
            "오류 단계"   = $CurrentStage
            "오류 내용"   = $_.Exception.Message
        }

        $Results.Add(
            (Convert-OrderedDictionaryToObject -Data $ErrorRow)
        )
    }
    finally {
        if ($null -ne $Archive) {
            try {
                Close-DiagnosticArchive -Archive $Archive
            }
            catch {
                # Do not replace the original result with a close error.
            }
        }
    }

    Write-Host ""
}

try {
    Save-ResultCsv `
        -Results @($Results.ToArray()) `
        -Path $ResultCsv

    Write-Host "============================================================"
    Write-Host " 검사 완료"
    Write-Host "============================================================"
    Write-Host "전체 파일 : $(@($InputFiles).Count)"
    Write-Host "ZIP       : $(@($ZipFiles).Count)"
    Write-Host "LOG       : $(@($LogFiles).Count)"
    Write-Host "TXT       : $(@($TextFiles).Count)"
    Write-Host ""
    Write-Host "CSV 저장 완료:"
    Write-Host $ResultCsv
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "CSV 저장 실패"
    Write-Host "오류: $($_.Exception.Message)"
    Write-Host ""
    exit 1
}
