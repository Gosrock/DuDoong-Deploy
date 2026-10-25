#!/usr/bin/env python3
"""nginx 국내 IP 허용 목록(nginx/geo/allow-kr.conf)을 다시 만든다 (Deploy #58).

- KR: APNIC delegated 통계 파일의 KR 할당분 (IPv4·IPv6, allocated/assigned)
- AWS 서울: ip-ranges.json 의 ap-northeast-2 EC2 대역. ARIN(미국) 등록이라 KR 목록에 없다.
  운영·스테이징 EIP, Fargate 배치 공인 IP 가 여기에 속한다

실행: python3 scripts/gen-geo-kr.py  → 결과 파일을 커밋하고 nginx 이미지를 새 태그로 빌드한다.
목록이 비정상적으로 작으면(다운로드 실패·형식 변경) 파일을 쓰지 않고 실패한다.
"""
import ipaddress
import json
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

APNIC_URL = "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest"
AWS_URL = "https://ip-ranges.amazonaws.com/ip-ranges.json"
OUT = Path(__file__).resolve().parent.parent / "nginx" / "geo" / "allow-kr.conf"

# 2026-10 기준 KR IPv4 는 약 1,000개 CIDR. 이보다 훨씬 적으면 데이터가 잘못된 것으로 본다
MIN_KR_V4 = 500
MIN_AWS = 50


def fetch(url: str) -> str:
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read().decode("utf-8")


def kr_networks() -> list:
    nets = []
    for line in fetch(APNIC_URL).splitlines():
        parts = line.split("|")
        if len(parts) < 7 or parts[1] != "KR" or parts[6] not in ("allocated", "assigned"):
            continue
        kind, start, value = parts[2], parts[3], parts[4]
        if kind == "ipv4":
            first = ipaddress.IPv4Address(start)
            last = first + int(value) - 1
            nets.extend(ipaddress.summarize_address_range(first, last))
        elif kind == "ipv6":
            nets.append(ipaddress.IPv6Network(f"{start}/{value}"))
    return nets


def aws_seoul_networks() -> list:
    data = json.loads(fetch(AWS_URL))
    nets = [
        ipaddress.ip_network(p["ip_prefix"])
        for p in data["prefixes"]
        if p["region"] == "ap-northeast-2" and p["service"] == "EC2"
    ]
    nets += [
        ipaddress.ip_network(p["ipv6_prefix"])
        for p in data["ipv6_prefixes"]
        if p["region"] == "ap-northeast-2" and p["service"] == "EC2"
    ]
    return nets


def collapse(nets: list) -> list:
    v4 = list(ipaddress.collapse_addresses(n for n in nets if n.version == 4))
    v6 = list(ipaddress.collapse_addresses(n for n in nets if n.version == 6))
    return v4 + v6


def main() -> int:
    kr = collapse(kr_networks())
    aws = collapse(aws_seoul_networks())
    kr_v4 = sum(1 for n in kr if n.version == 4)
    if kr_v4 < MIN_KR_V4 or len(aws) < MIN_AWS:
        print(f"목록이 너무 작다 (KR IPv4 {kr_v4}, AWS {len(aws)}) — 파일을 쓰지 않는다", file=sys.stderr)
        return 1

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    lines = [
        "# 자동 생성 파일 — 직접 고치지 말 것. scripts/gen-geo-kr.py 로 다시 만든다 (Deploy #58)",
        f"# 생성일 {now} (UTC). KR {len(kr)}개 (APNIC), AWS ap-northeast-2 EC2 {len(aws)}개",
        "# --- KR (APNIC delegated) ---",
        *(f"{n} 1;" for n in kr),
        "# --- AWS ap-northeast-2 EC2 ---",
        *(f"{n} 1;" for n in aws),
    ]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{OUT}: KR {len(kr)}개, AWS {len(aws)}개")
    return 0


if __name__ == "__main__":
    sys.exit(main())
