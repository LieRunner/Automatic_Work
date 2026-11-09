$lines = Get-Content .\input.txt

$output = @()

function Test-EppOnlyOS {
    param([string[]]$Values)

    foreach ($value in $Values) {
        # EL6 이하의 RPM 계열 및 Amazon Linux 1 (커널 표기도 포함)
        if (
            $value -match '(?i)(?:^|[._-])el[1-6](?!\d)' -or
            $value -match '(?i)(?:^|[._-])amzn1(?!\d)' -or
            $value -match '(?i)^Amazon\s+Linux(?:\s+AMI)?(?:\s+release)?\s+1(?!\d)' -or
            $value -match '(?i)^Amazon\s+Linux\s+AMI\s+20(?:0\d|1\d)\b' -or
            $value -match '(?i)^CentOS(?:\s+Linux)?(?:\s+release)?\s+[56](?!\d)' -or
            $value -match '(?i)^(?:Red\s*Hat(?:\s+Enterprise)?(?:\s+Linux)?(?:\s+Server)?|RHEL)(?:\s+release)?\s+[56](?!\d)' -or
            $value -match '(?i)^(?:Oracle(?:\s+Linux)?|Scientific(?:\s+Linux)?|CloudLinux)(?:\s+Server)?(?:\s+release)?\s+[1-6](?!\d)'
        ) {
            return $true
        }
    }

    return $false
}

for ($i = 0; $i -lt ($lines.Count - 2); $i++) {

    $id   = $lines[$i].Trim()
    $ip   = $lines[$i + 1].Trim()
    $uuid = $lines[$i + 2].Trim()

    $isIP = $ip -match '^\d{1,3}(\.\d{1,3}){3}$'
    $isUUID = $uuid -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

    if ($id -ne "" -and $isIP -and $isUUID) {

        $end = $lines.Count

        for ($j = $i + 3; $j -lt ($lines.Count - 2); $j++) {

            $nextIP   = $lines[$j + 1].Trim()
            $nextUUID = $lines[$j + 2].Trim()

            if (
                $nextIP -match '^\d{1,3}(\.\d{1,3}){3}$' -and
                $nextUUID -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            ) {
                $end = $j
                break
            }
        }

        $block = @()

        for ($j = $i + 3; $j -lt $end; $j++) {

            $value = $lines[$j].Trim()

            if ($value -ne "") {
                $block += $value
            }
        }

        # 일부 목록은 IP 앞에 번호가 있고, 실제 장비명은 UUID 다음에 나옴
        if ($id -match '^\d+$' -and $block.Count -gt 0 -and $block[0] -ne '-') {
            $id = $block[0]
        }

        # 버전이 없으면 X
        $linkStatus = ""
        $version1 = "X"
        $version2 = "X"

        $versionIndexes = @()

        for ($j = 0; $j -lt $block.Count; $j++) {

            $value = $block[$j]

            if ($value -match '^\d+\.\d+\.\d+\.\d+$') {

                $parts = $value.Split('.')
                $isIPValue = $true

                foreach ($part in $parts) {
                    if ([int]$part -gt 255) {
                        $isIPValue = $false
                        break
                    }
                }

                if (-not $isIPValue) {
                    $versionIndexes += $j
                }
            }
        }

        $isEppOnly = Test-EppOnlyOS -Values $block

        if ($isEppOnly) {
            # EDR 미지원 장비: 유일한 버전(또는 마지막 버전)은 EPP 버전
            if ($versionIndexes.Count -ge 1) {
                $version2 = $block[$versionIndexes[$versionIndexes.Count - 1]]
            }

            $linkStatus = '정상 연동(EPPOnly)'

            # 통신 중이고 최근 통신 시각이 있는 경우에만 정상 연동으로 표시
            $hasRecentContact = @($block | Where-Object { $_ -match '^Just now' }).Count -gt 0
            if ($block -notcontains 'Communicating' -or -not $hasRecentContact) {
                $linkStatus = '연동 확인 필요(EPPOnly)'
            }
        } else {

        if ($versionIndexes.Count -ge 1) {
            $v1Index = $versionIndexes[0]
            $version1 = $block[$v1Index]
        }

        if ($versionIndexes.Count -ge 2) {
            $v2Index = $versionIndexes[1]
            $version2 = $block[$v2Index]
        }

        if ($versionIndexes.Count -ge 1) {

            $v1Index = $versionIndexes[0]

            if ($v1Index -ge 5) {

                $connectedStatus = $block[$v1Index - 5]
                $onStatus        = $block[$v1Index - 4]
                $enabledStatus   = $block[$v1Index - 3]
                $time1           = $block[$v1Index - 2]
                $time2           = $block[$v1Index - 1]

                if ($connectedStatus -ne "Connected") {
                    $version1 += " X"
                }

                if ($onStatus -ne "Communicating") {
                    if ($version2 -eq "X") {
                        $version2 = "X"
                    } else {
                        $version2 += " X"
                    }
                }

                if ($enabledStatus -ne "Enabled") {
                    if ($version2 -eq "X") {
                        $version2 = "X [$enabledStatus]"
                    } else {
                        $version2 += " X [$enabledStatus]"
                    }
                }

                if ($time1 -notmatch '^Just now') {
                    $version1 += " [$time1]"
                }

                if ($time2 -notmatch '^Just now') {
                    if ($version2 -eq "X") {
                        $version2 = "X [$time2]"
                    } else {
                        $version2 += " [$time2]"
                    }
                }

                if (
                    $connectedStatus -eq 'Connected' -and
                    $onStatus -eq 'Communicating' -and
                    $enabledStatus -eq 'Enabled' -and
                    $time1 -match '^Just now' -and
                    $time2 -match '^Just now'
                ) {
                    $linkStatus = '정상 연동'
                }
            }
        }

        }

        $output += "$id`t$ip`t$uuid`t$linkStatus`t$version1`t$version2"

        $i = $end - 1
    }
}

$output | Set-Content .\output.txt -Encoding UTF8
 
