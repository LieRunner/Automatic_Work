#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# Extractors.psm1
#
# Responsibilities:
#   - Extract host / network / component status information
#   - Return Korean display fields for console / CSV
#   - Return normalized internal data for later decision logic
#
# This module MUST NOT contain:
#   - RPM DB / XBC Config error-message rules
#   - Quick-response decision logic
#   - ZIP path matching logic
# ============================================================

function Get-SafePropertyValue {
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

function Get-XmlChildText {
    param(
        [Parameter(Mandatory = $false)]
        $Node,

        [Parameter(Mandatory = $true)]
        [string]$XPath
    )

    if ($null -eq $Node) {
        return $null
    }

    $Child = $Node.SelectSingleNode($XPath)

    if ($null -eq $Child) {
        return $null
    }

    $Value = [string]$Child.InnerText

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    return $Value.Trim()
}

function ConvertFrom-DiagnosticJson {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    try {
        return ($Text | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Get-HostInformation {
    param(
        [Parameter(Mandatory = $true)]
        $Archive,

        [Parameter(Mandatory = $true)]
        $FileConfig
    )

    $Hostname = $null
    $IPAddress = $null
    $HostGUID = $null
    $SourcePath = $null

    foreach ($Entry in @(
        Get-DiagnosticEntriesById `
            -Archive $Archive `
            -FileConfig $FileConfig `
            -Id "HostInfo"
    )) {
        if ($null -eq $Entry) {
            continue
        }

        $Text = Read-DiagnosticEntryText -Entry $Entry

        if ([string]::IsNullOrWhiteSpace($Text)) {
            continue
        }

        try {
            [xml]$Xml = $Text
        }
        catch {
            continue
        }

        $HostNodes = $Xml.SelectNodes("/HostInformation/Host")

        foreach ($HostNode in @($HostNodes)) {
            if ($null -eq $HostNode) {
                continue
            }

            if ([string]::IsNullOrWhiteSpace($Hostname)) {
                $Hostname = Get-XmlChildText `
                    -Node $HostNode `
                    -XPath "./Hostname"
            }

            if ([string]::IsNullOrWhiteSpace($IPAddress)) {
                $IPAddress = Get-XmlChildText `
                    -Node $HostNode `
                    -XPath "./IP"

                if ([string]::IsNullOrWhiteSpace($IPAddress)) {
                    $IPAddress = Get-XmlChildText `
                        -Node $HostNode `
                        -XPath "./LastIPUsed"
                }
            }

            if ([string]::IsNullOrWhiteSpace($HostGUID)) {
                $HostGUID = Get-XmlChildText `
                    -Node $HostNode `
                    -XPath "./HostGUID"
            }

            if ([string]::IsNullOrWhiteSpace($SourcePath)) {
                $SourcePath = [string]$Entry.FullName
            }

            if (
                -not [string]::IsNullOrWhiteSpace($Hostname) -and
                -not [string]::IsNullOrWhiteSpace($IPAddress) -and
                -not [string]::IsNullOrWhiteSpace($HostGUID)
            ) {
                break
            }
        }

        if (
            -not [string]::IsNullOrWhiteSpace($Hostname) -and
            -not [string]::IsNullOrWhiteSpace($IPAddress) -and
            -not [string]::IsNullOrWhiteSpace($HostGUID)
        ) {
            break
        }
    }

    return [PSCustomObject]@{
        Hostname   = $Hostname
        IPAddress  = $IPAddress
        HostGUID   = $HostGUID
        SourcePath = $SourcePath
    }
}

function Get-ActiveProxyInformation {
    param(
        [Parameter(Mandatory = $true)]
        $Archive,

        [Parameter(Mandatory = $true)]
        $FileConfig
    )

    $Entry = Get-DiagnosticEntryById `
        -Archive $Archive `
        -FileConfig $FileConfig `
        -Id "ProxyInfo"

    if ($null -eq $Entry) {
        return [PSCustomObject]@{
            URL        = $null
            Available  = $null
            SourcePath = $null
        }
    }

    $Text = Read-DiagnosticEntryText -Entry $Entry
    $Json = ConvertFrom-DiagnosticJson -Text $Text

    if ($null -eq $Json) {
        return [PSCustomObject]@{
            URL        = $null
            Available  = $null
            SourcePath = [string]$Entry.FullName
        }
    }

    # HBUsedProxy is intentionally used as the primary source.
    # Configured proxy / Service Gateway candidates are not treated
    # as the proxy actually used by the agent.
    $HBUsedProxy = Get-SafePropertyValue `
        -Object $Json `
        -Name "HBUsedProxy"

    if ($null -eq $HBUsedProxy) {
        return [PSCustomObject]@{
            URL        = $null
            Available  = $null
            SourcePath = [string]$Entry.FullName
        }
    }

    $URL = Get-SafePropertyValue `
        -Object $HBUsedProxy `
        -Name "URL"

    $AvailableRaw = Get-SafePropertyValue `
        -Object $HBUsedProxy `
        -Name "Available"

    $Available = $null

    if ($null -ne $AvailableRaw) {
        $Available = [System.Convert]::ToBoolean($AvailableRaw)
    }

    return [PSCustomObject]@{
        URL        = $URL
        Available  = $Available
        SourcePath = [string]$Entry.FullName
    }
}

function Get-ServiceGatewayConnectionLabel {
    param(
        [Parameter(Mandatory = $false)]
        $Connection
    )

    if ($null -eq $Connection) {
        return $null
    }

    if ($Connection -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($Connection)) {
            return $Connection.Trim()
        }

        return $null
    }

    $PreferredProperties = @(
        "Name",
        "name",
        "URL",
        "url",
        "Host",
        "host",
        "Address",
        "address",
        "Endpoint",
        "endpoint"
    )

    foreach ($PropertyName in $PreferredProperties) {
        $Value = Get-SafePropertyValue `
            -Object $Connection `
            -Name $PropertyName

        if ($null -eq $Value) {
            continue
        }

        $TextValue = [string]$Value

        if (-not [string]::IsNullOrWhiteSpace($TextValue)) {
            return $TextValue.Trim()
        }
    }

    return $null
}

function Get-ConnectedServiceGateway {
    param(
        [Parameter(Mandatory = $true)]
        $Archive,

        [Parameter(Mandatory = $true)]
        $FileConfig
    )

    $Entry = Get-DiagnosticEntryById `
        -Archive $Archive `
        -FileConfig $FileConfig `
        -Id "ServiceGatewayInfo"

    if ($null -eq $Entry) {
        return [PSCustomObject]@{
            Connected  = $null
            Value      = $null
            SourcePath = $null
        }
    }

    $Text = Read-DiagnosticEntryText -Entry $Entry
    $Json = ConvertFrom-DiagnosticJson -Text $Text

    if ($null -eq $Json) {
        return [PSCustomObject]@{
            Connected  = $null
            Value      = $null
            SourcePath = [string]$Entry.FullName
        }
    }

    $Services = Get-SafePropertyValue `
        -Object $Json `
        -Name "services"

    if ($null -eq $Services) {
        return [PSCustomObject]@{
            Connected  = $null
            Value      = $null
            SourcePath = [string]$Entry.FullName
        }
    }

    $Values = New-Object System.Collections.Generic.List[string]
    $HasConnection = $false

    foreach ($ServiceName in @("gcs", "lau")) {
        $Service = Get-SafePropertyValue `
            -Object $Services `
            -Name $ServiceName

        if ($null -eq $Service) {
            continue
        }

        $Connections = Get-SafePropertyValue `
            -Object $Service `
            -Name "connections"

        foreach ($Connection in @($Connections)) {
            if ($null -eq $Connection) {
                continue
            }

            $HasConnection = $true

            $Label = Get-ServiceGatewayConnectionLabel `
                -Connection $Connection

            if (-not [string]::IsNullOrWhiteSpace($Label)) {
                if (-not $Values.Contains($Label)) {
                    $Values.Add($Label)
                }
            }
        }
    }

    $JoinedValue = $null

    if ($HasConnection) {
        if ($Values.ToArray()) {
            $JoinedValue = ($Values.ToArray() -join " | ")
        }
        else {
            $JoinedValue = "연결 정보 존재"
        }
    }

    return [PSCustomObject]@{
        Connected  = $HasConnection
        Value      = $JoinedValue
        SourcePath = [string]$Entry.FullName
    }
}

function Get-RunningProcessInformation {
    param(
        [Parameter(Mandatory = $true)]
        $Archive,

        [Parameter(Mandatory = $true)]
        $FileConfig
    )

    $Entry = Get-DiagnosticEntryById `
        -Archive $Archive `
        -FileConfig $FileConfig `
        -Id "RunningProcesses"

    if ($null -eq $Entry) {
        return [PSCustomObject]@{
            EvidenceAvailable = $false
            VlsAgentRunning   = $null
            TmxbcRunning      = $null
            SourcePath        = $null
        }
    }

    $Text = Read-DiagnosticEntryText -Entry $Entry

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [PSCustomObject]@{
            EvidenceAvailable = $false
            VlsAgentRunning   = $null
            TmxbcRunning      = $null
            SourcePath        = [string]$Entry.FullName
        }
    }

    try {
        [xml]$Xml = $Text
    }
    catch {
        return [PSCustomObject]@{
            EvidenceAvailable = $false
            VlsAgentRunning   = $null
            TmxbcRunning      = $null
            SourcePath        = [string]$Entry.FullName
        }
    }

    $VlsAgentRunning = $false
    $TmxbcRunning = $false

    foreach ($AttributeNode in @(
        $Xml.SelectNodes("//Attribute[@name='process']")
    )) {
        if ($null -eq $AttributeNode) {
            continue
        }

        $ProcessName = [string]$AttributeNode.GetAttribute("value")

        if ([string]::IsNullOrWhiteSpace($ProcessName)) {
            continue
        }

        if ($ProcessName -ieq "vls_agent") {
            $VlsAgentRunning = $true
        }

        if ($ProcessName -ieq "tmxbc") {
            $TmxbcRunning = $true
        }
    }

    return [PSCustomObject]@{
        EvidenceAvailable = $true
        VlsAgentRunning   = $VlsAgentRunning
        TmxbcRunning      = $TmxbcRunning
        SourcePath        = [string]$Entry.FullName
    }
}

function Get-ComponentInstallationInformation {
    param(
        [Parameter(Mandatory = $true)]
        $Archive,

        [Parameter(Mandatory = $true)]
        $FileConfig,

        [Parameter(Mandatory = $true)]
        $ProcessInfo
    )

    $StateEntry = Get-DiagnosticEntryById `
        -Archive $Archive `
        -FileConfig $FileConfig `
        -Id "StateCapture"

    $StateText = $null

    if ($null -ne $StateEntry) {
        $StateText = Read-DiagnosticEntryText -Entry $StateEntry
    }

    $TmxbcLogEntry = Get-DiagnosticEntryById `
        -Archive $Archive `
        -FileConfig $FileConfig `
        -Id "TmxbcLog"

    $VlsInstalled = $null
    $TmxbcInstalled = $null

    # A running process is definitive evidence that the component exists.
    if ($ProcessInfo.VlsAgentRunning -eq $true) {
        $VlsInstalled = $true
    }

    if ($ProcessInfo.TmxbcRunning -eq $true) {
        $TmxbcInstalled = $true
    }

    # State capture can provide additional local installation evidence.
    if (-not [string]::IsNullOrWhiteSpace($StateText)) {
        if (
            $StateText -match '(?im)/opt/TrendMicro/vls_agent/(?:vls_agent|vlsa|vls_am)\b' -or
            $StateText -match '(?im)\bvls_agent-[0-9]'
        ) {
            $VlsInstalled = $true
        }

        if (
            $StateText -match '(?im)/opt/TrendMicro/EndpointBasecamp/bin/tmxbc\b'
        ) {
            $TmxbcInstalled = $true
        }
    }

    # Presence of the current diagnostic tmxbc.log is additional evidence
    # that Endpoint Basecamp is/was present. It is not used to prove "not installed".
    if ($null -ne $TmxbcLogEntry) {
        $TmxbcInstalled = $true
    }

    return [PSCustomObject]@{
        VlsAgentInstalled = $VlsInstalled
        TmxbcInstalled    = $TmxbcInstalled
        StateCaptureText  = $StateText
        StateCapturePath  = $(if ($null -ne $StateEntry) { [string]$StateEntry.FullName } else { $null })
        TmxbcLogPath      = $(if ($null -ne $TmxbcLogEntry) { [string]$TmxbcLogEntry.FullName } else { $null })
    }
}

function Get-VlsAgentPortInformation {
    param(
        [Parameter(Mandatory = $false)]
        [string]$StateCaptureText
    )

    if ([string]::IsNullOrWhiteSpace($StateCaptureText)) {
        return [PSCustomObject]@{
            EvidenceAvailable = $false
            Listening         = $null
        }
    }

    $Listening = $false

    if (
        $StateCaptureText -match '(?im)^.*(?:127\.0\.0\.1|::1):14118\s+.*\bLISTEN\b.*\bvls_agent\b.*$'
    ) {
        $Listening = $true
    }

    return [PSCustomObject]@{
        EvidenceAvailable = $true
        Listening         = $Listening
    }
}

function Convert-BoolToInstalledText {
    param(
        [Parameter(Mandatory = $false)]
        $Value
    )

    if ($Value -eq $true) {
        return "설치됨"
    }

    return "설치 확인 안 됨"
}

function Convert-BoolToRunningText {
    param(
        [Parameter(Mandatory = $false)]
        $Value,

        [Parameter(Mandatory = $true)]
        [bool]$EvidenceAvailable
    )

    if (-not $EvidenceAvailable) {
        return "실행 확인 안 됨"
    }

    if ($Value -eq $true) {
        return "실행 중"
    }

    return "실행 안 됨"
}

function Convert-ProxyAvailableText {
    param(
        [Parameter(Mandatory = $false)]
        $Value,

        [Parameter(Mandatory = $false)]
        [string]$URL
    )

    if ([string]::IsNullOrWhiteSpace($URL)) {
        return "확인되지 않음"
    }

    if ($Value -eq $true) {
        return "사용 가능"
    }

    if ($Value -eq $false) {
        return "사용 불가"
    }

    return "상태 확인 안 됨"
}

function Convert-PortText {
    param(
        [Parameter(Mandatory = $false)]
        $Value,

        [Parameter(Mandatory = $true)]
        [bool]$EvidenceAvailable
    )

    if (-not $EvidenceAvailable) {
        return "확인되지 않음"
    }

    if ($Value -eq $true) {
        return "수신 대기 중"
    }

    return "수신 대기 확인 안 됨"
}

function Get-DiagnosticInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Archive,

        [Parameter(Mandatory = $true)]
        $FileConfig
    )

    $HostInfo = Get-HostInformation `
        -Archive $Archive `
        -FileConfig $FileConfig

    $ProxyInfo = Get-ActiveProxyInformation `
        -Archive $Archive `
        -FileConfig $FileConfig

    $ServiceGatewayInfo = Get-ConnectedServiceGateway `
        -Archive $Archive `
        -FileConfig $FileConfig

    $ProcessInfo = Get-RunningProcessInformation `
        -Archive $Archive `
        -FileConfig $FileConfig

    $InstallInfo = Get-ComponentInstallationInformation `
        -Archive $Archive `
        -FileConfig $FileConfig `
        -ProcessInfo $ProcessInfo

    $VlsPortInfo = Get-VlsAgentPortInformation `
        -StateCaptureText $InstallInfo.StateCaptureText

    $HostnameText = $HostInfo.Hostname
    $IPAddressText = $HostInfo.IPAddress
    $HostGUIDText = $HostInfo.HostGUID
    $ProxyURLText = $ProxyInfo.URL
    $ConnectedSGText = $ServiceGatewayInfo.Value

    if ([string]::IsNullOrWhiteSpace($HostnameText)) {
        $HostnameText = "확인되지 않음"
    }

    if ([string]::IsNullOrWhiteSpace($IPAddressText)) {
        $IPAddressText = "확인되지 않음"
    }

    if ([string]::IsNullOrWhiteSpace($HostGUIDText)) {
        $HostGUIDText = "확인되지 않음"
    }

    if ([string]::IsNullOrWhiteSpace($ProxyURLText)) {
        $ProxyURLText = "확인되지 않음"
    }

    if ([string]::IsNullOrWhiteSpace($ConnectedSGText)) {
        $ConnectedSGText = "확인되지 않음"
    }

    $Output = [ordered]@{
        "호스트명"          = $HostnameText
        "사용 IP"           = $IPAddressText
        "ds_agent HostGUID" = $HostGUIDText
        "사용 Proxy"        = $ProxyURLText
        "Proxy 상태"        = Convert-ProxyAvailableText `
                                -Value $ProxyInfo.Available `
                                -URL $ProxyInfo.URL
        "연결된 SG"         = $ConnectedSGText
        "vls_agent 설치"    = Convert-BoolToInstalledText `
                                -Value $InstallInfo.VlsAgentInstalled
        "vls_agent 실행"    = Convert-BoolToRunningText `
                                -Value $ProcessInfo.VlsAgentRunning `
                                -EvidenceAvailable ([bool]$ProcessInfo.EvidenceAvailable)
        "vls_agent 포트"    = Convert-PortText `
                                -Value $VlsPortInfo.Listening `
                                -EvidenceAvailable ([bool]$VlsPortInfo.EvidenceAvailable)
        "tmxbc 설치"        = Convert-BoolToInstalledText `
                                -Value $InstallInfo.TmxbcInstalled
        "tmxbc 실행"        = Convert-BoolToRunningText `
                                -Value $ProcessInfo.TmxbcRunning `
                                -EvidenceAvailable ([bool]$ProcessInfo.EvidenceAvailable)
    }

    $Data = [PSCustomObject]@{
        Hostname                    = $HostInfo.Hostname
        IPAddress                   = $HostInfo.IPAddress
        DsAgentHostGUID             = $HostInfo.HostGUID
        ActiveProxy                 = $ProxyInfo.URL
        ProxyAvailable              = $ProxyInfo.Available
        ServiceGatewayConnected     = $ServiceGatewayInfo.Connected
        ConnectedServiceGateway     = $ServiceGatewayInfo.Value
        VlsAgentInstalled           = $InstallInfo.VlsAgentInstalled
        VlsAgentRunning             = $ProcessInfo.VlsAgentRunning
        VlsAgentPort14118Listening  = $VlsPortInfo.Listening
        TmxbcInstalled              = $InstallInfo.TmxbcInstalled
        TmxbcRunning                = $ProcessInfo.TmxbcRunning
    }

    $Sources = [PSCustomObject]@{
        HostInfo           = $HostInfo.SourcePath
        ProxyInfo          = $ProxyInfo.SourcePath
        ServiceGatewayInfo = $ServiceGatewayInfo.SourcePath
        RunningProcesses   = $ProcessInfo.SourcePath
        StateCapture       = $InstallInfo.StateCapturePath
        TmxbcLog           = $InstallInfo.TmxbcLogPath
    }

    return [PSCustomObject]@{
        Output  = $Output
        Data    = $Data
        Sources = $Sources
    }
}

Export-ModuleMember -Function @(
    "Get-DiagnosticInventory"
)
