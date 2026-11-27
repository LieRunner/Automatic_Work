#!/usr/bin/env python3
"""SWP daily report: query Explorer, validate, and write a compact XLSX."""
import argparse
import json
import logging
import os
import sys
import time
from collections import Counter
from datetime import date, datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.parse import urljoin, urlsplit
from zoneinfo import ZoneInfo

import requests
from dotenv import load_dotenv
from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill

BASE_DIR = Path(__file__).resolve().parent
LOG = logging.getLogger("swp_daily_report")


def utc_string(value):
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def origin(url):
    parts = urlsplit(url)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password:
        raise ValueError("Invalid HTTPS API URL.")
    return parts.hostname.lower(), parts.port or 443


def configure_logging(directory, report_date, verbose):
    directory.mkdir(parents=True, exist_ok=True)
    LOG.setLevel(logging.INFO)
    LOG.handlers.clear()
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    handler = logging.FileHandler(directory / f"SWP_{report_date}.log", encoding="utf-8")
    handler.setFormatter(formatter)
    LOG.addHandler(handler)
    if verbose:
        handler = logging.StreamHandler(sys.stderr)
        handler.setFormatter(formatter)
        LOG.addHandler(handler)


def retry_delay(response, fallback):
    value = response.headers.get("Retry-After", "").strip()
    try:
        delay = float(value)
    except ValueError:
        try:
            delay = (parsedate_to_datetime(value) - datetime.now(timezone.utc)).total_seconds()
        except (ValueError, TypeError, OverflowError):
            delay = 0
    return max(fallback, delay)


def fetch(session, url, params, query, config):
    retries = int(config["max_retries"])
    for attempt in range(retries + 1):
        time.sleep(float(config["request_interval"]))
        try:
            response = session.get(url, headers={"TMV1-Query": query}, params=params,
                                   timeout=config["timeout"], verify=config["verify_ssl"],
                                   allow_redirects=False)
        except requests.exceptions.SSLError:
            raise RuntimeError("SSL certificate verification failed.") from None
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as error:
            if attempt == retries:
                raise RuntimeError(f"Network request failed: {type(error).__name__}") from None
            wait = float(config["retry_wait"])
        else:
            if response.status_code == 200:
                try:
                    return response.json()
                except ValueError:
                    raise RuntimeError("Invalid JSON response.") from None
            if response.status_code not in {429, 500, 502, 503, 504} or attempt == retries:
                # Do not write raw response bodies or request URLs to logs.
                raise RuntimeError(f"API request failed: HTTP {response.status_code}.")
            wait = retry_delay(response, float(config["retry_wait"]))
            LOG.warning("HTTP %s: retry %s/%s after %.0fs", response.status_code, attempt + 1, retries, wait)
        time.sleep(wait)
    raise RuntimeError("Retry limit exceeded.")


def classify_ips_action(raw):
    """Return a single category per record, plus its original action label."""
    values = [raw] if isinstance(raw, str) else raw
    if raw is None or values == []:
        return "unknown", "(Action missing)"
    if not isinstance(values, list) or not all(isinstance(a, str) for a in values):
        label = json.dumps(raw, ensure_ascii=False, sort_keys=True)
        return "unknown", label
    label = " | ".join(a.strip() or "(empty)" for a in values)
    normalized = [a.strip().casefold() for a in values]
    if all(a in {"detect only", "log", "log only"} or
           a.startswith("detect only:") for a in normalized):
        return "detect", label
    if all(a in {"reset", "block", "deny"} for a in normalized):
        return "block", label
    return "unknown", label


def collect(session, url, params, name, query, config):
    current, current_params = url, params
    trusted_origin = origin(url)
    seen_links, seen_ids = set(), set()
    counts = Counter()
    action_counts, other_actions = Counter(), Counter()
    progress = None
    page = 0
    while current:
        if origin(current) != trusted_origin:
            raise RuntimeError("Untrusted pagination URL.")
        if current in seen_links:
            raise RuntimeError("Repeated pagination URL; search incomplete.")
        seen_links.add(current)
        page += 1
        if page > int(config.get("max_pages", 10000)):
            raise RuntimeError("Pagination safety limit exceeded.")
        data = fetch(session, current, current_params, query, config)
        if not isinstance(data, dict) or not isinstance(data.get("items"), list):
            raise RuntimeError("Missing or invalid items in API response.")
        items = data["items"]
        progress = data.get("progressRate")
        for item in items:
            if not isinstance(item, dict):
                raise RuntimeError("Invalid event record.")
            counts["total"] += 1
            expected_event = "MALWARE_DETECTION" if name == "am" else "DEEP_PACKET_INSPECTION_EVENT"
            if item.get("productCode") != "sds" or item.get("eventName") != expected_event:
                raise RuntimeError(f"Unexpected product/event type in {name.upper()}.")
            uid = item.get("uuid")
            if uid:
                if uid in seen_ids:
                    counts["duplicate_uuid"] += 1
                seen_ids.add(uid)
            else:
                counts["missing_uuid"] += 1
            if name == "am":
                counts["detect"] += 1
                continue
            category, action_label = classify_ips_action(item.get("act"))
            action_counts[action_label] += 1
            rule = item.get("ruleName")
            if not isinstance(rule, str) or not rule.strip():
                counts["missing_rule"] += 1
                continue
            if "memory" in rule.casefold():
                counts["memory"] += 1
                continue
            counts[category] += 1
            if category == "unknown":
                other_actions[action_label] += 1
        LOG.info("%s page=%s progress=%s fetched=%s total=%s", name.upper(), page, progress, len(items), counts["total"])
        link = data.get("nextLink")
        if link and not isinstance(link, str):
            raise RuntimeError("Invalid nextLink.")
        current = urljoin(current, link) if link else None
        current_params = None
    try:
        complete = float(progress) == 100
    except (ValueError, TypeError):
        complete = False
    if not complete:
        raise RuntimeError(f"{name.upper()} search ended before 100%.")
    LOG.info("%s final counts: %s", name.upper(), dict(counts))
    if name == "ips":
        LOG.info("IPS all action counts (including Memory): %s", dict(action_counts))
        if other_actions:
            LOG.warning("IPS other actions (excluded from detect/block): %s", dict(other_actions))
        if counts["total"] != sum(counts[key] for key in ("detect", "block", "memory", "unknown", "missing_rule")):
            raise RuntimeError("IPS record count mismatch.")
    if counts["missing_rule"] or counts["duplicate_uuid"]:
        raise RuntimeError(f"{name.upper()} validation failed: missing rule={counts['missing_rule']}, unknown action={counts['unknown']}, duplicate UUID={counts['duplicate_uuid']}.")
    if counts["missing_uuid"]:
        LOG.warning("%s: %s records lack UUID; duplicate validation limited.", name.upper(), counts["missing_uuid"])
    return counts, other_actions


def format_report(report):
    lines = ["=" * 40, "          Server EDR 일일보고", "=" * 40,
             f"조회일 : {report['target_date']}",
             f"시간대 : 00:00 ~ 익일 00:00 ({report['timezone_label']})", "-" * 40]
    for label, values in (("Anti-Malware", report["am"]), ("IPS", report["ips"])):
        lines.extend([f"[{label}]", f"  탐지 : {values['detect']:>8,}건", f"  차단 : {values['block']:>8,}건", ""])
    if report.get("ips_other"):
        lines.extend(["[IPS 기타 Action - 확인 필요]", "  ※ 탐지·차단 집계 제외"])
        for action, count in report["ips_other"].items():
            label = action.replace("\r", "\\r").replace("\n", "\\n")
            lines.append(f"  {label} : {count:,}건")
        lines.append("")
    return "\n".join(lines[:-1] + ["=" * 40])


def write_xlsx(report, output_dir):
    output_dir.mkdir(parents=True, exist_ok=True)
    target = output_dir / f"SWP_Daily_Report_{report['target_date']}.xlsx"
    temp = target.with_name(f".{target.stem}.{os.getpid()}.xlsx")
    wb = Workbook()
    ws = wb.active
    ws.title = "Summary"
    ws.sheet_view.showGridLines = False
    ws.column_dimensions["A"].width = 5
    ws.column_dimensions["B"].width = 24
    ws.column_dimensions["C"].width = 24
    ws.column_dimensions["D"].width = 5
    for row, text in ((2, "Server EDR 일일보고"), (3, f"조회일: {report['target_date']}"),
                      (4, f"00:00 ~ 익일 00:00 ({report['timezone_label']})")):
        ws.merge_cells(start_row=row, start_column=2, end_row=row, end_column=3)
        cell = ws.cell(row, 2, text)
        cell.alignment = Alignment(horizontal="center", vertical="center")
        cell.font = Font(name="맑은 고딕", size=18 if row == 2 else 11, bold=row == 2,
                         color="FFFFFF" if row == 2 else "475569")
        if row == 2:
            cell.fill = PatternFill("solid", fgColor="24364B")
        ws.row_dimensions[row].height = 34 if row == 2 else 22
    for row, label, values in ((6, "Anti-Malware", report["am"]), (11, "IPS", report["ips"])):
        ws.merge_cells(start_row=row, start_column=2, end_row=row, end_column=3)
        header = ws.cell(row, 2, label)
        header.font = Font(name="맑은 고딕", bold=True, size=13, color="FFFFFF")
        header.fill = PatternFill("solid", fgColor="36516D")
        header.alignment = Alignment(horizontal="center", vertical="center")
        ws.row_dimensions[row].height = 27
        for col, key, caption, color, fill in ((2, "detect", "탐지", "A65D13", "FFF3DE"),
                                               (3, "block", "차단", "137348", "E6F5EC")):
            h = ws.cell(row + 1, col, caption)
            v = ws.cell(row + 2, col, values[key])
            for cell in (h, v):
                cell.alignment = Alignment(horizontal="center", vertical="center")
                cell.fill = PatternFill("solid", fgColor=fill)
            h.font = Font(name="맑은 고딕", size=11, bold=True, color=color)
            v.font = Font(name="맑은 고딕", size=24, bold=True, color=color)
            v.number_format = '#,##0"건"'
        ws.row_dimensions[row + 1].height = 24
        ws.row_dimensions[row + 2].height = 43
    ws.print_options.horizontalCentered = True
    last_row = 15
    if report.get("ips_other"):
        ws.merge_cells("B16:C16")
        cell = ws["B16"]
        cell.value = "IPS 기타 Action (확인 필요)"
        cell.font = Font(name="맑은 고딕", bold=True, color="FFFFFF", size=12)
        cell.fill = PatternFill("solid", fgColor="8A611B")
        cell.alignment = Alignment(horizontal="center", vertical="center")
        ws.row_dimensions[16].height = 27
        ws.merge_cells("B17:C17")
        ws["B17"] = "탐지·차단 집계에서 제외"
        ws["B17"].alignment = Alignment(horizontal="center", vertical="center")
        ws["B17"].font = Font(name="맑은 고딕", size=10, color="8A611B")
        for row, (action, count) in enumerate(report["ips_other"].items(), start=18):
            label = ws.cell(row, 2, action)
            label.data_type = "s"  # API text must never become an Excel formula.
            label.alignment = Alignment(wrap_text=True, vertical="center")
            label.font = Font(name="맑은 고딕", size=11)
            value = ws.cell(row, 3, count)
            value.number_format = '#,##0"건"'
            value.alignment = Alignment(horizontal="center", vertical="center")
            value.font = Font(name="맑은 고딕", size=12, bold=True)
            for c in (label, value):
                c.fill = PatternFill("solid", fgColor="FFF3DE")
            ws.row_dimensions[row].height = min(120, max(26, 16 * ((len(action) + 21) // 22)))
            last_row = row + 1
    ws.print_area = f"A1:D{last_row}"
    try:
        wb.save(temp)
        os.replace(temp, target)
    finally:
        if temp.exists():
            temp.unlink()
    return target


def main():
    parser = argparse.ArgumentParser(description="SWP daily report")
    parser.add_argument("--date", type=date.fromisoformat, help="Report reference date (YYYY-MM-DD)")
    parser.add_argument("--verbose", action="store_true", help="Also show progress on stderr")
    args = parser.parse_args()
    load_dotenv(BASE_DIR / ".env")
    with (BASE_DIR / "config.json").open(encoding="utf-8-sig") as file:
        config = json.load(file)
    for key in ("request_interval", "retry_wait", "max_retries"):
        if config[key] < 0:
            raise ValueError(f"Invalid configuration: {key}")
    if not isinstance(config["verify_ssl"], bool) and not isinstance(config["verify_ssl"], str):
        raise ValueError("Invalid verify_ssl value.")
    tz = ZoneInfo(config["timezone"])
    reference = args.date or datetime.now(tz).date()
    end = datetime.combine(reference, datetime.min.time(), tzinfo=tz)
    start = end - timedelta(days=1)
    if end > datetime.now(tz):
        raise ValueError("Report period has not ended.")
    target_date = start.date().isoformat()
    configure_logging(BASE_DIR / config.get("log_directory", "logs"), target_date, args.verbose)
    base_url = os.environ["VISION_ONE_BASE_URL"].strip().rstrip("/")
    token = (os.getenv("VISION_ONE_API_TOKEN") or os.getenv("VISION_ONE_API_KEY") or "").strip()
    if not token or token.lower().startswith("bearer "):
        raise ValueError("Set the raw API token in .env without Bearer prefix.")
    url = base_url + config["endpoint"]
    if origin(base_url) != origin(url):
        raise ValueError("Invalid API endpoint.")
    params = {"startDateTime": utc_string(start), "endDateTime": utc_string(end),
              "top": config["top"], "mode": config["mode"]}
    LOG.info("Report period: %s to %s", start.isoformat(), end.isoformat())
    if config["verify_ssl"] is False:
        LOG.warning("TLS certificate verification is disabled. Token exposure risk.")
    with requests.Session() as session:
        session.headers.update({"Authorization": f"Bearer {token}", "Accept": "application/json"})
        am, _ = collect(session, url, params, "am", config["queries"]["am"], config)
        ips, other_actions = collect(session, url, params, "ips", config["queries"]["ips"], config)
    # All output channels use this one validated report object.
    report = {"target_date": target_date, "start": start.isoformat(), "end": end.isoformat(),
              "timezone_label": "KST" if config["timezone"] == "Asia/Seoul" else config["timezone"],
              "am": {"detect": am["detect"], "block": 0},
              "ips": {"detect": ips["detect"], "block": ips["block"]},
              "ips_other": dict(sorted(other_actions.items()))}
    target = write_xlsx(report, BASE_DIR / config.get("output_directory", "reports"))
    LOG.info("XLSX saved: %s", target.name)
    print(format_report(report))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        # A failed run never publishes a new report. Existing output is untouched.
        message = str(exc) if isinstance(exc, (RuntimeError, ValueError, KeyError, FileNotFoundError)) else type(exc).__name__
        LOG.error("Report failed: %s", message)
        print(f"[ERROR] {message} (보고서 생성 중단)", file=sys.stderr)
        sys.exit(1)
