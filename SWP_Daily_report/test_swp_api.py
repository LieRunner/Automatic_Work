
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


# API 조회 테스트
with requests.Session() as session:

    session.headers.update({
        "Authorization": f"Bearer {API_KEY}",
        "Accept": "application/json"
    })

    for name, query in config["queries"].items():

        print("\n" + "=" * 60)
        print(f"[TEST] {name.upper()}")
        print(f"Query: {query}")

        try:
            response = session.get(
                URL,
                headers={"TMV1-Query": query},
                params=params,
                timeout=config["timeout"],
                verify=True,
                allow_redirects=False
            )

            print(f"HTTP Status: {response.status_code}")

            if response.status_code != 200:
                print(response.text[:2000])
                continue

            data = response.json()
            items = data.get("items", [])

            print(f"Response Keys: {list(data.keys())}")
            print(f"Total Count: {data.get('totalCount', 'N/A')}")
            print(f"Progress Rate: {data.get('progressRate', 'N/A')}")
            print(f"Returned Items: {len(items)}")
            print(f"Next Link Exists: {bool(data.get('nextLink'))}")

            fields = sorted({
                key
                for item in items
                for key in item.keys()
            })

            print("\n[Available Fields]")

            for field in fields:
                print(f" - {field}")

            if args.sample and items:
                print("\n[Sample Event]")
                print(json.dumps(
                    items[0],
                    indent=2,
                    ensure_ascii=False
                ))

        except requests.exceptions.RequestException as e:
            print(f"Request Error: {e}")

        except ValueError as e:
            print(f"Response Parse Error: {e}")

print("\n[TEST COMPLETED]")
