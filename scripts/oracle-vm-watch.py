#!/usr/bin/env python3
"""Small, configurable HTTP availability monitor for a Linux VM or any Python 3 host.

This performs real health checks; it does not generate artificial CPU, memory, or
bandwidth load and cannot guarantee that a cloud provider will retain an instance.
"""
from __future__ import annotations

import argparse
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Periodically make HTTP health checks and print their results."
    )
    parser.add_argument(
        "--url", action="append", required=True, dest="urls",
        help="URL to check; repeat this option to check multiple URLs."
    )
    parser.add_argument(
        "--interval", type=float, default=300,
        help="Seconds between rounds (minimum 30; default: 300)."
    )
    parser.add_argument(
        "--timeout", type=float, default=10,
        help="Per-request timeout in seconds (default: 10)."
    )
    parser.add_argument(
        "--user-agent", default="oracle-vm-watch/1.0",
        help="HTTP User-Agent (default: oracle-vm-watch/1.0)."
    )
    parser.add_argument(
        "--once", action="store_true",
        help="Check each URL once, then exit."
    )
    args = parser.parse_args()
    if args.interval < 30:
        parser.error("--interval must be at least 30 seconds")
    if args.timeout <= 0:
        parser.error("--timeout must be greater than zero")
    return args


def check(url: str, timeout: float, user_agent: str) -> tuple[bool, str]:
    request = urllib.request.Request(
        url, headers={"User-Agent": user_agent}, method="GET"
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = response.status
            response.read(1)
            return 200 <= status < 400, f"HTTP {status}"
    except urllib.error.HTTPError as exc:
        return False, f"HTTP {exc.code}"
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        return False, f"{type(exc).__name__}: {exc}"


def main() -> int:
    args = parse_args()
    try:
        while True:
            stamp = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
            for url in args.urls:
                ok, detail = check(url, args.timeout, args.user_agent)
                print(
                    f"{stamp} {'OK' if ok else 'FAIL'} {url} - {detail}",
                    flush=True,
                )
            if args.once:
                return 0
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nStopped.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
