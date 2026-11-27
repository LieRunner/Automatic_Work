#!/usr/bin/env python3
"""Read the validated SWP summary XLSX and submit a Teams Workflows card."""
import argparse
import json
import os
import sys
from datetime import date, datetime, timedelta
from pathlib import Path
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo

import requests
from dotenv import load_dotenv
from openpyxl import load_workbook

BASE_DIR = Path(__file__).resolve().parent


def read_report(path, target_date, timezone_label):
    if not path.is_file():
        raise ValueError(f"보고서 파일 없음: {path.name}")
    wb = load_workbook(path, read_only=True, data_only=False)
    try:
        if "Summary" not in wb.sheetnames:
            raise ValueError("Summary 시트 없음")
        ws = wb["Summary"]
        def value(cell):
            return ws[cell].value
        def count(cell):
            result = value(cell)
            if type(result) is not int or result < 0:
                raise ValueError(f"잘못된 건수: {cell}")
            return result
        expected = {"B2": "Server EDR 일일보고", "B3": f"조회일: {target_date}",
                    "B4": f"00:00 ~ 익일 00:00 ({timezone_label})", "B6": "Anti-Malware",
                    "B7": "탐지", "C7": "차단", "B11": "IPS", "B12": "탐지", "C12": "차단"}
        for cell, text in expected.items():
            if value(cell) != text:
                raise ValueError(f"보고서 날짜 또는 양식 불일치: {cell}")
        report = {"target_date": str(target_date), "timezone": timezone_label,
                  "am": {"detect": count("B8"), "block": count("C8")},
                  "ips": {"detect": count("B13"), "block": count("C13")}, "ips_other": {}}
        if value("B16") is not None:
            if value("B16") != "IPS 기타 Action (확인 필요)" or value("B17") != "탐지·차단 집계에서 제외":
                raise ValueError("기타 Action 영역 양식 불일치")
            for label, number in ws.iter_rows(min_row=18, max_col=3, min_col=2, values_only=True):
                if label is None and number is None:
                    continue
                if not isinstance(label, str) or not label.strip() or type(number) is not int or number <= 0:
                    raise ValueError("기타 Action 데이터 오류")
                if label in report["ips_other"]:
                    raise ValueError("중복 기타 Action")
                report["ips_other"][label] = number
            if not report["ips_other"]:
                raise ValueError("기타 Action 영역에 데이터 없음")
        return report
    finally:
        wb.close()


def text_block(text, **kwargs):
    return {"type": "TextBlock", "text": text, "wrap": True, **kwargs}


def metric(label, count, color):
    return {"type": "Column", "width": "stretch", "items": [
        text_block(label, isSubtle=True, horizontalAlignment="Center"),
        text_block(f"{count:,}건", size="ExtraLarge", weight="Bolder", color=color,
                   horizontalAlignment="Center", spacing="Small")]}


def escape_markdown(text):
    # Treat API action labels as text, not formatting or Teams mention markup.
    text = " ".join(text.split()).replace("<", "＜").replace(">", "＞")
    for ch in ("\\", "*", "_", "[", "]", "(", ")", "`", "#", "~"):
        text = text.replace(ch, "\\" + ch)
    return text


def build_payload(report):
    body = [text_block("Server EDR 일일보고", size="Large", weight="Bolder"),
            text_block(f"조회일: {report['target_date']}", isSubtle=True, spacing="Small"),
            text_block(f"조회 시간: 00:00 ~ 익일 00:00 ({report['timezone']})", isSubtle=True, spacing="None")]
    for name, key in (("Anti-Malware", "am"), ("IPS", "ips")):
        body.append({"type": "Container", "separator": True, "spacing": "Medium", "items": [
            text_block(name, weight="Bolder", size="Medium"),
            {"type": "ColumnSet", "columns": [metric("탐지", report[key]["detect"], "Warning"),
                                              metric("차단", report[key]["block"], "Good")]}]})
    if report["ips_other"]:
        items = [text_block("IPS 기타 Action (확인 필요)", weight="Bolder", color="Warning"),
                 text_block("탐지·차단 집계에서 제외", isSubtle=True, size="Small", spacing="Small")]
        for action, count in report["ips_other"].items():
            items.append(text_block(f"{escape_markdown(action)}: {count:,}건", spacing="Small"))
        body.append({"type": "Container", "separator": True, "spacing": "Medium", "items": items})
    return {"type": "message", "attachments": [{
        "contentType": "application/vnd.microsoft.card.adaptive", "contentUrl": None,
        "content": {"$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                    "type": "AdaptiveCard", "version": "1.2", "body": body}}]}


def send_card(payload, webhook_url, timeout, ca_bundle=None):
    parts = urlsplit(webhook_url)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password or parts.fragment:
        raise ValueError("TEAMS_WEBHOOK_URL에 올바른 HTTPS 웹훅 URL을 지정하세요.")
    # Never reuse the Vision One API's SSL bypass or its token for Teams.
    try:
        response = requests.post(webhook_url, json=payload, timeout=timeout,
                                 verify=ca_bundle or True, allow_redirects=False)
    except requests.exceptions.RequestException as error:
        # A request exception can contain the secret webhook URL. Do not print it.
        raise RuntimeError(f"Teams 요청 실패 ({type(error).__name__}). Workflow 실행 기록을 확인하세요.") from None
    if not 200 <= response.status_code < 300:
        raise RuntimeError(f"Teams 웹훅 요청 거부: HTTP {response.status_code}")
    return response.status_code


def main():
    parser = argparse.ArgumentParser(description="Send SWP report as a Teams Adaptive Card")
    parser.add_argument("--date", type=date.fromisoformat, help="보고 기준일 YYYY-MM-DD (전날 조회)")
    parser.add_argument("--dry-run", action="store_true", help="카드 JSON 출력만 수행, 실제 전송 없음")
    args = parser.parse_args()
    load_dotenv(BASE_DIR / ".env")
    with (BASE_DIR / "config.json").open(encoding="utf-8-sig") as f:
        config = json.load(f)
    tz = ZoneInfo(config["timezone"])
    today = datetime.now(tz).date()
    reference = args.date or today
    if reference > today:
        raise ValueError("조회 기간이 아직 종료되지 않았습니다.")
    target_date = reference - timedelta(days=1)
    timezone_label = "KST" if config["timezone"] == "Asia/Seoul" else config["timezone"]
    path = BASE_DIR / config.get("output_directory", "reports") / f"SWP_Daily_Report_{target_date}.xlsx"
    report = read_report(path, target_date, timezone_label)
    payload = build_payload(report)
    if args.dry_run:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0
    url = os.getenv("TEAMS_WEBHOOK_URL", "").strip()
    if not url:
        raise ValueError(".env에 TEAMS_WEBHOOK_URL을 설정하세요.")
    timeout = float(os.getenv("TEAMS_TIMEOUT", "30"))
    if not 0 < timeout <= 600:
        raise ValueError("TEAMS_TIMEOUT은 0초 초과 600초 이하로 지정하세요.")
    ca_bundle = os.getenv("TEAMS_CA_BUNDLE", "").strip() or None
    status = send_card(payload, url, timeout, ca_bundle)
    print(f"[TEAMS] {target_date} 웹훅 요청 접수: HTTP {status} (채널 게시 여부는 Workflow 실행 기록 확인)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        # Do not expose raw request URLs, credentials, or response bodies.
        message = str(error) if isinstance(error, (ValueError, RuntimeError)) else type(error).__name__
        print(f"[TEAMS ERROR] {message}", file=sys.stderr)
        sys.exit(1)
