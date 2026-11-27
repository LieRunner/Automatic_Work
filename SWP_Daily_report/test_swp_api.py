
import os
import json
import argparse
import requests

from pathlib import Path
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from dotenv import load_dotenv


# 설정 파일 불러오기
BASE_DIR = Path(__file__).resolve().parent

load_dotenv(BASE_DIR / ".env")

with open(
    BASE_DIR / "config.json",
    encoding="utf-8"
) as f:
    config = json.load(f)

BASE_URL = os.environ["VISION_ONE_BASE_URL"].rstrip("/")
API_KEY = os.environ["VISION_ONE_API_KEY"]

if not BASE_URL.startswith("https://"):
    raise ValueError("HTTPS API URL is required.")

URL = BASE_URL + config["endpoint"]
KST = ZoneInfo(config["timezone"])


# 조회 날짜 설정
parser = argparse.ArgumentParser()

parser.add_argument(
    "--date",
    type=lambda s: datetime.strptime(s, "%Y-%m-%d").date(),
    default=datetime.now(KST).date()
)

parser.add_argument(
    "--sample",
    action="store_true"
)

args = parser.parse_args()

end_kst = datetime.combine(
    args.date,
    datetime.min.time(),
    tzinfo=KST
)

start_kst = end_kst - timedelta(days=1)

params = {
    "startDateTime": start_kst.astimezone(
        timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ"),

    "endDateTime": end_kst.astimezone(
        timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ"),

    "top": config["top"],
    "mode": config["mode"]
}


# 조회 기간 출력
print("=" * 60)
print("SWP API TEST")
print("=" * 60)

print(f"Start (KST): {start_kst}")
print(f"End   (KST): {end_kst}")
print(f"Start (UTC): {params['startDateTime']}")
print(f"End   (UTC): {params['endDateTime']}")



# API 조회 및 전체 집계 테스트
from collections import Counter
from urllib.parse import urljoin, urlsplit

with requests.Session() as session:

    session.headers.update({
        "Authorization": f"Bearer {API_KEY}",
        "Accept": "application/json"
    })

    for name, query in config["queries"].items():

        print("\n" + "=" * 60)
        print(f"[TEST] {name.upper()}")
        print(f"Query: {query}")

        next_url = URL
        request_params = params
        page = 0
        progress = None

        counts = Counter()
        weighted = Counter()
        actions = Counter()
        memory_rules = Counter()

        try:
            while next_url:

                # API Token이 다른 도메인으로 전달되는 것을 방지
                if (
                    urlsplit(next_url).scheme != "https"
                    or urlsplit(next_url).netloc !=
                    urlsplit(URL).netloc
                ):
                    raise ValueError("Invalid nextLink host.")

                response = session.get(
                    next_url,
                    headers={"TMV1-Query": query},
                    params=request_params,
                    timeout=config["timeout"],
                    verify=config["verify_ssl"],
                    allow_redirects=False
                )

                if response.status_code != 200:
                    raise RuntimeError(
                        f"HTTP {response.status_code}: "
                        f"{response.text[:1000]}"
                    )

                data = response.json()
                items = data["items"]
                progress = data.get("progressRate")
                page += 1

                for item in items:

                    counts["total"] += 1

                    if name.lower() == "am":
                        continue

                    rule_name = item.get("ruleName") or ""

                    raw_action = item.get("act") or []

                    if isinstance(raw_action, str):
                        raw_action = [raw_action]

                    action = " | ".join(raw_action)
                    actions[action or "Missing"] += 1

                    try:
                        count = int(item["aggregatedCount"])
                        if count < 1:
                            raise ValueError
                        weighted["total"] += count
                    except (KeyError, ValueError, TypeError):
                        counts["missing_count"] += 1
                        count = 0

                    if not rule_name:
                        counts["missing_rule"] += 1
                        category = "missing_rule"

                    elif "memory" in rule_name.casefold():
                        memory_rules[rule_name] += 1
                        category = "memory"

                    elif raw_action and all(
                        a.casefold().startswith("detect only:")
                        for a in raw_action
                    ):
                        category = "detect"

                    elif raw_action and all(
                        a.casefold() in {"reset", "block"}
                        for a in raw_action
                    ):
                        category = "block"

                    else:
                        category = "unknown"

                    counts[category] += 1
                    weighted[category] += count

                print(
                    f"Page: {page} | "
                    f"Progress: {progress}% | "
                    f"Fetched: {len(items)} | "
                    f"Total: {counts['total']}"
                )

                link = data.get("nextLink")
                next_url = urljoin(URL, link) if link else None

                # nextLink에 포함된 파라미터 사용
                request_params = None

            if str(progress) != "100":
                raise RuntimeError(
                    "Search ended before progress reached 100."
                )

        except (
            requests.exceptions.RequestException,
            RuntimeError,
            ValueError,
            KeyError
        ) as error:

            print(f"\n[TEST FAILED] {error}")
            print("Partial results only. Do not use for reporting.")
            continue

        print("\n[FINAL RESULTS]")
        print(f"Total Pages   : {page}")
        print(f"Progress      : {progress}%")
        print(f"Total Records : {counts['total']}")

        if name.lower() == "ips":

            print("\n[Record Count]")
            print(f"Detect       : {counts['detect']}")
            print(f"Block        : {counts['block']}")
            print(f"Memory       : {counts['memory']}")
            print(f"Unknown      : {counts['unknown']}")
            print(f"Missing Rule : {counts['missing_rule']}")

            print("\n[Aggregated Count]")
            print(f"Total        : {weighted['total']}")
            print(f"Detect       : {weighted['detect']}")
            print(f"Block        : {weighted['block']}")
            print(f"Memory       : {weighted['memory']}")
            print(f"Unknown      : {weighted['unknown']}")
            print(f"Missing Rule : {weighted['missing_rule']}")
            print(f"Invalid Count Records : {counts['missing_count']}")

            print("\n[Action Values]")

            for action, count in actions.items():
                print(f" - {action}: {count}")

            print("\n[Memory Rule Names]")

            for rule, count in memory_rules.items():
                print(f" - {rule}: {count}")

print("\n[TEST COMPLETED]")
