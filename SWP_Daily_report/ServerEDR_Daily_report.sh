#!/bin/bash

set -e

export TZ=Asia/Seoul

BASE_DIR="/mnt/e/SWP_Daily_Report"
PYTHON="/usr/bin/python3"

cd "$BASE_DIR"

# Server EDR 일일보고 생성
"$PYTHON" "$BASE_DIR/SWP_daily_report.py"

# Teams 웹훅 전송
"$PYTHON" "$BASE_DIR/report_sendTeams.py"
