#!/usr/bin/env python3
"""Configurable workload based on the final example in 保活.docx."""
from __future__ import annotations

import os
import random
import statistics
import threading
import time
from collections import defaultdict, deque
from datetime import datetime

import numpy as np
import requests
import yfinance as yf


DEFAULT_SYMBOLS = (
    "EWY SPY QQQ SCHD LWLG QUBT IBM NOK BB CSTM SCHW AIQ CHAT SCHG IBKR AMD INTC "
    "DRAM EUV COHR SPCX GLW AAOI CIEN NBIS AXTI AEHR BE SNDK MU AVGO LITE MRVL "
    "AAPL NVDA MSFT AMZN GOOG META TSLA TSM QCOM TXN ADI NXPI ON ARM WDC STX "
    "KLAC LRCX AMAT ASML TER PSX CDNS SNPS MPWR FORM ONTO ORCL CRM ADBE CSCO "
    "PYPL SQ SHOP NOW SNOW PLTR CRWD DDOG PANW FTNT NET ZS TEAM MDB DOCU UBER "
    "JPM BAC V MA GS MS AXP BLK BX COF VOO IWM XLK SMH SOXX XLC XLF ARKK VTI "
    "VXUS NFLX DIS CMCSA PFE LLY ABBV JNJ UNH XOM CVX"
)


def number(name: str, default: str, minimum: float = 0) -> float:
    value = float(os.getenv(name, default))
    if value < minimum:
        raise ValueError(f"{name} must be >= {minimum}")
    return value


MEMORY_MB = int(number("MEMORY_MB", "256"))
CPU_PERCENT = number("CPU_PERCENT", "10")
DOWNLOAD_MB = int(number("DOWNLOAD_MB", "10"))
DOWNLOAD_INTERVAL = number("DOWNLOAD_INTERVAL", "600", 30)
STOCK_INTERVAL = number("STOCK_INTERVAL", "300", 30)
WEATHER_INTERVAL = number("WEATHER_INTERVAL", "180", 30)
FX_INTERVAL = number("FX_INTERVAL", "120", 30)
CLOUD_INTERVAL = number("CLOUD_INTERVAL", "300", 30)
ANALYTICS_INTERVAL = number("ANALYTICS_INTERVAL", "60", 10)
CYCLE_MIN = int(number("CYCLE_MIN", "420", 30))
CYCLE_MAX = int(number("CYCLE_MAX", "540", 30))
REST_TIME = number("REST_TIME", "60")
SYMBOLS = [s.strip().upper() for s in (os.getenv("SYMBOLS") or DEFAULT_SYMBOLS).replace(",", " ").split()]
DOWNLOAD_URL = os.getenv("DOWNLOAD_URL", "https://speed.cloudflare.com/__down")

if not 0 <= CPU_PERCENT <= 100:
    raise ValueError("CPU_PERCENT must be between 0 and 100")
if CYCLE_MIN > CYCLE_MAX:
    raise ValueError("CYCLE_MIN cannot exceed CYCLE_MAX")
if MEMORY_MB > 8192 or DOWNLOAD_MB > 1000:
    raise ValueError("MEMORY_MB must be <= 8192 and DOWNLOAD_MB <= 1000")

active = threading.Event()
active.set()
stock_history: dict[str, deque[float]] = defaultdict(lambda: deque(maxlen=200))
counts = defaultdict(int)
memory_pool: list[bytearray] = []
lock = threading.Lock()


def log(tag: str, message: str) -> None:
    print(f"{datetime.now().astimezone().isoformat(timespec='seconds')} [{tag}] {message}", flush=True)


def wait_active() -> None:
    while not active.is_set():
        time.sleep(1)


def cycle() -> None:
    while True:
        duration = random.randint(CYCLE_MIN, CYCLE_MAX)
        active.set()
        log("CORE", f"active for {duration}s")
        time.sleep(duration)
        active.clear()
        log("CORE", f"rest for {REST_TIME}s")
        time.sleep(REST_TIME)


def cpu() -> None:
    # Percentage of one CPU core, approximate; Docker applies the overall cap.
    period = 0.2
    while True:
        wait_active()
        start = time.monotonic()
        busy = period * CPU_PERCENT / 100
        while active.is_set() and time.monotonic() - start < busy:
            _ = 1234567 * 7654321
        time.sleep(max(0, period - (time.monotonic() - start)))


def memory() -> None:
    while True:
        wait_active()
        needed = MEMORY_MB - len(memory_pool)
        if needed > 0:
            for _ in range(min(needed, 20)):
                memory_pool.append(bytearray(1024 * 1024))
        elif needed < 0:
            del memory_pool[MEMORY_MB:]
        time.sleep(0.2)


def download() -> None:
    while True:
        wait_active()
        if DOWNLOAD_MB:
            target = DOWNLOAD_MB * 1024 * 1024
            url = f"{DOWNLOAD_URL}?bytes={target}" if "?" not in DOWNLOAD_URL else DOWNLOAD_URL
            started = time.monotonic()
            received = 0
            try:
                with requests.get(url, stream=True, timeout=(10, 30)) as response:
                    response.raise_for_status()
                    for chunk in response.iter_content(65536):
                        if not active.is_set() or received >= target:
                            break
                        received += min(len(chunk), target - received)
                log("DOWNLOAD", f"{received / 1048576:.1f} MiB in {time.monotonic() - started:.1f}s")
            except requests.RequestException as exc:
                log("DOWNLOAD", f"error: {exc}")
        time.sleep(DOWNLOAD_INTERVAL)


def stocks() -> None:
    while True:
        wait_active()
        for symbol in SYMBOLS:
            if not active.is_set():
                break
            try:
                price = float(yf.Ticker(symbol).fast_info["lastPrice"])
                with lock:
                    stock_history[symbol].append(price)
                    counts["stock"] += 1
            except Exception as exc:
                log("STOCK", f"{symbol}: {type(exc).__name__}")
        log("STOCK", f"prices collected: {counts['stock']}")
        time.sleep(STOCK_INTERVAL)


def weather() -> None:
    while True:
        wait_active()
        try:
            response = requests.get("https://wttr.in/?format=3", timeout=10)
            response.raise_for_status()
            log("WEATHER", response.text.strip()[:200])
            counts["weather"] += 1
        except requests.RequestException as exc:
            log("WEATHER", f"error: {exc}")
        time.sleep(WEATHER_INTERVAL)


def fx() -> None:
    while True:
        wait_active()
        try:
            response = requests.get("https://open.er-api.com/v6/latest/USD", timeout=10)
            response.raise_for_status()
            cny = response.json()["rates"]["CNY"]
            log("FX", f"USD/CNY {cny}")
            counts["fx"] += 1
        except (requests.RequestException, KeyError, ValueError) as exc:
            log("FX", f"error: {exc}")
        time.sleep(FX_INTERVAL)


def cloud() -> None:
    urls = ("https://status.azure.com", "https://health.aws.amazon.com", "https://ocistatus.oraclecloud.com")
    while True:
        wait_active()
        for url in urls:
            try:
                response = requests.get(url, timeout=10)
                log("CLOUD", f"{url} HTTP {response.status_code}")
                counts["cloud"] += 1
            except requests.RequestException as exc:
                log("CLOUD", f"{url}: {exc}")
        time.sleep(CLOUD_INTERVAL)


def analytics() -> None:
    while True:
        wait_active()
        with lock:
            snapshot = {key: list(values) for key, values in stock_history.items()}
        report = []
        ranking = []
        for symbol, prices in snapshot.items():
            if len(prices) < 20:
                continue
            recent = np.asarray(prices[-20:], dtype=float)
            mean = statistics.mean(prices[-200:])
            volatility = float(np.std(np.diff(recent)))
            price_volatility = float(np.std(recent) / mean * 100) if mean else 0.0
            ema20 = float(np.mean(recent))
            momentum = float(recent[-1] - recent[0])
            report.append(f"{symbol}: avg={mean:.2f} ma20={ema20:.2f} vol={price_volatility:.2f}%")
            ranking.append((abs(momentum), symbol, momentum, volatility))
        ranking.sort(reverse=True)
        if report:
            log("ANALYTICS", "; ".join(report[:5]))
            log("MARKET SCAN", "; ".join(f"{s} momentum={m:.2f} vol={v:.4f}" for _, s, m, v in ranking[:5]))
        time.sleep(ANALYTICS_INTERVAL)


def status() -> None:
    while True:
        log("STATUS", f"stock={counts['stock']} weather={counts['weather']} fx={counts['fx']} cloud={counts['cloud']} memory={len(memory_pool)}MiB")
        time.sleep(30)


def main() -> None:
    log("CONFIG", f"symbols={len(SYMBOLS)} memory={MEMORY_MB}MiB cpu={CPU_PERCENT}% of one core download={DOWNLOAD_MB}MiB/{DOWNLOAD_INTERVAL}s")
    for name, target in (("cycle", cycle), ("cpu", cpu), ("memory", memory), ("download", download),
                         ("stocks", stocks), ("weather", weather), ("fx", fx), ("cloud", cloud),
                         ("analytics", analytics), ("status", status)):
        threading.Thread(name=name, target=target, daemon=True).start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
